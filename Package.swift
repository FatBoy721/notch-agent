// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchAgent",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchAgent", path: "Sources/NotchAgent")
    ]
)
