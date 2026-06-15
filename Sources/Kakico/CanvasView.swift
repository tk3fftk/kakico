import SwiftUI
import AppKit
import CoreGraphics
import AnnotationModel
import AnnotationRender

private class MinimalTextView: NSTextView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.items.removeAll { item in
            if let action = item.action {
                return blockedMenuActions.contains(action)
            }
            return blockedMenuTitles.contains(item.title)
        }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
    }
}

// MARK: - SwiftUI bridge

struct CanvasView: NSViewRepresentable {
    @ObservedObject var controller: CanvasController

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {
        view.controller = controller
        view.refresh()
    }
}

// MARK: - AppKit canvas

final class CanvasNSView: NSView {
    weak var controller: CanvasController?

    private enum Drag {
        case none
        case moving(ElementID, last: CGPoint)
        case handle(ElementID, HandleRole)
        case creating(ElementID, HandleRole)
        case cropping(anchor: CGPoint)
        case movingCrop(last: CGPoint)
    }
    private var drag: Drag = .none
    private var flattened: CGImage?
    // Cache key for `flattened`: re-render only when the content it shows
    // (document sans crop + base image) actually changes, not on every redraw.
    private var flattenedKey: Document?
    private var flattenedBase: CGImage?
    private var textEditor: NSTextView?
    private var editingTextID: ElementID?
    private var antsTimer: Timer?
    private var antsPhase: CGFloat = 0

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        needsDisplay = true
    }

    // MARK: Coordinate mapping

    private var canvasSize: CGSize { controller?.document?.canvasSize ?? .zero }

    private var displayScale: CGFloat {
        let s = canvasSize
        guard s.width > 0, s.height > 0 else { return 1 }
        return min(bounds.width / s.width, bounds.height / s.height)
    }

    private var displayRect: CGRect {
        let s = canvasSize
        let scale = displayScale
        let w = s.width * scale, h = s.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func modelToView(_ p: CGPoint) -> CGPoint {
        let r = displayRect, scale = displayScale
        return CGPoint(x: r.minX + p.x * scale,
                       y: r.minY + (canvasSize.height - p.y) * scale)
    }

    private func viewToModel(_ p: CGPoint) -> CGPoint {
        let r = displayRect, scale = displayScale
        guard scale > 0 else { return .zero }
        return CGPoint(x: (p.x - r.minX) / scale,
                       y: canvasSize.height - (p.y - r.minY) / scale)
    }

    private var modelTolerance: CGFloat { 8 / max(displayScale, 0.0001) }

    private func viewRect(forModelRect box: CGRect) -> CGRect {
        CGRect(corner: modelToView(CGPoint(x: box.minX, y: box.minY)),
               modelToView(CGPoint(x: box.maxX, y: box.maxY)))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let controller, let doc = controller.document else { return }

        // Display always shows the full canvas; a pending crop is shown as
        // an overlay, not by shrinking the flattened image.
        var displayDoc = doc
        displayDoc.crop = nil
        if flattened == nil || flattenedKey != displayDoc || flattenedBase !== controller.baseImage {
            flattened = Renderer.flatten(displayDoc, baseImage: controller.baseImage, scale: 1)
            flattenedKey = displayDoc
            flattenedBase = controller.baseImage
        }
        if let img = flattened {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: displayRect)
        }

        // Crop dimming + outline.
        if let crop = doc.crop {
            drawCropOverlay(crop, in: ctx)
        }
        updateAntsTimer(cropVisible: doc.crop != nil)

        // Selection handles.
        if let sel = controller.selection, let element = doc.elements.first(where: { $0.id == sel }) {
            drawSelection(element, in: ctx)
        }
    }

    private func drawHandle(at center: CGPoint, stroke: NSColor, lineWidth: CGFloat, in ctx: CGContext) {
        let hr = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(hr)
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.stroke(hr)
    }

    private func drawSelection(_ element: Annotation, in ctx: CGContext) {
        let viewBox = viewRect(forModelRect: element.boundingBox())
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(viewBox.insetBy(dx: -2, dy: -2))
        ctx.setLineDash(phase: 0, lengths: [])

        for handle in element.handles() {
            drawHandle(at: modelToView(handle.position),
                       stroke: NSColor.controlAccentColor, lineWidth: 1.5, in: ctx)
        }
    }

    private func drawCropOverlay(_ crop: CGRect, in ctx: CGContext) {
        let viewCrop = viewRect(forModelRect: crop)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(displayRect)
        ctx.clear(viewCrop)
        if let img = flattened {
            ctx.saveGState()
            ctx.clip(to: viewCrop)
            ctx.draw(img, in: displayRect)
            ctx.restoreGState()
        }
        // Marching ants (phase advanced by `antsTimer`).
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: antsPhase, lengths: [5, 4])
        ctx.stroke(viewCrop)
        ctx.setLineDash(phase: 0, lengths: [])

        // Corner handles so the crop rect is re-editable with the crop tool.
        for handle in viewCrop.cornerHandles() {
            drawHandle(at: handle.position,
                       stroke: NSColor.black.withAlphaComponent(0.6), lineWidth: 1, in: ctx)
        }
    }

    private func updateAntsTimer(cropVisible: Bool) {
        if cropVisible, antsTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.antsPhase += 1
                self.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            antsTimer = timer
        } else if !cropVisible, let timer = antsTimer {
            timer.invalidate()
            antsTimer = nil
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            antsTimer?.invalidate()
            antsTimer = nil
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        guard let controller, controller.document != nil else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let p = viewToModel(viewPoint)
        controller.beginInteraction()

        // Double-click a text element (in any tool) to edit it.
        if event.clickCount == 2,
           let id = controller.document?.hitTest(p, tolerance: modelTolerance),
           case .text = controller.document?.elements.first(where: { $0.id == id }) {
            controller.selection = id
            drag = .none
            beginTextEditing(for: id)
            return
        }

        switch controller.tool {
        case .select:
            handleSelectMouseDown(at: p, viewPoint: viewPoint)
        case .crop:
            handleCropMouseDown(at: p, viewPoint: viewPoint)
        case .text:
            createText(at: p)
        default:
            createElement(tool: controller.tool, at: p)
        }
        refresh()
    }

    private func handleSelectMouseDown(at p: CGPoint, viewPoint: CGPoint) {
        guard let controller, let doc = controller.document else { return }
        // Handle grab on the current selection first.
        if let sel = controller.selection, let element = doc.elements.first(where: { $0.id == sel }) {
            for handle in element.handles() {
                if hypot(modelToView(handle.position).x - viewPoint.x,
                         modelToView(handle.position).y - viewPoint.y) <= 8 {
                    drag = .handle(sel, handle.role)
                    return
                }
            }
        }
        // Otherwise select / start moving the topmost hit element.
        if let hit = doc.hitTest(p, tolerance: modelTolerance) {
            controller.selection = hit
            drag = .moving(hit, last: p)
        } else {
            controller.selection = nil
            drag = .none
        }
    }

    /// Crop tool: grab a corner of an existing crop rect (drag resizes against
    /// the opposite corner), drag inside it to move it, or start a new rect.
    private func handleCropMouseDown(at p: CGPoint, viewPoint: CGPoint) {
        if let crop = controller?.document?.crop, crop.width > 0, crop.height > 0 {
            let handles = crop.cornerHandles()
            for handle in handles {
                let v = modelToView(handle.position)
                if hypot(v.x - viewPoint.x, v.y - viewPoint.y) <= 8,
                   let anchor = handles.first(where: { $0.role == handle.role.opposite }) {
                    drag = .cropping(anchor: anchor.position)
                    return
                }
            }
            if crop.contains(p) {
                drag = .movingCrop(last: p)
                return
            }
        }
        controller?.document?.crop = CGRect(corner: p, p)
        drag = .cropping(anchor: p)
    }

    private func createElement(tool: Tool, at p: CGPoint) {
        guard let controller else { return }
        let color = controller.strokeColor
        let width = controller.strokeWidth
        let zeroRect = CGRect(corner: p, p)
        let new: Annotation
        var role: HandleRole = .bottomRight
        switch tool {
        case .arrow:
            new = .arrow(SegmentElement(start: p, end: p, color: color, width: width)); role = .end
        case .line:
            new = .line(SegmentElement(start: p, end: p, color: color, width: width)); role = .end
        case .rectangle:
            new = .rectangle(ShapeElement(rect: zeroRect, color: color, width: width))
        case .ellipse:
            new = .ellipse(ShapeElement(rect: zeroRect, color: color, width: width))
        case .pixelate:
            new = .pixelate(RedactionElement(rect: zeroRect, amount: RedactionElement.defaultPixelateAmount))
        default:
            return
        }
        controller.document?.add(new)
        controller.selection = new.id
        drag = .creating(new.id, role)
    }

    private func createText(at p: CGPoint) {
        guard let controller else { return }
        let element = TextElement(origin: p, size: CGSize(width: 220, height: 44),
                                  string: "",
                                  font: FontSpec(pointSize: FontSpec.suggestedPointSize(forStrokeWidth: controller.strokeWidth)),
                                  color: controller.strokeColor)
        controller.document?.add(.text(element))
        controller.selection = element.id
        drag = .none
        refresh()
        beginTextEditing(for: element.id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller else { return }
        let p = viewToModel(convert(event.locationInWindow, from: nil))
        switch drag {
        case .none:
            return
        case .moving(let id, let last):
            let delta = CGVector(dx: p.x - last.x, dy: p.y - last.y)
            controller.document?.mutate(id) { $0.translate(by: delta) }
            drag = .moving(id, last: p)
        case .handle(let id, let role), .creating(let id, let role):
            controller.document?.mutate(id) { $0.moveHandle(role, to: p) }
        case .cropping(let anchor):
            controller.document?.crop = CGRect(corner: anchor, p)
        case .movingCrop(let last):
            if let crop = controller.document?.crop {
                controller.document?.crop = crop.offsetBy(dx: p.x - last.x, dy: p.y - last.y)
            }
            drag = .movingCrop(last: p)
        }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        // Drop degenerate freshly-created elements.
        if case .creating(let id, _) = drag,
           let element = controller.document?.elements.first(where: { $0.id == id }),
           element.boundingBox().width < 3, element.boundingBox().height < 3 {
            controller.document?.remove(id)
            controller.selection = nil
        }
        // Keep the crop rect within the canvas; drop degenerate ones.
        switch drag {
        case .cropping, .movingCrop:
            if let doc = controller.document, let crop = doc.crop {
                controller.document?.crop = doc.clampedCrop(crop)
            }
        default:
            break
        }
        drag = .none
        controller.commitInteraction()
        refresh()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 51, 117: // delete / forward-delete
            controller.deleteSelection()
            refresh()
        case 36, 76: // return / keypad enter — apply pending crop
            if controller.document?.crop != nil {
                controller.applyCrop()
                refresh()
            } else {
                super.keyDown(with: event)
            }
        case 53: // escape — cancel pending crop, else clear selection
            if controller.document?.crop != nil {
                controller.cancelCrop()
            } else {
                controller.selection = nil
            }
            refresh()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Inline text editing

    private func beginTextEditing(for id: ElementID) {
        guard let controller,
              let element = controller.document?.elements.first(where: { $0.id == id }),
              case .text(let text) = element else { return }
        commitTextEditing()

        let tv = MinimalTextView(frame: viewRect(forModelRect: element.boundingBox()).insetBy(dx: -2, dy: -2))
        tv.string = text.string
        tv.font = nsFont(for: text.font, scale: displayScale)
        tv.textColor = nsColor(text.color)
        tv.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        tv.isRichText = false
        tv.drawsBackground = true
        tv.delegate = self
        addSubview(tv)
        window?.makeFirstResponder(tv)
        textEditor = tv
        editingTextID = id
    }

    func commitTextEditing() {
        guard let tv = textEditor, let id = editingTextID, let controller else { return }
        let newString = tv.string
        tv.removeFromSuperview()
        textEditor = nil
        editingTextID = nil

        if newString.isEmpty {
            controller.perform { $0.remove(id) }
            if controller.selection == id { controller.selection = nil }
        } else {
            controller.perform { doc in
                doc.mutate(id) { annotation in
                    if case .text(var t) = annotation {
                        t.string = newString
                        annotation = .text(t)
                    }
                }
            }
        }
        refresh()
    }

    private func nsColor(_ c: RGBAColor) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    private func nsFont(for spec: FontSpec, scale: CGFloat) -> NSFont {
        let size = spec.pointSize * scale
        let base = NSFont(name: spec.family, size: size) ?? NSFont.systemFont(ofSize: size)
        if spec.bold {
            return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        }
        return base
    }

    // MARK: Drag & drop import

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL],
           let url = urls.first {
            controller?.loadImage(at: url)
            refresh()
            return true
        }
        if let objs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = objs.first?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            controller?.loadImage(img)
            refresh()
            return true
        }
        return false
    }
}

extension CanvasNSView: NSTextViewDelegate {
    func textDidEndEditing(_ notification: Notification) {
        commitTextEditing()
    }
}
