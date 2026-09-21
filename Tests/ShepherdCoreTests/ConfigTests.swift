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

@Test func defaultConfigUsesHyperWForTheQuickSwitcher() {
    #expect(ShepherdConfig.default.hotkey.switchSession == "hyper+w")
}

@Test func configWithoutAHotkeyKeyDecodesToTheDefaultBinding() throws {
    let json = """
    {"projects":{"directories":["~/dev"],"exclude":[]}}
    """
    let decoded = try JSONDecoder().decode(ShepherdConfig.self, from: Data(json.utf8))
    #expect(decoded.hotkey.switchSession == "hyper+w")
}

@Test func parseHotkeyReadsModifiersAndKeyCodeRegardlessOfOrder() {
    let parsed = parseHotkey("cmd+shift+k")
    #expect(parsed?.keyCode == 40)
    #expect(parsed?.modifiers == 256 | 512)
}

@Test func parseHotkeyExpandsHyperToAllFourModifiers() {
    let parsed = parseHotkey("hyper+w")
    #expect(parsed?.keyCode == 13)
    #expect(parsed?.modifiers == 256 | 512 | 2048 | 4096)
}

@Test func parseHotkeyIsCaseInsensitive() {
    #expect(parseHotkey("Hyper+W")?.keyCode == parseHotkey("hyper+w")?.keyCode)
}

@Test func parseHotkeyRejectsAnUnrecognisedToken() {
    #expect(parseHotkey("cmd+doesnotexist") == nil)
}

@Test func parseHotkeyRejectsAStringWithNoKey() {
    #expect(parseHotkey("cmd+shift") == nil)
}

@Test func defaultConfigHasNotificationsEnabled() {
    #expect(ShepherdConfig.default.notifications.enabled == true)
}

@Test func configWithoutANotificationsKeyDecodesToEnabled() throws {
    let json = """
    {"projects":{"directories":["~/dev"],"exclude":[]}}
    """
    let decoded = try JSONDecoder().decode(ShepherdConfig.self, from: Data(json.utf8))
    #expect(decoded.notifications.enabled == true)
}

@Test func notificationsDisabledPersistsThroughARoundTrip() throws {
    var cfg = ShepherdConfig.default
    cfg.notifications.enabled = false
    let data = try JSONEncoder().encode(cfg)
    let decoded = try JSONDecoder().decode(ShepherdConfig.self, from: data)
    #expect(decoded.notifications.enabled == false)
}

@Test func defaultConfigActivatesGhosttyForBackwardCompatibility() {
    #expect(ShepherdConfig.default.terminal.appName == "Ghostty")
}

@Test func configWithoutATerminalKeyDecodesToGhostty() throws {
    let json = """
    {"projects":{"directories":["~/dev"],"exclude":[]}}
    """
    let decoded = try JSONDecoder().decode(ShepherdConfig.self, from: Data(json.utf8))
    #expect(decoded.terminal.appName == "Ghostty")
}

@Test func aConfiguredTerminalAppNamePersistsThroughARoundTrip() throws {
    var cfg = ShepherdConfig.default
    cfg.terminal.appName = "iTerm2"
    let data = try JSONEncoder().encode(cfg)
    let decoded = try JSONDecoder().decode(ShepherdConfig.self, from: data)
    #expect(decoded.terminal.appName == "iTerm2")
}
