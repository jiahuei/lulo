// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Lulo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LuloCore", targets: ["LuloCore"]),
        .library(name: "LuloImaging", targets: ["LuloImaging"]),
    ],
    targets: [
        .target(name: "LuloCore"),
        .target(name: "LuloImaging", dependencies: ["LuloCore"]),
        .testTarget(name: "LuloCoreTests", dependencies: ["LuloCore"]),
        .testTarget(name: "LuloImagingTests", dependencies: ["LuloImaging", "LuloCore"]),
    ]
)
