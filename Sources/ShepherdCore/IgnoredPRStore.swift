import Foundation

/// Persists explicitly-ignored PRs (the "not reviewing this" action) at
/// `~/.config/shepherd/ignored-prs.json`, keyed by `ReviewPR.id`
/// (`"owner/repo#number"`). No "unignore" UI in v1 - hand-editable, same
/// precedent as `ShepherdConfig`'s `projects.exclude`.
public struct IgnoredPRStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL = IgnoredPRStore.defaultURL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/shepherd/ignored-prs.json")
    }

    public func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    public func ignore(_ id: String) {
        var ids = load()
        ids.insert(id)
        save(ids)
    }

    private func save(_ ids: Set<String>) {
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
