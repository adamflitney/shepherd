import Foundation
@testable import ShepherdGhostty

/// A Ghostty that records what it is asked to do and hands out predictable ids.
final class FakeGhosttyScripting: GhosttyScripting, @unchecked Sendable {
    enum Call: Equatable {
        case open(command: String, cwd: String, env: [String: String], windowID: String?)
        case inputText(String, terminal: String)
        case sendKey(String, modifiers: [String], terminal: String)
        case focus(String)
        case close(String)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _terminals: [GhosttyTerminalInfo] = []
    private var counter = 0
    var running = true
    var frontmost: String?
    var failOpenWith: GhosttyError?
    var calls: [Call] { lock.withLock { _calls } }

    func setTerminals(_ t: [GhosttyTerminalInfo]) { lock.withLock { _terminals = t } }

    func isRunning() async -> Bool { running }

    func open(command: String, workingDirectory: String, environment: [String: String], windowID: String?) async throws -> GhosttyTerminalRef {
        if let failOpenWith { throw failOpenWith }
        return lock.withLock {
            counter += 1
            _calls.append(.open(command: command, cwd: workingDirectory, env: environment, windowID: windowID))
            let ref = GhosttyTerminalRef(windowID: windowID ?? "win-1", tabID: "tab-\(counter)", terminalID: "term-\(counter)")
            _terminals.append(GhosttyTerminalInfo(ref: ref, name: ""))
            return ref
        }
    }

    func listTerminals() async throws -> [GhosttyTerminalInfo] {
        if !running { throw GhosttyError.notRunning }
        return lock.withLock { _terminals }
    }

    func inputText(_ text: String, terminalID: String) async throws { lock.withLock { _calls.append(.inputText(text, terminal: terminalID)) } }
    func sendKey(_ key: String, modifiers: [String], terminalID: String) async throws { lock.withLock { _calls.append(.sendKey(key, modifiers: modifiers, terminal: terminalID)) } }
    func focus(terminalID: String) async throws { lock.withLock { _calls.append(.focus(terminalID)) } }
    func close(terminalID: String) async throws {
        lock.withLock {
            _calls.append(.close(terminalID))
            _terminals.removeAll { $0.ref.terminalID == terminalID }
        }
    }
    func frontmostTerminalID() async throws -> String? { frontmost }
    func frontWindowID() async throws -> String? { "win-1" }
}

final class FakeProbe: ProcessProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _alive: Set<String> = []
    private var _terminated: [String] = []
    var alive: Set<String> {
        get { lock.withLock { _alive } }
        set { lock.withLock { _alive = newValue } }
    }
    var terminated: [String] { lock.withLock { _terminated } }
    /// Treat every session as alive unless told otherwise.
    var everythingAlive = true

    func aliveSessions(among ids: [String]) async -> Set<String> {
        lock.withLock { everythingAlive ? Set(ids) : Set(ids).intersection(_alive) }
    }
    func terminate(sessionID: String) async { lock.withLock { _terminated.append(sessionID) } }
}

final class MemoryWindowStore: AgentsWindowStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func get() -> String? { lock.withLock { value } }
    func set(_ windowID: String?) { lock.withLock { value = windowID } }
}
