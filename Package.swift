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
        // Task files (markdown + frontmatter), the store, and the SessionStart hook logic. Foundation only.
        .target(
            name: "ShepherdTasks",
            path: "Sources/ShepherdTasks"
        ),
        // `crook`: the CLI agents use to keep their task's plan and log current.
        .executableTarget(
            name: "crook",
            dependencies: ["ShepherdTasks"],
            path: "Sources/crook"
        ),
        // Herdr-socket adapter: framing, wire DTOs, reducer, transport. Depends on Core.
        .target(
            name: "ShepherdHerdr",
            dependencies: ["ShepherdCore"],
            path: "Sources/ShepherdHerdr"
        ),
        // Ghostty-as-the-terminal backend: AppleScript driver, session records, hook-driven attention.
        // Depends on Core only (and Tasks for task-linked sessions).
        .target(
            name: "ShepherdGhostty",
            dependencies: ["ShepherdCore", "ShepherdTasks"],
            path: "Sources/ShepherdGhostty"
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
            dependencies: ["ShepherdCore", "ShepherdHerdr", "ShepherdGhostty", "ShepherdUI", "ShepherdWebKit"],
            path: "Sources/Shepherd",
            resources: [.copy("HookScripts")]
        ),
        // Prototype: a standalone HTTP+SSE bridge over the same
        // SessionBackend the menu bar app uses, for the mobile-web
        // experiment. Its own process (not the menu bar app) so it can be
        // iterated on and restarted without relaunching the GUI.
        .target(
            name: "ShepherdWebKit",
            dependencies: ["ShepherdCore", "ShepherdHerdr", "ShepherdUI"],
            path: "Sources/ShepherdWebKit",
            resources: [.copy("Public")]
        ),
        // Dev harness over ShepherdWebKit: the same server the menu bar app
        // hosts, runnable on its own (`swift run ShepherdWeb [--fake]`).
        .executableTarget(
            name: "ShepherdWeb",
            dependencies: ["ShepherdCore", "ShepherdHerdr", "ShepherdWebKit"],
            path: "Sources/ShepherdWeb"
        ),
        .testTarget(
            name: "ShepherdTasksTests",
            dependencies: ["ShepherdTasks"],
            path: "Tests/ShepherdTasksTests"
        ),
        .testTarget(
            name: "ShepherdGhosttyTests",
            dependencies: ["ShepherdGhostty", "ShepherdCore", "ShepherdTasks"],
            path: "Tests/ShepherdGhosttyTests"
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
            name: "ShepherdWebTests",
            dependencies: ["ShepherdWebKit"],
            path: "Tests/ShepherdWebTests"
        ),
        .testTarget(
            name: "ShepherdUITests",
            dependencies: ["ShepherdUI"],
            path: "Tests/ShepherdUITests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
