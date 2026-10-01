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

/// Herdr moves a finished Claude Code session straight to idle - the `done`
/// status that `notificationsToFire` keys on doesn't occur for real sessions
/// - so "an agent finished" is a working -> idle transition here.
func sessionsThatFinishedWorking(previousKinds: [SessionID: AttentionState.Kind], sessions: [Session]) -> [Session] {
    sessions.filter { previousKinds[$0.id] == .working && $0.attention.kind == .idle }
}

/// Watches the backend and pushes once per *transition into* blocked/done
/// (via the same `notificationsToFire` policy the menu bar app uses) or out
/// of working into idle. The initial snapshot only seeds state, so starting
/// (or restarting) the server never fires for sessions already waiting.
func runPushNotifier(backend: any SessionBackend, push: PushService) async {
    var lastNotified: [SessionID: AttentionState.Kind] = [:]
    var lastKinds: [SessionID: AttentionState.Kind] = [:]
    if let initial = try? await backend.snapshot() {
        lastNotified = notificationsToFire(for: initial.sessions, lastNotifiedKind: [:]).updatedState
        lastKinds = Dictionary(uniqueKeysWithValues: initial.sessions.map { ($0.id, $0.attention.kind) })
    }
    for await _ in backend.events() {
        guard let snapshot = try? await backend.snapshot() else { continue }
        for session in snapshot.sessions where lastKinds[session.id] != session.attention.kind {
            print("state: \(session.title.prefix(40)): \(lastKinds[session.id]?.rawValue ?? "new") -> \(session.attention.kind.rawValue)")
        }
        let result = notificationsToFire(for: snapshot.sessions, lastNotifiedKind: lastNotified)
        let finished = sessionsThatFinishedWorking(previousKinds: lastKinds, sessions: snapshot.sessions)
        lastNotified = result.updatedState
        lastKinds = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0.attention.kind) })

        let firing = result.toFire.compactMap { pending in snapshot.sessions.first { $0.id == pending.sessionID } }
        let toNotify = firing + finished.filter { f in !firing.contains { $0.id == f.id } }
        for session in toNotify {
            guard let payload = try? JSONEncoder().encode(PushMessage(for: session)) else { continue }
            let delivered = await push.send(payload)
            print("push: \(session.title.prefix(40)) (\(session.attention.kind.rawValue)) delivered to \(delivered)/\(await push.subscriptionCount)")
        }
    }
}
