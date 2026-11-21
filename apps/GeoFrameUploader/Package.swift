// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GeoFrameUploader",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UploaderCore", targets: ["UploaderCore"]),
        .executable(name: "GeoFrameUploader", targets: ["GeoFrameUploader"]),
    ],
    targets: [
        .target(name: "UploaderCore", path: "Sources/UploaderCore"),
        .executableTarget(
            name: "GeoFrameUploader",
            dependencies: ["UploaderCore"],
            path: "Sources/GeoFrameUploader"
        ),
        .testTarget(
            name: "UploaderCoreTests",
            dependencies: ["UploaderCore"],
            path: "Tests/UploaderCoreTests"
        ),
    ]
)
