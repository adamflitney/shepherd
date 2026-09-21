import Testing
@testable import ShepherdCore
@testable import ShepherdUI

@Test func filterProjectsReturnsAllInExistingOrderWhenQueryIsEmpty() {
    // Empty query is the frecency-sorted state already produced by `scored` -
    // filtering must not reorder it.
    let projects = [
        Project(name: "hot", path: "/dev/hot", score: 10),
        Project(name: "cold", path: "/dev/cold", score: 1),
    ]
    #expect(filterProjects(projects, query: "").map(\.name) == ["hot", "cold"])
}

@Test func filterProjectsDropsNonMatches() {
    let projects = [
        Project(name: "yolo-club-api", path: "/dev/yolo-club-api"),
        Project(name: "unrelated", path: "/dev/unrelated"),
    ]
    #expect(filterProjects(projects, query: "club").map(\.name) == ["yolo-club-api"])
}

@Test func filterProjectsCombinesFuzzyScoreWithExistingFrecencyScore() {
    // Both match "app" equally well by name, but "b" has a much higher
    // frecency score already baked in - it should win.
    let lowFrecency = Project(name: "app-a", path: "/dev/app-a", score: 0)
    let highFrecency = Project(name: "app-b", path: "/dev/app-b", score: 100)

    let result = filterProjects([lowFrecency, highFrecency], query: "app")

    #expect(result.map(\.name) == ["app-b", "app-a"])
}
