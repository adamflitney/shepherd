// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "ptyd",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")],
    targets: [
        .executableTarget(name: "ptyd", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "snap", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
