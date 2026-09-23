import Foundation
import Testing
@testable import ShepherdCore
@testable import ShepherdHerdr

private func withTempFile(_ body: (URL) throws -> Void) rethrows {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("shepherd-attention-since-test-\(UUID().uuidString)")
        .appendingPathComponent("attention-since.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try body(url)
}

@Test func attentionSinceStoreRoundTripsSavedValues() {
    withTempFile { url in
        let store = AttentionSinceStore(fileURL: url)
        let since = Date(timeIntervalSince1970: 1_000)
        let saved: [SessionID: PersistedSessionAttention] = [
            SessionID(rawValue: "agent:abc"): PersistedSessionAttention(kind: "idle", since: since),
        ]

        store.save(saved)

        #expect(store.load() == saved)
    }
}

@Test func attentionSinceStoreLoadDegradesToEmptyWhenNoFileExistsYet() {
    withTempFile { url in
        let store = AttentionSinceStore(fileURL: url)
        #expect(store.load().isEmpty)
    }
}

@Test func attentionSinceStoreSavePrunesEntriesNotIncludedInTheNewMap() {
    withTempFile { url in
        let store = AttentionSinceStore(fileURL: url)
        let since = Date(timeIntervalSince1970: 1_000)
        store.save([SessionID(rawValue: "agent:gone"): PersistedSessionAttention(kind: "idle", since: since)])

        store.save([SessionID(rawValue: "agent:still-here"): PersistedSessionAttention(kind: "working", since: since)])

        #expect(store.load().keys.map(\.rawValue) == ["agent:still-here"])
    }
}
