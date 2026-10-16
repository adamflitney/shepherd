import Darwin
import Foundation
import ShepherdHolder
import ShepherdTerminalBridge
import Testing
@testable import ShepherdWebKit

/// The real HTTP server, the real bridge and real holders (the built `shepherd-holder`), with a URLSession WebSocket
/// client and a raw socket for the things no client would send.
private final class Rig: @unchecked Sendable {
    let root: URL
    let registry: SessionRegistry
    let launcher: HolderLauncher
    let server: HTTPServer
    let bridge: TerminalBridge
    let port: UInt16
    let allowedDirectory = "/tmp"

    static func holderExecutable() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { url.deleteLastPathComponent() }
        let candidates = [".build/debug/shepherd-holder", ".build/arm64-apple-macosx/debug/shepherd-holder", ".build/x86_64-apple-macosx/debug/shepherd-holder"]
        guard let found = candidates.map({ url.appendingPathComponent($0).path }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "rig", code: 1, userInfo: [NSLocalizedDescriptionKey: "shepherd-holder is not built"])
        }
        return found
    }

    init() async throws {
        root = URL(fileURLWithPath: "/tmp/tb-\(UUID().uuidString.prefix(6))")
        registry = SessionRegistry(directory: root.appendingPathComponent("s"))
        launcher = HolderLauncher(registry: registry, holderExecutable: try Self.holderExecutable(), allowShell: true)
        let launcher = self.launcher
        let config = TerminalBridgeConfig(
            registry: registry,
            isDirectoryAllowed: { $0 == "/tmp" || $0.hasPrefix("/tmp/") || $0 == "/private/tmp" || $0.hasPrefix("/private/tmp/") },
            spawn: { request in
                let spec = SessionSpec(agent: .shell, cwd: request.cwd, argv: ["/bin/sh", "-c", "echo spawned; sleep 60"], title: request.title)
                return try launcher.launch(spec).id
            })
        bridge = TerminalBridge(config: config)
        let bridge = self.bridge
        var started: (HTTPServer, UInt16)?
        for _ in 0..<20 where started == nil {
            let p = UInt16.random(in: 20_000...40_000)
            let s = try HTTPServer(
                port: p, queue: DispatchQueue(label: "test-ws-server"),
                router: { _ in .notFound() },
                sseEvents: { AsyncStream { $0.finish() } },
                upgrade: { request, connection in
                    bridge.adopt(connection: connection, headers: request.headers, leftover: Data())
                    return true
                })
            if (try? await s.start()) != nil { started = (s, p) }
        }
        guard let started else { throw NSError(domain: "rig", code: 2) }
        (server, port) = started
    }

    func holder(_ script: String) throws -> String {
        try launcher.launch(SessionSpec(agent: .shell, cwd: "/tmp", argv: ["/bin/sh", "-c", script])).id
    }

    /// Synchronous so a test can `defer` it: a fire-and-forget task would be cut off when the test run ends.
    func stopBlocking() {
        bridge.shutdown()
        let done = DispatchSemaphore(value: 0)
        let server = self.server
        Task.detached { await server.stop(); done.signal() }
        _ = done.wait(timeout: .now() + 3)
        for r in registry.all() { HolderClient.kill(socketPath: registry.socketPath(r.id)) }
        usleep(400_000)
        try? FileManager.default.removeItem(at: root)
    }
}

/// A WebSocket client that records everything the server sends.
private final class Client: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var texts: [[String: Any]] = []
    private var binary = Data()
    private(set) var ended = false

    init(port: UInt16, protocols: [String] = ["shepherd-v1"]) {
        task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!, protocols: protocols)
        task.resume()
        Task { await pump() }
    }

    init(request: URLRequest) {
        task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        task.resume()
        Task { await pump() }
    }

    private func pump() async {
        while true {
            guard let message = try? await task.receive() else { lock.withLock { ended = true }; return }
            lock.withLock {
                switch message {
                case .string(let s): if let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] { texts.append(o) }
                case .data(let d): binary.append(d)
                @unknown default: break
                }
            }
        }
    }

    func send(_ object: [String: Any]) async {
        let data = try! JSONSerialization.data(withJSONObject: object)
        try? await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
    func type(_ text: String) async { try? await task.send(.data(Data(text.utf8))) }
    func close() { task.cancel(with: .goingAway, reason: nil) }

    var output: String { lock.withLock { String(decoding: binary, as: UTF8.self) } }
    func messages(ofType type: String) -> [[String: Any]] { lock.withLock { texts.filter { $0["type"] as? String == type } } }

    func waitForMessage(_ type: String, seconds: Double = 5) async -> [String: Any]? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let m = messages(ofType: type).first { return m }
            if lock.withLock({ ended }) { return nil }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return nil
    }

    func waitForOutput(containing text: String, seconds: Double = 5) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if output.contains(text) { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return false
    }

    func waitUntilEnded(seconds: Double = 5) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if lock.withLock({ ended }) { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return false
    }
}

private func originRequest(port: UInt16, origin: String) -> URLRequest {
    var r = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/ws")!)
    r.setValue("shepherd-v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
    r.setValue(origin, forHTTPHeaderField: "Origin")
    return r
}

/// Opens a TCP connection, completes the WebSocket handshake by hand and returns the fd and what followed the headers.
private func rawHandshake(port: UInt16, extraHeaders: String = "", protocolHeader: String = "Sec-WebSocket-Protocol: shepherd-v1\r\n") -> (fd: Int32, response: String)? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard connected == 0 else { close(fd); return nil }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    let request = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n\(protocolHeader)\(extraHeaders)\r\n"
    _ = request.withCString { send(fd, $0, strlen($0), 0) }
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !received.contains(0x0a) || String(decoding: received, as: UTF8.self).range(of: "\r\n\r\n") == nil {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { break }
        received.append(contentsOf: buffer[0..<n])
    }
    return (fd, String(decoding: received, as: UTF8.self))
}

private func readAll(_ fd: Int32, seconds: Int = 2) -> [UInt8] {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var out: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { break }
        out += buffer[0..<n]
    }
    return out
}

@Suite("Terminal bridge", .serialized)
struct TerminalBridgeIntegrationTests {
    @Test func listsAttachesAndCarriesInputAndOutput() async throws {
        let rig = try await Rig(); defer { rig.stopBlocking() }
        let id = try rig.holder("echo ready; while IFS= read -r l; do echo got:$l; done")
        let c = Client(port: rig.port)
        #expect(await c.waitForMessage("hello") != nil)

        await c.send(["type": "list"])
        let list = try #require(await c.waitForMessage("sessions"))
        #expect((list["sessions"] as? [[String: Any]])?.contains { $0["id"] as? String == id } == true)

        await c.send(["type": "attach", "id": id, "cols": 100, "rows": 30])
        #expect(await c.waitForMessage("attached") != nil)
        #expect(await c.waitForMessage("ready") != nil)
        #expect(await c.waitForOutput(containing: "ready"))
        await c.type("hi\n")
        #expect(await c.waitForOutput(containing: "got:hi"))
        c.close()
    }

    @Test func refusesAClientThatDoesNotSpeakTheProtocol() async throws {
        let rig = try await Rig(); defer { rig.stopBlocking() }
        let c = Client(port: rig.port, protocols: ["something-else"])
        #expect(await c.waitForMessage("hello", seconds: 2) == nil)
        #expect(await c.waitUntilEnded())
    }

    @Test func refusesABrowserOnAnotherPort() async throws {
        let rig = try await Rig(); defer { rig.stopBlocking() }
        let other = Client(request: originRequest(port: rig.port, origin: "http://127.0.0.1:\(rig.port &+ 1)"))
        #expect(await other.waitForMessage("hello", seconds: 2) == nil)
        let same = Client(request: originRequest(port: rig.port, origin: "http://127.0.0.1:\(rig.port)"))
        #expect(await same.waitForMessage("hello") != nil)
        same.close()
    }

    @Test func startsSessionsOnlyInAllowedDirectories() async throws {
        let rig = try await Rig(); defer { rig.stopBlocking() }
        let c = Client(port: rig.port)
        _ = await c.waitForMessage("hello")
        await c.send(["type": "spawn", "cwd": "/etc", "cols": 80, "rows": 24])
        let refused = try #require(await c.waitForMessage("error"))
        #expect((refused["message"] as? String)?.contains("not allowed") == true)
        await c.send(["type": "spawn", "cwd": "/tmp", "cols": 80, "rows": 24, "title": "from the phone"])
        let spawned = try #require(await c.waitForMessage("spawned"))
        let id = try #require(spawned["id"] as? String)
        #expect(rig.registry.load(id)?.title == "from the phone")
        c.close()
    }

    @Test func twoBrowsersShareASessionAndTheLastToTypeSetsTheSize() async throws {
        let rig = try await Rig(); defer { rig.stopBlocking() }
        let id = try rig.holder("echo shared; while IFS= read -r l; do echo got:$l; done")
        let a = Client(port: rig.port), b = Client(port: rig.port)
        _ = await a.waitForMessage("hello"); _ = await b.waitForMessage("hello")
        await a.send(["type": "attach", "id": id, "cols": 100, "rows": 30])
        #expect(await a.waitForMessage("ready") != nil)
        await a.send(["type": "resize", "cols": 100, "rows": 30])   // a page sizes itself once attached, which makes it the driver
        await b.send(["type": "attach", "id": id, "cols": 60, "rows": 20])
        let attached = try #require(await b.waitForMessage("attached"))
        #expect(attached["cols"] as? Int == 100)   // a joiner sees the session's size, it does not resize it
        #expect(await b.waitForMessage("ready") != nil)

        await b.send(["type": "resize", "cols": 70, "rows": 22])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(HolderClient.info(socketPath: rig.registry.socketPath(id))?.cols == 100)   // not typing: held back

        await b.type("from b\n")
        #expect(await a.waitForOutput(containing: "got:from b"))
        #expect(await a.waitForMessage("size") != nil)
        #expect(HolderClient.info(socketPath: rig.registry.socketPath(id))?.cols == 70)
        a.close(); b.close()
    }

    @Test func detachingStopsOutputAndReattachingReplaysIt() async throws {
        let rig = try await Rig(); defer { rig.stopBlocking() }
        let id = try rig.holder("echo earlier; sleep 60")
        let c = Client(port: rig.port)
        _ = await c.waitForMessage("hello")
        await c.send(["type": "attach", "id": id, "cols": 80, "rows": 24])
        #expect(await c.waitForOutput(containing: "earlier"))
        await c.send(["type": "detach"])
        #expect(await c.waitForMessage("detached") != nil)
        let c2 = Client(port: rig.port)
        _ = await c2.waitForMessage("hello")
        await c2.send(["type": "attach", "id": id, "cols": 80, "rows": 24])
        #expect(await c2.waitForOutput(containing: "earlier"))
        c.close(); c2.close()
    }

    @Test func tellsABrowserWhenItsSessionEnds() async throws {
        let rig = try await Rig(); defer { rig.stopBlocking() }
        let id = try rig.holder("sleep 60")
        let c = Client(port: rig.port)
        _ = await c.waitForMessage("hello")
        await c.send(["type": "attach", "id": id, "cols": 80, "rows": 24])
        #expect(await c.waitForMessage("ready") != nil)
        HolderClient.kill(socketPath: rig.registry.socketPath(id))
        #expect(await c.waitForMessage("detached") != nil)
        c.close()
    }

    @Test func rejectsBadControlMessagesWithoutDroppingTheConnectionUntilTheLimit() async throws {
        let rig = try await Rig(); defer { rig.stopBlocking() }
        let c = Client(port: rig.port)
        _ = await c.waitForMessage("hello")
        await c.send(["type": "nonsense"])
        await c.send(["type": "attach", "id": "../../etc/passwd", "cols": 80, "rows": 24])
        await c.send(["type": "attach", "id": "nothere", "cols": 99999, "rows": 24])
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(c.messages(ofType: "error").count >= 3)
        await c.send(["type": "list"])
        #expect(await c.waitForMessage("sessions") != nil)
        c.close()
    }

    @Test func protocolViolationsCloseTheConnectionAndTheServerSurvives() async throws {
        let rig = try await Rig(); defer { rig.stopBlocking() }
        // an unmasked frame
        var (fd, response) = try #require(rawHandshake(port: rig.port))
        #expect(response.hasPrefix("HTTP/1.1 101"))
        _ = send(fd, [0x81, 0x01, 0x41] as [UInt8], 3, 0)
        var bytes = readAll(fd)
        close(fd)
        #expect(bytes.contains(0x88))   // a close frame came back (after the hello text frame)
        // a frame that claims to be 2^62 bytes long
        (fd, response) = try #require(rawHandshake(port: rig.port))
        _ = send(fd, [0x82, 0xff, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] as [UInt8], 14, 0)
        bytes = readAll(fd)
        close(fd)
        #expect(bytes.contains(0x88))
        // the server still answers
        let c = Client(port: rig.port)
        #expect(await c.waitForMessage("hello") != nil)
        c.close()
    }

    @Test func refusesABadUpgradeRequest() async throws {
        let rig = try await Rig(); defer { rig.stopBlocking() }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = rig.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let request = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:\(rig.port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: not-base64\r\nSec-WebSocket-Protocol: shepherd-v1\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        let response = String(decoding: readAll(fd), as: UTF8.self)
        close(fd)
        #expect(response.hasPrefix("HTTP/1.1 400"))
    }

    @Test func manyConnectionsAreCappedAndClosedOnesAreForgotten() async throws {
        let rig = try await Rig(); defer { rig.stopBlocking() }
        let clients = (0..<5).map { _ in Client(port: rig.port) }
        for c in clients { _ = await c.waitForMessage("hello") }
        #expect(rig.bridge.connectionCount == 5)
        clients.forEach { $0.close() }
        for _ in 0..<50 where rig.bridge.connectionCount > 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(rig.bridge.connectionCount == 0)
    }
}
