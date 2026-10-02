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
///
/// `notifyOnFinishedWork` adds one more event for a caller that wants it: a
/// session going from working to idle (a finished run). Herdr reports `done`
/// for a finished run you haven't looked at, but `idle` once it's been seen -
/// fine for the menu bar app (you're at the Mac), not for a phone, where you
/// want to hear about a finish regardless. It's edge-triggered off
/// `previousKinds` (each session's kind on the previous evaluation), so it
/// fires once per run and, unlike blocked/done, isn't re-attempted later.
public func notificationsToFire(
    for sessions: [Session],
    lastNotifiedKind: [SessionID: AttentionState.Kind],
    previousKinds: [SessionID: AttentionState.Kind] = [:],
    notifyOnFinishedWork: Bool = false
) -> (toFire: [PendingNotification], updatedState: [SessionID: AttentionState.Kind]) {
    var toFire: [PendingNotification] = []
    var updatedState: [SessionID: AttentionState.Kind] = [:]

    for session in sessions {
        let kind = session.attention.kind
        if notifyOnFinishedWork, kind == .idle, previousKinds[session.id] == .working {
            toFire.append(PendingNotification(sessionID: session.id, kind: .idle))
            continue
        }
        guard kind == .blocked || kind == .done else { continue }

        updatedState[session.id] = kind
        if lastNotifiedKind[session.id] != kind {
            toFire.append(PendingNotification(sessionID: session.id, kind: kind))
        }
    }

    return (toFire, updatedState)
}
