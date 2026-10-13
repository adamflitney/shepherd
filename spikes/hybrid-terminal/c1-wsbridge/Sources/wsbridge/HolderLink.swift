import Foundation
import Darwin

/// One connection to the PTY holder daemon's unix socket, driven by dispatch sources on the bridge queue.
/// Always drained promptly (the holder blocks on a reader that doesn't read), so slow *browser* clients are
/// handled by bounded queues on the bridge side, never by leaving this fd unread.
final class HolderLink {
    enum Phase { case reply, replay(Int), live, done }
    let fd: Int32
    private let q: DispatchQueue
    private var rsrc: DispatchSourceRead?
    private var wsrc: DispatchSourceWrite?
    private var rbuf = [UInt8]()
    private var phase = Phase.reply
    private var wq = [UInt8]()
    private var wsrcResumed = false
    private(set) var closed = false
    let oneShot: Bool
    static let maxQueued = 1 << 20

    var onReply: (([String: Any]) -> Void)?
    var onBytes: (([UInt8], Bool) -> Void)?
    var onReplayDone: (() -> Void)?
    var onClose: (() -> Void)?

    init?(path: String, queue: DispatchQueue, oneShot: Bool) {
        guard let fd = connectUnixNonblocking(path) else { return nil }
        self.fd = fd; self.q = queue; self.oneShot = oneShot
    }

    func start(request: [String: Any]) {
        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
        r.setEventHandler { self.readable() } // strong: keeps a one-shot link alive until it finishes (cancel releases the handler)
        r.resume()
        rsrc = r
        _ = write(jsonBytes(request) + [10])
    }

    private func readable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { finish(); return }
        if n < 0 { return }
        rbuf.append(contentsOf: buf[0..<n])
        process()
    }

    private func process() {
        while !closed {
            switch phase {
            case .reply:
                guard let nl = rbuf.firstIndex(of: 10) else { if rbuf.count > 1 << 20 { finish() }; return }
                let line = Array(rbuf[0..<nl]); rbuf.removeFirst(nl + 1)
                let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] ?? ["ok": false]
                onReply?(obj)
                if oneShot || (obj["ok"] as? Bool) != true { finish(); return }
                let n = obj["replay"] as? Int ?? 0
                if n > 0 { phase = .replay(n) } else { phase = .live; onReplayDone?() }
            case .replay(let left):
                if rbuf.isEmpty { return }
                let take = min(left, rbuf.count)
                let chunk = Array(rbuf[0..<take]); rbuf.removeFirst(take)
                onBytes?(chunk, true)
                if take == left { phase = .live; onReplayDone?() } else { phase = .replay(left - take) }
            case .live:
                if rbuf.isEmpty { return }
                let chunk = rbuf; rbuf.removeAll(keepingCapacity: true)
                onBytes?(chunk, false)
            case .done: return
            }
        }
    }

    /// Queues bytes toward the holder; false if the queue is over its cap (caller should drop the client).
    @discardableResult func write(_ bytes: [UInt8]) -> Bool {
        if closed { return false }
        var off = 0
        if wq.isEmpty {
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n < 0 { if errno == EINTR { continue }; if errno == EAGAIN { break }; finish(); return false }
                off += n
            }
        }
        if off < bytes.count {
            wq.append(contentsOf: bytes[off...])
            if wq.count > Self.maxQueued { finish(); return false }
            if wsrc == nil {
                let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: q)
                w.setEventHandler { self.writable() }
                wsrc = w
            }
            if !wsrcResumed { wsrc?.resume(); wsrcResumed = true }
        }
        return true
    }

    private func writable() {
        while !wq.isEmpty {
            let n = wq.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; if errno == EAGAIN { return }; finish(); return }
            wq.removeFirst(n)
        }
        if wsrcResumed { wsrc?.suspend(); wsrcResumed = false }
    }

    func close() { finish(notify: false) }

    private func finish(notify: Bool = true) {
        if closed { return }
        closed = true; phase = .done
        rsrc?.cancel()
        if let w = wsrc { if !wsrcResumed { w.resume() }; w.cancel() }
        Darwin.close(fd)
        if notify { onClose?() }
    }

    // Holder frame protocol: [type u8][len u32 be][payload]; 0 input, 1 resize(cols u16, rows u16), 2 detach.
    static func frame(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let n = payload.count
        return [type, UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] + payload
    }
    func sendInput(_ b: [UInt8]) -> Bool { write(Self.frame(0, b)) }
    func sendResize(_ cols: Int, _ rows: Int) -> Bool {
        write(Self.frame(1, [UInt8(cols >> 8 & 0xff), UInt8(cols & 0xff), UInt8(rows >> 8 & 0xff), UInt8(rows & 0xff)]))
    }
}
