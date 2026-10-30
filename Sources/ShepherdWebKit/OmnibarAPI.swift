import Foundation
import ShepherdCore

/// What the omnibar's Ask and Review modes need from the app: `claude -p`, `gh` and git worktrees live in the app target,
/// so they come in as closures, the way the panel gets them.
public struct OmnibarServices: Sendable {
    public var ask: @Sendable (_ text: String, _ resumeSessionID: String?) async -> InlinePromptOutcome
    public var reviews: @Sendable () async throws -> [MatchedReviewPR]
    /// Starts (or finds) the review session for a PR by its id (`owner/repo#number`) and returns the session's id.
    public var startReview: @Sendable (_ prID: String) async throws -> String
    public var setIgnored: @Sendable (_ prID: String, _ ignored: Bool) -> Void

    public init(
        ask: @escaping @Sendable (String, String?) async -> InlinePromptOutcome,
        reviews: @escaping @Sendable () async throws -> [MatchedReviewPR],
        startReview: @escaping @Sendable (String) async throws -> String,
        setIgnored: @escaping @Sendable (String, Bool) -> Void
    ) {
        self.ask = ask
        self.reviews = reviews
        self.startReview = startReview
        self.setIgnored = setIgnored
    }
}

private struct AskBody: Decodable {
    let text: String
    let resumeSessionID: String?
    enum CodingKeys: String, CodingKey { case text, resumeSessionID = "resume_session_id" }
}
private struct ContinueBody: Decodable {
    let sessionID: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}
private struct PRBody: Decodable { let id: String }

private struct AskWire: Encodable {
    var text: String?
    var sessionID: String?
    var escalated = false
    enum CodingKeys: String, CodingKey { case text, escalated, sessionID = "session_id" }
}
private struct ReviewWire: Encodable {
    let id: String
    let repo: String
    let number: Int
    let title: String
    let url: String
    let branch: String
    let isMine: Bool
    let isDraft: Bool
    let isBot: Bool
    let ignored: Bool
    let cloned: Bool
    let status: String
    let checks: String?
    let checksFailing: Bool
    let updated: Date
    /// A session already running in this PR's review worktree.
    let sessionID: String?
    enum CodingKeys: String, CodingKey {
        case id, repo, number, title, url, branch, ignored, cloned, status, checks, updated
        case sessionID = "session_id"
        case isMine = "is_mine", isDraft = "is_draft", isBot = "is_bot", checksFailing = "checks_failing"
    }
}
private struct SessionRefWire: Encodable {
    let sessionID: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}
private struct ErrorWire: Encodable { let error: String }

/// `/api/ask*` and `/api/reviews*`: the panel's Ask and Review tabs as endpoints, for the dashboard's omnibar.
struct OmnibarAPI {
    let backend: any SessionBackend
    let services: OmnibarServices
    var config: @Sendable () -> ShepherdConfig = { ShepherdConfig.load() }
    var home = FileManager.default.homeDirectoryForCurrentUser

    func handles(_ path: String) -> Bool {
        path == "/api/ask" || path == "/api/ask/continue" || path == "/api/reviews" || path.hasPrefix("/api/reviews/")
    }

    func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        do {
            switch (request.method, request.path) {
            case ("POST", "/api/ask"): return try await ask(request)
            case ("POST", "/api/ask/continue"): return try await continueAsk(request)
            case ("GET", "/api/reviews"): return try await reviews()
            case ("POST", "/api/reviews/start"): return try await startReview(request)
            case ("POST", "/api/reviews/ignore"): return try setIgnored(request, true)
            case ("POST", "/api/reviews/restore"): return try setIgnored(request, false)
            default: return .notFound()
            }
        } catch let error as DecodingError {
            return fail("bad request: \(error)", 400)
        } catch {
            return fail("\(error)", 502)
        }
    }

    private func fail(_ message: String, _ status: Int) -> HTTPServer.Response {
        .json((try? JSONEncoder().encode(ErrorWire(error: message))) ?? Data(), status: status)
    }

    private func ask(_ request: HTTPServer.Request) async throws -> HTTPServer.Response {
        let body = try JSONDecoder().decode(AskBody.self, from: request.body)
        let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return fail("ask needs some text", 400) }
        switch await services.ask(text, body.resumeSessionID) {
        case .answered(let answer, let sessionID): return .json(try JSONEncoder().encode(AskWire(text: answer, sessionID: sessionID)))
        case .escalated: return .json(try JSONEncoder().encode(AskWire(escalated: true)))
        case .failed(let message): return fail(message, 502)
        }
    }

    /// Carries a quick answer on in a real session (same conversation, `--resume`) in the default folder.
    private func continueAsk(_ request: HTTPServer.Request) async throws -> HTTPServer.Response {
        let body = try JSONDecoder().decode(ContinueBody.self, from: request.body)
        let id = try await backend.createSession(CreateSessionRequest(
            workingDirectory: URL(fileURLWithPath: config().resolvedDefaultSessionDirectory),
            agent: config().resolvedAgentKind, resumeSessionID: body.sessionID))
        return .json(try JSONEncoder().encode(SessionRefWire(sessionID: id.rawValue)))
    }

    /// The session already working in a PR's review worktree, if there is one (a finished or interrupted one counts: going to
    /// it is better than a second conversation about the same PR).
    private func existingSession(repoSlug: String, number: Int) async -> String? {
        let path = reviewWorktreePath(repoSlug: repoSlug, number: number, home: home)
        let sessions = (try? await backend.snapshot().sessions) ?? []
        return sessions.first { $0.workingDirectory?.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path }?.id.rawValue
    }

    private func reviews() async throws -> HTTPServer.Response {
        let matches = try await services.reviews()
        var running: [String: String] = [:]
        for m in matches { if let id = await existingSession(repoSlug: m.pr.repoSlug, number: m.pr.number) { running[m.id] = id } }
        let wire = matches.map { m in
            ReviewWire(
                id: m.id, repo: m.pr.repoSlug, number: m.pr.number, title: m.pr.title, url: m.pr.url, branch: m.pr.headRefName,
                isMine: m.pr.isMine, isDraft: m.pr.isDraft, isBot: m.pr.isBot, ignored: m.isIgnored, cloned: m.isCloned,
                status: m.pr.isDraft ? "Draft" : reviewStatusLabel(m.pr.reviewDecision),
                checks: m.pr.checkSummary.map { "\($0.passing)/\($0.total)" }, checksFailing: m.pr.checkSummary?.hasFailure ?? false,
                updated: m.pr.updatedAt, sessionID: running[m.id])
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return .json(try encoder.encode(wire))
    }

    private func startReview(_ request: HTTPServer.Request) async throws -> HTTPServer.Response {
        let body = try JSONDecoder().decode(PRBody.self, from: request.body)
        if let slash = body.id.lastIndex(of: "#"), let number = Int(body.id[body.id.index(after: slash)...]),
           let existing = await existingSession(repoSlug: String(body.id[..<slash]), number: number) {
            return .json(try JSONEncoder().encode(SessionRefWire(sessionID: existing)))
        }
        return .json(try JSONEncoder().encode(SessionRefWire(sessionID: try await services.startReview(body.id))))
    }

    private func setIgnored(_ request: HTTPServer.Request, _ ignored: Bool) throws -> HTTPServer.Response {
        let body = try JSONDecoder().decode(PRBody.self, from: request.body)
        services.setIgnored(body.id, ignored)
        return .json(Data("{}".utf8))
    }
}
