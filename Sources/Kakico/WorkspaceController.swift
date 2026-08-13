import AppKit
import Observation

/// Identity-based id so controllers work directly with ForEach and View.id().
extension CanvasController: Identifiable {}

/// Owns the open tabs and the active tab. One CanvasController per tab —
/// everything per-document (image, selection, zoom, undo stack, toast) already
/// lives on CanvasController, so this class only manages the collection and
/// the close/quit routing.
@MainActor @Observable
final class WorkspaceController {
    /// Invariant: never empty. Closing the last tab quits the app instead of
    /// removing the tab, so the active tab can stay non-optional.
    private(set) var tabs: [CanvasController]
    private(set) var active: CanvasController

    /// Injected so unit tests can simulate the user's confirm/cancel choice
    /// without running an NSAlert.
    @ObservationIgnored
    private let confirmDiscard: (_ message: String, _ info: String, _ confirmTitle: String) -> Bool
    /// Injected quit hook; the default routes through applicationShouldTerminate,
    /// which owns the (single) quit confirmation.
    @ObservationIgnored
    private let requestTermination: () -> Void

    init(
        confirmDiscard: @escaping (String, String, String) -> Bool = {
            ExportService.confirmDiscard(message: $0, info: $1, confirmTitle: $2)
        },
        requestTermination: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.confirmDiscard = confirmDiscard
        self.requestTermination = requestTermination
        let first = CanvasController()
        tabs = [first]
        active = first
    }

    var openDocumentCount: Int { tabs.count { $0.hasDocument } }

    static func title(for controller: CanvasController) -> String {
        controller.sourceURL?.lastPathComponent ?? "Untitled"
    }

    func newTab() {
        let controller = CanvasController()
        tabs.append(controller)
        activate(controller)
    }

    func activate(_ controller: CanvasController) {
        guard controller !== active, tabs.contains(where: { $0 === controller }) else { return }
        // Commit inline text editing before the outgoing tab's canvas view is
        // torn down.
        ExportService.commitPendingTextEditing()
        active = controller
    }

    /// Wrap-around adjacent-tab navigation (Safari's Show Next/Previous Tab).
    func activateNextTab() { activateAdjacent(offset: 1) }

    func activatePreviousTab() { activateAdjacent(offset: -1) }

    private func activateAdjacent(offset: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === active }) else { return }
        activate(tabs[(index + offset + tabs.count) % tabs.count])
    }

    func closeActiveTab() { close(active) }

    func close(_ controller: CanvasController) {
        guard let index = tabs.firstIndex(where: { $0 === controller }) else { return }
        // Last tab: closing quits. Defer the confirmation to the termination
        // path so the user is prompted exactly once, with quit wording.
        guard tabs.count > 1 else {
            requestTermination()
            return
        }
        if controller.hasDocument {
            guard confirmDiscard(
                "Close this tab?",
                "Closing will discard the image you are editing. Unsaved annotations will be lost.",
                "Close Tab"
            ) else { return }
        }
        tabs.remove(at: index)
        if controller === active {
            // Finder behavior: activate the right neighbor, or the new last
            // tab when the closed tab was rightmost.
            active = tabs[min(index, tabs.count - 1)]
        }
    }
}
