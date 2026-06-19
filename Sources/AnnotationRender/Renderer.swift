import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AnnotationModel

/// Pure drawing pipeline shared by the on-screen canvas and file/clipboard
/// export, so what you see equals what you get.
public enum Renderer {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: true])

    /// Draws the base image plus every annotation into `ctx`. The context must
    /// already be set up so that model coordinates (top-left origin, y-down)
    /// map directly — see `flatten` / the canvas view for the CTM setup.
    public static func draw(_ doc: Document, baseImage: CGImage?, in ctx: CGContext) {
        let canvas = CGRect(origin: .zero, size: doc.canvasSize)
        if let baseImage {
            drawImage(baseImage, in: canvas, ctx: ctx)
        }
        for element in doc.elements {
            draw(element, base: baseImage, canvasSize: doc.canvasSize, in: ctx)
        }
    }

    /// Renders the document to a `CGImage`, honoring the crop rect, at `scale`.
    public static func flatten(_ doc: Document, baseImage: CGImage?, scale: CGFloat = 1) -> CGImage? {
        let out = doc.outputRect
        let pixelW = Int((out.width * scale).rounded())
        let pixelH = Int((out.height * scale).rounded())
        guard pixelW > 0, pixelH > 0 else { return nil }

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: pixelW, height: pixelH,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Map model space (top-left origin, y-down, cropped) into the bitmap
        // (bottom-left origin, y-up).
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: out.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -out.origin.x, y: -out.origin.y)

        draw(doc, baseImage: baseImage, in: ctx)
        return ctx.makeImage()
    }

    /// Encodes a CGImage to PNG or JPEG bytes.
    public static func encode(_ image: CGImage, as type: UTType, jpegQuality: CGFloat = 0.9) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Per-element drawing

    private static func draw(_ element: Annotation, base: CGImage?, canvasSize: CGSize, in ctx: CGContext) {
        switch element {
        case .arrow(let e): drawArrow(e, in: ctx)
        case .line(let e): drawLine(e, in: ctx)
        case .rectangle(let e): drawRect(e, in: ctx)
        case .ellipse(let e): drawEllipse(e, in: ctx)
        case .text(let e): drawText(e, in: ctx)
        case .pixelate(let e): drawRedaction(e.rect, amount: e.amount, base: base, canvasSize: canvasSize, in: ctx)
        }
    }

    /// CGContext image/text drawing assumes a y-up space, but the renderer
    /// runs with a y-down (model-space) CTM, which would mirror content
    /// vertically. Runs `body` with the context flipped locally around `rect`
    /// so the content lands upright.
    private static func withYFlip(around rect: CGRect, in ctx: CGContext, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.maxY + rect.minY)
        ctx.scaleBy(x: 1, y: -1)
        body()
        ctx.restoreGState()
    }

    private static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        withYFlip(around: rect, in: ctx) {
            ctx.draw(image, in: rect)
        }
    }

    private static func setStroke(_ ctx: CGContext, _ color: RGBAColor, _ width: CGFloat) {
        ctx.setStrokeColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
    }

    private static func setFill(_ ctx: CGContext, _ color: RGBAColor) {
        ctx.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
    }

    private static func drawLine(_ e: SegmentElement, in ctx: CGContext) {
        setStroke(ctx, e.color, e.width)
        ctx.beginPath()
        ctx.move(to: e.start)
        ctx.addLine(to: e.end)
        ctx.strokePath()
    }

    private static func drawArrow(_ e: SegmentElement, in ctx: CGContext) {
        // Skitch-style arrow: one filled polygon (tapered shaft + barbed head).
        let outline = e.arrowOutline()
        guard let first = outline.first else { return }
        setFill(ctx, e.color)
        ctx.beginPath()
        ctx.move(to: first)
        for p in outline.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawRect(_ e: ShapeElement, in ctx: CGContext) {
        if let fill = e.fill {
            setFill(ctx, fill)
            ctx.fill(e.rect)
        }
        setStroke(ctx, e.color, e.width)
        ctx.stroke(e.rect)
    }

    private static func drawEllipse(_ e: ShapeElement, in ctx: CGContext) {
        if let fill = e.fill {
            setFill(ctx, fill)
            ctx.fillEllipse(in: e.rect)
        }
        setStroke(ctx, e.color, e.width)
        ctx.strokeEllipse(in: e.rect)
    }

    private static func drawText(_ e: TextElement, in ctx: CGContext) {
        guard !e.string.isEmpty else { return }
        let traits: CTFontSymbolicTraits = e.font.bold ? .traitBold : []
        let base = CTFontCreateWithName(e.font.family as CFString, e.font.pointSize, nil)
        let font = CTFontCreateCopyWithSymbolicTraits(base, e.font.pointSize, nil, traits, traits) ?? base
        let color = CGColor(red: e.color.r, green: e.color.g, blue: e.color.b, alpha: e.color.a)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let attr = NSAttributedString(string: e.string, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: e.boundingBox(), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        withYFlip(around: e.boundingBox(), in: ctx) {
            CTFrameDraw(frame, ctx)
        }
    }

    private static func drawRedaction(_ rect: CGRect, amount: CGFloat,
                                      base: CGImage?, canvasSize: CGSize, in ctx: CGContext) {
        guard let base, rect.width > 1, rect.height > 1 else {
            // Fallback: opaque gray block if no base image is available.
            ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            ctx.fill(rect)
            return
        }
        // CIImage is y-up; convert the y-down model rect into image space.
        let ciImage = CIImage(cgImage: base)
        let flippedY = canvasSize.height - rect.maxY
        let ciRect = CGRect(x: rect.minX, y: flippedY, width: rect.width, height: rect.height)

        let f = CIFilter(name: "CIPixellate")!
        f.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(max(2, amount), forKey: kCIInputScaleKey)
        f.setValue(CIVector(x: ciRect.midX, y: ciRect.midY), forKey: kCIInputCenterKey)
        let cropped = f.outputImage!.cropped(to: ciRect)
        guard let out = ciContext.createCGImage(cropped, from: ciRect) else { return }
        drawImage(out, in: rect, ctx: ctx)
    }
}
