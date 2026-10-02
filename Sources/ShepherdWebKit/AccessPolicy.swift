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
