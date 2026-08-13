import SwiftUI
import AppKit
import AnnotationModel

let blockedMenuTitles: Set<String> = [
    "Writing Tools", "AutoFill",
    "Start Dictation\u{2026}", "Emoji & Symbols",
]
let blockedMenuActions: Set<Selector> = [
    #selector(NSApplication.orderFrontCharacterPalette(_:)),
    NSSelectorFromString("startDictation:"),
    NSSelectorFromString("orderFrontWritingTools:"),
]

@main
struct KakicoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Kakico", id: "main") {
            ContentView(workspace: appDelegate.workspace)
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands { AppCommands(workspace: appDelegate.workspace) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let workspace = WorkspaceController()
    private var pasteKeyMonitor: Any?
    private var copyKeyMonitor: Any?
    private var toolKeyMonitor: Any?
    private var editMenuDelegate: EditMenuFilter?
    private var windowDelegateProxy: TerminationRoutingWindowDelegate?
    private var windowHookObserver: NSObjectProtocol?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let openCount = workspace.openDocumentCount
        guard openCount > 0 else { return .terminateNow }
        let info = openCount == 1
            ? "Quitting will discard the image you are editing. Unsaved annotations will be lost."
            : "Quitting will discard the \(openCount) images you are editing. Unsaved annotations will be lost."
        if ExportService.confirmDiscard(
            message: "Quit Kakico?",
            info: info,
            confirmTitle: "Quit"
        ) { return .terminateNow }
        // Safety net: if a close path ever slipped past the windowShouldClose
        // proxy, the window is already gone — bring it back so cancelling
        // never strands a windowless app.
        if !NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) {
            NSApp.windows.first { !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
        }
        return .terminateCancel
    }

    /// Local monitor for a plain-⌘ letter shortcut. Field editors and the
    /// inline text annotation editor are NSTextViews; the event passes through
    /// while one is focused so they keep handling the key themselves. `action`
    /// returns true to consume the event, false to pass it through.
    private func commandKeyMonitor(for character: String,
                                   action: @escaping @MainActor () -> Bool) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == character,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
            return action() ? nil : event
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI's bridged Edit ▸ Paste item swallows ⌘V without dispatching
        // paste: down the AppKit responder chain, so intercept the key event
        // before menu dispatch instead.
        pasteKeyMonitor = commandKeyMonitor(for: "v") { [workspace] in
            DispatchQueue.main.async { ExportService.confirmAndPasteImage(workspace.active) }
            return true
        }

        // Plain ⌘C copies the flattened image when nothing is selected; it
        // passes through while an annotation is selected, so future element
        // copy keeps working.
        copyKeyMonitor = commandKeyMonitor(for: "c") { [workspace] in
            let controller = workspace.active
            guard controller.hasDocument, controller.selection == nil else { return false }
            ExportService.copyToClipboard(controller)
            return true
        }

        // Legacy digit shortcuts (0-7, the Tool.allCases order) kept alongside
        // the Miro-style letters shown in the Tools menu.
        toolKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]),
                  let chars = event.charactersIgnoringModifiers,
                  let index = Int(chars),
                  Tool.allCases.indices.contains(index),
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
            self.workspace.active.tool = Tool.allCases[index]
            return nil
        }

        DispatchQueue.main.async {
            if let editMenu = NSApp.mainMenu?.items
                .first(where: { $0.submenu?.items.contains(where: { $0.action == #selector(NSText.cut(_:)) }) == true })?.submenu {
                self.editMenuDelegate = EditMenuFilter()
                editMenu.delegate = self.editMenuDelegate
            }
        }

        // SwiftUI creates the main window (and installs its own delegate) on
        // its own schedule around didFinishLaunching — possibly before this
        // method runs — and may replace the delegate later. Sweep now, again
        // after the current turn, and on every didBecomeMain; the installer
        // is idempotent, so re-wrapping is a no-op.
        NSApp.windows.forEach { installTerminationRouting(on: $0) }
        DispatchQueue.main.async {
            NSApp.windows.forEach { self.installTerminationRouting(on: $0) }
        }
        windowHookObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.installTerminationRouting(on: window)
            }
        }
    }

    /// Wraps `window`'s delegate in the close→terminate routing proxy. Never
    /// wraps panels (alerts, open/save sheets), and re-invoking for an
    /// already-wrapped window is a no-op — safe to run on every didBecomeMain.
    private func installTerminationRouting(on window: NSWindow) {
        guard !(window is NSPanel),
              !(window.delegate is TerminationRoutingWindowDelegate) else { return }
        let proxy = TerminationRoutingWindowDelegate(wrapping: window.delegate)
        windowDelegateProxy = proxy
        window.delegate = proxy
    }
}

/// Wraps SwiftUI's window delegate so every close path (red button, ⌘W,
/// File ▸ Close) routes through applicationShouldTerminate, letting the quit
/// confirmation cancel before the window disappears. All other delegate
/// callbacks are forwarded to SwiftUI's original delegate untouched.
private final class TerminationRoutingWindowDelegate: NSObject, NSWindowDelegate {
    // Strong on purpose: NSWindow.delegate is weak, so once this proxy takes
    // that slot it may be the only owner of SwiftUI's delegate.
    private let wrapped: NSWindowDelegate?

    init(wrapping wrapped: NSWindowDelegate?) {
        self.wrapped = wrapped
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Defer so the confirmation alert runs outside performClose:'s stack.
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (wrapped?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if wrapped?.responds(to: aSelector) == true { return wrapped }
        return super.forwardingTarget(for: aSelector)
    }
}

private class EditMenuFilter: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            guard !item.isSeparatorItem else { continue }
            if let action = item.action {
                item.isHidden = blockedMenuActions.contains(action)
            } else {
                item.isHidden = blockedMenuTitles.contains(item.title)
            }
        }
        var trailingEdge = true
        for item in menu.items.reversed() {
            if trailingEdge, item.isSeparatorItem {
                item.isHidden = true
            } else if !item.isHidden {
                trailingEdge = false
            }
        }
        var leadingEdge = true
        for item in menu.items {
            if leadingEdge, item.isSeparatorItem {
                item.isHidden = true
            } else if !item.isHidden {
                leadingEdge = false
            }
        }
    }
}

struct AppCommands: Commands {
    var workspace: WorkspaceController

    var body: some Commands {
        // Actions and disabled(...) states both read `workspace.active` in
        // place, so commands always target the current tab and stay reactive
        // to tab switches.
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { workspace.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Divider()
            Button("Open Image…") { ExportService.openPanel(workspace.active) }
                .keyboardShortcut("o", modifiers: .command)
            // ⇧⌘V kept as an explicit alias; plain ⌘V is handled by the key
            // monitor in AppDelegate so it still reaches inline text editors.
            Button("Paste Image") { ExportService.confirmAndPasteImage(workspace.active) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            // Replacing .saveItem removes the system Close item with it, so
            // provide our own. Closing the last tab routes to NSApp.terminate
            // and the quit confirmation, like the red close button.
            Button("Close Tab") { workspace.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
            Divider()
            Button("Export Image…") { ExportService.exportPanel(workspace.active) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!workspace.active.hasDocument)
            Button("Copy Image to Clipboard") { ExportService.copyToClipboard(workspace.active) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!workspace.active.hasDocument)
            Divider()
            Picker("Export Bounds", selection: Binding(
                get: { workspace.active.exportBounds },
                set: { workspace.active.exportBounds = $0 }
            )) {
                Text("Expand to Fit Annotations").tag(ExportBounds.expandToFit)
                Text("Clip at Image Boundary").tag(ExportBounds.clipToImage)
            }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { workspace.active.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!workspace.active.canUndo)
            Button("Redo") { workspace.active.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!workspace.active.canRedo)
        }
        // Lands in the system View menu. ⌘0 doesn't collide with the legacy
        // digit tool shortcuts — AppDelegate's key monitor skips ⌘-modified keys.
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Zoom In") { workspace.active.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!workspace.active.hasDocument)
            Button("Zoom Out") { workspace.active.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!workspace.active.hasDocument)
            Button("Fit to Window") { workspace.active.zoomToFit() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!workspace.active.hasDocument)
        }
        // Lands in the Window menu, where Safari keeps its tab navigation.
        CommandGroup(before: .windowArrangement) {
            Button("Show Previous Tab") { workspace.activatePreviousTab() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(workspace.tabs.count < 2)
            Button("Show Next Tab") { workspace.activateNextTab() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(workspace.tabs.count < 2)
            Divider()
        }
        CommandMenu("Tools") {
            // Unmodified letter equivalents would steal typing from the inline
            // text editor, so disable them while it is active. The legacy 0-7
            // digit shortcuts are handled by the key monitor in AppDelegate.
            ForEach(Tool.allCases) { tool in
                Button(tool.label) { workspace.active.tool = tool }
                    .keyboardShortcut(KeyEquivalent(tool.shortcutKey), modifiers: [])
                    .disabled(workspace.active.isEditingText)
            }
        }
    }
}
