import Foundation

/// Trimmed down from mac-sesh's `Config.swift` - shepherd only needs
/// configurable project-scan directories for the project picker; the
/// hotkey is a single hardcoded binding (see `Shepherd`'s `HotkeyManager`),
/// so there's no `HotkeyConfig`/`SessionConfig` to carry over.
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

public struct ShepherdConfig: Codable, Equatable, Sendable {
    public var projects: ProjectsConfig

    public init(projects: ProjectsConfig) {
        self.projects = projects
    }

    public static let `default` = ShepherdConfig(
        projects: ProjectsConfig(directories: ["~/dev"], exclude: [])
    )
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
