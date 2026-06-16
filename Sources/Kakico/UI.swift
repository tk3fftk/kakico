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

    var body: some View {
        VStack(spacing: 0) {
            ToolbarBar(controller: controller)
            Divider()
            if controller.hasDocument {
                CanvasView(controller: controller)
                    .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                EmptyState(controller: controller)
            }
        }
    }
}

struct EmptyState: View {
    var controller: CanvasController
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Open or drop an image to start annotating")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Image…") { ExportService.openPanel(controller) }
                Button("Paste from Clipboard") { ExportService.confirmAndPasteImage(controller) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Toolbar

struct ToolbarBar: View {
    var controller: CanvasController

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(controller.strokeColor) },
                set: { controller.strokeColor = rgbaColor(from: $0) })
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Tool.allCases) { tool in
                Button {
                    controller.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 22, height: 18)
                }
                .help(tool.label)
                .buttonStyle(.bordered)
                .tint(controller.tool == tool ? .accentColor : nil)
            }

            Divider().frame(height: 22)

            ColorPicker("", selection: colorBinding, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 44)

            HStack(spacing: 4) {
                Image(systemName: "lineweight").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(controller.strokeWidth) },
                                      set: { controller.strokeWidth = CGFloat($0) }),
                       in: 1...40)
                .frame(width: 90)
            }

            Spacer()

            if controller.document?.crop != nil {
                Button("Apply Crop") { controller.applyCrop() }
                    .help("Apply the crop (Return)")
                Button("Cancel Crop") { controller.cancelCrop() }
                    .help("Cancel the crop (Esc)")
            }

            DragOutWell(controller: controller)
                .frame(width: 30, height: 24)
                .help("Drag out to share as PNG")

            Button { ExportService.copyToClipboard(controller) } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help("Copy image to clipboard")
            .disabled(!controller.hasDocument)

            Button { ExportService.exportPanel(controller) } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Export image")
            .disabled(!controller.hasDocument)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
