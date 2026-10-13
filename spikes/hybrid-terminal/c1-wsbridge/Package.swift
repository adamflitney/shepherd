// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "wsbridge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ptyd", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "wsbridge", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "nwprobe", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
