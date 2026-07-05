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
            ContentView(controller: appDelegate.controller)
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands { AppCommands(controller: appDelegate.controller) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = CanvasController()
    private var pasteKeyMonitor: Any?
    private var copyKeyMonitor: Any?
    private var toolKeyMonitor: Any?
    private var editMenuDelegate: EditMenuFilter?
    private var windowDelegateProxy: TerminationRoutingWindowDelegate?
    private var windowHookObserver: NSObjectProtocol?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.hasDocument else { return .terminateNow }
        return ExportService.confirmDiscard(
            message: "Quit Kakico?",
            info: "Quitting will discard the image you are editing. Unsaved annotations will be lost.",
            confirmTitle: "Quit"
        ) ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI's bridged Edit ▸ Paste item swallows ⌘V without dispatching
        // paste: down the AppKit responder chain, so intercept the key event
        // before menu dispatch instead.
        pasteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            // Field editors and the inline text annotation editor are
            // NSTextViews; let them handle ⌘V (text paste) themselves.
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            let controller = self.controller
            DispatchQueue.main.async { ExportService.confirmAndPasteImage(controller) }
            return nil
        }

        // Plain ⌘C copies the flattened image when nothing is selected. The
        // event passes through untouched while a text editor is active or an
        // annotation is selected, so text copy and future element copy keep
        // working.
        copyKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "c" else { return event }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            guard self.controller.hasDocument, self.controller.selection == nil else { return event }
            ExportService.copyToClipboard(self.controller)
            return nil
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
            self.controller.tool = Tool.allCases[index]
            return nil
        }

        DispatchQueue.main.async {
            if let editMenu = NSApp.mainMenu?.items
                .first(where: { $0.submenu?.items.contains(where: { $0.action == #selector(NSText.cut(_:)) }) == true })?.submenu {
                self.editMenuDelegate = EditMenuFilter()
                editMenu.delegate = self.editMenuDelegate
            }
        }

        // SwiftUI creates the main window (and installs its own delegate)
        // after didFinishLaunching, so wrap that delegate once the window
        // first becomes main.
        windowHookObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, self.windowDelegateProxy == nil, let window else { return }
                let proxy = TerminationRoutingWindowDelegate(wrapping: window.delegate)
                self.windowDelegateProxy = proxy
                window.delegate = proxy
                if let observer = self.windowHookObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.windowHookObserver = nil
                }
            }
        }
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
    var controller: CanvasController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Image…") { ExportService.openPanel(controller) }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Kakico Document…") { ExportService.openDocument(controller) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            // ⇧⌘V kept as an explicit alias; plain ⌘V is handled by the key
            // monitor in AppDelegate so it still reaches inline text editors.
            Button("Paste Image") { ExportService.confirmAndPasteImage(controller) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Kakico Document…") { ExportService.saveDocument(controller) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!controller.hasDocument)
            Button("Export Image…") { ExportService.exportPanel(controller) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!controller.hasDocument)
            Button("Copy Image to Clipboard") { ExportService.copyToClipboard(controller) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!controller.hasDocument)
            Divider()
            Picker("Export Bounds", selection: Binding(
                get: { controller.exportBounds },
                set: { controller.exportBounds = $0 }
            )) {
                Text("Expand to Fit Annotations").tag(ExportBounds.expandToFit)
                Text("Clip at Image Boundary").tag(ExportBounds.clipToImage)
            }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { controller.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!controller.canUndo)
            Button("Redo") { controller.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!controller.canRedo)
        }
        // Lands in the system View menu. ⌘0 doesn't collide with the legacy
        // digit tool shortcuts — AppDelegate's key monitor skips ⌘-modified keys.
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Zoom In") { controller.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!controller.hasDocument)
            Button("Zoom Out") { controller.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!controller.hasDocument)
            Button("Fit to Window") { controller.zoomToFit() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!controller.hasDocument)
        }
        CommandMenu("Tools") {
            // Unmodified letter equivalents would steal typing from the inline
            // text editor, so disable them while it is active. The legacy 0-7
            // digit shortcuts are handled by the key monitor in AppDelegate.
            ForEach(Tool.allCases) { tool in
                Button(tool.label) { controller.tool = tool }
                    .keyboardShortcut(KeyEquivalent(tool.shortcutKey), modifiers: [])
                    .disabled(controller.isEditingText)
            }
        }
    }
}
