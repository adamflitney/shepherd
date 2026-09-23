import Foundation
import ShepherdCore

/// What `SessionProjection` needs to decide whether a persisted timestamp
/// still applies: the kind it was recorded against, since a session may
/// have transitioned between app runs and a stale timestamp for the wrong
/// kind would be worse than no timestamp at all.
public struct PersistedSessionAttention: Codable, Equatable, Sendable {
    public let kind: String
    public let since: Date

    public init(kind: String, since: Date) {
        self.kind = kind
        self.since = since
    }
}

/// Persists `AttentionState.since` per session across app restarts, keyed
/// by `SessionID.rawValue`, at `~/.config/shepherd/attention-since.json`.
///
/// Herdr's own wire schema carries no timestamp field at all (`PaneWire`
/// has no `updated_at`/`state_change_seq` - confirmed against the live
/// schema) - `since` is purely this app's own bookkeeping, and
/// `SessionProjection` is a fresh, empty value type on every app launch.
/// Without this, every session that isn't actively transitioning right at
/// that moment (i.e. most idle ones) gets `since` reset to the exact same
/// restart timestamp, degenerating "most-recently-active first" into an
/// alphabetical tie-break - exactly what happened after several restarts
/// in one day. Pure I/O at the edge, same tier as `HookStateStore`.
public struct AttentionSinceStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL = AttentionSinceStore.defaultURL) {
        self.fileURL = fileURL
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/shepherd/attention-since.json")
    }

    public func load() -> [SessionID: PersistedSessionAttention] {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONDecoder().decode([String: PersistedSessionAttention].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.map { (SessionID(rawValue: $0.key), $0.value) })
    }

    /// Overwrites the file with exactly the given map, so sessions that no
    /// longer exist (closed) are pruned for free on the next save.
    public func save(_ attentionByID: [SessionID: PersistedSessionAttention]) {
        let raw = Dictionary(uniqueKeysWithValues: attentionByID.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
