import Foundation

/// Trimmed down from mac-sesh's `Config.swift` - shepherd only needs
/// configurable project-scan directories for the project picker, plus the
/// quick-switcher hotkey binding ported from mac-sesh's `HotkeyConfig`.
public struct ProjectsConfig: Codable, Equatable, Sendable {
    /// Root directories to scan for git projects.
    public var directories: [String]
    /// Paths to exclude. Prefix-matched after tilde expansion.
    public var exclude: [String]

    public init(directories: [String], exclude: [String]) {
        self.directories = directories
        self.exclude = exclude
    }
}

/// A human-readable hotkey binding like `"hyper+w"` or `"cmd+shift+k"`,
/// parsed by `parseHotkey(_:)`.
public struct HotkeyConfig: Codable, Equatable, Sendable {
    public var switchSession: String

    public init(switchSession: String) {
        self.switchSession = switchSession
    }
}

/// Whether shepherd posts desktop notifications on blocked/done transitions.
/// Gates `NotificationManager` locally - the OS-level authorization request
/// is untouched by this, so re-enabling never needs a fresh permission prompt.
public struct NotificationsConfig: Codable, Equatable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

/// The AppleScript-activatable terminal app to raise after
/// `workspace.focus` retargets Herdr's own internal focus. Defaults to
/// Ghostty for backward compatibility - shepherd only ever supported
/// Ghostty until this became configurable.
public struct TerminalConfig: Codable, Equatable, Sendable {
    public var appName: String

    public init(appName: String) {
        self.appName = appName
    }
}

public struct ShepherdConfig: Codable, Equatable, Sendable {
    public var projects: ProjectsConfig
    public var hotkey: HotkeyConfig
    public var notifications: NotificationsConfig
    public var terminal: TerminalConfig

    public init(
        projects: ProjectsConfig,
        hotkey: HotkeyConfig = HotkeyConfig(switchSession: "hyper+w"),
        notifications: NotificationsConfig = NotificationsConfig(enabled: true),
        terminal: TerminalConfig = TerminalConfig(appName: "Ghostty")
    ) {
        self.projects = projects
        self.hotkey = hotkey
        self.notifications = notifications
        self.terminal = terminal
    }

    // Custom decode so existing config files written before `hotkey`/
    // `notifications`/`terminal` existed (no such keys on disk) default to
    // Hyper+W, enabled notifications, and Ghostty instead of failing to load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode(ProjectsConfig.self, forKey: .projects)
        hotkey = try container.decodeIfPresent(HotkeyConfig.self, forKey: .hotkey)
            ?? HotkeyConfig(switchSession: "hyper+w")
        notifications = try container.decodeIfPresent(NotificationsConfig.self, forKey: .notifications)
            ?? NotificationsConfig(enabled: true)
        terminal = try container.decodeIfPresent(TerminalConfig.self, forKey: .terminal)
            ?? TerminalConfig(appName: "Ghostty")
    }

    public static let `default` = ShepherdConfig(
        projects: ProjectsConfig(directories: ["~/dev"], exclude: []),
        hotkey: HotkeyConfig(switchSession: "hyper+w"),
        notifications: NotificationsConfig(enabled: true),
        terminal: TerminalConfig(appName: "Ghostty")
    )
}

// MARK: - Hotkey parsing

// Carbon modifier values as raw integers - no Carbon import needed here,
// keeping ShepherdCore free of AppKit/Carbon dependencies.
private let modifierMap: [String: Int] = [
    "cmd": 256, "command": 256,
    "shift": 512,
    "opt": 2048, "option": 2048, "alt": 2048,
    "ctrl": 4096, "control": 4096,
    // Hyper = Cmd+Ctrl+Option+Shift (Caps Lock remap).
    "hyper": 256 | 512 | 2048 | 4096,
]

// Carbon virtual key codes for printable keys and a small set of specials.
private let keyCodeMap: [String: Int] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
    "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "9": 25, "7": 26, "8": 28, "0": 29,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
    "j": 38, "k": 40, "n": 45, "m": 46,
    "space": 49, "tab": 48, "return": 36, "escape": 53, "delete": 51,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118,
    "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

/// Parses a hotkey string like `"hyper+w"` or `"cmd+shift+k"` into a
/// `(keyCode, modifiers)` pair suitable for Carbon `RegisterEventHotKey`.
/// Returns nil if the string is malformed or uses an unrecognised key name.
public func parseHotkey(_ string: String) -> (keyCode: Int, modifiers: Int)? {
    let parts = string.lowercased().split(separator: "+").map(String.init)
    var modifiers = 0
    var keyName: String?

    for part in parts {
        if let mod = modifierMap[part] {
            modifiers |= mod
        } else if keyCodeMap[part] != nil {
            keyName = part
        } else {
            return nil // unrecognised token
        }
    }

    guard let keyName, let keyCode = keyCodeMap[keyName] else { return nil }
    return (keyCode: keyCode, modifiers: modifiers)
}

// MARK: - Load / save

public extension ShepherdConfig {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/shepherd/config.json")
    }

    /// Loads the config from disk. Falls back to `.default` on any error and
    /// writes the default file so the user has a template to edit.
    static func load() -> ShepherdConfig {
        guard let data = try? Data(contentsOf: configURL) else {
            (try? ShepherdConfig.default.save())
            return .default
        }
        return (try? JSONDecoder().decode(ShepherdConfig.self, from: data)) ?? .default
    }

    func save() throws {
        let url = ShepherdConfig.configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Project directory helpers

public extension ShepherdConfig {
    /// Resolves tilde in paths and returns the expanded include directories.
    var resolvedDirectories: [String] {
        projects.directories.map(expandTilde)
    }

    /// Returns true if the given project path should be excluded.
    func isExcluded(_ path: String) -> Bool {
        projects.exclude
            .map(expandTilde)
            .contains { path.hasPrefix($0) }
    }
}

private func expandTilde(_ path: String) -> String {
    guard path.hasPrefix("~") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return home + path.dropFirst()
}
