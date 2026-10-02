import Foundation

/// One `Web` entry of `tailscale serve status --json`: a host:port Tailscale
/// terminates HTTPS on, and what it forwards to.
struct ServeEntry: Equatable {
    let hostPort: String
    /// The `/` handler's proxy target, when it is one.
    let rootProxy: String?
    let handlerCount: Int
}

func parseServeStatus(_ data: Data) -> [ServeEntry] {
    struct Wire: Decodable {
        struct Entry: Decodable {
            struct Handler: Decodable { let Proxy: String? }
            let Handlers: [String: Handler]?
        }
        let Web: [String: Entry]?
    }
    guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return [] }
    return (wire.Web ?? [:]).map { hostPort, entry in
        ServeEntry(hostPort: hostPort, rootProxy: entry.Handlers?["/"]?.Proxy, handlerCount: entry.Handlers?.count ?? 0)
    }
}

enum ServePlan: Equatable {
    /// Our proxy is already published on this HTTPS port.
    case alreadyServing(httpsPort: Int)
    /// Nothing is on this HTTPS port, so we can publish there.
    case create(httpsPort: Int)
    /// Every HTTPS port Tailscale allows is in use by something else.
    case noFreePort
}

/// The HTTPS ports `tailscale serve` accepts.
let serveHTTPSPorts = [443, 8443, 10000]

/// Where to publish `localPort` for this machine. The serve config is global
/// to the machine, so this never overwrites an entry that isn't ours: it
/// reuses our own entry if there is one, otherwise the first free HTTPS port
/// (443 preferred, since it gives the shortest address).
func planServe(dnsName: String, entries: [ServeEntry], localPort: Int) -> ServePlan {
    let ours: (ServeEntry) -> Bool = {
        $0.handlerCount == 1 && ($0.rootProxy == "http://127.0.0.1:\(localPort)" || $0.rootProxy == "http://localhost:\(localPort)")
    }
    for port in serveHTTPSPorts {
        if let entry = entries.first(where: { $0.hostPort == "\(dnsName):\(port)" }), ours(entry) {
            return .alreadyServing(httpsPort: port)
        }
    }
    for port in serveHTTPSPorts where !entries.contains(where: { $0.hostPort == "\(dnsName):\(port)" }) {
        return .create(httpsPort: port)
    }
    return .noFreePort
}

/// `https://name`, or `https://name:port` off the default port.
func serveURL(dnsName: String, httpsPort: Int) -> String {
    httpsPort == 443 ? "https://\(dnsName)" : "https://\(dnsName):\(httpsPort)"
}

/// What the CLI says when it can't proceed without the user doing something
/// in Tailscale's admin console (Serve or HTTPS not enabled for the tailnet).
/// It prints a link and waits, so the call times out rather than failing -
/// the output is how we know why.
func parseServeNeedsAction(_ output: String) -> (message: String, url: String?)? {
    let lower = output.lowercased()
    guard lower.contains("not enabled") || lower.contains("must be enabled") || lower.contains("to enable") else { return nil }
    let url = output.split(whereSeparator: { $0.isWhitespace }).map(String.init).first { $0.hasPrefix("https://login.tailscale.com") }
    let firstLine = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Tailscale needs a setting turned on"
    return (firstLine, url)
}
