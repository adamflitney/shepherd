import Testing
import ShepherdCore
@testable import ShepherdUI

private func task(_ id: Int, _ title: String, _ status: String = "active", project: String? = nil) -> TaskSummary {
    TaskSummary(id: id, title: title, projectPath: project, status: status)
}

private let all = [
    task(1, "Fix the build", "inbox", project: "/dev/api"),
    task(2, "Board view", "active", project: "/dev/shepherd"),
    task(3, "Write docs", "review"),
    task(4, "Old thing", "done"),
    task(5, "Plan the quarter", "ready"),
    task(6, "Another active one", "active"),
]

@Test func openTasksAreOrderedActiveFirstThenReviewReadyInboxAndDoneIsHidden() {
    #expect(filterTasks(all, query: "").map(\.id) == [2, 6, 3, 5, 1])
}

@Test func tasksOfTheSameStatusKeepTheirIncomingOrder() {
    #expect(filterTasks(all, query: "").prefix(2).map(\.id) == [2, 6])
}

@Test func doneTasksCanBeIncluded() {
    #expect(filterTasks(all, query: "", includeDone: true).map(\.id).last == 4)
}

@Test func aNumberOrHashNumberFindsTheTaskById() {
    #expect(filterTasks(all, query: "3").first?.id == 3)
    #expect(filterTasks(all, query: "#5").first?.id == 5)
}

@Test func fuzzyMatchesTheTitleAndTheProjectName() {
    #expect(filterTasks(all, query: "bld").first?.id == 1)      // "Fix the build"
    #expect(filterTasks(all, query: "shepherd").first?.id == 2)  // by project folder
    #expect(filterTasks(all, query: "zzzz").isEmpty)
}

@Test func theGroupIdMatchesWhatABackendPutsOnALiveSession() {
    #expect(task(12, "x").groupID == "task-12")
}
