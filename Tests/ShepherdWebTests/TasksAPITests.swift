import Foundation
import ShepherdCore
import ShepherdGhostty
import ShepherdTasks
import Testing
@testable import ShepherdWebKit

/// A fake backend that remembers what it was asked to start.
private actor RecordingBackend: SessionBackend {
    let inner: FakeSessionBackend
    private(set) var created: [CreateSessionRequest] = []
    private(set) var prompts: [String] = []
    private(set) var closed: [SessionID] = []
    init(sessions: [Session] = []) { inner = FakeSessionBackend(sessions: sessions) }
    func snapshot() async throws -> SessionsSnapshot { try await inner.snapshot() }
    nonisolated func events() -> AsyncStream<BackendEvent> { inner.events() }
    func focus(_ id: SessionID) async throws { try await inner.focus(id) }
    func createSession(_ request: CreateSessionRequest) async throws -> SessionID {
        created.append(request)
        return try await inner.createSession(request)
    }
    func close(_ id: SessionID) async throws { closed.append(id); try await inner.close(id) }
    func prompt(_ id: SessionID, text: String) async throws { prompts.append(text); try await inner.prompt(id, text: text) }
    func peek(_ id: SessionID) async throws -> String { try await inner.peek(id) }
    func respond(_ id: SessionID, keys: [String]) async throws { try await inner.respond(id, keys: keys) }
}

private struct Rig {
    let root: URL
    let projects: URL
    let repo: URL
    let store: TaskStore
    let config: ShepherdConfig

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tasks-api-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        projects = root.appendingPathComponent("projects")
        repo = projects.appendingPathComponent("board")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = TaskStore(directory: root.appendingPathComponent("tasks"))
        var c = ShepherdConfig.default
        c.sessions.defaultDirectory = home.path
        c.projects.directories = [projects.path]
        config = c
    }

    func api(_ backend: any SessionBackend) -> TasksAPI {
        let store = self.store, config = self.config
        return TasksAPI(backend: backend, store: { store }, config: { config })
    }

    func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
}

private func request(_ method: String, _ path: String, body: Data = Data()) -> HTTPServer.Request {
    HTTPServer.Request(method: method, path: path, query: [:], headers: [:], body: body)
}

private func object(_ response: HTTPServer.Response) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
}

private func array(_ response: HTTPServer.Response) -> [[String: Any]] {
    (try? JSONSerialization.jsonObject(with: response.body)) as? [[String: Any]] ?? []
}

@Test func listsOpenTasksAndOnlyTheLatestDoneOnes() async throws {
    let rig = try Rig()
    for i in 1...4 { _ = try rig.store.create(NewTask(title: "open \(i)")) }
    for i in 1...5 {
        let t = try rig.store.create(NewTask(title: "done \(i)"))
        _ = try rig.store.update(t.id) { $0.setStatus(.done) }
    }
    var api = rig.api(RecordingBackend())
    api.doneLimit = 3
    let tasks = array(await api.handle(request("GET", "/api/tasks")))
    #expect(tasks.filter { $0["status"] as? String != "done" }.count == 4)
    #expect(tasks.filter { $0["status"] as? String == "done" }.count == 3)
}

@Test func theDetailCarriesThePlanAndTheLog() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Detail", objective: "Show it"))
    _ = try rig.store.update(t.id) { $0.setPlan(["one", "two"]); try $0.setPlanItem(1, done: true); $0.appendLog("did a thing") }
    let detail = object(await rig.api(RecordingBackend()).handle(request("GET", "/api/tasks/\(t.id)")))
    let plan = detail["plan"] as? [[String: Any]]
    #expect(plan?.count == 2 && plan?[0]["done"] as? Bool == true && plan?[1]["done"] as? Bool == false)
    #expect((detail["log"] as? [String])?.last?.contains("did a thing") == true)
    #expect(detail["progress_done"] as? Int == 1 && detail["progress_total"] as? Int == 2)
    #expect((await rig.api(RecordingBackend()).handle(request("GET", "/api/tasks/999"))).status == 404)
}

@Test func createsATaskOnlyWithATitleAndInAnOfferedFolder() async throws {
    let rig = try Rig()
    let api = rig.api(RecordingBackend())
    let created = await api.handle(request("POST", "/api/tasks", body: rig.json(["title": "  New thing  ", "project_path": rig.repo.path])))
    #expect(created.status == 200)
    #expect(object(created)["title"] as? String == "New thing")
    #expect(object(created)["status"] as? String == "inbox")
    #expect(rig.store.list().count == 1)

    #expect((await api.handle(request("POST", "/api/tasks", body: rig.json(["title": "   "])))).status == 400)
    #expect((await api.handle(request("POST", "/api/tasks", body: rig.json(["title": "x", "project_path": "/etc"])))).status == 400)
    #expect(rig.store.list().count == 1)
}

@Test func movesATaskAndRefusesAnUnknownStatusOrTask() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Move me"))
    let api = rig.api(RecordingBackend())
    #expect((await api.handle(request("POST", "/api/tasks/\(t.id)/status", body: rig.json(["status": "review"])))).status == 200)
    #expect(rig.store.get(t.id)?.status == .review)
    #expect((await api.handle(request("POST", "/api/tasks/\(t.id)/status", body: rig.json(["status": "nonsense"])))).status == 400)
    #expect((await api.handle(request("POST", "/api/tasks/99/status", body: rig.json(["status": "done"])))).status == 404)
}

@Test func startingATaskStartsASessionForItAndMovesItOutOfTheInbox() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Start me", projectPath: rig.repo.path))
    let backend = RecordingBackend()
    let response = await rig.api(backend).handle(request("POST", "/api/tasks/\(t.id)/start"))
    #expect(response.status == 200)
    #expect(object(response)["session_id"] as? String != nil)
    let created = await backend.created
    #expect(created.count == 1 && created[0].taskID == t.id)
    #expect(created[0].workingDirectory.path == rig.repo.path)
    #expect(rig.store.get(t.id)?.status == .active)
}

@Test func aTaskWithNoFolderStartsInTheDefaultDirectory() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "No folder"))
    let backend = RecordingBackend()
    _ = await rig.api(backend).handle(request("POST", "/api/tasks/\(t.id)/start"))
    #expect(await backend.created.first?.workingDirectory.path == rig.root.appendingPathComponent("home").path)
}

@Test func startingATaskWhoseFolderIsNotOfferedIsRefused() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Elsewhere", projectPath: "/etc"))
    let backend = RecordingBackend()
    let response = await rig.api(backend).handle(request("POST", "/api/tasks/\(t.id)/start"))
    #expect(response.status == 400)
    #expect(await backend.created.isEmpty)
    #expect(rig.store.get(t.id)?.status == .inbox)
}

@Test func startingATaskThatHasALiveSessionGoesToItInstead() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Running", projectPath: rig.repo.path))
    let live = Session(id: SessionID(rawValue: "live-1"), title: "Running", agent: .claude, attention: .idle(),
                       group: SessionGroup(id: "task-\(t.id)", label: "#\(t.id) Running"), capabilities: [.focus])
    let backend = RecordingBackend(sessions: [live])
    let response = await rig.api(backend).handle(request("POST", "/api/tasks/\(t.id)/start"))
    #expect(object(response)["session_id"] as? String == "live-1")
    #expect(await backend.created.isEmpty)
}

@Test func anUntrackedSessionCanBecomeATaskOnce() async throws {
    let rig = try Rig()
    let session = Session(id: SessionID(rawValue: "loose-1"), title: "Loose work", agent: .claude, workingDirectory: rig.repo,
                          attention: .idle(), group: SessionGroup(id: rig.repo.path, label: "board"), capabilities: [.focus])
    let api = rig.api(RecordingBackend(sessions: [session]))
    let first = await api.handle(request("POST", "/api/tasks/from-session", body: rig.json(["session_id": "loose-1"])))
    #expect(first.status == 200)
    let task = try #require(rig.store.list().first)
    #expect(task.title == "Loose work" && task.sessions == ["loose-1"] && task.status == .active && task.projectPath == rig.repo.path)
    let again = await api.handle(request("POST", "/api/tasks/from-session", body: rig.json(["session_id": "loose-1"])))
    #expect(object(again)["id"] as? Int == task.id)
    #expect(rig.store.list().count == 1)
    #expect((await api.handle(request("POST", "/api/tasks/from-session", body: rig.json(["session_id": "ghost"])))).status == 404)
}

@Test func editsATasksTitleAndObjectiveAndRefusesAnEmptyTitle() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Old", objective: "Before"))
    let api = rig.api(RecordingBackend())
    let edited = await api.handle(request("POST", "/api/tasks/\(t.id)/edit", body: rig.json(["title": " Better ", "objective": "After"])))
    #expect(edited.status == 200)
    #expect(rig.store.get(t.id)?.title == "Better" && rig.store.get(t.id)?.objective == "After")
    #expect((await api.handle(request("POST", "/api/tasks/\(t.id)/edit", body: rig.json(["title": "  "])))).status == 400)
    #expect((await api.handle(request("POST", "/api/tasks/999/edit", body: rig.json(["title": "x"])))).status == 404)
}

@Test func deletesATaskUnlessASessionIsStillRunningIt() async throws {
    let rig = try Rig()
    let gone = try rig.store.create(NewTask(title: "Bin me"))
    let busy = try rig.store.create(NewTask(title: "Busy"))
    let live = Session(id: SessionID(rawValue: "live-9"), title: "Running", agent: .claude, attention: .idle(),
                       group: SessionGroup(id: "task-\(busy.id)", label: "Busy"))
    let api = rig.api(RecordingBackend(sessions: [live]))
    #expect((await api.handle(request("POST", "/api/tasks/\(busy.id)/delete"))).status == 409)
    #expect(rig.store.get(busy.id) != nil)
    #expect((await api.handle(request("POST", "/api/tasks/\(gone.id)/delete"))).status == 200)
    #expect(rig.store.get(gone.id) == nil)
    #expect((await api.handle(request("POST", "/api/tasks/\(gone.id)/delete"))).status == 404)
}

private func liveSession(_ id: Int, summary: String? = nil, kind: AttentionState.Kind = .idle) -> Session {
    Session(id: SessionID(rawValue: "live-\(id)"), title: "Running", agent: .claude, attention: AttentionState(kind: kind, summary: summary),
            group: SessionGroup(id: "task-\(id)", label: "Task"), capabilities: [.focus, .prompt, .close])
}

@Test func doneOnATaskWithNothingRunningFinishesAtOnce() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Quiet"))
    let response = await rig.api(RecordingBackend()).handle(request("POST", "/api/tasks/\(t.id)/done"))
    #expect(object(response)["state"] as? String == "done")
    #expect(rig.store.get(t.id)?.status == .done)
}

@Test func doneAsksTheSessionForAResultThenEndsItAndFinishesTheTask() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Investigate"))
    let backend = RecordingBackend(sessions: [liveSession(t.id, summary: "fallback line")])
    var api = rig.api(backend)
    api.finishWait = 5
    let response = await api.handle(request("POST", "/api/tasks/\(t.id)/done"))
    #expect(object(response)["state"] as? String == "wrapping")
    #expect(array(await api.handle(request("GET", "/api/tasks"))).first?["finishing"] as? Bool == true)

    try await Task.sleep(nanoseconds: 700_000_000)
    _ = try rig.store.update(t.id) { $0.setResult("Found it: the limit lives in the basket service.") }
    for _ in 0..<40 where rig.store.get(t.id)?.status != .done { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(rig.store.get(t.id)?.status == .done)
    #expect(rig.store.get(t.id)?.result == "Found it: the limit lives in the basket service.")
    #expect(await backend.prompts.count == 1)
    #expect(await backend.closed.count == 1)
    #expect(array(await api.handle(request("GET", "/api/tasks"))).first?["finishing"] as? Bool == false)
}

@Test func doneFallsBackToTheSessionSummaryWhenNoResultIsWritten() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Silent agent"))
    var api = rig.api(RecordingBackend(sessions: [liveSession(t.id, summary: "Counted 14 resellers.")]))
    api.finishWait = 0.6
    _ = await api.handle(request("POST", "/api/tasks/\(t.id)/done"))
    for _ in 0..<40 where rig.store.get(t.id)?.status != .done { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(rig.store.get(t.id)?.status == .done)
    #expect(rig.store.get(t.id)?.result == "Counted 14 resellers.")
}

@Test func aBlockedSessionIsNotTypedAtAndDoneNowSkipsTheWait() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Waiting on you"))
    let backend = RecordingBackend(sessions: [liveSession(t.id, kind: .blocked)])
    var api = rig.api(backend)
    api.finishWait = 0.3
    _ = await api.handle(request("POST", "/api/tasks/\(t.id)/done"))
    for _ in 0..<40 where rig.store.get(t.id)?.status != .done { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(await backend.prompts.isEmpty)
    #expect(rig.store.get(t.id)?.status == .done)

    let u = try rig.store.create(NewTask(title: "Now"))
    let quick = rig.api(RecordingBackend(sessions: [liveSession(u.id)]))
    let response = await quick.handle(HTTPServer.Request(method: "POST", path: "/api/tasks/\(u.id)/done", query: ["now": "1"], headers: [:], body: Data()))
    #expect(object(response)["state"] as? String == "done")
}

@Test func reopenPutsADoneTaskBackToActive() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Again"))
    _ = try rig.store.update(t.id) { $0.setStatus(.done) }
    let response = await rig.api(RecordingBackend()).handle(request("POST", "/api/tasks/\(t.id)/reopen"))
    #expect(response.status == 200)
    #expect(rig.store.get(t.id)?.status == .active)
}

@Test func aSubtaskInheritsTheParentsFolderAndTheListCountsSubtasks() async throws {
    let rig = try Rig()
    let parent = try rig.store.create(NewTask(title: "Reseller work", projectPath: rig.repo.path))
    let api = rig.api(RecordingBackend())
    let created = await api.handle(request("POST", "/api/tasks", body: rig.json(["title": "Count them", "parent_id": parent.id])))
    #expect(created.status == 200)
    #expect(object(created)["parent_id"] as? Int == parent.id)
    #expect(rig.store.get(object(created)["id"] as! Int)?.projectPath == rig.repo.path)
    let second = try rig.store.create(NewTask(title: "Second", parent: parent.id))
    _ = try rig.store.update(second.id) { $0.setStatus(.done) }

    let listed = array(await api.handle(request("GET", "/api/tasks")))
    let row = listed.first { $0["id"] as? Int == parent.id }
    #expect(row?["subtasks_total"] as? Int == 2 && row?["subtasks_done"] as? Int == 1)
    let detail = object(await api.handle(request("GET", "/api/tasks/\(parent.id)")))
    #expect((detail["children"] as? [[String: Any]])?.count == 2)
    #expect((await api.handle(request("POST", "/api/tasks", body: rig.json(["title": "Deep", "parent_id": second.id])))).status == 400)
}

@Test func aParentWithSubtasksCannotBeDeletedAndDoneCanTakeTheChildrenWithIt() async throws {
    let rig = try Rig()
    let parent = try rig.store.create(NewTask(title: "Parent"))
    let childA = try rig.store.create(NewTask(title: "A", parent: parent.id))
    let childB = try rig.store.create(NewTask(title: "B", parent: parent.id))
    _ = try rig.store.update(childB.id) { $0.setStatus(.done) }
    let api = rig.api(RecordingBackend())
    #expect((await api.handle(request("POST", "/api/tasks/\(parent.id)/delete"))).status == 409)

    let done = await api.handle(HTTPServer.Request(method: "POST", path: "/api/tasks/\(parent.id)/done", query: ["children": "1"], headers: [:], body: Data()))
    #expect(object(done)["state"] as? String == "done")
    #expect(rig.store.get(parent.id)?.status == .done && rig.store.get(childA.id)?.status == .done)
}

@Test func resumingAnEarlierSessionUsesTheFolderItRanInAndRefusesForeignSessions() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Across repos", projectPath: rig.repo.path))
    _ = try rig.store.update(t.id) { $0.linkSession("sess-1"); $0.recordSession(id: "sess-1", cwd: rig.projects.appendingPathComponent("other").path) }
    let backend = RecordingBackend()
    let api = rig.api(backend)
    let ok = await api.handle(request("POST", "/api/tasks/\(t.id)/resume", body: rig.json(["session_id": "sess-1"])))
    #expect(ok.status == 200)
    let made = await backend.created.first
    #expect(made?.resumeSessionID == "sess-1" && made?.taskID == t.id)
    #expect(made?.workingDirectory.path == rig.projects.appendingPathComponent("other").path)
    #expect((await api.handle(request("POST", "/api/tasks/\(t.id)/resume", body: rig.json(["session_id": "someone-elses"])))).status == 400)
}

@Test func theTranscriptOfATasksSessionIsReadFromWhereItRan() async throws {
    let rig = try Rig()
    let t = try rig.store.create(NewTask(title: "Read back", projectPath: rig.repo.path))
    _ = try rig.store.update(t.id) { $0.linkSession("sess-9"); $0.recordSession(id: "sess-9", cwd: rig.repo.path) }
    var api = rig.api(RecordingBackend())
    api.home = rig.root.appendingPathComponent("claude-home")
    let file = TranscriptPeek.transcriptURL(workingDirectory: rig.repo.path, sessionID: "sess-9", home: api.home)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = [#"{"type":"user","message":{"role":"user","content":"how many resellers?"}}"#,
                 #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fourteen."}]}}"#]
    try Data(lines.joined(separator: "\n").utf8).write(to: file)
    let response = await api.handle(HTTPServer.Request(method: "GET", path: "/api/tasks/\(t.id)/transcript", query: ["session": "sess-9"], headers: [:], body: Data()))
    let text = object(response)["text"] as? String
    #expect(text?.contains("You\nhow many resellers?") == true && text?.contains("Claude\nFourteen.") == true)
    let missing = await api.handle(HTTPServer.Request(method: "GET", path: "/api/tasks/\(t.id)/transcript", query: ["session": "nope"], headers: [:], body: Data()))
    #expect(missing.status == 404)
}

@Test func searchFindsDoneTasksByTheirNotesAndStartingOneBringsItBack() async throws {
    let rig = try Rig()
    let a = try rig.store.create(NewTask(title: "Reseller investigation", projectPath: rig.repo.path))
    _ = try rig.store.update(a.id) { $0.appendNote("Found the Acme distributor in Leeds"); $0.setStatus(.done) }
    _ = try rig.store.create(NewTask(title: "Unrelated", projectPath: rig.repo.path))
    let api = rig.api(RecordingBackend())

    var search = HTTPServer.Request(method: "GET", path: "/api/tasks/search", query: ["q": "acme  LEEDS"], headers: [:], body: Data())
    var hits = try #require(try JSONSerialization.jsonObject(with: await api.handle(search).body) as? [[String: Any]])
    #expect(hits.count == 1 && hits[0]["id"] as? Int == a.id && hits[0]["found"] as? String == "notes" && hits[0]["status"] as? String == "done")
    search.query = ["q": "reseller"]
    hits = try #require(try JSONSerialization.jsonObject(with: await api.handle(search).body) as? [[String: Any]])
    #expect(hits.first?["found"] as? String == "title")
    search.query = ["q": "zzz"]
    #expect(try #require(try JSONSerialization.jsonObject(with: await api.handle(search).body) as? [Any]).isEmpty)

    let started = await api.handle(request("POST", "/api/tasks/\(a.id)/start"))
    #expect(started.status == 200 && rig.store.get(a.id)?.status == .active)
}
