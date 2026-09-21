import ShepherdCore

/// What the menu bar icon shows: the most urgent kind present, and how many
/// sessions share it. Kept as a pure function over `[Session]` (rather than a
/// method on the store) so the icon-caching layer can key an `NSImage` cache
/// on the result without redrawing per event.
public struct MenuBarStatus: Equatable {
    public let worstKind: AttentionState.Kind
    public let count: Int

    public init(worstKind: AttentionState.Kind, count: Int) {
        self.worstKind = worstKind
        self.count = count
    }
}

public func menuBarStatus(for sessions: [Session]) -> MenuBarStatus {
    guard let worst = sessions.map(\.attention.kind).min(by: { urgencyRank($0) < urgencyRank($1) }) else {
        return MenuBarStatus(worstKind: .unknown, count: 0)
    }
    let count = sessions.filter { $0.attention.kind == worst }.count
    return MenuBarStatus(worstKind: worst, count: count)
}
