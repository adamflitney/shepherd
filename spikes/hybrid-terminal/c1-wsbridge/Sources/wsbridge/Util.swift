import Foundation
import Darwin
import CryptoKit

func sha1Base64(_ s: String) -> String { Data(Insecure.SHA1.hash(data: Data(s.utf8))).base64EncodedString() }

func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff = x.count ^ y.count
    for i in 0..<max(x.count, y.count) { diff |= Int((i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)) }
    return diff == 0
}

/// `localhost:8787` -> `localhost`, `[::1]:8787` -> `[::1]`; lower-cased, trailing dot removed (from AccessPolicy.swift).
func hostname(fromHostHeader value: String) -> String? {
    var host = value.trimmingCharacters(in: .whitespaces).lowercased()
    if host.hasPrefix("[") {
        guard let close = host.firstIndex(of: "]") else { return nil }
        host = String(host[...close])
    } else if let colon = host.firstIndex(of: ":") {
        host = String(host[..<colon])
    }
    if host.hasSuffix(".") { host.removeLast() }
    return host.isEmpty ? nil : host
}

func log(_ s: String) { FileHandle.standardError.write(Data("[bridge] \(s)\n".utf8)) }

func jsonBytes(_ o: Any) -> [UInt8] {
    (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map { Array($0) } ?? []
}

private func withSocketPath<T>(_ path: String, _ body: (sockaddr_un) -> T) -> T {
    let url = URL(fileURLWithPath: path)
    let old = FileManager.default.currentDirectoryPath
    FileManager.default.changeCurrentDirectoryPath(url.deletingLastPathComponent().path)
    defer { FileManager.default.changeCurrentDirectoryPath(old) }
    var a = sockaddr_un()
    a.sun_family = sa_family_t(AF_UNIX)
    let name = url.lastPathComponent
    let cap = MemoryLayout.size(ofValue: a.sun_path)
    name.withCString { src in
        withUnsafeMutablePointer(to: &a.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in _ = strncpy(dst, src, cap - 1) }
        }
    }
    return body(a)
}

func connectUnixNonblocking(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    fcntl(fd, F_SETFD, FD_CLOEXEC)
    let ok: Bool = withSocketPath(path) { addr in
        var a = addr
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    }
    if !ok { close(fd); return nil }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
}
