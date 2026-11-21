// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MD5Precheck",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MD5Precheck", path: "Sources/MD5Precheck")
    ]
)
