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
        // Pinned exactly: third-party fork of a CVE-prone C library, so new
        // revisions should land only through a reviewed bump.
        // 1.5.0
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", revision: "0d60654eeefd5d7d2bef3835804892c40225e8b2"),
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
