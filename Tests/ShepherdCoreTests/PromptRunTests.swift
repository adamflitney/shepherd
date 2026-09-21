import Foundation
import Testing
@testable import ShepherdCore

// Fixtures captured verbatim from real `claude -p --output-format json`
// invocations (claude-code CLI, 2026-09-18) - trimmed to just the fields
// the decoder reads plus enough surrounding shape to be realistic.

private let successJSON = """
{"session_id":"65ad8dd9-145d-4cce-a27d-3443ded1a18c","permission_denials":[],\
"is_error":false,"result":"2 + 2 = 4.","type":"result"}
""".data(using: .utf8)!

private let deniedToolJSON = """
{"session_id":"d4ec3cf6-b5b1-4177-ae43-584b62a336aa","is_error":false,\
"permission_denials":[{"tool_name":"Bash","tool_use_id":"toolu_01","tool_input":{"command":"echo hi"}}],\
"result":"That was blocked \\u2014 this session can only write within your home directory.","type":"result"}
""".data(using: .utf8)!

private let markerJSON = """
{"session_id":"11111111-1111-1111-1111-111111111111","is_error":false,\
"permission_denials":[],\
"result":"This needs a real edit across several files.\\nNEEDS_SESSION","type":"result"}
""".data(using: .utf8)!

private let errorJSON = """
{"session_id":"ab59fac9-3575-4670-ab0c-920df5530a01","is_error":true,\
"permission_denials":[],"errors":["Reached maximum budget ($0.0001)"],"type":"result"}
""".data(using: .utf8)!

@Test func decodesASuccessfulResult() throws {
    let result = try decodePromptRunResult(from: successJSON)
    #expect(result.rawText == "2 + 2 = 4.")
    #expect(result.sessionID == "65ad8dd9-145d-4cce-a27d-3443ded1a18c")
    #expect(result.isError == false)
    #expect(result.hadPermissionDenials == false)
}

@Test func decodesPermissionDenialsAsNonEmpty() throws {
    let result = try decodePromptRunResult(from: deniedToolJSON)
    #expect(result.hadPermissionDenials == true)
}

@Test func decodesErrorResultFallingBackToErrorsArray() throws {
    let result = try decodePromptRunResult(from: errorJSON)
    #expect(result.isError == true)
    #expect(result.rawText == "Reached maximum budget ($0.0001)")
}

@Test func malformedJSONThrows() {
    #expect(throws: PromptRunDecodeError.self) {
        try decodePromptRunResult(from: Data("not json".utf8))
    }
}

@Test func shouldEscalateWhenPermissionsWereDenied() throws {
    let result = try decodePromptRunResult(from: deniedToolJSON)
    #expect(shouldEscalateToSession(result))
}

@Test func shouldEscalateWhenReplyEndsWithMarker() throws {
    let result = try decodePromptRunResult(from: markerJSON)
    #expect(shouldEscalateToSession(result))
}

@Test func shouldNotEscalateOnAPlainSuccessfulAnswer() throws {
    let result = try decodePromptRunResult(from: successJSON)
    #expect(!shouldEscalateToSession(result))
}

@Test func displayTextStripsTheMarkerLine() throws {
    let result = try decodePromptRunResult(from: markerJSON)
    #expect(displayText(for: result) == "This needs a real edit across several files.")
}

@Test func displayTextIsUnchangedWhenThereIsNoMarker() throws {
    let result = try decodePromptRunResult(from: successJSON)
    #expect(displayText(for: result) == "2 + 2 = 4.")
}
