import Foundation
import Network
import ShepherdCore

/// A minimal HTTP/1.1 server over `Network.framework` - no third-party
/// dependency (matching the rest of this package), and small enough for a
/// prototype's needs: one request per connection (`Connection: close`),
/// plus one special-cased long-lived path for Server-Sent Events. Not a
/// general-purpose HTTP implementation - no chunked request bodies, no
/// keep-alive reuse, no HTTP/1.0.
actor HTTPServer {
    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        /// Lower-cased names.
        var headers: [String: String] = [:]
        var body: Data
    }

    struct Response {
        var status: Int = 200
        var reason: String = "OK"
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ data: Data, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], body: data)
        }

        static func notFound() -> Response {
            Response(status: 404, reason: "Not Found", headers: ["Content-Type": "text/plain"], body: Data("Not found".utf8))
        }

        static func forbidden(_ message: String) -> Response {
            Response(status: 403, reason: "Forbidden", headers: ["Content-Type": "text/plain"], body: Data(message.utf8))
        }

        static func serverError(_ message: String) -> Response {
            Response(status: 500, reason: "Internal Server Error", headers: ["Content-Type": "text/plain"], body: Data(message.utf8))
        }
    }

    /// Handles every path except `/api/events`, which is routed to
    /// `sseEvents` instead since it never returns a normal response.
    private let router: (Request) async -> Response
    /// Runs before every request, including the SSE stream: a non-nil
    /// response is sent instead of handling the request.
    private let gate: (Request) async -> Response?
    /// One independent event subscription per SSE connection - safe because
    /// `BackendEventHub.makeStream()` (what every `SessionBackend` is built
    /// on) already fans out to any number of subscribers. Takes the raw
    /// `SessionBackend.events()` stream directly (rather than a
    /// pre-converted `AsyncStream<Data>` built by wrapping it in a second,
    /// unstructured `Task` at the call site) - that extra layer tripped a
    /// Swift 6 concurrency runtime isolation check in practice; iterating
    /// the original stream straight from this actor's own task, as done
    /// below, doesn't.
    private let sseEvents: () -> AsyncStream<BackendEvent>
    private let listener: NWListener

    init(
        port: UInt16,
        gate: @escaping (Request) async -> Response? = { _ in nil },
        router: @escaping (Request) async -> Response,
        sseEvents: @escaping () -> AsyncStream<BackendEvent>
    ) throws {
        self.router = router
        self.gate = gate
        self.sseEvents = sseEvents
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort(port)
        }
        // Loopback only: the sole way in from another device is
        // `tailscale serve` (which also gives us TLS and the caller's
        // identity). Binding every interface would expose an unauthenticated
        // way to approve prompts and type into agents to the whole LAN, and
        // would trigger macOS's "accept incoming connections" dialog.
        // (`requiredInterfaceType = .loopback` was tried first and still left
        // the socket on `*:port`; pinning the local address is what binds it.)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        listener = try NWListener(using: parameters)
    }

    enum ServerError: Error { case invalidPort(UInt16), connectionClosed }

    private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    /// Returns once the socket is actually listening, and throws if it can't
    /// be (typically: the port is already in use) - `NWListener` reports
    /// that asynchronously, not from `init`.
    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    func stop() {
        listener.cancel()
        // Cancelling the tasks also ends any open SSE streams.
        connectionTasks.values.forEach { $0.cancel() }
        connectionTasks = [:]
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connectionTasks[id] = Task { [weak self] in
            await self?.handle(connection)
            await self?.connectionFinished(id)
        }
    }

    private func connectionFinished(_ id: UUID) {
        connectionTasks[id] = nil
    }

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: .main)
        guard let (head, body) = try? await readRequest(connection) else {
            connection.cancel()
            return
        }

        let request = Request(method: head.method, path: head.path, query: head.query, headers: head.headers, body: body)
        if let denied = await gate(request) {
            try? await write(connection, response: denied, keepAlive: false)
            connection.cancel()
            return
        }

        if head.path == "/api/events" && head.method == "GET" {
            await streamSSE(connection)
            return
        }

        let response = await router(request)
        try? await write(connection, response: response, keepAlive: false)
        connection.cancel()
    }

    // MARK: - Request parsing

    private struct RequestHead {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var contentLength: Int
    }

    /// Reads until the blank line ending the header block, then (if
    /// `Content-Length` says so) exactly that many more bytes for the body.
    /// No support for chunked transfer-encoding - not needed by this
    /// prototype's own client.
    private func readRequest(_ connection: NWConnection) async throws -> (RequestHead, Data) {
        var buffer = Data()
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard let chunk = try await receive(connection), !chunk.isEmpty else {
                throw ServerError.connectionClosed
            }
            buffer.append(chunk)
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        }

        let headerData = buffer[..<headerEnd!.lowerBound]
        var bodyData = buffer[headerEnd!.upperBound...]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let head = parseHead(headerText)

        while bodyData.count < head.contentLength {
            guard let chunk = try await receive(connection), !chunk.isEmpty else { break }
            bodyData.append(chunk)
        }

        return (head, Data(bodyData.prefix(head.contentLength)))
    }

    private func parseHead(_ headerText: String) -> RequestHead {
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: true)
        let requestLine = lines.first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : "GET"
        let rawTarget = parts.count > 1 ? String(parts[1]) : "/"

        var path = rawTarget
        var query: [String: String] = [:]
        if let qIndex = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[rawTarget.startIndex..<qIndex])
            let queryString = rawTarget[rawTarget.index(after: qIndex)...]
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }

        var contentLength = 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
            if key == "content-length" {
                contentLength = Int(value) ?? 0
            }
        }

        return RequestHead(method: method, path: path, query: query, headers: headers, contentLength: contentLength)
    }

    // MARK: - Response writing

    private func write(_ connection: NWConnection, response: Response, keepAlive: Bool) async throws {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)
        try await send(connection, payload)
    }

    // MARK: - Server-Sent Events

    /// Sends SSE headers, then relays `sseEvents()` as `data: <json>\n\n`
    /// frames until the stream ends or the connection drops. Distinct from
    /// the normal request/response path since it never completes on its
    /// own - it's the client (closing the tab) or a network error that
    /// ends it.
    private func streamSSE(_ connection: NWConnection) async {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        guard (try? await send(connection, Data(head.utf8))) != nil else {
            connection.cancel()
            return
        }

        for await event in sseEvents() {
            guard let payload = sseEventData(for: event) else { continue }
            var frame = Data("data: ".utf8)
            frame.append(payload)
            frame.append(Data("\n\n".utf8))
            guard (try? await send(connection, frame)) != nil else { break }
        }
        connection.cancel()
    }

    // MARK: - NWConnection async bridging

    private func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if isComplete && (data == nil || data!.isEmpty) {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
