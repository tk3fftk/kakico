import Foundation
import CoreGraphics
import libwebp

/// Lossy WebP encoding via libwebp. macOS ImageIO decodes WebP but cannot
/// encode it, so export goes through libwebp instead.
public enum WebPEncoder {

    /// libwebp's WEBP_MAX_DIMENSION.
    public static let maxDimension = 16383

    /// Encodes a CGImage as lossy WebP. `quality` is a 0-1 fraction of
    /// libwebp's 0-100 scale. Returns nil when a side exceeds 16383 pixels
    /// (a WebP format limit) or the bitmap can't be read.
    public static func encodeLossy(_ image: CGImage, quality: CGFloat) -> Data? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension else { return nil }
        guard var rgba = straightRGBA(of: image) else { return nil }

        var output: UnsafeMutablePointer<UInt8>?
        let clamped = Float(min(max(quality, 0), 1)) * 100
        let size = rgba.withUnsafeMutableBufferPointer { buf in
            WebPEncodeRGBA(buf.baseAddress, Int32(width), Int32(height),
                           Int32(width * 4), clamped, &output)
        }
        guard size > 0, let output else { return nil }
        return Data(bytesNoCopy: UnsafeMutableRawPointer(output), count: size,
                    deallocator: .custom { ptr, _ in WebPFree(ptr) })
    }

    /// Straight-alpha RGBA8 bytes (row-major, top row first) for any CGImage,
    /// normalized by redrawing into an sRGB context the same way
    /// `Renderer.flatten` renders.
    ///
    /// The redraw allocates a second width x height x 4 buffer on top of the
    /// flattened bitmap, doubling peak memory on the WebP path. Accepted
    /// trade-off (PR #44 review): CGBitmapContext cannot draw straight alpha
    /// directly, avoiding the copy would need flatten to expose its raw
    /// buffer for in-place unpremultiply, and the overhead only matters near
    /// the 16383x16383 limit (~+1GB) — typical exports add tens of MB.
    private static func straightRGBA(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        unpremultiply(&rgba)
        return rgba
    }

    /// In-place premultiplied → straight alpha, with rounding. WebP stores
    /// straight alpha.
    private static func unpremultiply(_ rgba: inout [UInt8]) {
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let a = Int(rgba[i + 3])
            if a == 255 { continue }
            // a == 0: premultiplied RGB is already 0, only the division
            // needs skipping.
            if a == 0 { continue }
            for c in i..<(i + 3) {
                rgba[c] = UInt8(min(255, (Int(rgba[c]) * 255 + a / 2) / a))
            }
        }
    }
}
