import CoreGraphics
import Foundation
import ShepherdCore
import ShepherdUI

struct PushSubscription: Codable, Equatable, Sendable {
    let endpoint: String
    let p256dh: String
    let auth: String
}

/// Everything the web push path needs: the VAPID identity, the phones
/// subscribed so far (persisted, so a restart doesn't silently unsubscribe
/// everyone), and the actual send.
actor PushService {
    private let vapid: VAPIDKeys
    private let storeURL: URL
    private let session: URLSession
    private var subscriptions: [PushSubscription]

    init(directory: URL, subject: String, session: URLSession = .shared) throws {
        self.vapid = try VAPIDKeys.loadOrCreate(in: directory, subject: subject)
        self.storeURL = directory.appendingPathComponent("subscriptions.json")
        self.session = session
        let saved = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONDecoder().decode([PushSubscription].self, from: $0) }
        self.subscriptions = saved ?? []
    }

    nonisolated var publicKey: String { vapid.publicKeyBase64URL }

    var subscriptionCount: Int { subscriptions.count }

    func subscribe(_ subscription: PushSubscription) {
        // Same endpoint re-subscribing (the page re-syncs on every load)
        // replaces rather than duplicates, or one phone would get N copies.
        subscriptions.removeAll { $0.endpoint == subscription.endpoint }
        subscriptions.append(subscription)
        persist()
    }

    func unsubscribe(endpoint: String) {
        subscriptions.removeAll { $0.endpoint == endpoint }
        persist()
    }

    /// Fans a payload out to every subscription. A subscription the push
    /// service reports gone (404/410) is dropped; any other failure is
    /// logged and left in place, since it may be transient.
    @discardableResult
    func send(_ payload: Data, urgency: String = "high", ttl: Int = 3600) async -> Int {
        var delivered = 0
        for subscription in subscriptions {
            do {
                switch try await deliver(payload, to: subscription, urgency: urgency, ttl: ttl) {
                case .delivered: delivered += 1
                case .gone: unsubscribe(endpoint: subscription.endpoint)
                case .failed(let status): print("push: \(status) from \(subscription.endpoint.prefix(60))…")
                }
            } catch {
                print("push: send failed: \(error)")
            }
        }
        return delivered
    }

    private enum Outcome { case delivered, gone, failed(Int) }

    private func deliver(_ payload: Data, to subscription: PushSubscription, urgency: String, ttl: Int) async throws -> Outcome {
        guard let endpoint = URL(string: subscription.endpoint),
              let userKey = Base64URL.decode(subscription.p256dh),
              let authSecret = Base64URL.decode(subscription.auth) else {
            return .gone
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try WebPushEncryption.encrypt(plaintext: payload, userPublicKey: userKey, authSecret: authSecret)
        request.setValue(try vapid.authorizationHeader(forEndpoint: endpoint), forHTTPHeaderField: "Authorization")
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(ttl), forHTTPHeaderField: "TTL")
        request.setValue(urgency, forHTTPHeaderField: "Urgency")

        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return .delivered
        case 404, 410: return .gone
        default: return .failed(status)
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(subscriptions) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}

struct PushMessage: Encodable {
    let title: String
    let body: String
    let sessionID: String
    let kind: String

    enum CodingKeys: String, CodingKey {
        case title, body, kind
        case sessionID = "session_id"
    }

    init(title: String, body: String, sessionID: String = "", kind: String = "test") {
        self.title = title
        self.body = body
        self.sessionID = sessionID
        self.kind = kind
    }

    init(for session: Session) {
        let attention = session.attention
        switch attention.kind {
        case .blocked:
            let fallback = attention.blocker == .needsPermission ? "Needs your permission" : "Needs your answer"
            self.init(title: session.title, body: attention.summary ?? fallback, sessionID: session.id.rawValue, kind: "blocked")
        default:
            self.init(title: session.title, body: "Finished", sessionID: session.id.rawValue, kind: attention.kind.rawValue)
        }
    }
}

/// Seconds since the last keyboard or mouse input on this Mac.
func secondsSinceLastUserInput() -> TimeInterval {
    // `~0` is kCGAnyInputEventType: any keyboard, mouse or trackpad event.
    guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
}

/// Decides, session by session, when the phone gets a push, and sends it.
/// The rules come from the shared `notificationsToFire` (the menu bar app's
/// own policy) with `notifyOnFinishedWork` on - see there for why a phone
/// also hears about a finished run.
///
/// With `onlyWhenAway`, a push is held back while you're at the Mac (recent
/// keyboard/mouse input). Held-back blocked/done stay pending - a session
/// still waiting when you walk away is exactly when you want the push - and
/// are retried on a timer, since nothing else would wake us. A finished run
/// is dropped instead: it's a one-off, and you were there when it happened.
actor PushNotifier {
    private var lastNotified: [SessionID: AttentionState.Kind] = [:]
    private var lastKinds: [SessionID: AttentionState.Kind] = [:]
    private let onlyWhenAway: Bool
    private let awayAfter: TimeInterval
    private let idleSeconds: @Sendable () -> TimeInterval
    private let send: @Sendable (PushMessage) async -> Int

    init(
        onlyWhenAway: Bool,
        awayAfter: TimeInterval = 120,
        idleSeconds: @escaping @Sendable () -> TimeInterval = secondsSinceLastUserInput,
        send: @escaping @Sendable (PushMessage) async -> Int
    ) {
        self.onlyWhenAway = onlyWhenAway
        self.awayAfter = awayAfter
        self.idleSeconds = idleSeconds
        self.send = send
    }

    /// The first snapshot only seeds state, so starting (or restarting) the
    /// server never announces sessions that were already waiting.
    func seed(with sessions: [Session]) {
        lastNotified = notificationsToFire(for: sessions, lastNotifiedKind: [:]).updatedState
        lastKinds = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.attention.kind) })
    }

    func evaluate(_ sessions: [Session]) async {
        let away = !onlyWhenAway || idleSeconds() >= awayAfter
        let result = notificationsToFire(
            for: sessions, lastNotifiedKind: lastNotified, previousKinds: lastKinds, notifyOnFinishedWork: true
        )
        for session in sessions where lastKinds[session.id] != session.attention.kind {
            print("state: \(session.title.prefix(40)): \(lastKinds[session.id]?.rawValue ?? "new") -> \(session.attention.kind.rawValue)")
        }
        lastKinds = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.attention.kind) })

        guard away else {
            // Not recording what would have fired keeps blocked/done pending.
            let held = Set(result.toFire.map(\.sessionID))
            lastNotified = result.updatedState.filter { !held.contains($0.key) }
            return
        }
        lastNotified = result.updatedState
        for pending in result.toFire {
            guard let session = sessions.first(where: { $0.id == pending.sessionID }) else { continue }
            let delivered = await send(PushMessage(for: session))
            print("push: \(session.title.prefix(40)) (\(pending.kind.rawValue)) delivered to \(delivered)")
        }
    }

    /// Runs until cancelled: re-evaluates on every backend event, plus on a
    /// timer when pushes can be held back.
    func run(backend: any SessionBackend) async {
        if let initial = try? await backend.snapshot() { seed(with: initial.sessions) }
        let ticker: Task<Void, Never>? = onlyWhenAway ? Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if let snapshot = try? await backend.snapshot() { await self?.evaluate(snapshot.sessions) }
            }
        } : nil
        defer { ticker?.cancel() }
        for await _ in backend.events() {
            guard let snapshot = try? await backend.snapshot() else { continue }
            await evaluate(snapshot.sessions)
        }
    }
}
