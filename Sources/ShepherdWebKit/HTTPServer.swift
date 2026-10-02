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
            plain(403, "Forbidden", message)
        }

        static func plain(_ status: Int, _ reason: String, _ message: String) -> Response {
            Response(status: status, reason: reason, headers: ["Content-Type": "text/plain"], body: Data(message.utf8))
        }

        static func serverError(_ message: String) -> Response {
            Response(status: 500, reason: "Internal Server Error", headers: ["Content-Type": "text/plain"], body: Data(message.utf8))
        }
    }

    /// Handles every path except `/api/events`, which is routed to
    /// `sseEvents` instead since it never returns a normal response.
    private let router: @Sendable (Request) async -> Response
    /// Runs before every request, including the SSE stream: a non-nil
    /// response is sent instead of handling the request.
    private let gate: @Sendable (Request) async -> Response?
    /// One independent event subscription per SSE connection - safe because
    /// `BackendEventHub.makeStream()` (what every `SessionBackend` is built
    /// on) already fans out to any number of subscribers. Takes the raw
    /// `SessionBackend.events()` stream directly (rather than a
    /// pre-converted `AsyncStream<Data>` built by wrapping it in a second,
    /// unstructured `Task` at the call site) - that extra layer tripped a
    /// Swift 6 concurrency runtime isolation check in practice; iterating
    /// the original stream straight from this actor's own task, as done
    /// below, doesn't.
    private let sseEvents: @Sendable () -> AsyncStream<BackendEvent>
    private let listener: NWListener

    /// Limits on what a client may make us read. The real traffic is tiny (a
    /// short JSON body at most), so these are generous for it and tight
    /// against anything else.
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 256 * 1024
    private let readTimeout: Duration
    private let queue: DispatchQueue

    init(
        port: UInt16,
        readTimeout: Duration = .seconds(10),
        queue: DispatchQueue = .main,
        gate: @escaping @Sendable (Request) async -> Response? = { _ in nil },
        router: @escaping @Sendable (Request) async -> Response,
        sseEvents: @escaping @Sendable () -> AsyncStream<BackendEvent>
    ) throws {
        self.readTimeout = readTimeout
        self.queue = queue
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

    enum ServerError: Error {
        case invalidPort(UInt16), connectionClosed, timedOut
        /// A request we refuse to parse, with the response to send for it.
        case rejected(Int, String, String)
    }

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
            listener.start(queue: queue)
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
        connection.start(queue: queue)
        let head: RequestHead
        let body: Data
        do {
            (head, body) = try await readRequest(connection)
        } catch ServerError.rejected(let status, let reason, let message) {
            try? await write(connection, response: .plain(status, reason, message), keepAlive: false)
            connection.cancel()
            return
        } catch {
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
        /// Set when the framing headers can't be trusted (a negative or
        /// non-numeric `Content-Length`, or a `Transfer-Encoding` we don't
        /// implement) - the request is refused rather than guessed at.
        var framingError: String?
    }

    /// Reads until the blank line ending the header block, then (if
    /// `Content-Length` says so) exactly that many more bytes for the body.
    /// No support for chunked transfer-encoding - not needed by this
    /// server's own client, and refused outright rather than half-handled.
    /// Bounded in size and in time, so a client that sends too much, or
    /// stalls, can't hold the server's memory or a connection open.
    private func readRequest(_ connection: NWConnection) async throws -> (RequestHead, Data) {
        let timeout = readTimeout
        return try await withThrowingTaskGroup(of: (RequestHead, Data)?.self) { group in
            group.addTask { try await self.readRequestUnbounded(connection) }
            group.addTask {
                try await Task.sleep(for: timeout)
                // `receive` can't be cancelled from here; closing the
                // connection is what makes a stalled read return.
                connection.cancel()
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else { throw ServerError.timedOut }
            return result
        }
    }

    private func readRequestUnbounded(_ connection: NWConnection) async throws -> (RequestHead, Data) {
        var buffer = Data()
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard let chunk = try await receive(connection), !chunk.isEmpty else {
                throw ServerError.connectionClosed
            }
            buffer.append(chunk)
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if (headerEnd?.lowerBound ?? buffer.count) > Self.maxHeaderBytes {
                throw ServerError.rejected(431, "Request Header Fields Too Large", "Headers too large")
            }
        }

        let headerData = buffer[..<headerEnd!.lowerBound]
        var bodyData = buffer[headerEnd!.upperBound...]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let head = parseHead(headerText)

        if let problem = head.framingError {
            throw ServerError.rejected(400, "Bad Request", problem)
        }
        if head.contentLength > Self.maxBodyBytes {
            throw ServerError.rejected(413, "Payload Too Large", "Body too large")
        }

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
        var framingError: String?
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
            if key == "content-length" {
                // A non-numeric or negative length is not "0" - and a
                // negative one used to crash the process outright.
                if let length = Int(value), length >= 0 {
                    contentLength = length
                } else {
                    framingError = "Invalid Content-Length"
                }
            }
            if key == "transfer-encoding" {
                framingError = "Transfer-Encoding is not supported"
            }
        }

        return RequestHead(method: method, path: path, query: query, headers: headers, contentLength: contentLength, framingError: framingError)
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
