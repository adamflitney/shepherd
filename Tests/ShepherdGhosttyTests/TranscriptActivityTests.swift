import Foundation
import Testing
@testable import ShepherdGhostty

@Suite struct TranscriptActivityTests {
    private func assistant(_ blocks: String) -> String { #"{"type":"assistant","message":{"content":[\#(blocks)]}}"# }
    private let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#

    @Test func describesTheLastToolCall() {
        let tail = [assistant(#"{"type":"tool_use","name":"Edit","input":{"file_path":"/a/b/Foo.swift"}}"#)].joined(separator: "\n")
        #expect(TranscriptPeek.currentActivity(inTail: tail) == "Editing Foo.swift")
    }

    @Test func skipsToolResultsToTheAssistantTurn() {
        let tail = [assistant(#"{"type":"tool_use","name":"Bash","input":{"description":"Run the tests"}}"#), toolResult].joined(separator: "\n")
        #expect(TranscriptPeek.currentActivity(inTail: tail) == "Run the tests")
    }

    @Test func fallsBackToTheLastSentenceOfText() {
        let tail = assistant(#"{"type":"text","text":"Found it. Now fixing the retry limit."}"#)
        #expect(TranscriptPeek.currentActivity(inTail: tail) == "Now fixing the retry limit")
    }

    @Test func aFreshPromptMeansNothingYet() {
        let tail = [assistant(#"{"type":"text","text":"Done."}"#), #"{"type":"user","message":{"content":"next please"}}"#].joined(separator: "\n")
        #expect(TranscriptPeek.currentActivity(inTail: tail) == nil)
    }
}
