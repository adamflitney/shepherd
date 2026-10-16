import Foundation
import Darwin

public struct HolderInfo: Equatable, Sendable {
    public var id: String
    public var alive: Bool
    public var cols: Int
    public var rows: Int
    public var ringBytes: Int
    public var modes: [Int]
    public var claudeSessionID: String?
    public var exitStatus: Int?
}

/// Blocking client for a holder's socket. The app's web bridge drives the same protocol with dispatch sources; this is
/// the simple form used by the command line and the tests.
public enum HolderClient {
    private static func request(socketPath: String, _ object: [String: Any]) -> (reply: [String: Any], fd: Int32, left: [UInt8])? {
        guard let fd = connectUnix(socketPath) else { return nil }
        guard writeAll(fd, jsonBytes(object) + [10]) else { close(fd); return nil }
        var left: [UInt8] = []
        guard let line = readLine(fd, leftover: &left, timeoutMs: 3000),
              let reply = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { close(fd); return nil }
        return (reply, fd, left)
    }

    fileprivate static func readLine(_ fd: Int32, leftover: inout [UInt8], timeoutMs: Int32) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = leftover.firstIndex(of: 10) {
                let line = Array(leftover[0..<newline])
                leftover.removeFirst(newline + 1)
                return line
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&p, 1, timeoutMs) > 0 else { return nil }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return nil }
            leftover += buf[0..<n]
        }
    }

    public static func isLive(socketPath: String) -> Bool { info(socketPath: socketPath)?.alive == true }

    public static func info(socketPath: String) -> HolderInfo? {
        guard let r = request(socketPath: socketPath, ["op": "info"]) else { return nil }
        close(r.fd)
        guard r.reply["ok"] as? Bool == true, let id = r.reply["id"] as? String else { return nil }
        return HolderInfo(id: id, alive: r.reply["alive"] as? Bool ?? false, cols: r.reply["cols"] as? Int ?? 0,
                          rows: r.reply["rows"] as? Int ?? 0, ringBytes: r.reply["ring"] as? Int ?? 0,
                          modes: r.reply["modes"] as? [Int] ?? [], claudeSessionID: r.reply["claudeSessionID"] as? String,
                          exitStatus: r.reply["exitStatus"] as? Int)
    }

    @discardableResult
    public static func kill(socketPath: String) -> Bool {
        guard let r = request(socketPath: socketPath, ["op": "kill"]) else { return false }
        close(r.fd)
        return r.reply["ok"] as? Bool == true
    }

    /// The replay buffer as it is now (what a client attaching this instant would be sent).
    public static func dump(socketPath: String) -> [UInt8]? {
        guard let r = request(socketPath: socketPath, ["op": "dump"]), let count = r.reply["bytes"] as? Int else { return nil }
        var data = r.left
        var buf = [UInt8](repeating: 0, count: 65536)
        while data.count < count {
            var p = pollfd(fd: r.fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&p, 1, 3000) > 0 else { break }
            let n = read(r.fd, &buf, buf.count)
            if n <= 0 { break }
            data += buf[0..<n]
        }
        close(r.fd)
        return data
    }

    public final class Attachment {
        public let replay: [UInt8]
        public let modes: [Int]
        public let cols: Int
        public let rows: Int
        /// For callers that poll the connection themselves.
        public let fileDescriptor: Int32
        private var fd: Int32 { fileDescriptor }
        private var closed = false

        fileprivate init(fd: Int32, replay: [UInt8], modes: [Int], cols: Int, rows: Int) {
            self.fileDescriptor = fd; self.replay = replay; self.modes = modes; self.cols = cols; self.rows = rows
        }

        deinit { close() }

        @discardableResult public func send(_ bytes: [UInt8]) -> Bool { writeAll(fd, HolderFrame.input(bytes).encoded()) }
        @discardableResult public func resize(cols: UInt16, rows: UInt16) -> Bool { writeAll(fd, HolderFrame.resize(cols: cols, rows: rows).encoded()) }

        /// Output from the session, waiting up to `timeoutMs` for the first bytes. Empty means nothing arrived;
        /// `nil` means the holder closed the connection (the session ended or this client was dropped).
        public func read(timeoutMs: Int32) -> [UInt8]? {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&p, 1, timeoutMs) > 0 else { return [] }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            return n <= 0 ? nil : Array(buf[0..<n])
        }

        /// Reads until `needle` shows up in the output or the time runs out; returns everything read.
        public func read(until needle: String, timeoutMs: Int) -> (text: String, found: Bool) {
            var all: [UInt8] = []
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                guard let chunk = read(timeoutMs: 100) else { break }
                all += chunk
                if String(decoding: all, as: UTF8.self).contains(needle) { return (String(decoding: all, as: UTF8.self), true) }
            }
            return (String(decoding: all, as: UTF8.self), false)
        }

        /// A full-screen program may have a truncated replay, so make it repaint by nudging the size.
        public func forceRedraw() {
            guard rows > 2 else { return }
            resize(cols: UInt16(cols), rows: UInt16(rows - 1))
            usleep(50_000)
            resize(cols: UInt16(cols), rows: UInt16(rows))
        }

        public func detach() {
            guard !closed else { return }
            _ = writeAll(fd, HolderFrame.detach.encoded())
            close()
        }

        private func close() {
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }

    public static func attach(socketPath: String, cols: Int? = nil, rows: Int? = nil) -> Attachment? {
        var req: [String: Any] = ["op": "attach"]
        if let cols, let rows { req["cols"] = cols; req["rows"] = rows }
        guard let r = request(socketPath: socketPath, req), r.reply["ok"] as? Bool == true else { return nil }
        let count = r.reply["replay"] as? Int ?? 0
        var data = r.left
        var buf = [UInt8](repeating: 0, count: 65536)
        while data.count < count {
            var p = pollfd(fd: r.fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&p, 1, 3000) > 0 else { break }
            let n = read(r.fd, &buf, buf.count)
            if n <= 0 { break }
            data += buf[0..<n]
        }
        let replay = Array(data.prefix(count))
        let live = Array(data.dropFirst(count))
        let attachment = Attachment(fd: r.fd, replay: replay + live, modes: r.reply["modes"] as? [Int] ?? [],
                                    cols: r.reply["cols"] as? Int ?? cols ?? 0, rows: r.reply["rows"] as? Int ?? rows ?? 0)
        return attachment
    }
}
