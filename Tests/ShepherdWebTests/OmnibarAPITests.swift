import Foundation
import ShepherdCore
import Testing
@testable import ShepherdWebKit

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _asks: [(String, String?)] = []
    private var _ignored: [(String, Bool)] = []
    private var _started: [String] = []
    var asks: [(String, String?)] { lock.withLock { _asks } }
    var ignored: [(String, Bool)] { lock.withLock { _ignored } }
    var started: [String] { lock.withLock { _started } }
    func ask(_ t: String, _ r: String?) { lock.withLock { _asks.append((t, r)) } }
    func ignore(_ id: String, _ v: Bool) { lock.withLock { _ignored.append((id, v)) } }
    func start(_ id: String) { lock.withLock { _started.append(id) } }
}

private let pr = ReviewPR(repoSlug: "yotoplay/yoto-api", number: 7, title: "Fix the thing", url: "https://github.com/yotoplay/yoto-api/pull/7",
                          headRefName: "fix", isBot: false, updatedAt: Date(timeIntervalSince1970: 1_700_000_000), reviewDecision: "APPROVED",
                          checkSummary: CheckSummary(passing: 3, total: 4, hasFailure: true))

private func api(_ calls: Calls, outcome: InlinePromptOutcome = .answered(text: "Four.", sessionID: "inline-1"), failStart: Bool = false) -> OmnibarAPI {
    OmnibarAPI(backend: FakeSessionBackend(sessions: []), services: OmnibarServices(
        ask: { text, resume in calls.ask(text, resume); return outcome },
        reviews: { [MatchedReviewPR(pr: pr, localPath: "/src/yoto-api"), MatchedReviewPR(pr: pr, localPath: nil, isIgnored: true)] },
        startReview: { id in if failStart { throw NSError(domain: "x", code: 1) }; calls.start(id); return "sess-1" },
        setIgnored: { id, v in calls.ignore(id, v) }))
}

private func call(_ api: OmnibarAPI, _ method: String, _ path: String, _ body: [String: Any] = [:]) async -> (Int, [String: Any]) {
    let data = body.isEmpty ? Data() : try! JSONSerialization.data(withJSONObject: body)
    let r = await api.handle(HTTPServer.Request(method: method, path: path, query: [:], headers: [:], body: data))
    return (r.status, (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:])
}

private func apiWithSession(in directory: String, _ calls: Calls, home: URL) -> OmnibarAPI {
    var a = OmnibarAPI(backend: FakeSessionBackend(sessions: [
        Session(id: SessionID(rawValue: "running-1"), title: "Review", agent: .claude, workingDirectory: URL(fileURLWithPath: directory), attention: .idle())]),
        services: OmnibarServices(
            ask: { _, _ in .failed("x") },
            reviews: { [MatchedReviewPR(pr: pr, localPath: nil)] },
            startReview: { id in calls.start(id); return "new" },
            setIgnored: { _, _ in }))
    a.home = home
    return a
}

@Suite struct OmnibarAPITests {
    @Test func aPRWithASessionInItsWorktreeIsMarkedAndStartingItGoesToThatSession() async throws {
        let home = URL(fileURLWithPath: "/tmp/omni-home")
        let calls = Calls()
        let a = apiWithSession(in: reviewWorktreePath(repoSlug: "yotoplay/yoto-api", number: 7, home: home), calls, home: home)
        let listed = await a.handle(HTTPServer.Request(method: "GET", path: "/api/reviews", query: [:], headers: [:], body: Data()))
        let list = try #require(try JSONSerialization.jsonObject(with: listed.body) as? [[String: Any]])
        #expect(list[0]["session_id"] as? String == "running-1")
        let (status, body) = await call(a, "POST", "/api/reviews/start", ["id": "yotoplay/yoto-api#7"])
        #expect(status == 200 && body["session_id"] as? String == "running-1" && calls.started.isEmpty)
        let other = apiWithSession(in: "/tmp/elsewhere", calls, home: home)
        let (_, fresh) = await call(other, "POST", "/api/reviews/start", ["id": "yotoplay/yoto-api#7"])
        #expect(fresh["session_id"] as? String == "new" && calls.started == ["yotoplay/yoto-api#7"])
    }

    @Test func askReturnsTheAnswerAndPassesTheFollowUpConversationOn() async {
        let calls = Calls()
        let (status, body) = await call(api(calls), "POST", "/api/ask", ["text": " what is 2+2 ", "resume_session_id": "inline-0"])
        #expect(status == 200 && body["text"] as? String == "Four." && body["session_id"] as? String == "inline-1")
        #expect(calls.asks.first?.0 == "what is 2+2" && calls.asks.first?.1 == "inline-0")
    }

    @Test func askEscalationAndFailuresAreReportedAndEmptyTextIsRefused() async {
        let calls = Calls()
        let (_, escalated) = await call(api(calls, outcome: .escalated), "POST", "/api/ask", ["text": "edit files"])
        #expect(escalated["escalated"] as? Bool == true)
        let (failed, failBody) = await call(api(calls, outcome: .failed("no claude")), "POST", "/api/ask", ["text": "hi"])
        #expect(failed == 502 && failBody["error"] as? String == "no claude")
        let (empty, _) = await call(api(calls), "POST", "/api/ask", ["text": "  "])
        #expect(empty == 400 && calls.asks.count == 2)
    }

    @Test func continuingAnAnswerStartsASessionThatResumesIt() async {
        let (status, body) = await call(api(Calls()), "POST", "/api/ask/continue", ["session_id": "inline-1"])
        #expect(status == 200 && body["session_id"] is String)
    }

    @Test func reviewsListsPRsWithTheirStatusAndWhetherTheyAreCloned() async throws {
        let r = await api(Calls()).handle(HTTPServer.Request(method: "GET", path: "/api/reviews", query: [:], headers: [:], body: Data()))
        let list = try #require(try JSONSerialization.jsonObject(with: r.body) as? [[String: Any]])
        #expect(list.count == 2)
        #expect(list[0]["id"] as? String == "yotoplay/yoto-api#7" && list[0]["status"] as? String == "Approved")
        #expect(list[0]["checks"] as? String == "3/4" && list[0]["checks_failing"] as? Bool == true)
        #expect(list[0]["cloned"] as? Bool == true && list[1]["cloned"] as? Bool == false && list[1]["ignored"] as? Bool == true)
    }

    @Test func startingIgnoringAndRestoringAReviewReachTheApp() async {
        let calls = Calls()
        let a = api(calls)
        let (status, body) = await call(a, "POST", "/api/reviews/start", ["id": "yotoplay/yoto-api#7"])
        #expect(status == 200 && body["session_id"] as? String == "sess-1" && calls.started == ["yotoplay/yoto-api#7"])
        _ = await call(a, "POST", "/api/reviews/ignore", ["id": "o/r#1"])
        _ = await call(a, "POST", "/api/reviews/restore", ["id": "o/r#1"])
        #expect(calls.ignored.map(\.1) == [true, false])
        let (failed, _) = await call(api(calls, failStart: true), "POST", "/api/reviews/start", ["id": "o/r#2"])
        #expect(failed == 502)
    }

    @Test func otherPathsAndBadBodiesAreRefused() async {
        let a = api(Calls())
        #expect(!a.handles("/api/tasks") && a.handles("/api/reviews/start") && a.handles("/api/ask"))
        let (bad, _) = await call(a, "POST", "/api/reviews/start", ["nope": 1])
        #expect(bad == 400)
        let (missing, _) = await call(a, "GET", "/api/reviews/start")
        #expect(missing == 404)
    }
}
