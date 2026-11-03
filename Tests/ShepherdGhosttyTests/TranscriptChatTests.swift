import Foundation
import Testing
@testable import ShepherdGhostty

@Suite struct TranscriptChatTests {
    private func file(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func readsTextToolsResultsAndImagesInOrder() throws {
        let url = try file([
            #"{"type":"user","message":{"content":"hello"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"hi"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a/b.swift"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"file body"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}}"#,
            #"{"type":"user","isMeta":true,"message":{"content":"noise"}}"#,
        ])
        let page = TranscriptChat.read(at: url, after: nil)
        #expect(page.items.map(\.kind) == ["text", "text", "tool", "result", "image"])
        #expect(page.items[2].text == "/a/b.swift")
        #expect(page.items[3].toolUseID == "t1")
    }

    @Test func aSecondReadFromTheOffsetReturnsOnlyWhatIsNew() throws {
        let url = try file([#"{"type":"user","message":{"content":"one"}}"#])
        let first = TranscriptChat.read(at: url, after: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data((#"{"type":"assistant","message":{"content":[{"type":"text","text":"two"}]}}"# + "\n").utf8))
        try h.close()
        let second = TranscriptChat.read(at: url, after: first.offset)
        #expect(second.items.map { $0.text } == ["two"])
    }

    @Test func aHalfWrittenLastLineWaitsForTheNextRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).jsonl")
        let whole = #"{"type":"user","message":{"content":"a"}}"#
        try (whole + "\n" + #"{"type":"user","mess"#).write(to: url, atomically: true, encoding: .utf8)
        let page = TranscriptChat.read(at: url, after: nil)
        #expect(page.items.count == 1)
        #expect(page.offset == UInt64(whole.utf8.count + 1))
    }
}
