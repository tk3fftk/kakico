// Frozen pre-optimization shape renderer for visual regression and Release benchmarks.
import Foundation
import CoreGraphics
import AnnotationModel

/// Test-only snapshot of shape rendering at 530d8b4.
/// Text and redaction are excluded; their production drawing is unchanged.
enum ShadowReferenceRenderer {

    /// Draws the base image plus every annotation into `ctx`. The context must
    /// already be set up so that model coordinates (top-left origin, y-down)
    /// map directly — see `flatten` / the canvas view for the CTM setup.
    static func draw(_ doc: Document, baseImage: CGImage?, shadows: Bool = true, in ctx: CGContext) {
        let canvas = CGRect(origin: .zero, size: doc.canvasSize)
        if let baseImage {
            drawImage(baseImage, in: canvas, ctx: ctx)
        }
        for element in doc.elements {
            draw(element, base: baseImage, canvasSize: doc.canvasSize, shadows: shadows, in: ctx)
        }
    }

    /// Renders the document to a `CGImage`, honoring the crop rect, at `scale`.
    public static func flatten(_ doc: Document, baseImage: CGImage?,
                               scale: CGFloat = 1,
                               bounds: ExportBounds = .clipToImage) -> CGImage? {
        let out = doc.outputRect(for: bounds)
        let pixelW = Int((out.width * scale).rounded())
        let pixelH = Int((out.height * scale).rounded())
        let maxPixelCount = 256 * 1024 * 1024
        guard pixelW > 0, pixelH > 0, pixelW <= maxPixelCount, pixelH <= maxPixelCount, pixelW * pixelH <= maxPixelCount else { return nil }

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

        if bounds == .expandToFit {
            setFill(ctx, .white)
            ctx.fill(out)
        }

        draw(doc, baseImage: baseImage, in: ctx)
        return ctx.makeImage()
    }

    // MARK: - Per-element drawing

    private static func draw(_ element: Annotation, base: CGImage?, canvasSize: CGSize, shadows: Bool, in ctx: CGContext) {
        switch element {
        case .arrow(let e): drawArrow(e, shadows: shadows, in: ctx)
        case .line(let e): drawLine(e, shadows: shadows, in: ctx)
        case .rectangle(let e): drawRect(e, shadows: shadows, in: ctx)
        case .ellipse(let e): drawEllipse(e, shadows: shadows, in: ctx)
        case .text: break
        case .pixelate: break
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

    /// Draws a soft drop shadow whose size follows the element's stroke width.
    /// CGContext shadows use device-space dimensions, so scale the offset and
    /// blur to keep their appearance consistent at every render scale. Drawing
    /// in a transparency layer makes a filled and stroked shape cast one shadow.
    static func withShadow(forStrokeWidth width: CGFloat, enabled: Bool, in ctx: CGContext, _ body: () -> Void) {
        if !enabled { body(); return }
        let ctm = ctx.ctm
        let deviceScale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        let drop = max(1.5, width * 0.35) * deviceScale
        let blur = max(1.5, width * 0.5) * deviceScale
        ctx.saveGState()
        // Base space is y-up in each renderer context, so negative height
        // offsets the shadow down in the resulting image.
        ctx.setShadow(offset: CGSize(width: drop * 0.4, height: -drop), blur: blur,
                      color: CGColor(gray: 0, alpha: 0.45))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func drawLine(_ e: SegmentElement, shadows: Bool, in ctx: CGContext) {
        withShadow(forStrokeWidth: e.width, enabled: shadows, in: ctx) {
            setStroke(ctx, e.color, e.width)
            ctx.beginPath()
            ctx.move(to: e.start)
            ctx.addLine(to: e.end)
            ctx.strokePath()
        }
    }

    private static func drawArrow(_ e: SegmentElement, shadows: Bool, in ctx: CGContext) {
        // Skitch-style arrow: one filled polygon (tapered shaft + barbed head).
        let outline = e.arrowOutline()
        guard let first = outline.first else { return }
        withShadow(forStrokeWidth: e.width, enabled: shadows, in: ctx) {
            setFill(ctx, e.color)
            ctx.beginPath()
            ctx.move(to: first)
            for p in outline.dropFirst() { ctx.addLine(to: p) }
            ctx.closePath()
            ctx.fillPath()
        }
    }

    private static func drawRect(_ e: ShapeElement, shadows: Bool, in ctx: CGContext) {
        withShadow(forStrokeWidth: e.width, enabled: shadows, in: ctx) {
            if let fill = e.fill {
                setFill(ctx, fill)
                ctx.fill(e.rect)
            }
            setStroke(ctx, e.color, e.width)
            ctx.stroke(e.rect)
        }
    }

    private static func drawEllipse(_ e: ShapeElement, shadows: Bool, in ctx: CGContext) {
        withShadow(forStrokeWidth: e.width, enabled: shadows, in: ctx) {
            if let fill = e.fill {
                setFill(ctx, fill)
                ctx.fillEllipse(in: e.rect)
            }
            setStroke(ctx, e.color, e.width)
            ctx.strokeEllipse(in: e.rect)
        }
    }

}
