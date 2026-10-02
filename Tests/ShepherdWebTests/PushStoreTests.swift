import Foundation
import Testing
@testable import ShepherdWebKit

private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("push-store-\(UUID().uuidString)")
}

private func service(in directory: URL, now: Date = Date()) throws -> PushService {
    try PushService(directory: directory, subject: "https://example.test", now: now)
}

private func subscription(_ endpoint: String, label: String = "iPhone", lastSeen: Date) -> PushSubscription {
    PushSubscription(endpoint: endpoint, p256dh: "k", auth: "a", label: label, lastSeen: lastSeen)
}

private let day: TimeInterval = 24 * 3600

@Test func aSubscriptionIsListedWithItsLabelAndLastSeenTime() async throws {
    let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let push = try service(in: dir)
    let seen = Date(timeIntervalSince1970: 1_000_000)
    await push.subscribe(subscription("https://push.test/a", label: "iPhone", lastSeen: seen))
    let phones = await push.phones()
    #expect(phones.count == 1)
    #expect(phones.first?.label == "iPhone")
    #expect(phones.first?.lastSeen == seen)
}

@Test func reRegisteringRefreshesLastSeenInsteadOfAddingAPhone() async throws {
    let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let push = try service(in: dir)
    await push.subscribe(subscription("https://push.test/a", lastSeen: Date(timeIntervalSince1970: 1_000)))
    await push.subscribe(subscription("https://push.test/a", lastSeen: Date(timeIntervalSince1970: 9_000)))
    let phones = await push.phones()
    #expect(phones.count == 1)
    #expect(phones.first?.lastSeen == Date(timeIntervalSince1970: 9_000))
}

@Test func phonesAreListedMostRecentlySeenFirst() async throws {
    let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let push = try service(in: dir)
    await push.subscribe(subscription("https://push.test/old", label: "Old", lastSeen: Date(timeIntervalSince1970: 1_000)))
    await push.subscribe(subscription("https://push.test/new", label: "New", lastSeen: Date(timeIntervalSince1970: 9_000)))
    #expect(await push.phones().map(\.label) == ["New", "Old"])
}

@Test func aPhoneCanBeRemovedByItsId() async throws {
    let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let push = try service(in: dir)
    await push.subscribe(subscription("https://push.test/a", label: "Keep", lastSeen: Date()))
    await push.subscribe(subscription("https://push.test/b", label: "Stale", lastSeen: Date()))
    let stale = try #require(await push.phones().first { $0.label == "Stale" })
    await push.removePhone(id: stale.id)
    #expect(await push.phones().map(\.label) == ["Keep"])
}

@Test func phoneIdsAreStableAndDontExposeTheEndpoint() async throws {
    let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let push = try service(in: dir)
    await push.subscribe(subscription("https://push.test/secret-token-123", lastSeen: Date()))
    let first = try #require(await push.phones().first)
    #expect(!first.id.contains("secret"))
    #expect(first.id.count == 16)
    await push.subscribe(subscription("https://push.test/secret-token-123", lastSeen: Date()))
    #expect(await push.phones().first?.id == first.id)
}

@Test func onlyPhonesUnseenForLongerThanTheCutoffArePruned() async throws {
    let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    let push = try service(in: dir)
    await push.subscribe(subscription("https://push.test/recent", label: "Recent", lastSeen: now.addingTimeInterval(-89 * day)))
    await push.subscribe(subscription("https://push.test/stale", label: "Stale", lastSeen: now.addingTimeInterval(-91 * day)))
    let removed = await push.pruneStale(now: now)
    #expect(removed == 1)
    #expect(await push.phones().map(\.label) == ["Recent"])
}

@Test func pruningSurvivesARestart() async throws {
    let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    let first = try service(in: dir, now: now)
    await first.subscribe(subscription("https://push.test/stale", label: "Stale", lastSeen: now.addingTimeInterval(-200 * day)))
    await first.subscribe(subscription("https://push.test/fresh", label: "Fresh", lastSeen: now))
    // a fresh launch prunes on load
    let second = try service(in: dir, now: now)
    #expect(await second.phones().map(\.label) == ["Fresh"])
}

@Test func aFileSavedBeforeTimestampsExistedKeepsEveryPhoneAndIsUpgraded() async throws {
    let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let old = #"[{"endpoint":"https://push.test/legacy","p256dh":"k","auth":"a"}]"#
    try old.write(to: dir.appendingPathComponent("subscriptions.json"), atomically: true, encoding: .utf8)

    let now = Date()
    let push = try service(in: dir, now: now)
    let phones = await push.phones()
    #expect(phones.count == 1)                                  // not dropped by the upgrade
    #expect(phones.first?.label == "Phone")
    #expect(abs(phones.first!.lastSeen.timeIntervalSince(now)) < 5)

    // ...and the file now carries the new fields, so the clock starts from this first launch
    let rewritten = try String(contentsOf: dir.appendingPathComponent("subscriptions.json"), encoding: .utf8)
    #expect(rewritten.contains("lastSeen"))
}

@Test func theLabelNamesTheDeviceFromItsUserAgent() {
    #expect(phoneLabel(userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148") == "iPhone")
    #expect(phoneLabel(userAgent: "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15") == "iPad")
    #expect(phoneLabel(userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/126.0 Mobile Safari/537.36") == "Android phone")
    #expect(phoneLabel(userAgent: "Mozilla/5.0 (Linux; Android 14; SM-X900) AppleWebKit/537.36 Chrome/126.0 Safari/537.36") == "Android tablet")
    #expect(phoneLabel(userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15") == "Mac (Safari)")
    #expect(phoneLabel(userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126.0 Safari/537.36") == "Mac (Chrome)")
    #expect(phoneLabel(userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0 Edg/126.0 Safari/537.36") == "Windows PC (Edge)")
}

@Test func anUnknownOrMissingUserAgentFallsBackToPhone() {
    #expect(phoneLabel(userAgent: nil) == "Phone")
    #expect(phoneLabel(userAgent: "") == "Phone")
    #expect(phoneLabel(userAgent: "curl/8.0") == "Phone")
}
