import Foundation
import CoreGraphics
import AppKit
import AnnotationModel

/// Holds the document, the loaded base image, the current tool/selection, and
/// a snapshot-based undo stack. The single source of truth for the UI.
@MainActor
final class CanvasController: ObservableObject {
    @Published var document: Document?
    @Published var baseImage: CGImage?
    @Published var selection: ElementID?
    @Published var tool: Tool = .arrow
    @Published var strokeColor: RGBAColor = .red
    @Published var strokeWidth: CGFloat = 6
    @Published private(set) var sourceURL: URL?

    /// Undo unit: the document plus the base image (destructive crop swaps the
    /// image, so document snapshots alone can't restore it).
    private struct State {
        var document: Document
        var image: CGImage?
    }

    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private var interactionSnapshot: State?

    var hasDocument: Bool { document != nil }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Loading

    func loadImage(at url: URL) {
        guard let image = ImageLoader.cgImage(from: url) else {
            NSSound.beep()
            return
        }
        load(image: image, sourceURL: url)
    }

    func loadImage(_ image: CGImage, sourceURL: URL? = nil) {
        load(image: image, sourceURL: sourceURL)
    }

    private func load(image: CGImage, sourceURL: URL?) {
        let size = CGSize(width: image.width, height: image.height)
        let ref: ImageRef
        if let sourceURL { ref = .file(path: sourceURL.path) } else { ref = .pngData(Data()) }
        baseImage = image
        document = Document(baseImage: ref, canvasSize: size)
        self.sourceURL = sourceURL
        selection = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Loads an image from the general pasteboard, if present.
    @discardableResult
    func pasteImage() -> Bool {
        let pb = NSPasteboard.general
        if let objs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let nsImage = objs.first,
           let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            load(image: cg, sourceURL: nil)
            return true
        }
        return false
    }

    // MARK: - Undo

    /// Capture state at the start of an interaction (e.g. mouseDown).
    func beginInteraction() {
        guard let document else { return }
        interactionSnapshot = State(document: document, image: baseImage)
    }

    /// Commit an interaction; pushes the pre-state if the document changed.
    func commitInteraction() {
        defer { interactionSnapshot = nil }
        guard let pre = interactionSnapshot, pre.document != document else { return }
        undoStack.append(pre)
        redoStack.removeAll()
        objectWillChange.send()
    }

    /// One-shot mutation with undo registration.
    func perform(_ change: (inout Document) -> Void) {
        guard var doc = document else { return }
        let pre = State(document: doc, image: baseImage)
        change(&doc)
        guard doc != pre.document else { return }
        undoStack.append(pre)
        redoStack.removeAll()
        document = doc
    }

    func undo() {
        guard let pre = undoStack.popLast(), let current = document else { return }
        redoStack.append(State(document: current, image: baseImage))
        document = pre.document
        baseImage = pre.image
        clampSelection()
    }

    func redo() {
        guard let next = redoStack.popLast(), let current = document else { return }
        undoStack.append(State(document: current, image: baseImage))
        document = next.document
        baseImage = next.image
        clampSelection()
    }

    private func clampSelection() {
        if let sel = selection, document?.index(of: sel) == nil { selection = nil }
    }

    func deleteSelection() {
        guard let sel = selection else { return }
        perform { $0.remove(sel) }
        selection = nil
    }

    // MARK: - Crop

    /// Destructively applies the pending crop: trims the base image, shifts
    /// elements into the new origin, and shrinks the canvas. Undoable; the
    /// crop stays non-destructive (re-editable) until this is called.
    func applyCrop() {
        guard let doc = document, let crop = doc.crop, let base = baseImage,
              let clamped = doc.clampedCrop(crop)?.integral,
              let croppedBase = base.cropping(to: clamped) else { return }

        var newDoc = doc
        newDoc.crop = nil
        newDoc.canvasSize = clamped.size
        let delta = CGVector(dx: -clamped.minX, dy: -clamped.minY)
        for i in newDoc.elements.indices { newDoc.elements[i].translate(by: delta) }

        undoStack.append(State(document: doc, image: base))
        redoStack.removeAll()
        baseImage = croppedBase
        document = newDoc
    }

    /// Cancels the pending crop without touching the image.
    func cancelCrop() {
        guard document?.crop != nil else { return }
        perform { $0.crop = nil }
    }
}
