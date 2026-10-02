import Darwin
import Foundation
import ShepherdCore
import Testing
@testable import ShepherdWebKit

/// Sends raw bytes to 127.0.0.1:`port` and returns everything the server
/// writes back before it closes the connection (or `seconds` pass) - raw
/// because the requests under test are ones no HTTP client would send.
private func exchange(_ port: UInt16, _ request: String, seconds: Int = 3) async -> String {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else { continuation.resume(returning: "connect failed"); return }
            var timeout = timeval(tv_sec: seconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = request.withCString { send(fd, $0, strlen($0), 0) }
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(fd, &buffer, buffer.count, 0)
                if count <= 0 { break }
                received.append(contentsOf: buffer[0..<count])
            }
            continuation.resume(returning: String(decoding: received, as: UTF8.self))
        }
    }
}

private func startServer(
    readTimeout: Duration = .seconds(10),
    gate: @escaping @Sendable (HTTPServer.Request) async -> HTTPServer.Response? = { _ in nil }
) async throws -> (HTTPServer, UInt16) {
    for _ in 0..<20 {
        let port = UInt16.random(in: 20_000...40_000)
        let server = try HTTPServer(
            port: port, readTimeout: readTimeout, queue: DispatchQueue(label: "test-http-server"),
            gate: gate,
            router: { request in .json(Data(#"{"ok":true,"bytes":\#(request.body.count)}"#.utf8)) },
            sseEvents: { AsyncStream { $0.finish() } }
        )
        if (try? await server.start()) != nil { return (server, port) }
    }
    throw HTTPServer.ServerError.invalidPort(0)
}

private let alive = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"

private func status(_ response: String) -> String {
    String(response.split(separator: "\r\n").first ?? "(no response)")
}

@Test func anOrdinaryRequestStillWorks() async throws {
    let (server, port) = try await startServer()
    defer { Task { await server.stop() } }
    let response = await exchange(port, "POST /x HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nbody")
    #expect(status(response) == "HTTP/1.1 200 OK")
    #expect(response.contains(#""bytes":4"#))
}

@Test func aNegativeContentLengthIsRefusedAndTheServerSurvives() async throws {
    // This used to crash the whole process ("Can't take a prefix of negative length").
    let (server, port) = try await startServer()
    defer { Task { await server.stop() } }
    let bad = await exchange(port, "POST /x HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n")
    #expect(status(bad) == "HTTP/1.1 400 Bad Request")
    #expect(status(await exchange(port, alive)) == "HTTP/1.1 200 OK")
}

@Test func aNonNumericContentLengthIsRefused() async throws {
    let (server, port) = try await startServer()
    defer { Task { await server.stop() } }
    #expect(status(await exchange(port, "POST /x HTTP/1.1\r\nHost: localhost\r\nContent-Length: abc\r\n\r\n")) == "HTTP/1.1 400 Bad Request")
}

@Test func aChunkedRequestIsRefusedNotHalfHandled() async throws {
    let (server, port) = try await startServer()
    defer { Task { await server.stop() } }
    let response = await exchange(port, "POST /x HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
    #expect(status(response) == "HTTP/1.1 400 Bad Request")
}

@Test func aBodyBiggerThanTheLimitIsRefusedBeforeItIsRead() async throws {
    let (server, port) = try await startServer()
    defer { Task { await server.stop() } }
    let response = await exchange(port, "POST /x HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10000000\r\n\r\n")
    #expect(status(response) == "HTTP/1.1 413 Payload Too Large")
}

@Test func headersBiggerThanTheLimitAreRefused() async throws {
    let (server, port) = try await startServer()
    defer { Task { await server.stop() } }
    let junk = String(repeating: "a", count: HTTPServer.maxHeaderBytes + 1024)
    let response = await exchange(port, "GET / HTTP/1.1\r\nHost: localhost\r\nX-Junk: \(junk)\r\n\r\n")
    #expect(status(response) == "HTTP/1.1 431 Request Header Fields Too Large")
}

@Test func aClientThatStallsMidRequestIsDisconnected() async throws {
    let (server, port) = try await startServer(readTimeout: .milliseconds(300))
    defer { Task { await server.stop() } }
    let started = Date()
    // Never finishes its headers; without a timeout this would wait for the client's own 3s receive limit.
    let response = await exchange(port, "GET / HTTP/1.1\r\nHost: local", seconds: 3)
    #expect(response.isEmpty)
    #expect(Date().timeIntervalSince(started) < 2.5)
}

@Test func theGateRunsBeforeTheRouter() async throws {
    let (server, port) = try await startServer(gate: { request in
        request.headers["x-deny"] != nil ? .forbidden("nope") : nil
    })
    defer { Task { await server.stop() } }
    #expect(status(await exchange(port, "GET / HTTP/1.1\r\nHost: localhost\r\nX-Deny: 1\r\n\r\n")) == "HTTP/1.1 403 Forbidden")
    #expect(status(await exchange(port, alive)) == "HTTP/1.1 200 OK")
}
