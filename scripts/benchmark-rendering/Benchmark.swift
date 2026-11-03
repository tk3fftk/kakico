import Foundation
import CoreGraphics
import AnnotationModel
import AnnotationRender

func document(size: CGSize, count: Int, width: CGFloat) -> Document {
    var doc = Document(baseImage: .pngData(Data()), canvasSize: size)
    for i in 0..<count {
        let x = CGFloat((i * 173) % (Int(size.width) - 240))
        let y = CGFloat((i * 97) % (Int(size.height) - 240))
        let color = RGBAColor(r: 1, g: 0.2, b: 0.1, a: 0.6)
        let shape = ShapeElement(rect: CGRect(x: x, y: y, width: 130, height: 95),
                                 color: color, width: width,
                                 fill: RGBAColor(r: 0.1, g: 0.6, b: 1, a: 0.35))
        let line = SegmentElement(start: CGPoint(x: x, y: y + 140),
                                  end: CGPoint(x: x + 160, y: y + 20), color: color, width: width)
        switch i % 4 {
        case 0: doc.add(.arrow(line))
        case 1: doc.add(.line(line))
        case 2: doc.add(.rectangle(shape))
        default: doc.add(.ellipse(shape))
        }
    }
    return doc
}

#if CURRENT_CACHE
let modes = ["normal", "cache"]
#else
let modes = ["normal"]
#endif
for size in [CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160)] {
    for count in [1, 20, 100] {
        for width: CGFloat in [6, 24] {
            for index in Set([0, count / 2, count - 1]).sorted() {
                for mode in modes {
                    var doc = document(size: size, count: count, width: width)
                    #if CURRENT_CACHE
                    let cache = Renderer.CanvasCache()
                    #endif
                    for frame in 0..<35 {
                        doc.elements[index].translate(by: CGVector(dx: 1, dy: 0))
                        let ms: Double = autoreleasepool {
                            let start = DispatchTime.now().uptimeNanoseconds
                            let image: CGImage?
                            #if CURRENT_CACHE
                            image = mode == "cache"
                                ? cache.flatten(doc, baseImage: nil, activeElementID: doc.elements[index].id)
                                : Renderer.flatten(doc, baseImage: nil)
                            #else
                            image = Renderer.flatten(doc, baseImage: nil)
                            #endif
                            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                            guard let image, image.width == Int(size.width), image.height == Int(size.height) else {
                                fatalError("Renderer returned a missing or incorrectly sized image")
                            }
                            withExtendedLifetime(image) {}
                            return elapsed
                        }
                        print("SAMPLE,\(Int(size.width)),\(count),\(Int(width)),\(index),\(mode),\(frame),\(ms)")
                    }
                }
            }
        }
    }
}
print("BENCHMARK_COMPLETE")
