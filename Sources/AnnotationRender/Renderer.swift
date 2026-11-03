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

    /// Pixellated output per (base image, rect, amount). CIPixellate runs on
    /// the software renderer, so re-rendering every redaction on every
    /// flatten makes canvas redraws O(number of redactions) — measured at
    /// ~11ms per large redaction, i.e. 3+ redactions blow the 16ms frame
    /// budget during a slider drag. With the cache only the element being
    /// edited re-renders; the rest are straight blits. NSCache is documented
    /// thread-safe, hence `nonisolated(unsafe)`.
    private nonisolated(unsafe) static let redactionCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

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

    /// Per-canvas raster cache. Export continues to use `flatten`.
    public final class CanvasCache {
        private struct Key: Equatable {
            var elements: [Annotation]
            var canvas: CGSize
            var output: CGRect
            var active: ElementID
        }
        private var lowerKey: Key?
        private var upperKey: Key?
        private struct Raster {
            var image: CGImage?
            var rect: CGRect
        }
        private var lower: Raster?
        private var upper: Raster?
        private var base: CGImage?
        private(set) var generationCount = 0

        public init() {}

        public func reset() {
            lower = nil; upper = nil; lowerKey = nil; upperKey = nil; base = nil
        }

        public func flatten(_ doc: Document, baseImage: CGImage?, activeElementID: ElementID?,
                            bounds: ExportBounds = .clipToImage) -> CGImage? {
            guard let activeElementID, let index = doc.index(of: activeElementID) else {
                reset()
                return Renderer.flatten(doc, baseImage: baseImage, bounds: bounds)
            }
            let out = doc.outputRect(for: bounds)
            // Two additional RGBA surfaces, capped at 128 MiB. Bounded
            // surfaces share the output's pixel grid; fractional crops use
            // the direct renderer to avoid resampling at cache boundaries.
            guard out == out.integral, out.width > 0, out.height > 0,
                  out.width.rounded() * out.height.rounded() <= CGFloat(128 * 1024 * 1024 / 8) else {
                reset()
                return Renderer.flatten(doc, baseImage: baseImage, bounds: bounds)
            }
            func context(for rect: CGRect) -> CGContext? {
                guard let ctx = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height),
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                ctx.translateBy(x: 0, y: rect.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.translateBy(x: -rect.minX, y: -rect.minY)
                return ctx
            }
            let low = Key(elements: Array(doc.elements[..<index]), canvas: doc.canvasSize, output: out, active: activeElementID)
            let high = Key(elements: Array(doc.elements[(index + 1)...]), canvas: doc.canvasSize, output: out, active: activeElementID)
            let changedBase = base !== baseImage
            func raster(_ elements: [Annotation], includeBase: Bool) -> Raster? {
                var rect = includeBase && baseImage != nil ? out : CGRect.null
                for element in elements {
                    // Text glyphs can overhang their layout frame. Keep the full
                    // surface for text until glyph ink bounds are available.
                    if case .text = element { rect = out; break }
                    var ink = element.boundingBox()
                    if case .arrow(let arrow) = element {
                        for point in arrow.arrowOutline() {
                            ink = ink.union(CGRect(origin: point, size: .zero))
                        }
                    }
                    let width = element.strokeWidth ?? 0
                    let margin = max(1.5, width * 0.5) * 3 + max(1.5, width * 0.35) + 2
                    rect = rect.union(ink.insetBy(dx: -margin, dy: -margin))
                }
                rect = rect.integral.intersection(out)
                if rect.isNull || rect.isEmpty { return Raster(image: nil, rect: .zero) }
                guard let ctx = context(for: rect) else { return nil }
                if includeBase, let baseImage {
                    Renderer.drawImage(baseImage, in: CGRect(origin: .zero, size: doc.canvasSize), ctx: ctx)
                }
                for element in elements {
                    Renderer.draw(element, base: baseImage, canvasSize: doc.canvasSize, in: ctx)
                }
                guard let image = ctx.makeImage() else { return nil }
                generationCount += 1
                return Raster(image: image, rect: rect)
            }
            if lowerKey != low || changedBase || lower == nil {
                lower = raster(low.elements, includeBase: true); lowerKey = low
            }
            if upperKey != high || changedBase || upper == nil {
                upper = raster(high.elements, includeBase: false); upperKey = high
            }
            base = baseImage
            guard let lower, let upper, let ctx = context(for: out) else {
                reset()
                return Renderer.flatten(doc, baseImage: baseImage, bounds: bounds)
            }
            if bounds == .expandToFit { Renderer.setFill(ctx, .white); ctx.fill(out) }
            if let image = lower.image {
                // The destination is transparent in clip mode, so copying the
                // premultiplied pixels avoids blending with an empty surface.
                if bounds == .clipToImage { ctx.setBlendMode(.copy) }
                Renderer.drawImage(image, in: lower.rect, ctx: ctx)
                ctx.setBlendMode(.normal)
            }
            Renderer.draw(doc.elements[index], base: baseImage, canvasSize: doc.canvasSize, in: ctx)
            if let image = upper.image { Renderer.drawImage(image, in: upper.rect, ctx: ctx) }
            return ctx.makeImage()
        }
    }

    /// Encodes a CGImage to PNG, JPEG, or WebP bytes. WebP goes through
    /// libwebp (lossy) because ImageIO cannot write it; `quality` applies to
    /// both lossy formats.
    public static func encode(_ image: CGImage, as type: UTType, quality: CGFloat = 0.9) -> Data? {
        if type == .webP {
            return WebPEncoder.encodeLossy(image, quality: quality)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
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

    /// Draws a soft drop shadow whose size follows the element's stroke width.
    /// CGContext shadows use device-space dimensions, so scale the offset and
    /// blur to keep their appearance consistent at every render scale. Drawing
    /// in a transparency layer makes a filled and stroked shape cast one shadow.
    private static func withShadow(forStrokeWidth width: CGFloat, layerBounds: CGRect? = nil,
                                   in ctx: CGContext, _ body: () -> Void) {
        let ctm = ctx.ctm
        let deviceScale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        let drop = max(1.5, width * 0.35) * deviceScale
        let blur = max(1.5, width * 0.5) * deviceScale
        ctx.saveGState()
        // Base space is y-up in each renderer context, so negative height
        // offsets the shadow down in the resulting image.
        ctx.setShadow(offset: CGSize(width: drop * 0.4, height: -drop), blur: blur,
                      color: CGColor(gray: 0, alpha: 0.45))
        if let layerBounds {
            // Include stroke coverage (supplied by the caller), antialiasing,
            // and a conservative blur/offset margin in model coordinates.
            let margin = max(1.5, width * 0.5) * 3 + max(1.5, width * 0.35) + 2
            ctx.beginTransparencyLayer(in: layerBounds.insetBy(dx: -margin, dy: -margin),
                                       auxiliaryInfo: nil)
            body()
            ctx.endTransparencyLayer()
        } else {
            // A single fill/stroke already casts one shadow; no group needed.
            body()
        }
        ctx.restoreGState()
    }

    private static func drawLine(_ e: SegmentElement, in ctx: CGContext) {
        withShadow(forStrokeWidth: e.width, in: ctx) {
            setStroke(ctx, e.color, e.width)
            ctx.beginPath()
            ctx.move(to: e.start)
            ctx.addLine(to: e.end)
            ctx.strokePath()
        }
    }

    private static func drawArrow(_ e: SegmentElement, in ctx: CGContext) {
        // Skitch-style arrow: one filled polygon (tapered shaft + barbed head).
        let outline = e.arrowOutline()
        guard let first = outline.first else { return }
        withShadow(forStrokeWidth: e.width, in: ctx) {
            setFill(ctx, e.color)
            ctx.beginPath()
            ctx.move(to: first)
            for p in outline.dropFirst() { ctx.addLine(to: p) }
            ctx.closePath()
            ctx.fillPath()
        }
    }

    private static func drawRect(_ e: ShapeElement, in ctx: CGContext) {
        withShadow(forStrokeWidth: e.width,
                   layerBounds: e.rect.insetBy(dx: -e.width / 2, dy: -e.width / 2), in: ctx) {
            if let fill = e.fill {
                setFill(ctx, fill)
                ctx.fill(e.rect)
            }
            setStroke(ctx, e.color, e.width)
            ctx.stroke(e.rect)
        }
    }

    private static func drawEllipse(_ e: ShapeElement, in ctx: CGContext) {
        withShadow(forStrokeWidth: e.width,
                   layerBounds: e.rect.insetBy(dx: -e.width / 2, dy: -e.width / 2), in: ctx) {
            if let fill = e.fill {
                setFill(ctx, fill)
                ctx.fillEllipse(in: e.rect)
            }
            setStroke(ctx, e.color, e.width)
            ctx.strokeEllipse(in: e.rect)
        }
    }

    private static func attributedString(for e: TextElement) -> NSAttributedString {
        let traits: CTFontSymbolicTraits = e.font.bold ? .traitBold : []
        let base = CTFontCreateWithName(e.font.family as CFString, e.font.pointSize, nil)
        let font = CTFontCreateCopyWithSymbolicTraits(base, e.font.pointSize, nil, traits, traits) ?? base
        let color = CGColor(red: e.color.r, green: e.color.g, blue: e.color.b, alpha: e.color.a)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return NSAttributedString(string: e.string, attributes: attrs)
    }

    /// Size needed to render the full string wrapped at the element's current
    /// width. CoreText drops lines that don't fit the frame rect, so callers
    /// must grow `size` to this value or overflowing text silently disappears.
    /// An empty string yields the one-line minimum height, so editors shrink
    /// back when all text is deleted.
    public static func suggestedSize(for e: TextElement) -> CGSize {
        guard !e.string.isEmpty else {
            return CGSize(width: e.size.width, height: e.font.pointSize + 8)
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(for: e))
        let constraint = CGSize(width: e.size.width, height: .greatestFiniteMagnitude)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        // +2 guards against fractional-height rounding clipping the last line.
        return CGSize(width: e.size.width, height: max(ceil(fit.height) + 2, e.font.pointSize + 8))
    }

    private static func drawText(_ e: TextElement, in ctx: CGContext) {
        guard !e.string.isEmpty else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(for: e))
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
        // The base image's identity plus its dimensions guards against a
        // recycled ObjectIdentifier serving stale pixels for a new image.
        let key = "\(ObjectIdentifier(base))|\(base.width)x\(base.height)|\(rect)|\(amount)|\(canvasSize.height)" as NSString
        if let cached = redactionCache.object(forKey: key) {
            drawImage(cached, in: rect, ctx: ctx)
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
        redactionCache.setObject(out, forKey: key, cost: out.bytesPerRow * out.height)
        drawImage(out, in: rect, ctx: ctx)
    }
}
