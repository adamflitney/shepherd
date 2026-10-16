import Foundation
import Testing
@testable import ShepherdHolder

/// A real holder on a real PTY, run on a thread of the test process.
final class RunningHolder: @unchecked Sendable {
    let registry: SessionRegistry
    let id = SessionSpec.newID()
    let holder: Holder
    private let finished = DispatchSemaphore(value: 0)
    private(set) var result: SessionRecord?

    var socket: String { registry.socketPath(id) }

    init(script: String, cols: Int = 80, rows: Int = 24, ringBytes: Int = 512 * 1024, exitGrace: TimeInterval = 0.3) {
        let dir = "/tmp/sh-\(UUID().uuidString.prefix(6))"
        registry = SessionRegistry(directory: URL(fileURLWithPath: dir))
        let record = SessionRecord(id: id, agent: .shell, cwd: "/tmp", argv: ["/bin/sh", "-c", script], cols: cols, rows: rows)
        holder = Holder(config: HolderConfig(record: record, registry: registry, ringBytes: ringBytes, exitGrace: exitGrace))
        let h = holder
        Thread.detachNewThread { [self] in
            result = h.run()
            finished.signal()
        }
        var tries = 0
        while !HolderClient.isLive(socketPath: socket), tries < 100 { usleep(20_000); tries += 1 }
    }

    func stopAndWait() {
        holder.stop()
        _ = finished.wait(timeout: .now() + 5)
        try? FileManager.default.removeItem(at: registry.directory)
    }

    func waitUntilFinished(seconds: Double = 5) -> SessionRecord? {
        _ = finished.wait(timeout: .now() + seconds)
        return result
    }
}

@Suite("Holder", .serialized)
struct HolderTests {
    @Test func replaysEarlierOutputToALateClientAndTakesInput() throws {
        let h = RunningHolder(script: "echo first; read line; echo got:$line; sleep 30")
        defer { h.stopAndWait() }
        let a = try #require(HolderClient.attach(socketPath: h.socket))
        #expect(String(decoding: a.replay, as: UTF8.self).contains("first") || a.read(until: "first", timeoutMs: 3000).found)
        a.send(Array("hello\r".utf8))
        #expect(a.read(until: "got:hello", timeoutMs: 3000).found)
        a.detach()

        let b = try #require(HolderClient.attach(socketPath: h.socket))
        let replay = String(decoding: b.replay, as: UTF8.self)
        #expect(replay.contains("first") && replay.contains("got:hello"))
        b.detach()
    }

    @Test func tellsALateClientWhichModesAreOn() throws {
        let h = RunningHolder(script: "printf '\\033[?1049h\\033[?2004h'; sleep 30")
        defer { h.stopAndWait() }
        for _ in 0..<50 where (HolderClient.info(socketPath: h.socket)?.modes ?? []).isEmpty { usleep(20_000) }
        let a = try #require(HolderClient.attach(socketPath: h.socket))
        #expect(a.modes == [1049, 2004])
        a.detach()
    }

    @Test func appliesTheSizeAClientAsksFor() throws {
        let h = RunningHolder(script: "sleep 0.2; stty size; sleep 30", cols: 80, rows: 24)
        defer { h.stopAndWait() }
        let a = try #require(HolderClient.attach(socketPath: h.socket, cols: 132, rows: 43))
        #expect(a.read(until: "43 132", timeoutMs: 3000).found)
        a.resize(cols: 90, rows: 20)
        usleep(100_000)
        #expect(HolderClient.info(socketPath: h.socket)?.cols == 90)
        a.detach()
    }

    @Test func recordsAnExitAndEndsByItself() throws {
        let h = RunningHolder(script: "echo bye; exit 3")
        let record = try #require(h.waitUntilFinished())
        #expect(record.state == .exited)
        #expect(record.exitStatus == 3)
        #expect(h.registry.load(h.id)?.state == .exited)
        #expect(!HolderClient.isLive(socketPath: h.socket))
        try? FileManager.default.removeItem(at: h.registry.directory)
    }

    @Test func killEndsTheSessionAndRecordsIt() throws {
        let h = RunningHolder(script: "sleep 60")
        #expect(HolderClient.kill(socketPath: h.socket))
        let record = try #require(h.waitUntilFinished())
        #expect(record.state == .killed)
        #expect(h.registry.load(h.id)?.state == .killed)
        try? FileManager.default.removeItem(at: h.registry.directory)
    }

    @Test func aClientThatNeverReadsIsDroppedAndTheHolderKeepsServing() throws {
        let h = RunningHolder(script: "yes 0123456789abcdef")
        defer { h.stopAndWait() }
        let stalled = try #require(HolderClient.attach(socketPath: h.socket))
        var answered = 0
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            if HolderClient.info(socketPath: h.socket) != nil { answered += 1 }
            usleep(100_000)
        }
        #expect(answered >= 10)
        var dropped = false
        let drain = Date()
        while Date().timeIntervalSince(drain) < 5 {
            if stalled.read(timeoutMs: 100) == nil { dropped = true; break }
        }
        #expect(dropped)
        let fresh = try #require(HolderClient.attach(socketPath: h.socket))
        #expect(fresh.read(timeoutMs: 1000)?.isEmpty == false)
        fresh.detach()
    }

    @Test func garbageDoesNotHurtTheHolder() throws {
        let h = RunningHolder(script: "sleep 30")
        defer { h.stopAndWait() }
        func send(_ bytes: [UInt8]) {
            guard let fd = connectUnix(h.socket) else { return }
            _ = writeAll(fd, bytes)
            usleep(50_000)
            close(fd)
        }
        send(Array("not json\n".utf8))
        send(Array("{\"op\":\"explode\"}\n".utf8))
        send([UInt8](repeating: 65, count: 100_000))
        send(Array("{\"op\":\"attach\"}\n".utf8) + [0, 0xff, 0xff, 0xff, 0xff])
        send(Array("{\"op\":\"attach\"}\n".utf8) + [9, 0, 0, 0, 0])
        #expect(HolderClient.info(socketPath: h.socket)?.alive == true)
    }

    @Test func refusesClientsBeyondTheCap() throws {
        let dir = "/tmp/sh-\(UUID().uuidString.prefix(6))"
        let registry = SessionRegistry(directory: URL(fileURLWithPath: dir))
        let record = SessionRecord(id: "cap1", agent: .shell, cwd: "/tmp", argv: ["/bin/sh", "-c", "sleep 30"], cols: 80, rows: 24)
        let holder = Holder(config: HolderConfig(record: record, registry: registry, maxClients: 3))
        Thread.detachNewThread { holder.run() }
        defer { holder.stop(); usleep(300_000); try? FileManager.default.removeItem(at: registry.directory) }
        for _ in 0..<100 where !HolderClient.isLive(socketPath: registry.socketPath("cap1")) { usleep(20_000) }
        let idle = (0..<3).compactMap { _ in connectUnix(registry.socketPath("cap1")) }
        #expect(idle.count == 3)
        usleep(100_000)
        #expect(HolderClient.info(socketPath: registry.socketPath("cap1")) == nil)
        idle.forEach { close($0) }
        usleep(100_000)
        #expect(HolderClient.info(socketPath: registry.socketPath("cap1"))?.alive == true)
    }
}
