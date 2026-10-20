import AppKit
import ShepherdCore
import ShepherdGhostty
import ShepherdHerdr
import ShepherdHolder
import ShepherdHolderBackend
import ShepherdTerminalBridge

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

    let backend: any SessionBackend
    var onTerminalAppNameChanged: ((String) -> Void)?
    var useFrontGhosttyWindow: (() async throws -> Void)?
    var terminals: TerminalBridgeConfig?
    let args = CommandLine.arguments
    let environmentBackend = ProcessInfo.processInfo.environment["SHEPHERD_BACKEND"]
    let useHerdr = args.contains("--herdr")
        || environmentBackend == "herdr"
        || (!args.contains("--ghostty") && ShepherdConfig.load().backend.isHerdr)
    // Holders are the default; `--ghostty` / `SHEPHERD_BACKEND=ghostty` / `backend.kind: "ghostty"` pick the Ghostty tabs.
    let wantsGhostty = args.contains("--ghostty") || environmentBackend == "ghostty"
        || (!args.contains("--holder") && environmentBackend != "holder" && ShepherdConfig.load().backend.isGhostty)
    let useHolder = !useHerdr && !wantsGhostty
    // The holder backend has a window of its own (the dashboard), so it gets a Dock icon; the others stay menu-bar only.
    app.setActivationPolicy(useHolder ? .regular : .accessory)
    if args.contains("--fake") {
        backend = FakeSessionBackend(sessions: DemoSessions.all)
    } else if useHolder {
        // Agents run in PTY holders that outlive the app; the dashboard window (see AppDelegate) is where they are shown.
        let crook = HookInstaller.crookURL.path
        let registry = SessionRegistry.standard
        let holderExecutable = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("shepherd-holder").path
        let holderBackend = HolderSessionBackend(
            registry: registry,
            launcher: HolderLauncher(registry: registry, holderExecutable: holderExecutable),
            crookPath: FileManager.default.isExecutableFile(atPath: crook) ? crook : nil,
            remoteControlNames: ShepherdConfig.load().backend.remoteControlNames ?? true,
            prSync: TaskPRSync())
        Task { await holderBackend.startListening() }
        backend = holderBackend
        // Browsers (the phone, later the dashboard) attach to the same holders over /ws, and may start sessions in the
        // folders the web server offers as start targets.
        terminals = TerminalBridgeConfig(
            registry: registry,
            spawn: { request in
                let id = try await holderBackend.createSession(CreateSessionRequest(
                    workingDirectory: URL(fileURLWithPath: request.cwd), agent: .claude, title: request.title, taskID: request.taskID))
                guard let holderID = await holderBackend.holderID(for: id) else { throw BackendError.unavailable("the session did not start") }
                return holderID
            })
    } else if !useHerdr {
        // Agents run in ordinary Ghostty tabs and are driven through Ghostty's AppleScript interface.
        let crook = HookInstaller.crookURL.path
        let ghosttyBackend = GhosttySessionBackend(crookPath: FileManager.default.isExecutableFile(atPath: crook) ? crook : nil)
        Task { await ghosttyBackend.startListening() }
        backend = ghosttyBackend
        useFrontGhosttyWindow = { _ = try await ghosttyBackend.useFrontmostWindowForAgents() }
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

    let delegate = AppDelegate(
        backend: backend,
        onTerminalAppNameChanged: onTerminalAppNameChanged,
        useFrontGhosttyWindow: useFrontGhosttyWindow,
        terminals: terminals
    )
    app.delegate = delegate
    app.run()
}
