import Foundation

/// Raising the terminal app is a separate step from Herdr's own internal
/// focus (`workspace.focus` changes which pane Herdr considers focused; it
/// doesn't bring any window to the front). `SessionBackend.focus` means
/// "make this visible to the human," so `HerdrSessionBackend` does both -
/// this seam keeps the AppleScript/process-launching side injectable and
/// testable, mirroring how the transport itself is injected.
public protocol TerminalActivator: Sendable {
    func activate() async
}

public struct NoOpTerminalActivator: TerminalActivator {
    public init() {}
    public func activate() async {}
}

/// Brings the configured terminal app to the front via AppleScript, same
/// technique as mac-sesh's `Ghostty.focusApp()` (which this generalizes -
/// Ghostty was the only terminal shepherd supported until this became
/// configurable). Herdr's tab titles can't identify which tab of a
/// multi-window terminal hosts a given client, so app-level activation is
/// all that's possible - `workspace.focus` above already redirected
/// Herdr's own internal focus. Only works for terminals with an
/// AppleScript `activate` verb (Ghostty, iTerm2, Terminal.app); GPU
/// terminals like Alacritty/kitty/WezTerm have no scripting dictionary and
/// need a different mechanism entirely (out of scope for now).
public struct AppleScriptTerminalActivator: TerminalActivator {
    public let appName: String

    public init(appName: String) {
        self.appName = appName
    }

    public func activate() async {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application \"\(appName)\" to activate"]
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume()
            }
        }
    }
}
