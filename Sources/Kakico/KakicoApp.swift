import SwiftUI
import AppKit

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
    private var editMenuDelegate: EditMenuFilter?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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

        DispatchQueue.main.async {
            if let editMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu {
                self.editMenuDelegate = EditMenuFilter()
                editMenu.delegate = self.editMenuDelegate
            }
        }
    }
}

private class EditMenuFilter: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let blockedTitles: Set<String> = [
            "Writing Tools", "AutoFill",
            "Start Dictation\u{2026}", "Emoji & Symbols",
        ]
        let blockedActions: Set<String> = [
            "orderFrontCharacterPalette:",
            "startDictation:",
            "orderFrontWritingTools:",
        ]
        for item in menu.items {
            guard !item.isSeparatorItem else { continue }
            if let action = item.action {
                item.isHidden = blockedActions.contains(NSStringFromSelector(action))
            } else {
                item.isHidden = blockedTitles.contains(item.title)
            }
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var controller: CanvasController

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
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { controller.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!controller.canUndo)
            Button("Redo") { controller.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!controller.canRedo)
        }
        CommandMenu("Tools") {
            ForEach(Array(Tool.allCases.enumerated()), id: \.element.id) { index, tool in
                Button(tool.label) { controller.tool = tool }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [])
            }
        }
    }
}
