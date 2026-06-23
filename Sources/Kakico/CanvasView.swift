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
    var controller: CanvasController

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
    weak var controller: CanvasController? {
        didSet {
            guard controller !== oldValue else { return }
            startObserving()
        }
    }

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
    private var flattenedBounds: ExportBounds?
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

    private func startObserving() {
        guard let controller else { return }
        withObservationTracking {
            _ = controller.document
            _ = controller.baseImage
            _ = controller.selection
            _ = controller.exportBounds
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.startObserving()
            }
        }
    }

    // MARK: Coordinate mapping

    private struct DisplayInfo {
        let canvas: CGRect
        let scale: CGFloat
        let rect: CGRect

        func modelToView(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + (p.x - canvas.origin.x) * scale,
                    y: rect.minY + (canvas.height - (p.y - canvas.origin.y)) * scale)
        }

        func viewToModel(_ p: CGPoint) -> CGPoint {
            guard scale > 0 else { return .zero }
            return CGPoint(x: canvas.origin.x + (p.x - rect.minX) / scale,
                           y: canvas.origin.y + canvas.height - (p.y - rect.minY) / scale)
        }

        var modelTolerance: CGFloat { 8 / max(scale, 0.0001) }

        func viewRect(forModelRect box: CGRect) -> CGRect {
            CGRect(corner: modelToView(CGPoint(x: box.minX, y: box.minY)),
                   modelToView(CGPoint(x: box.maxX, y: box.maxY)))
        }
    }

    private var displayDocument: Document? {
        guard var doc = controller?.document else { return nil }
        doc.crop = nil
        return doc
    }

    private var displayInfo: DisplayInfo {
        let canvas: CGRect
        if let controller, let doc = displayDocument {
            canvas = doc.outputRect(for: controller.exportBounds)
        } else {
            canvas = CGRect(origin: .zero, size: .zero)
        }
        guard canvas.width > 0, canvas.height > 0 else {
            return DisplayInfo(canvas: canvas, scale: 1, rect: .zero)
        }
        let scale = min(bounds.width / canvas.width, bounds.height / canvas.height)
        let w = canvas.width * scale, h = canvas.height * scale
        let rect = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        return DisplayInfo(canvas: canvas, scale: scale, rect: rect)
    }

    private var displayScale: CGFloat { displayInfo.scale }
    private var displayRect: CGRect { displayInfo.rect }

    private func modelToView(_ p: CGPoint) -> CGPoint { displayInfo.modelToView(p) }
    private func viewToModel(_ p: CGPoint) -> CGPoint { displayInfo.viewToModel(p) }
    private var modelTolerance: CGFloat { displayInfo.modelTolerance }
    private func viewRect(forModelRect box: CGRect) -> CGRect { displayInfo.viewRect(forModelRect: box) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let controller, let doc = controller.document,
              let displayDoc = displayDocument else { return }
        let exportBounds = controller.exportBounds
        if flattened == nil || flattenedKey != displayDoc || flattenedBase !== controller.baseImage || flattenedBounds != exportBounds {
            flattened = Renderer.flatten(displayDoc, baseImage: controller.baseImage, scale: 1,
                                        bounds: exportBounds)
            flattenedKey = displayDoc
            flattenedBase = controller.baseImage
            flattenedBounds = exportBounds
        }
        let info = displayInfo
        if let img = flattened {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: info.rect)
        }

        // Crop dimming + outline.
        if let crop = doc.crop {
            drawCropOverlay(crop, info: info, in: ctx)
        }
        updateAntsTimer(cropVisible: doc.crop != nil)

        // Selection handles.
        if let sel = controller.selection, let element = doc.elements.first(where: { $0.id == sel }) {
            drawSelection(element, info: info, in: ctx)
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

    private func drawSelection(_ element: Annotation, info: DisplayInfo, in ctx: CGContext) {
        let viewBox = info.viewRect(forModelRect: element.boundingBox())
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(viewBox.insetBy(dx: -2, dy: -2))
        ctx.setLineDash(phase: 0, lengths: [])

        for handle in element.handles() {
            drawHandle(at: info.modelToView(handle.position),
                       stroke: NSColor.controlAccentColor, lineWidth: 1.5, in: ctx)
        }
    }

    private func drawCropOverlay(_ crop: CGRect, info: DisplayInfo, in ctx: CGContext) {
        let viewCrop = info.viewRect(forModelRect: crop)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(info.rect)
        ctx.clear(viewCrop)
        if let img = flattened {
            ctx.saveGState()
            ctx.clip(to: viewCrop)
            ctx.draw(img, in: info.rect)
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
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.antsPhase += 1
                    self.needsDisplay = true
                }
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
        let info = displayInfo
        let viewPoint = convert(event.locationInWindow, from: nil)
        let p = info.viewToModel(viewPoint)
        controller.beginInteraction()

        // Double-click a text element (in any tool) to edit it.
        if event.clickCount == 2,
           let id = controller.document?.hitTest(p, tolerance: info.modelTolerance),
           case .text = controller.document?.elements.first(where: { $0.id == id }) {
            controller.selection = id
            drag = .none
            beginTextEditing(for: id)
            return
        }

        switch controller.tool {
        case .select:
            handlePointerMouseDown(at: p, creationTool: nil, info: info)
        case .crop:
            handleCropMouseDown(at: p, viewPoint: viewPoint, info: info)
        default:
            handlePointerMouseDown(at: p, creationTool: controller.tool, info: info)
        }
        refresh()
    }

    /// Shared pointer handling for `select` and creation tools. A handle on the
    /// current selection resizes; a body hit selects and moves. On empty space
    /// `select` clears the selection, while a creation tool creates a new element.
    /// The active tool is never changed.
    private func handlePointerMouseDown(at p: CGPoint, creationTool: Tool?, info: DisplayInfo) {
        guard let controller, let doc = controller.document else { return }
        switch doc.resolvePointer(at: p, selection: controller.selection,
                                  bodyTolerance: info.modelTolerance, handleTolerance: info.modelTolerance) {
        case .handle(let id, let role):
            drag = .handle(id, role)
        case .body(let id):
            controller.selection = id
            drag = .moving(id, last: p)
        case .empty:
            guard let tool = creationTool else {
                controller.selection = nil
                drag = .none
                return
            }
            if tool == .text { createText(at: p) } else { createElement(tool: tool, at: p) }
        }
    }

    /// Crop tool: grab a corner of an existing crop rect (drag resizes against
    /// the opposite corner), drag inside it to move it, or start a new rect.
    private func handleCropMouseDown(at p: CGPoint, viewPoint: CGPoint, info: DisplayInfo) {
        if let crop = controller?.document?.crop, crop.width > 0, crop.height > 0 {
            let handles = crop.cornerHandles()
            for handle in handles {
                let v = info.modelToView(handle.position)
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
        let info = displayInfo
        let p = info.viewToModel(convert(event.locationInWindow, from: nil))
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
        // A plain click (no real drag) leaves a degenerate element: give it a
        // default initial size, Skitch-style, rather than dropping it. Drag-
        // created elements keep their size (the helper is a no-op for them).
        if case .creating(let id, _) = drag {
            controller.document?.mutate(id) { $0 = $0.applyingDefaultInitialSize() }
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

        let info = displayInfo
        let tv = MinimalTextView(frame: info.viewRect(forModelRect: element.boundingBox()).insetBy(dx: -2, dy: -2))
        tv.string = text.string
        tv.font = nsFont(for: text.font, scale: info.scale)
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
