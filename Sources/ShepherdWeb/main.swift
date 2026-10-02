import Foundation
import ShepherdCore
import ShepherdHerdr
import ShepherdWebKit

// Dev harness: the same server the menu bar app hosts, as its own process.
// `--fake` mirrors the main app's demo-data flag, for UX iteration without a
// running Herdr; `--port N` lets a throwaway instance run alongside another.

setbuf(stdout, nil) // unbuffered - so `print` shows up immediately when redirected to a log file

let arguments = CommandLine.arguments
let port: UInt16 = arguments.firstIndex(of: "--port")
    .flatMap { arguments.indices.contains($0 + 1) ? UInt16(arguments[$0 + 1]) : nil } ?? 8787

let backend: any SessionBackend
if arguments.contains("--fake") {
    let fake = FakeSessionBackend(sessions: demoSessions)
    await fake.setPeekText(demoPermissionPeekText, for: SessionID(rawValue: "demo:permission"))
    await fake.setPeekText(demoQuestionPeekText, for: SessionID(rawValue: "demo:question"))
    backend = fake
} else {
    // Real terminal-raising (not the default no-op), same as the menu bar
    // app: "Focus" from the phone is meant to leave that session's window
    // frontmost on the Mac for whenever you get back to it.
    let herdrBackend = HerdrSessionBackend(
        requestClient: RequestClient(transport: UnixSocketTransport()),
        eventTransport: UnixSocketTransport(),
        terminalActivator: AppleScriptTerminalActivator(appName: ShepherdConfig.load().terminal.appName)
    )
    Task { await herdrBackend.startListening() }
    backend = herdrBackend
}

let server = MobileAccessServer(
    backend: backend,
    options: .init(
        port: port,
        keepAwake: !arguments.contains("--no-keep-awake"),
        onlyWhenAway: arguments.contains("--alerts-only-when-away")
    )
)
do {
    try await server.start()
} catch {
    print("Couldn't start: \(error)")
    exit(1)
}
print("Shepherd web listening on http://localhost:\(port) (loopback only; other devices reach it through `tailscale serve`)")

// Nothing else keeps the process alive - the listener runs on a dispatch
// queue, not this task.
try await Task.sleep(nanoseconds: .max)
