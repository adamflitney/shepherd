import Foundation
import ShepherdCore
import ShepherdHerdr

// Prototype entry point: a standalone process (not the menu bar app) that
// opens its own Herdr connection and serves the mobile web UI + JSON API
// over plain HTTP on the local network. `--fake` mirrors the main app's
// demo-data flag, for UX iteration without a running Herdr instance.

setbuf(stdout, nil) // unbuffered - so `print` below shows up immediately when redirected to a log file

// `--port N` lets a throwaway instance (e.g. `--fake` on another port) run
// alongside the real one.
let port: UInt16 = CommandLine.arguments.firstIndex(of: "--port")
    .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? UInt16(CommandLine.arguments[$0 + 1]) : nil } ?? 8787

let backend: any SessionBackend
if CommandLine.arguments.contains("--fake") {
    let fake = FakeSessionBackend(sessions: demoSessions)
    await fake.setPeekText(demoPermissionPeekText, for: SessionID(rawValue: "demo:permission"))
    await fake.setPeekText(demoQuestionPeekText, for: SessionID(rawValue: "demo:question"))
    backend = fake
} else {
    // Real terminal-raising (not the default no-op), same as the menu bar
    // app: "Focus" from the phone is meant to leave that session's window
    // frontmost on the Mac for whenever you get back to it, not just
    // update Herdr's own internal focus state invisibly.
    let herdrBackend = HerdrSessionBackend(
        requestClient: RequestClient(transport: UnixSocketTransport()),
        eventTransport: UnixSocketTransport(),
        terminalActivator: AppleScriptTerminalActivator(appName: ShepherdConfig.load().terminal.appName)
    )
    Task { await herdrBackend.startListening() }
    backend = herdrBackend
}

let api = SessionsAPI(backend: backend)

// VAPID `sub` is a contact URI the push service can use to reach the
// operator - a project URL rather than a personal email address, since it's
// sent to Apple/Google with every push.
let pushDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".shepherd/web-push")
let push = try PushService(directory: pushDirectory, subject: "https://github.com/adamflitney/shepherd")
let pushAPI = PushAPI(push: push)
Task { await runPushNotifier(backend: backend, push: push) }

if !CommandLine.arguments.contains("--no-keep-awake") {
    let keepAwake = KeepAwakeController(assertion: SystemSleepAssertion())
    Task { await runKeepAwake(backend: backend, controller: keepAwake) }
}
let publicDirectory = locatePublicDirectory()

let server = try HTTPServer(
    port: port,
    router: { request in
        if request.method == "GET", !request.path.hasPrefix("/api/") {
            return serveStaticFile(request.path, from: publicDirectory)
        }
        if request.path.hasPrefix("/api/push/") {
            return await pushAPI.handle(request)
        }
        return await api.handle(request)
    },
    sseEvents: { backend.events() }
)

print("Shepherd web prototype listening on http://localhost:\(port) (also reachable at http://<this-mac's-lan-ip>:\(port) on your home network)")
await server.start()

// `main.swift` needs something to keep the process alive - the server's
// own NWListener runs on a dispatch queue, not this task, so block forever
// rather than falling off the end of the script.
try await Task.sleep(nanoseconds: .max)
