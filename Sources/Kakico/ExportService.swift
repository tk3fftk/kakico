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
        let rep = NSBitmapImageRep(cgImage: cg)
        let image = NSImage(size: NSSize(width: cg.width, height: cg.height))
        image.addRepresentation(rep)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
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
            let alert = NSAlert()
            alert.messageText = "Replace the current image?"
            alert.informativeText = "Pasting will replace the image you are editing. Unsaved annotations will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        // End any in-progress inline text editing (fires textDidEndEditing →
        // commitTextEditing) so the editor doesn't linger over the new document.
        NSApp.keyWindow?.makeFirstResponder(nil)
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
