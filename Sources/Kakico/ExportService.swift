import Foundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import AnnotationModel
import AnnotationRender

@MainActor
enum ExportService {

    /// Flattens the current document honoring crop.
    static func flatten(_ controller: CanvasController, scale: CGFloat = 1) -> CGImage? {
        guard let doc = controller.document else { return nil }
        return Renderer.flatten(doc, baseImage: controller.baseImage, scale: scale,
                               bounds: controller.exportBounds)
    }

    /// Flattened document as PNG bytes (for clipboard / drag-out).
    static func pngData(_ controller: CanvasController, scale: CGFloat = 1) -> Data? {
        guard let cg = flatten(controller, scale: scale) else { return nil }
        return Renderer.encode(cg, as: .png)
    }

    static func copyToClipboard(_ controller: CanvasController) {
        guard let cg = flatten(controller) else { NSSound.beep(); return }
        // Write concrete PNG + TIFF bytes instead of an NSImage promise:
        // promised data can resolve late (or not at all for clipboard
        // managers), and PNG-only consumers never see NSImage's TIFF-first
        // offering. Toast only after both writes actually succeed.
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]),
              let tiff = rep.tiffRepresentation else {
            NSSound.beep(); return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        guard pb.setData(png, forType: .png), pb.setData(tiff, forType: .tiff) else {
            NSSound.beep(); return
        }
        controller.flashToast("Copied to clipboard")
    }

    private static let exportFormatKey = "exportFormat"

    /// Last format chosen in the export panel; also its initial selection.
    static var lastExportFormat: ExportFormat {
        get { UserDefaults.standard.rawRepresentable(forKey: exportFormatKey, default: .png) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: exportFormatKey) }
    }

    static func exportPanel(_ controller: CanvasController) {
        guard controller.hasDocument else { NSSound.beep(); return }
        let panel = NSSavePanel()
        let format = lastExportFormat
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        let base = controller.sourceURL?.deletingPathExtension().lastPathComponent ?? "annotated"
        panel.nameFieldStringValue = "\(base).\(format.filenameExtension)"
        let accessory = ExportFormatAccessory(selected: format) { [weak panel] format in
            // With a single allowed type the panel rewrites the typed
            // extension to match.
            panel?.allowedContentTypes = [format.utType]
        }
        panel.accessoryView = accessory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // With a single allowed type the panel forces the extension to
            // match, so the selection is the format. Persist it only on save
            // so a cancelled panel doesn't rewrite the sticky default.
            lastExportFormat = accessory.selected
            export(controller, to: url, as: accessory.selected)
        }
    }

    static func export(_ controller: CanvasController, to url: URL, as format: ExportFormat) {
        // Some formats cap the pixel size (WebP: 16383 px per side); check
        // before the expensive flatten so the user gets a reason instead of
        // a silent failure.
        if let limit = format.maxPixelDimension, let doc = controller.document {
            let out = doc.outputRect(for: controller.exportBounds)
            let pixelW = Int(out.width.rounded())
            let pixelH = Int(out.height.rounded())
            if max(pixelW, pixelH) > limit {
                let alert = NSAlert()
                alert.messageText = "Cannot export as \(format.displayName)"
                alert.informativeText = "The image is \(pixelW) × \(pixelH) pixels, but "
                    + "\(format.displayName) supports at most \(limit) pixels per side. "
                    + "Choose a different format."
                alert.runModal()
                return
            }
        }
        guard let cg = flatten(controller), let data = Renderer.encode(cg, as: format.utType) else {
            NSSound.beep(); return
        }
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Warning alert with a destructive confirm button and Cancel.
    /// Returns true when the user confirms.
    static func confirmDiscard(message: String, info: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Ends any in-progress inline text editing by resigning the first
    /// responder (fires textDidEndEditing → commitTextEditing).
    static func commitPendingTextEditing() {
        NSApp?.keyWindow?.makeFirstResponder(nil)
    }

    /// Pastes an image from the clipboard, asking for confirmation first when a
    /// document is already open. Returns true if a new image was loaded.
    @discardableResult
    static func confirmAndPasteImage(_ controller: CanvasController) -> Bool {
        let pb = NSPasteboard.general
        guard pb.canReadObject(forClasses: [NSImage.self], options: nil) else {
            NSSound.beep()
            return false
        }
        if controller.hasDocument {
            guard confirmDiscard(
                message: "Replace the current image?",
                info: "Pasting will replace the image you are editing. Unsaved annotations will be lost.",
                confirmTitle: "Replace"
            ) else { return false }
        }
        // Commit inline text editing so the editor doesn't linger over the
        // new document.
        commitPendingTextEditing()
        return controller.pasteImage()
    }

    static func openPanel(_ controller: CanvasController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            controller.loadImage(at: url)
        }
    }
}

/// "Format:" popup shown as the export save panel's accessory view.
/// Being the view itself, `panel.accessoryView` keeps the target/action
/// wiring alive for the panel's lifetime.
private final class ExportFormatAccessory: NSStackView {
    private(set) var selected: ExportFormat
    private let onChange: (ExportFormat) -> Void
    private let popup: NSPopUpButton

    init(selected: ExportFormat, onChange: @escaping (ExportFormat) -> Void) {
        self.selected = selected
        self.onChange = onChange
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for format in ExportFormat.allCases {
            popup.addItem(withTitle: format.displayName)
        }
        popup.selectItem(at: ExportFormat.allCases.firstIndex(of: selected) ?? 0)
        super.init(frame: .zero)
        addArrangedSubview(NSTextField(labelWithString: "Format:"))
        addArrangedSubview(popup)
        orientation = .horizontal
        edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        popup.target = self
        popup.action = #selector(selectionChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func selectionChanged() {
        selected = ExportFormat.allCases[popup.indexOfSelectedItem]
        onChange(selected)
    }
}
