import Testing
import Foundation
@testable import ShepherdCore

// ── Project name extraction ───────────────────────────────────────────────────

@Test func projectNameExtractsLastPathComponent() {
    #expect(projectName(fromPath: "/Users/adam/dev/my-app") == "my-app")
}

@Test func projectNameHandlesTrailingSlash() {
    #expect(projectName(fromPath: "/Users/adam/dev/my-app/") == "my-app")
}

// ── Frecency scoring ──────────────────────────────────────────────────────────

@Test func scoreIsZeroWithNoVisits() {
    #expect(frecencyScore(visits: []) == 0.0)
}

@Test func moreRecentVisitsScoreHigher() {
    let now = Date()
    let recentVisits = [now, now.addingTimeInterval(-3600)]           // last hour
    let oldVisits    = [now.addingTimeInterval(-86400 * 30)]          // last month

    #expect(frecencyScore(visits: recentVisits) > frecencyScore(visits: oldVisits))
}

@Test func moreVisitsScoreHigherThanFewer() {
    let now = Date()
    let many = Array(repeating: now.addingTimeInterval(-3600), count: 5)
    let few  = Array(repeating: now.addingTimeInterval(-3600), count: 1)
    #expect(frecencyScore(visits: many) > frecencyScore(visits: few))
}

// ── Git project discovery ─────────────────────────────────────────────────────

@Test func findGitProjectsDiscoversGitRepos() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("shepherd-test-\(UUID().uuidString)")

    let repoA   = tmp.appendingPathComponent("project-a")
    let repoB   = tmp.appendingPathComponent("project-b")
    let nonRepo = tmp.appendingPathComponent("not-a-repo")

    for dir in [repoA, repoB, nonRepo] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: repoA.appendingPathComponent(".git"),
                                             withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: repoB.appendingPathComponent(".git"),
                                             withIntermediateDirectories: false)

    defer { try? FileManager.default.removeItem(at: tmp) }

    let projects = findGitProjects(in: [tmp.path])
    let names = projects.map(\.name).sorted()
    #expect(names == ["project-a", "project-b"])
}

@Test func findGitProjectsIgnoresMissingDirectories() {
    let projects = findGitProjects(in: ["/nonexistent/path"])
    #expect(projects.isEmpty)
}

// ── Frecency application ──────────────────────────────────────────────────────

@Test func scoredSortsByFrecencyDescending() {
    let now = Date()
    let projects = [
        Project(name: "cold", path: "/a"),
        Project(name: "hot", path: "/b"),
    ]
    let visits: [String: [Date]] = [
        "/b": [now, now.addingTimeInterval(-60)],
    ]

    let result = scored(projects, visits: visits)

    #expect(result.map(\.name) == ["hot", "cold"])
}
