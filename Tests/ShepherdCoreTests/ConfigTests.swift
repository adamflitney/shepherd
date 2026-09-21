import Testing
import Foundation
@testable import ShepherdCore

@Test func defaultConfigScansDevDirectory() {
    #expect(ShepherdConfig.default.projects.directories == ["~/dev"])
}

@Test func configRoundTrip() throws {
    let original = ShepherdConfig.default
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ShepherdConfig.self, from: data)
    #expect(decoded == original)
}

@Test func isExcludedMatchesPrefix() {
    var cfg = ShepherdConfig.default
    cfg.projects.exclude = ["/Users/adam/dev/archived"]
    #expect(cfg.isExcluded("/Users/adam/dev/archived/old-project"))
    #expect(!cfg.isExcluded("/Users/adam/dev/active-project"))
}

@Test func isExcludedExpandsTilde() {
    var cfg = ShepherdConfig.default
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    cfg.projects.exclude = ["~/dev/archived"]
    #expect(cfg.isExcluded("\(home)/dev/archived/old-project"))
    #expect(!cfg.isExcluded("\(home)/dev/active"))
}

@Test func resolvedDirectoriesExpandsTilde() {
    let cfg = ShepherdConfig.default
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    #expect(cfg.resolvedDirectories == ["\(home)/dev"])
}
