// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StorageScope",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "StorageScope", path: "Sources/StorageScope")
    ]
)
