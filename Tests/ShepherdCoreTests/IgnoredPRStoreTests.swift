import Foundation
import Testing
@testable import ShepherdCore

private func withTempFile(_ body: (URL) throws -> Void) rethrows {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("shepherd-ignored-pr-test-\(UUID().uuidString)")
        .appendingPathComponent("ignored-prs.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try body(url)
}

@Test func ignoredPRStoreLoadDegradesToEmptyWhenNoFileExistsYet() {
    withTempFile { url in
        #expect(IgnoredPRStore(fileURL: url).load().isEmpty)
    }
}

@Test func ignoredPRStoreIgnorePersistsTheID() {
    withTempFile { url in
        let store = IgnoredPRStore(fileURL: url)
        store.ignore("owner/repo#5")
        #expect(store.load() == ["owner/repo#5"])
    }
}

@Test func ignoredPRStoreIgnoreAccumulatesMultipleIDs() {
    withTempFile { url in
        let store = IgnoredPRStore(fileURL: url)
        store.ignore("owner/repo#5")
        store.ignore("owner/repo#6")
        #expect(store.load() == ["owner/repo#5", "owner/repo#6"])
    }
}

@Test func ignoredPRStoreIgnoringTheSameIDTwiceStaysIdempotent() {
    withTempFile { url in
        let store = IgnoredPRStore(fileURL: url)
        store.ignore("owner/repo#5")
        store.ignore("owner/repo#5")
        #expect(store.load() == ["owner/repo#5"])
    }
}
