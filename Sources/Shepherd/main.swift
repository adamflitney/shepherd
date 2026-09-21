import AppKit
import ShepherdCore
import ShepherdHerdr

// Headless hook install/uninstall, for scripting or a terminal-triggered
// switch - the same `HookInstaller` the menu bar's "Install/Uninstall
// Hooks…" item calls, just reachable without a GUI click.
if CommandLine.arguments.contains("--install-hooks") {
    do {
        try HookInstaller.install()
        print("Hooks installed.")
        exit(0)
    } catch {
        print("Hook install failed: \(error)")
        exit(1)
    }
}
if CommandLine.arguments.contains("--uninstall-hooks") {
    do {
        try HookInstaller.uninstall()
        print("Hooks uninstalled.")
        exit(0)
    } catch {
        print("Hook uninstall failed: \(error)")
        exit(1)
    }
}

// @main entry is always called on the main thread; MainActor.assumeIsolated
// lets us call @MainActor-isolated AppKit APIs without an async context.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let backend: any SessionBackend
    var onTerminalAppNameChanged: ((String) -> Void)?
    if CommandLine.arguments.contains("--fake") {
        backend = FakeSessionBackend(sessions: DemoSessions.all)
    } else {
        let herdrBackend = HerdrSessionBackend(
            requestClient: RequestClient(transport: UnixSocketTransport()),
            eventTransport: UnixSocketTransport(),
            terminalActivator: AppleScriptTerminalActivator(appName: ShepherdConfig.load().terminal.appName)
        )
        // startListening() launches its own internal task loop and returns
        // quickly; fire-and-forget is fine since main.swift has no async
        // context to await it in.
        Task { await herdrBackend.startListening() }
        backend = herdrBackend
        onTerminalAppNameChanged = { appName in
            Task { await herdrBackend.setTerminalActivator(AppleScriptTerminalActivator(appName: appName)) }
        }
    }

    let delegate = AppDelegate(backend: backend, onTerminalAppNameChanged: onTerminalAppNameChanged)
    app.delegate = delegate
    app.run()
}
