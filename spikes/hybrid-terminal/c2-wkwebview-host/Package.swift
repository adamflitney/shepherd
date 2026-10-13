// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "c2host",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "c2host", path: "Sources/c2host")]
)
