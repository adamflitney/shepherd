import Foundation
import Testing
@testable import ShepherdTasks

/// 2026-10-11 09:30:00 in the current time zone, so formatted stamps are stable wherever this runs.
private let now: Date = {
    var c = DateComponents()
    c.year = 2026; c.month = 10; c.day = 11; c.hour = 9; c.minute = 30; c.second = 0
    return Calendar.current.date(from: c)!
}()

@Suite("TaskFile")
struct TaskFileTests {
    @Test func appendsLogEntriesUnderLogAndCreatesTheSectionIfMissing() {
        var t = TaskFile.parse("---\nid: 1\ntitle: T\n---\n\n## Plan\n- [ ] a\n")
        t.appendLog("started", now: now)
        #expect(t.serialize() == "---\nid: 1\ntitle: T\nupdated: 2026-10-11T09:30:00\n---\n\n## Plan\n- [ ] a\n\n## Log\n- 2026-10-11 09:30: started\n")
        t.appendLog("more", now: now)
        #expect(t.serialize().contains("- 2026-10-11 09:30: started\n- 2026-10-11 09:30: more\n"))
    }

    @Test func writesAResultSectionAndReplacesItWholeWithoutTouchingTheRest() {
        var t = TaskFile.parse("---\nid: 1\ntitle: T\n---\n\n## Plan\n- [ ] a\n\n## Log\n- 2026-10-11 09:30: started\n")
        #expect(t.result == nil)
        t.setResult("First answer.\n## Not a heading", now: now)
        #expect(t.result == "First answer.\n- Not a heading")
        t.setResult("Second answer.", now: now)
        #expect(t.result == "Second answer.")
        #expect(t.serialize().components(separatedBy: "## Result").count == 2)
        #expect(t.section("Plan") == ["- [ ] a"] && t.section("Log").count == 1)
    }

    @Test func notesWhereASessionRanOnceAndReadsItBack() {
        var t = TaskFile.parse("---\nid: 1\ntitle: T\n---\n\n## Plan\n\n## Log\n")
        #expect(t.sessionNotes.isEmpty)
        let first = t.recordSession(id: "abc", cwd: "/Users/me/Dev/api", title: "#1 Fix it · really", now: now)
        let again = t.recordSession(id: "abc", cwd: "/elsewhere", now: now)
        let second = t.recordSession(id: "def", cwd: "/Users/me/Dev/web", now: now)
        #expect(first && !again && second)
        let notes = t.sessionNotes
        #expect(notes.map(\.id) == ["abc", "def"])
        #expect(notes[0].cwd == "/Users/me/Dev/api" && notes[0].title == "#1 Fix it - really" && notes[1].title == nil)
        let reread = TaskFile.parse(t.serialize())
        #expect(reread.sessionNotes == notes)
        #expect(reread.section("Plan").isEmpty && reread.section("Log").isEmpty)
    }

    @Test func aTaskKnowsItsParentAndTheContextMentionsFamily() {
        var child = TaskFile.create(id: 2, title: "Child", parent: 1, now: now)
        #expect(child.parent == 1)
        child.setParent(nil, now: now)
        #expect(child.parent == nil)
        child.setParent(1, now: now)
        var parent = TaskFile.create(id: 1, title: "Parent", now: now)
        parent.setObjective("Ship the reseller work", now: now)
        let context = taskContext(child, parent: parent)
        #expect(context.contains("part of #1: Parent (Ship the reseller work)"))
        #expect(taskContext(parent, children: [child]).contains("Subtasks: #2 Child [inbox]"))
    }

    @Test func keepsTextAfterTheLogSectionsLastEntryInOrder() {
        var t = TaskFile.parse("---\nid: 1\n---\n## Log\n- old\n\n## Notes\nkeep\n")
        t.appendLog("new", now: now)
        #expect(t.body == "## Log\n- old\n- 2026-10-11 09:30: new\n\n## Notes\nkeep\n")
    }

    @Test func linksSessionsOnceAndUnlinksThem() {
        var t = TaskFile.parse("---\nid: 1\nsessions: [a]\n---\n")
        t.linkSession("b")
        t.linkSession("b")
        #expect(t.sessions == ["a", "b"])
        t.unlinkSession("a")
        #expect(t.sessions == ["b"])
    }

    @Test func addsAndChecksPlanItems() throws {
        var t = TaskFile.parse("---\nid: 1\n---\n")
        t.addPlanItem("first")
        t.addPlanItem("second")
        try t.setPlanItem(2, done: true)
        #expect(t.body == "## Plan\n- [ ] first\n- [x] second\n")
        #expect(t.progress == PlanProgress(done: 1, total: 2))
        try t.setPlanItem(2, done: false)
        #expect(t.progress == PlanProgress(done: 0, total: 2))
        #expect(throws: TaskError("no plan item 9")) { try t.setPlanItem(9, done: true) }
    }

    @Test func aNewTaskHasEmptyPlanAndLogSections() {
        let t = TaskFile.create(id: 7, title: "Do it: now", objective: "ship", projectPath: "/p", now: now)
        #expect(t.id == 7)
        #expect(t.title == "Do it: now")  // survives the quoting
        #expect(t.status == .inbox)
        #expect(t.body == "## Plan\n\n## Log\n")
    }

    @Test func contextKeepsThePlanAndTheNewestLogLinesWithinTheLimit() {
        var t = TaskFile.create(id: 1, title: "Big", now: now)
        t.addPlanItem("the plan")
        for i in 0..<500 { t.appendLog("entry number \(i)", now: now) }
        let text = taskContext(t, max: 2000)
        #expect(text.count <= 2000)
        #expect(text.contains("the plan"))
        #expect(text.contains("entry number 499"))
        #expect(!text.contains("entry number 0\n"))
        #expect(text.contains("(most recent)"))
    }

    @Test func aTitleOnlyTaskTellsTheAgentToFillInTheObjectiveAndPlan() {
        let t = TaskFile.create(id: 7, title: "Fix login", now: now)
        let text = taskContext(t)
        #expect(text.contains("still missing an objective and a plan"))
        #expect(text.contains("task objective 7 <text>"))
        #expect(text.contains("task plan 7 add <step>"))
    }

    @Test func theContextTellsAgentsToUseReviewAndNeverDone() {
        let text = taskContext(TaskFile.create(id: 7, title: "T", now: now))
        #expect(text.contains("task status <id> review"))
        #expect(text.contains("Never mark a task done yourself"))
    }

    @Test func theContextAsksForAPushWhenTheUserIsNeeded() {
        let text = taskContext(TaskFile.create(id: 7, title: "T", now: now))
        #expect(text.contains("PushNotification"))
    }

    @Test func settingThePlanKeepsCheckedStepsAndKeepsTheLogIntact() throws {
        var t = TaskFile.create(id: 1, title: "T", now: now)
        t.addPlanItem("reproduce")
        t.addPlanItem("fix")
        try t.setPlanItem(1, done: true, now: now)
        t.appendLog("started", now: now)
        t.setPlan(["reproduce", "write a test", "fix", "  "], now: now)
        #expect(t.section("Plan") == ["- [x] reproduce", "- [ ] write a test", "- [ ] fix"])
        #expect(t.section("Log").count == 1)
        #expect(t.body.contains("## Log"))
        #expect(t.progress == PlanProgress(done: 1, total: 3))
    }

    @Test func settingThePlanCreatesTheSectionWhenMissing() {
        var t = TaskFile.parse("---\nid: 1\n---\n")
        t.setPlan(["a"], now: now)
        #expect(t.section("Plan") == ["- [ ] a"])
    }

    @Test func aFleshedOutTaskGetsNoNudge() {
        var t = TaskFile.create(id: 7, title: "Fix login", objective: "Stop the 500", now: now)
        t.addPlanItem("reproduce")
        #expect(!taskContext(t).contains("still missing"))
    }

    @Test func settingTheObjectiveReplacesItAndStampsUpdated() {
        var t = TaskFile.create(id: 1, title: "T", objective: "old", now: now)
        t.setObjective("new", now: now)
        #expect(t.objective == "new")
    }
}

@Suite("TaskStore")
struct TaskStoreTests {
    private func makeStore() -> TaskStore {
        TaskStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("crook-\(UUID().uuidString)"))
    }

    @Test func subtasksGoOneLevelDeepUnderATaskThatExists() throws {
        let store = makeStore()
        let parent = try store.create(NewTask(title: "Reseller work"), now: now)
        let child = try store.create(NewTask(title: "Count resellers", parent: parent.id), now: now)
        #expect(child.parent == parent.id)
        #expect(store.children(of: parent.id).map(\.id) == [child.id])
        #expect(throws: TaskError.self) { try store.create(NewTask(title: "Grandchild", parent: child.id), now: now) }
        #expect(throws: TaskError.self) { try store.create(NewTask(title: "Orphan", parent: 99), now: now) }
        #expect(store.list().count == 2)
    }

    @Test func createsTasksWithSequentialIdsAndSluggedFilenames() throws {
        let store = makeStore()
        let a = try store.create(NewTask(title: "Board TUI!", projectPath: "/p"), now: now)
        let b = try store.create(NewTask(title: "Second one"), now: now)
        #expect((a.id, b.id) == (1, 2))
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
        #expect(names == ["0001-board-tui.md", "0002-second-one.md"])
    }

    @Test func getsByIdAndListsInOrderSkippingNonTaskFiles() throws {
        let store = makeStore()
        try store.create(NewTask(title: "a"), now: now)
        try store.create(NewTask(title: "b"), now: now)
        try "hi".write(to: store.directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        #expect(store.list().map(\.title) == ["a", "b"])
        #expect(store.get(2)?.title == "b")
        #expect(store.get(9) == nil)
    }

    @Test func updateRereadsTheFileSoConcurrentEditsToOtherFieldsSurvive() throws {
        let store = makeStore()
        let t = try store.create(NewTask(title: "a"), now: now)
        let file = store.directory.appendingPathComponent("0001-a.md")
        try store.update(t.id, now: now) { $0.linkSession("s1") }
        // someone hand-edits the file between our read and write
        let edited = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "title: a", with: "title: a\nnew_field: x")
        try edited.write(to: file, atomically: true, encoding: .utf8)
        try store.update(t.id, now: now) { $0.setStatus(.active) }
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("new_field: x"))
        #expect(text.contains("status: active"))
        #expect(text.contains("sessions: [s1]"))
    }

    @Test func findsTasksByLinkedSessionId() throws {
        let store = makeStore()
        try store.create(NewTask(title: "a"), now: now)
        let b = try store.create(NewTask(title: "b"), now: now)
        try store.update(b.id, now: now) { $0.linkSession("sess-9") }
        #expect(store.findBySession("sess-9")?.id == 2)
        #expect(store.findBySession("nope") == nil)
    }

    @Test func updatingAMissingTaskThrows() {
        #expect(throws: TaskError("no task 3")) { try makeStore().update(3) { _ in } }
    }

    @Test func slugsAreShortLowercaseAndNeverEmpty() {
        #expect(slug("Board TUI!") == "board-tui")
        #expect(slug("!!!") == "task")
        #expect(slug(String(repeating: "word ", count: 20)).count <= 40)
    }
}

@Test func exposesThePlanStepsTheLogAndTheUpdatedStamp() throws {
    var t = TaskFile.create(id: 9, title: "Expose", now: Date(timeIntervalSince1970: 1_800_000_000))
    t.setPlan(["first", "second", "third"])
    try t.setPlanItem(2, done: true)
    t.appendLog("one", now: Date(timeIntervalSince1970: 1_800_000_100))
    t.appendLog("two", now: Date(timeIntervalSince1970: 1_800_000_200))
    #expect(t.plan == [PlanStep(text: "first", done: false), PlanStep(text: "second", done: true), PlanStep(text: "third", done: false)])
    #expect(t.logEntries.count == 2 && t.logEntries[0].hasSuffix("one") && t.logEntries[1].hasSuffix("two"))
    #expect(t.updated != nil && t.created != nil)
    #expect(TaskFile.create(id: 1, title: "Empty").plan.isEmpty)
}
