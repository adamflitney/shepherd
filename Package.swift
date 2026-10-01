// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shepherd",
    platforms: [.macOS(.v14)],
    targets: [
        // Domain model, SessionBackend protocol, FakeSessionBackend. No Herdr knowledge.
        .target(
            name: "ShepherdCore",
            path: "Sources/ShepherdCore"
        ),
        // Herdr-socket adapter: framing, wire DTOs, reducer, transport. Depends on Core.
        .target(
            name: "ShepherdHerdr",
            dependencies: ["ShepherdCore"],
            path: "Sources/ShepherdHerdr"
        ),
        // @Observable view models + SwiftUI views. Depends on Core ONLY — this boundary
        // is what keeps UI decoupled from Herdr's wire format.
        .target(
            name: "ShepherdUI",
            dependencies: ["ShepherdCore"],
            path: "Sources/ShepherdUI"
        ),
        // App entry point: backend selection, NSStatusItem, panel window.
        .executableTarget(
            name: "Shepherd",
            dependencies: ["ShepherdCore", "ShepherdHerdr", "ShepherdUI"],
            path: "Sources/Shepherd",
            resources: [.copy("HookScripts")]
        ),
        // Prototype: a standalone HTTP+SSE bridge over the same
        // SessionBackend the menu bar app uses, for the mobile-web
        // experiment. Its own process (not the menu bar app) so it can be
        // iterated on and restarted without relaunching the GUI.
        .executableTarget(
            name: "ShepherdWeb",
            dependencies: ["ShepherdCore", "ShepherdHerdr", "ShepherdUI"],
            path: "Sources/ShepherdWeb",
            resources: [.copy("Public")]
        ),
        .testTarget(
            name: "ShepherdCoreTests",
            dependencies: ["ShepherdCore"],
            path: "Tests/ShepherdCoreTests"
        ),
        .testTarget(
            name: "ShepherdHerdrTests",
            dependencies: ["ShepherdHerdr"],
            path: "Tests/ShepherdHerdrTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ShepherdUITests",
            dependencies: ["ShepherdUI"],
            path: "Tests/ShepherdUITests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
