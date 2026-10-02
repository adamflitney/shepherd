import Foundation

enum AccessDecision: Equatable {
    case allow
    case deny(String)
}

/// Who may talk to the server. It only listens on loopback, so a request
/// arrives one of two ways: directly from a process on this Mac (a local
/// browser, curl) - trusted, same as any local process that can already read
/// `~/.shepherd` - or via `tailscale serve`, which stamps the caller's
/// identity onto it (and strips any client-supplied copy of those headers,
/// so they can't be forged from the network).
///
/// Everything a proxied request can't prove is refused: a public Funnel
/// request, a tagged device with no user, or a user who isn't the Mac's own
/// owner (e.g. a device shared into the tailnet).
func accessDecision(headers: [String: String], ownerLogin: String?) -> AccessDecision {
    if headers["tailscale-funnel-request"] != nil {
        return .deny("This server is not available over Tailscale Funnel")
    }
    if let login = headers["tailscale-user-login"] {
        guard let ownerLogin else { return .deny("Can't verify the Mac's Tailscale owner") }
        return login.caseInsensitiveCompare(ownerLogin) == .orderedSame
            ? .allow
            : .deny("This Mac's owner hasn't allowed that account")
    }
    if headers["x-forwarded-for"] != nil {
        return .deny("Requests through the proxy must carry a Tailscale user identity")
    }
    return .allow
}

/// `localhost:8787` -> `localhost`, `[::1]:8787` -> `[::1]`; lower-cased, with
/// a trailing dot (a fully-qualified name) removed.
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

func isLocalHostName(_ host: String?) -> Bool {
    guard let host else { return false }
    return ["localhost", "127.0.0.1", "[::1]"].contains(host)
}

/// Defences against a *web page* in the user's own browser reaching this
/// loopback server - the identity check can't help there, because such a
/// request comes from a local process (the browser) and is trusted. Browsers
/// will send cross-origin "simple" POSTs (and DNS-rebinding pages even read
/// the replies) without asking, so the server has to refuse them itself:
///
/// - `Host` must be a name we serve (loopback, or this Mac's tailnet name):
///   stops DNS rebinding, where an attacker's own domain resolves to us.
/// - `Sec-Fetch-Site` (sent by current browsers) must say the request is
///   same-origin or user-initiated - this also catches another app on a
///   different localhost port, which is "same-site" but not us.
/// - A present `Origin` must name the same host as `Host`.
/// - A request body must be JSON: it's what our own client sends, and a
///   non-JSON POST is exactly what a cross-site form or `text/plain` fetch
///   produces.
func requestSafety(method: String, headers: [String: String], hasBody: Bool, tailnetHost: String?) -> AccessDecision {
    guard let host = headers["host"].flatMap(hostname(fromHostHeader:)) else {
        return .deny("Missing Host header")
    }
    let tailnet = tailnetHost.map { $0.lowercased().hasSuffix(".") ? String($0.lowercased().dropLast()) : $0.lowercased() }
    guard isLocalHostName(host) || host == tailnet else {
        return .deny("Unexpected Host")
    }
    if let site = headers["sec-fetch-site"], site != "same-origin", site != "none" {
        return .deny("Cross-site requests are not allowed")
    }
    if let origin = headers["origin"] {
        guard let originHost = URL(string: origin)?.host.flatMap({ hostname(fromHostHeader: $0.contains(":") ? "[\($0)]" : $0) }),
              originHost == host else {
            return .deny("Cross-origin requests are not allowed")
        }
    }
    if hasBody, ["POST", "PUT", "PATCH", "DELETE"].contains(method.uppercased()) {
        guard (headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else {
            return .deny("Request bodies must be application/json")
        }
    }
    return .allow
}
