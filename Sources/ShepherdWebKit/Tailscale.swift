import Foundation

/// What `tailscale status --json` says that Shepherd cares about.
struct TailscaleStatus: Equatable, Sendable {
    var backendState: String
    var dnsName: String?
    var certDomains: [String]
    var ownerLogin: String?

    var isRunning: Bool { backendState == "Running" }

    /// HTTPS certificates are enabled for the tailnet (the admin-console
    /// switch): Tailscale then lists this machine's name under CertDomains.
    var httpsEnabled: Bool {
        guard let dnsName else { return false }
        return certDomains.contains(dnsName)
    }

    /// `https://<machine>.<tailnet>.ts.net`, once there's a name to use.
    var httpsURL: String? { dnsName.map { "https://\($0)" } }

    static func parse(_ data: Data) -> TailscaleStatus? {
        struct Wire: Decodable {
            struct Node: Decodable {
                let DNSName: String?
                let UserID: Int64?
            }
            struct User: Decodable { let LoginName: String? }
            let BackendState: String?
            let Selfnode: Node?
            let CertDomains: [String]?
            let User: [String: User]?

            enum CodingKeys: String, CodingKey {
                case BackendState, CertDomains, User
                case Selfnode = "Self"
            }
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        // Tailscale reports the name with a trailing dot.
        let dns = wire.Selfnode?.DNSName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.flatMap { $0.isEmpty ? nil : $0 }
        let owner = wire.Selfnode?.UserID.flatMap { wire.User?[String($0)]?.LoginName }
        return TailscaleStatus(
            backendState: wire.BackendState ?? "Unknown",
            dnsName: dns,
            certDomains: wire.CertDomains ?? [],
            ownerLogin: owner
        )
    }
}

/// Where the `tailscale` CLI lives: Homebrew/standalone installs put it on
/// the PATH-ish locations, and the Mac App Store / standalone app both ship
/// it inside the app bundle (the GUI binary doubles as the CLI).
func locateTailscaleCLI(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
    [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ].first(where: fileExists)
}

/// Thin async wrapper over the CLI, with a short cache - the access gate
/// asks for the owner on every phone request, and `tailscale status` is a
/// process spawn.
actor TailscaleService {
    private var cached: (status: TailscaleStatus?, at: Date)?
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 10) { self.ttl = ttl }

    var isInstalled: Bool { locateTailscaleCLI() != nil }

    func status(forceRefresh: Bool = false) async -> TailscaleStatus? {
        if !forceRefresh, let cached, Date().timeIntervalSince(cached.at) < ttl { return cached.status }
        let fresh = await run(["status", "--json"]).flatMap { $0.status == 0 ? TailscaleStatus.parse($0.output) : nil }
        cached = (fresh, Date())
        return fresh
    }

    /// Runs the CLI; nil if it isn't installed or doesn't answer in time.
    func run(_ arguments: [String], timeout: TimeInterval = 8) async -> (status: Int32, output: Data)? {
        guard let path = locateTailscaleCLI() else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: (process.terminationStatus, output))
            }
        }
    }
}
