import Foundation
import CoreGraphics
import AppKit
import AnnotationModel
import AnnotationRender

/// Holds the document, the loaded base image, the current tool/selection, and
/// a snapshot-based undo stack. The single source of truth for the UI.
@MainActor @Observable
final class CanvasController {
    var document: Document? {
        didSet { documentVersion &+= 1 }
    }
    /// Monotonic counter bumped on every write to `document`; a cheap
    /// change-detection key for the canvas's flatten cache. Bumps are
    /// conservative — equal-value writes also increment.
    @ObservationIgnored private(set) var documentVersion: Int = 0
    var baseImage: CGImage?
    var selection: ElementID? {
        didSet { syncToolStateFromSelection() }
    }
    var tool: Tool = .arrow
    /// True while the inline text annotation editor is active; disables the
    /// unmodified single-letter tool shortcuts so they don't steal typing.
    var isEditingText = false
    var strokeColor: RGBAColor = .red {
        didSet { applyColorToSelection() }
    }
    var strokeWidth: CGFloat = 6 {
        didSet { applyStrokeWidthToSelection() }
    }
    private static let exportBoundsKey = "exportBounds"
    var exportBounds: ExportBounds = {
        if let raw = UserDefaults.standard.string(forKey: CanvasController.exportBoundsKey),
           let value = ExportBounds(rawValue: raw) {
            return value
        }
        return .expandToFit
    }() {
        didSet {
            UserDefaults.standard.set(exportBounds.rawValue, forKey: Self.exportBoundsKey)
        }
    }
    private(set) var sourceURL: URL?

    /// Undo unit: the document plus the base image (destructive crop swaps the
    /// image, so document snapshots alone can't restore it).
    private struct State {
        var document: Document
        var image: CGImage?
    }

    /// True while `syncToolStateFromSelection()` writes the tool state, so the
    /// setters' `didSet` apply hooks don't re-fire back into the document.
    @ObservationIgnored private var isSyncing = false

    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private var interactionSnapshot: State?
    @ObservationIgnored private var pendingCommitTask: Task<Void, Never>?

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
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        interactionSnapshot = nil
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
        flushPendingCommit()
        guard let document else { return }
        interactionSnapshot = State(document: document, image: baseImage)
    }

    /// Commit an interaction; pushes the pre-state if the document changed.
    func commitInteraction() {
        defer { interactionSnapshot = nil }
        guard let pre = interactionSnapshot, pre.document != document else { return }
        undoStack.append(pre)
        redoStack.removeAll()
    }

    /// One-shot mutation with undo registration.
    func perform(_ change: (inout Document) -> Void) {
        flushPendingCommit()
        guard var doc = document else { return }
        let pre = State(document: doc, image: baseImage)
        change(&doc)
        guard doc != pre.document else { return }
        undoStack.append(pre)
        redoStack.removeAll()
        document = doc
    }

    func undo() {
        flushPendingCommit()
        guard let pre = undoStack.popLast(), let current = document else { return }
        redoStack.append(State(document: current, image: baseImage))
        document = pre.document
        baseImage = pre.image
        clampSelection()
    }

    func redo() {
        flushPendingCommit()
        guard let next = redoStack.popLast(), let current = document else { return }
        undoStack.append(State(document: current, image: baseImage))
        document = next.document
        baseImage = next.image
        clampSelection()
    }

    private func clampSelection() {
        if let sel = selection, document?.index(of: sel) == nil { selection = nil }
        syncToolStateFromSelection()
    }

    // MARK: - Tool state ↔ selection

    /// Adopts the selected element's stroke width and color so the controls
    /// start from the current values (and new elements inherit them).
    private func syncToolStateFromSelection() {
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return }
        isSyncing = true
        defer { isSyncing = false }
        let element = doc.elements[i]
        if case .text(let t) = element {
            let width = FontSpec.strokeWidth(forPointSize: t.font.pointSize)
            if width != strokeWidth { strokeWidth = width }
        } else if let width = element.strokeWidth, width != strokeWidth {
            strokeWidth = width
        }
        if let color = element.color, color != strokeColor { strokeColor = color }
    }

    /// Applies the global stroke width to the selected element; no-op when the
    /// value is unchanged (breaks the sync → apply feedback loop) or the
    /// element has no stroke width. For text the width maps to the font point
    /// size (same mapping as creation) and the box height is re-measured so
    /// wrapped text doesn't get clipped. Undo boundaries are the caller's job
    /// (the slider wraps drags in begin/commitInteraction).
    private func applyStrokeWidthToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return }
        if case .text(var t) = doc.elements[i] {
            let pointSize = FontSpec.suggestedPointSize(forStrokeWidth: strokeWidth)
            guard t.font.pointSize != pointSize else { return }
            t.font.pointSize = pointSize
            t.size = Renderer.suggestedSize(for: t)
            document?.elements[i] = .text(t)
        } else if let current = doc.elements[i].strokeWidth, current != strokeWidth {
            document?.elements[i].strokeWidth = strokeWidth
        }
    }

    /// Applies the global stroke color to the selected element; no-op when the
    /// value is unchanged (breaks the sync → apply feedback loop) or the
    /// element has no color. The color picker has no drag begin/end events, so
    /// the undo boundary is debounced: changes within 500ms coalesce into one
    /// undo step.
    private func applyColorToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection,
              let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].color,
              current != strokeColor else { return }
        if pendingCommitTask == nil { beginInteraction() }
        document?.elements[i].color = strokeColor
        pendingCommitTask?.cancel()
        pendingCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            pendingCommitTask = nil
            commitInteraction()
        }
    }

    /// Discrete color choice (preset swatch tap): applies through the normal
    /// `didSet` path, then flushes the debounce so the tap is one undo step
    /// instead of coalescing with neighboring changes.
    func selectStrokeColor(_ color: RGBAColor) {
        flushPendingCommit()
        strokeColor = color
        flushPendingCommit()
    }

    /// Commits a debounce-pending change immediately so a following
    /// interaction or undo/redo doesn't clobber its snapshot.
    private func flushPendingCommit() {
        guard pendingCommitTask != nil else { return }
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        commitInteraction()
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
        guard let doc = document, let base = baseImage,
              let clamped = doc.integralCrop,
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
