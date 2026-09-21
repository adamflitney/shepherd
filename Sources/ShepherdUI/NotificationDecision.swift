import ShepherdCore

public struct PendingNotification: Equatable {
    public let sessionID: SessionID
    public let kind: AttentionState.Kind
}

/// Decides which sessions should raise a fresh notification: once per
/// *transition into* `.blocked`/`.done`, tracked by `lastNotifiedKind`. A
/// session leaving those kinds (or disappearing entirely) has no entry in
/// `updatedState`, which is what re-arms the next transition - the "seen"
/// semantics fall out of this alone, no backend-side watermark needed.
public func notificationsToFire(
    for sessions: [Session],
    lastNotifiedKind: [SessionID: AttentionState.Kind]
) -> (toFire: [PendingNotification], updatedState: [SessionID: AttentionState.Kind]) {
    var toFire: [PendingNotification] = []
    var updatedState: [SessionID: AttentionState.Kind] = [:]

    for session in sessions {
        let kind = session.attention.kind
        guard kind == .blocked || kind == .done else { continue }

        updatedState[session.id] = kind
        if lastNotifiedKind[session.id] != kind {
            toFire.append(PendingNotification(sessionID: session.id, kind: kind))
        }
    }

    return (toFire, updatedState)
}
