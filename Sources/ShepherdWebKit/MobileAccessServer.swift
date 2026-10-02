import Foundation
import ShepherdCore

/// Where phone access stands, for the setup checklist. Each flag is the
/// precondition for the next, so a UI can show the first unmet one as the
/// thing to do.
public struct MobileAccessStatus: Equatable, Sendable {
    public var tailscaleInstalled = false
    /// Tailscale is signed in and connected.
    public var tailscaleConnected = false
    /// HTTPS certificates are enabled for the tailnet (an admin-console
    /// switch only the user can flip).
    public var httpsEnabled = false
    /// The address to open on the phone, once this Mac is publishing the
    /// server through Tailscale.
    public var publishedURL: String?
    public var serverRunning = false
    /// Phones that have turned on alerts.
    public var phoneCount = 0

    public init() {}
}

public extension MobileAccessStatus {
    /// The first thing still standing between the user and a working phone
    /// view; each step only makes sense once the one before it is done.
    enum Step: Equatable, Sendable {
        case installTailscale, signInToTailscale, enableHTTPS, publish, ready
    }

    var nextStep: Step {
        if !tailscaleInstalled { return .installTailscale }
        if !tailscaleConnected { return .signInToTailscale }
        if !httpsEnabled { return .enableHTTPS }
        if publishedURL == nil { return .publish }
        return .ready
    }
}

public enum MobileAccessSetupError: Error, Equatable, Sendable, LocalizedError {
    /// Something earlier in the checklist isn't done yet.
    case notReady(String)
    /// Tailscale needs the user to flip a setting in its admin console.
    case needsAction(message: String, url: String?)
    case noFreePort
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let message), .failed(let message): message
        case .needsAction(let message, _): message
        case .noFreePort: "Every HTTPS port Tailscale allows is already in use on this Mac."
        }
    }
}

/// The phone-facing web server as one start/stop unit: the HTTP listener
/// (loopback only), the push notifier, and the keep-awake behaviour. The menu
/// bar app owns one of these; `swift run ShepherdWeb` is a thin wrapper over
/// the same thing.
public actor MobileAccessServer {
    public struct Options: Sendable {
        public var port: UInt16
        public var keepAwake: Bool
        /// Hold phone alerts back while you're at the Mac.
        public var onlyWhenAway: Bool

        public init(port: UInt16 = 8787, keepAwake: Bool = true, onlyWhenAway: Bool = false) {
            self.port = port
            self.keepAwake = keepAwake
            self.onlyWhenAway = onlyWhenAway
        }
    }

    public enum StartError: Error, Equatable {
        case portInUse(UInt16)
    }

    private let backend: any SessionBackend
    private let options: Options
    private let tailscale = TailscaleService()
    private var http: HTTPServer?
    private var push: PushService?
    private var keepAwake: KeepAwakeController?
    private var tasks: [Task<Void, Never>] = []

    public init(backend: any SessionBackend, options: Options = Options()) {
        self.backend = backend
        self.options = options
    }

    public var isRunning: Bool { http != nil }
    public var port: UInt16 { options.port }

    public func start() async throws {
        guard http == nil else { return }

        // VAPID `sub` is a contact URI the push service can use to reach the
        // operator - a project URL rather than a personal email address,
        // since it's sent to Apple/Google with every push.
        let pushDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".shepherd/web-push")
        let push = try PushService(directory: pushDirectory, subject: "https://github.com/adamflitney/shepherd")
        let api = SessionsAPI(backend: backend)
        let pushAPI = PushAPI(push: push)
        let publicDirectory = locatePublicDirectory()
        let tailscale = self.tailscale
        let backend = self.backend

        let server = try HTTPServer(
            port: options.port,
            gate: { request in
                // Only look up the Mac's Tailscale owner when a request
                // actually carries an identity to compare it against.
                let owner = request.headers["tailscale-user-login"] != nil ? await tailscale.status()?.ownerLogin : nil
                switch accessDecision(headers: request.headers, ownerLogin: owner) {
                case .allow: return nil
                case .deny(let reason): return .forbidden(reason)
                }
            },
            router: { request in
                if request.method == "GET", !request.path.hasPrefix("/api/") {
                    return serveStaticFile(request.path, from: publicDirectory)
                }
                if request.path.hasPrefix("/api/push/") {
                    return await pushAPI.handle(request)
                }
                return await api.handle(request)
            },
            sseEvents: { backend.events() }
        )
        do {
            try await server.start()
        } catch {
            throw StartError.portInUse(options.port)
        }

        self.http = server
        self.push = push
        let notifier = PushNotifier(onlyWhenAway: options.onlyWhenAway) { message in
            guard let payload = try? JSONEncoder().encode(message) else { return 0 }
            return await push.send(payload)
        }
        tasks.append(Task { await notifier.run(backend: backend) })
        if options.keepAwake {
            let controller = KeepAwakeController(assertion: SystemSleepAssertion())
            keepAwake = controller
            tasks.append(Task { await runKeepAwake(backend: backend, controller: controller) })
        }
    }

    public func status() async -> MobileAccessStatus {
        var status = MobileAccessStatus()
        status.serverRunning = http != nil
        status.phoneCount = await push?.subscriptionCount ?? 0
        status.tailscaleInstalled = locateTailscaleCLI() != nil
        guard status.tailscaleInstalled, let ts = await tailscale.status(forceRefresh: true) else { return status }
        status.tailscaleConnected = ts.isRunning
        status.httpsEnabled = ts.httpsEnabled
        if ts.isRunning, let dns = ts.dnsName, case .alreadyServing(let httpsPort) = await servePlan(dnsName: dns) {
            status.publishedURL = serveURL(dnsName: dns, httpsPort: httpsPort)
        }
        return status
    }

    private func servePlan(dnsName: String) async -> ServePlan {
        let entries = await tailscale.run(["serve", "status", "--json"]).map { parseServeStatus($0.output) } ?? []
        return planServe(dnsName: dnsName, entries: entries, localPort: Int(options.port))
    }

    /// Publishes the server on this Mac's tailnet address and returns it.
    /// Never replaces someone else's `tailscale serve` entry - see `planServe`.
    @discardableResult
    public func enableTailscaleServe() async throws -> String {
        guard locateTailscaleCLI() != nil else { throw MobileAccessSetupError.notReady("Tailscale isn't installed") }
        guard let ts = await tailscale.status(forceRefresh: true), ts.isRunning, let dns = ts.dnsName else {
            throw MobileAccessSetupError.notReady("Tailscale isn't signed in")
        }
        guard ts.httpsEnabled else {
            throw MobileAccessSetupError.notReady("HTTPS certificates aren't enabled for your tailnet")
        }
        switch await servePlan(dnsName: dns) {
        case .alreadyServing(let httpsPort):
            return serveURL(dnsName: dns, httpsPort: httpsPort)
        case .noFreePort:
            throw MobileAccessSetupError.noFreePort
        case .create(let httpsPort):
            let result = await tailscale.run(["serve", "--bg", "--https=\(httpsPort)", String(options.port)])
            let output = result.map { String(decoding: $0.output, as: UTF8.self) } ?? ""
            if let action = parseServeNeedsAction(output) {
                throw MobileAccessSetupError.needsAction(message: action.message, url: action.url)
            }
            guard result?.status == 0 else {
                throw MobileAccessSetupError.failed(output.isEmpty ? "tailscale serve didn't respond" : output)
            }
            return serveURL(dnsName: dns, httpsPort: httpsPort)
        }
    }

    /// Removes our entry (and only ours) from the machine's serve config.
    public func disableTailscaleServe() async {
        guard let ts = await tailscale.status(forceRefresh: true), let dns = ts.dnsName,
              case .alreadyServing(let httpsPort) = await servePlan(dnsName: dns) else { return }
        _ = await tailscale.run(["serve", "--https=\(httpsPort)", "off"])
    }

    /// Sends a test notification to every phone with alerts on; returns how
    /// many accepted it.
    public func sendTestNotification() async -> Int {
        guard let push, let payload = try? JSONEncoder().encode(PushMessage(title: "Shepherd", body: "Notifications are working.")) else { return 0 }
        return await push.send(payload)
    }

    public func stop() async {
        tasks.forEach { $0.cancel() }
        tasks = []
        await keepAwake?.shutdown()
        keepAwake = nil
        await http?.stop()
        http = nil
        push = nil
    }
}
