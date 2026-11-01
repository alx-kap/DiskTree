// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskTree",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DiskTree", path: "Sources/DiskTree")
    ]
)
