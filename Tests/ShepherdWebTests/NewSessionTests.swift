import Foundation
import ShepherdCore
import Testing
@testable import ShepherdWeb

private struct Fixture {
    let root: URL
    let config: ShepherdConfig

    init(exclude: [String] = [], agent: String = "claude") throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("new-session-\(UUID().uuidString)")
        for name in ["beta", "Alpha", "excluded"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("\(name)/.git"), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notarepo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        self.root = root
        self.config = ShepherdConfig(
            projects: ProjectsConfig(directories: [root.path], exclude: exclude.map { root.appendingPathComponent($0).path }),
            sessions: SessionsConfig(defaultDirectory: root.appendingPathComponent("home").path),
            agent: AgentConfig(kind: agent)
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func targetsListTheDefaultDirectoryFirstThenGitProjectsByName() throws {
    let f = try Fixture(exclude: ["excluded"])
    defer { f.cleanup() }
    let targets = startTargets(config: f.config)
    #expect(targets.map(\.name) == ["home", "Alpha", "beta"])
    #expect(targets.first?.isDefault == true)
    #expect(targets.dropFirst().allSatisfy { !$0.isDefault })
}

@Test func nonGitFoldersAndExcludedProjectsAreNotOffered() throws {
    let f = try Fixture(exclude: ["excluded"])
    defer { f.cleanup() }
    let names = startTargets(config: f.config).map(\.name)
    #expect(!names.contains("notarepo"))
    #expect(!names.contains("excluded"))
}

@Test func aProjectPathBuildsARequestWithTheConfiguredAgent() throws {
    let f = try Fixture(agent: "opencode")
    defer { f.cleanup() }
    let request = makeCreateRequest(path: f.root.appendingPathComponent("beta").path, prompt: nil, config: f.config)
    #expect(request?.workingDirectory.lastPathComponent == "beta")
    #expect(request?.agent == AgentKind(rawValue: "opencode"))
    #expect(request?.initialPrompt == nil)
}

@Test func theFirstMessageIsTrimmedAndABlankOneIsDropped() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let path = f.root.appendingPathComponent("beta").path
    #expect(makeCreateRequest(path: path, prompt: "  fix the bug \n", config: f.config)?.initialPrompt == "fix the bug")
    #expect(makeCreateRequest(path: path, prompt: "   \n", config: f.config)?.initialPrompt == nil)
}

@Test func theDefaultDirectoryIsAllowed() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    #expect(makeCreateRequest(path: f.root.appendingPathComponent("home").path, prompt: nil, config: f.config) != nil)
}

@Test func pathsThatWereNotOfferedAreRejected() throws {
    let f = try Fixture(exclude: ["excluded"])
    defer { f.cleanup() }
    #expect(makeCreateRequest(path: "/etc", prompt: nil, config: f.config) == nil)
    #expect(makeCreateRequest(path: f.root.appendingPathComponent("notarepo").path, prompt: nil, config: f.config) == nil)
    #expect(makeCreateRequest(path: f.root.appendingPathComponent("excluded").path, prompt: nil, config: f.config) == nil)
}

@Test func traversalOutOfAnOfferedDirectoryIsRejected() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let sneaky = f.root.appendingPathComponent("beta/../notarepo").path
    #expect(makeCreateRequest(path: sneaky, prompt: nil, config: f.config) == nil)
}
