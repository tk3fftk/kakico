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

    static func exportPanel(_ controller: CanvasController) {
        guard controller.hasDocument else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        let base = controller.sourceURL?.deletingPathExtension().lastPathComponent ?? "annotated"
        panel.nameFieldStringValue = "\(base).png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            let type: UTType = (ext == "jpg" || ext == "jpeg") ? .jpeg : .png
            export(controller, to: url, as: type)
        }
    }

    static func export(_ controller: CanvasController, to url: URL, as type: UTType) {
        guard let cg = flatten(controller), let data = Renderer.encode(cg, as: type) else {
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

    // MARK: Native document format (.kakico — JSON package with embedded PNG)

    static func saveDocument(_ controller: CanvasController) {
        guard var doc = controller.document, let cg = controller.baseImage else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "kakico") ?? .json]
        panel.nameFieldStringValue = "untitled.kakico"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Embed the base image so the document is self-contained.
            if let png = Renderer.encode(cg, as: .png) {
                doc.baseImage = .pngData(png)
            }
            do {
                let data = try JSONEncoder().encode(doc)
                try data.write(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    static func openDocument(_ controller: CanvasController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "kakico") ?? .json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let doc = try JSONDecoder().decode(Document.self, from: data)
                guard case .pngData(let png) = doc.baseImage,
                      let cg = ImageLoader.cgImage(from: png) else {
                    NSSound.beep(); return
                }
                controller.loadImage(cg)
                controller.document = doc
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
