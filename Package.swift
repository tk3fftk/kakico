// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kakico",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Kakico", targets: ["Kakico"]),
        .library(name: "AnnotationModel", targets: ["AnnotationModel"]),
        .library(name: "AnnotationRender", targets: ["AnnotationRender"]),
    ],
    dependencies: [
        // ImageIO cannot encode WebP, so WebP export uses libwebp.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "AnnotationModel"),
        .target(name: "AnnotationRender", dependencies: [
            "AnnotationModel",
            .product(name: "libwebp", package: "libwebp-Xcode"),
        ]),
        .executableTarget(
            name: "Kakico",
            dependencies: ["AnnotationModel", "AnnotationRender"]
        ),
        .testTarget(name: "KakicoTests", dependencies: ["Kakico"]),
        .testTarget(name: "AnnotationModelTests", dependencies: ["AnnotationModel"]),
        .testTarget(name: "AnnotationRenderTests", dependencies: ["AnnotationModel", "AnnotationRender"]),
    ]
)
