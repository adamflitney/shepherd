import Foundation
import ShepherdCore

struct StartTarget: Encodable, Equatable {
    let name: String
    let path: String
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case name, path
        case isDefault = "is_default"
    }
}

/// Symlink-resolved and normalised, so `/var/x` and `/private/var/x` (which
/// directory enumeration returns) compare equal. Both the allow-list and the
/// exclusion check go through this - a plain string-prefix match would let an
/// excluded project through whenever a symlink is involved.
private func canonical(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
}

/// Where a phone is allowed to start a session: the configured default
/// directory first, then the git projects the menu bar app's picker lists
/// (same config, same exclusions). This list is also the allow-list - the
/// server never starts an agent in a path it didn't itself offer.
func startTargets(config: ShepherdConfig) -> [StartTarget] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let defaultPath = canonical(config.resolvedDefaultSessionDirectory)
    let defaultTarget = StartTarget(
        name: defaultPath == canonical(home) ? "Home" : URL(fileURLWithPath: defaultPath).lastPathComponent,
        path: defaultPath,
        isDefault: true
    )
    let excluded = config.projects.exclude.map(canonical)
    let projects = findGitProjects(in: config.resolvedDirectories)
        .filter { project in
            let path = canonical(project.path)
            return !config.isExcluded(project.path) && !excluded.contains { path.hasPrefix($0) }
        }
        .map { StartTarget(name: $0.name, path: canonical($0.path), isDefault: false) }
        .filter { $0.path != defaultPath }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return [defaultTarget] + projects
}

/// The request for starting a session at `path`, or nil if `path` isn't one
/// of the offered start targets.
func makeCreateRequest(path: String, prompt: String?, config: ShepherdConfig) -> CreateSessionRequest? {
    let wanted = canonical(path)
    guard startTargets(config: config).contains(where: { $0.path == wanted }) else { return nil }
    let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    return CreateSessionRequest(
        workingDirectory: URL(fileURLWithPath: wanted),
        agent: config.resolvedAgentKind,
        initialPrompt: (trimmed?.isEmpty ?? true) ? nil : trimmed
    )
}
