import Foundation
import ShepherdCore
import ShepherdUI
import UserNotifications

/// Thin side-effecting wrapper around `notificationsToFire` - the decision
/// logic is pure and lives in ShepherdUI; this only owns the
/// `UNUserNotificationCenter` calls and the click-to-focus wiring.
///
/// `UNUserNotificationCenter.current()` crashes outright (an uncaught
/// `NSInternalInconsistencyException`, "bundleProxyForCurrentProcess is
/// nil") when the process has no real app bundle - true for a bare
/// `swift run`/`.build/debug/Shepherd` invocation, only false once it's
/// assembled into a `.app` (Phase 0's bundling step). `isSupported` guards
/// every entry point so the ordinary dev workflow keeps working; only an
/// installed `.app` actually gets notifications.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private var lastNotifiedKind: [SessionID: AttentionState.Kind] = [:]
    var onNotificationClicked: ((SessionID) -> Void)?

    private let isSupported = Bundle.main.bundleIdentifier != nil

    override init() {
        super.init()
        guard isSupported else { return }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func update(sessions: [Session]) {
        guard isSupported else { return }
        let (toFire, updatedState) = notificationsToFire(for: sessions, lastNotifiedKind: lastNotifiedKind)
        lastNotifiedKind = updatedState
        for pending in toFire {
            guard let session = sessions.first(where: { $0.id == pending.sessionID }) else { continue }
            post(pending, session: session)
        }
    }

    private func post(_ pending: PendingNotification, session: Session) {
        let content = UNMutableNotificationContent()
        content.title = session.title
        content.body = pending.kind == .blocked ? (session.attention.summary ?? "Needs your attention") : "Done"
        content.sound = .default
        content.userInfo = ["sessionID": pending.sessionID.rawValue]

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Notifications are suppressed by default while the app itself is
    // frontmost; a menu-bar app is "frontmost" essentially never in the
    // normal sense, but this still needs to be explicit or banners silently
    // don't show at all.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let rawID = response.notification.request.content.userInfo["sessionID"] as? String
        if let rawID {
            Task { @MainActor in
                onNotificationClicked?(SessionID(rawValue: rawID))
            }
        }
        completionHandler()
    }
}
