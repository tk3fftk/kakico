import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AnnotationModel

// MARK: - Color bridging

extension Color {
    init(_ c: RGBAColor) {
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}

func rgbaColor(from color: Color) -> RGBAColor {
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? .red
    return RGBAColor(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                     b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
}

// MARK: - Content

struct ContentView: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = controller.exportBounds
        // swiftlint:disable:next redundant_discardable_let
        let _ = controller.document
        // swiftlint:disable:next redundant_discardable_let
        let _ = controller.selection
        // swiftlint:disable:next redundant_discardable_let
        let _ = controller.baseImage
        ZStack {
            MiroTheme.board(scheme)
            MiroGrid(color: MiroTheme.grid(scheme))
            if controller.hasDocument {
                CanvasView(controller: controller)
                    .padding(.leading, 76)
                    .padding(.trailing, 24)
                    .padding(.vertical, 24)
            } else {
                EmptyState(controller: controller)
            }
        }
        .overlay(alignment: .leading) {
            if controller.hasDocument {
                ToolPalette(controller: controller)
                    .padding(.leading, 16)
            }
        }
        .overlay(alignment: .topTrailing) {
            if controller.hasDocument {
                ActionBar(controller: controller)
                    .padding(16)
            }
        }
        .overlay(alignment: .bottom) {
            if controller.document?.crop != nil {
                CropActionBar(controller: controller)
                    .padding(.bottom, 20)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let doc = controller.document {
                ImageSizeBadge(document: doc, exportBounds: controller.exportBounds)
                    .padding(16)
            }
        }
        .animation(.easeOut(duration: 0.12), value: controller.document?.crop != nil)
    }
}

struct EmptyState: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(MiroTheme.textSecondary(scheme))
            Text("Open or drop an image to start annotating")
                .font(.miroBody)
                .foregroundStyle(MiroTheme.textSecondary(scheme))
            HStack(spacing: 12) {
                MiroPrimaryButton(title: "Open Image…") { ExportService.openPanel(controller) }
                MiroSecondaryButton(title: "Paste from Clipboard") { ExportService.confirmAndPasteImage(controller) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Icon tiles

/// Shared icon-in-tile label used by the palette and action-bar buttons; the
/// content shape matches `MiroTileButtonStyle`'s 11pt hover/pressed fill.
private func tileIcon(_ symbol: String, tint: Color,
                      iconSize: CGFloat = 20, tile: CGFloat = 40) -> some View {
    Image(systemName: symbol)
        .font(.system(size: iconSize, weight: .medium))
        .foregroundStyle(tint)
        .frame(width: tile, height: tile)
        .contentShape(.rect(cornerRadius: 11))
}

// MARK: - Floating tool palette

struct ToolPalette: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsStrokeWidth = false

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(controller.strokeColor) },
                set: { controller.strokeColor = rgbaColor(from: $0) })
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Tool.allCases) { tool in
                Button {
                    if reduceMotion {
                        controller.tool = tool
                    } else {
                        withAnimation(.easeOut(duration: 0.12)) { controller.tool = tool }
                    }
                } label: {
                    tileIcon(tool.symbol,
                             tint: controller.tool == tool ? Color.miroInk : MiroTheme.textSecondary(scheme))
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(controller.tool == tool ? Color.miroYellow : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help(tool.label)
                .keyboardShortcut(.none)
            }

            Rectangle()
                .fill(Color.miroDivider)
                .frame(width: 28, height: 1)
                .padding(.vertical, 4)

            ColorPicker("", selection: colorBinding, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 40, height: 28)
                .help("Stroke color")

            Button {
                showsStrokeWidth.toggle()
            } label: {
                tileIcon("lineweight", tint: MiroTheme.textSecondary(scheme))
            }
            .buttonStyle(MiroTileButtonStyle())
            .help("Stroke width")
            .popover(isPresented: $showsStrokeWidth, arrowEdge: .trailing) {
                HStack(spacing: 8) {
                    Image(systemName: "lineweight")
                        .foregroundStyle(MiroTheme.textSecondary(scheme))
                    Slider(value: Binding(get: { Double(controller.strokeWidth) },
                                          set: { controller.strokeWidth = CGFloat($0) }),
                           in: 1...40)
                    .frame(width: 140)
                    .tint(.miroBlue)
                }
                .padding(12)
            }
        }
        .miroFloatingPanel()
    }
}

// MARK: - Floating action bar (share / copy / export)

struct ActionBar: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            DragOutWell(controller: controller)
                .frame(width: 32, height: 32)
                .help("Drag out to share as PNG")

            actionTile(copied ? "checkmark" : "doc.on.clipboard",
                       help: "Copy image to clipboard",
                       tint: copied ? .miroSuccess : nil) {
                ExportService.copyToClipboard(controller)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    copied = false
                }
            }
            actionTile("square.and.arrow.down", help: "Export image") {
                ExportService.exportPanel(controller)
            }
        }
        .miroFloatingPanel()
    }

    private func actionTile(_ symbol: String, help: String, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            tileIcon(symbol, tint: tint ?? MiroTheme.textSecondary(scheme), iconSize: 16, tile: 36)
        }
        .buttonStyle(MiroTileButtonStyle())
        .help(help)
        .disabled(!controller.hasDocument)
    }
}

// MARK: - Crop action bar

struct CropActionBar: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            MiroPrimaryButton(title: "Apply Crop") { controller.applyCrop() }
                .help("Apply the crop (Return)")
            Button("Cancel") { controller.cancelCrop() }
                .buttonStyle(.plain)
                .font(.miroControl)
                .foregroundStyle(MiroTheme.textSecondary(scheme))
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .help("Cancel the crop (Esc)")
        }
        .miroFloatingPanel()
        .transition(.opacity)
    }
}

/// Bottom-right badge showing the exported image size in pixels; during a
/// pending crop it also shows the original size in parentheses.
struct ImageSizeBadge: View {
    var document: Document
    var exportBounds: ExportBounds
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(label)
            .font(.miroCaption)
            .foregroundStyle(MiroTheme.textSecondary(scheme))
            .miroFloatingPanel()
    }

    private var label: String {
        let out = document.outputRect(for: exportBounds).integral
        let size = "\(Int(out.width)) × \(Int(out.height))"
        guard document.crop != nil else { return size }
        let w = Int(document.canvasSize.width)
        let h = Int(document.canvasSize.height)
        return "\(size) (\(w) × \(h))"
    }
}

// MARK: - Drag-out well (NSFilePromiseProvider)

struct DragOutWell: NSViewRepresentable {
    var controller: CanvasController

    func makeNSView(context: Context) -> DragOutView {
        let v = DragOutView()
        v.controller = controller
        return v
    }
    func updateNSView(_ nsView: DragOutView, context: Context) {
        nsView.controller = controller
    }
}

final class DragOutView: NSView, NSFilePromiseProviderDelegate, NSDraggingSource {
    weak var controller: CanvasController?
    nonisolated(unsafe) private var pendingData: Data?
    private let ioQueue = OperationQueue()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let enabled = controller?.hasDocument ?? false
        let symbol = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        symbol?.isTemplate = true
        NSColor.secondaryLabelColor.withAlphaComponent(enabled ? 1 : 0.3).set()
        if let tinted = symbol?.tinted(with: NSColor.secondaryLabelColor.withAlphaComponent(enabled ? 1 : 0.3)) {
            let r = NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
            tinted.draw(in: r)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, controller.hasDocument,
              let data = ExportService.pngData(controller) else { return }
        pendingData = data
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: self)
        let item = NSDraggingItem(pasteboardWriter: provider)
        let preview = NSImage(data: data) ?? NSImage()
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    // NSDraggingSource
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    // NSFilePromiseProviderDelegate
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        let base = controller?.sourceURL?.deletingPathExtension().lastPathComponent ?? "annotated"
        return "\(base).png"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            if let data = pendingData { try data.write(to: url) }
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { ioQueue }
}

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
