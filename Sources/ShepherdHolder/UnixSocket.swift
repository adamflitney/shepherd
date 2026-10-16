import Foundation
import Darwin

/// Low-level helpers shared by the holder and its clients.

func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN { usleep(1000); continue }
            return false
        }
        off += n
    }
    return true
}

/// Writes to a nonblocking socket and gives up only if the peer makes no progress for `budgetMs`. The deadline
/// restarts whenever bytes are accepted, so a slow reader is fine and a stalled one is cut loose rather than
/// freezing the holder.
func writeBounded(_ fd: Int32, _ bytes: [UInt8], budgetMs: Int32 = 300) -> Bool {
    var off = 0
    var deadline = DispatchTime.now() + .milliseconds(Int(budgetMs))
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN {
                let now = DispatchTime.now()
                if now >= deadline { return false }
                let leftMs = Int32((deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000)
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, max(1, min(leftMs, 50)))
                continue
            }
            return false
        }
        off += n
        deadline = DispatchTime.now() + .milliseconds(Int(budgetMs))
    }
    return true
}

private let chdirLock = NSLock()

/// `sun_path` is 104 bytes on macOS. A path that fits is used as it is; a longer one is reached by binding relative to
/// its directory, which changes the working directory of the whole process, so that is done under a lock and only when
/// there is no other way.
private func withSocketAddress<T>(_ path: String, _ body: (sockaddr_un) -> T) -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    func fill(_ name: String) {
        name.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, source, capacity - 1) }
            }
        }
    }
    if path.utf8.count < capacity {
        fill(path)
        return body(address)
    }
    let url = URL(fileURLWithPath: path)
    chdirLock.lock()
    defer { chdirLock.unlock() }
    let manager = FileManager.default
    let old = manager.currentDirectoryPath
    manager.changeCurrentDirectoryPath(url.deletingLastPathComponent().path)
    defer { manager.changeCurrentDirectoryPath(old) }
    fill(url.lastPathComponent)
    return body(address)
}

func listenUnix(_ path: String) -> Int32? {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    fcntl(fd, F_SETFD, FD_CLOEXEC)
    let bound: Bool = withSocketAddress(path) { address in
        var a = address
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }
    guard bound, listen(fd, 16) == 0 else { close(fd); return nil }
    chmod(path, 0o600)
    return fd
}

func connectUnix(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    fcntl(fd, F_SETFD, FD_CLOEXEC)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let connected: Bool = withSocketAddress(path) { address in
        var a = address
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }
    if !connected { close(fd); return nil }
    return fd
}

func jsonBytes(_ object: Any) -> [UInt8] {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { Array($0) } ?? []
}

func logLine(_ text: String) {
    FileHandle.standardError.write(Data("[\(ProcessInfo.processInfo.processIdentifier)] \(text)\n".utf8))
}
