import Foundation
import Testing
@testable import ShepherdTasks

private let sessions = [
    AgentSession(id: "aaaa1111-0000", title: "#34 Resellers", state: "idle", taskID: 34),
    AgentSession(id: "bbbb2222-0000", title: "#35 Other", state: "blocked", taskID: 35),
    AgentSession(id: "bbbb3333-0000", title: "#35 Second", state: "working", taskID: 35),
    AgentSession(id: "cccc4444-0000", title: "Loose", state: "idle", canPrompt: false),
]

@Suite("AgentCLI")
struct AgentCLITests {
    @Test func resolvesByTaskOrUniqueIdPrefix() throws {
        #expect(try AgentCLI.resolve("#34", in: sessions).get().id == "aaaa1111-0000")
        #expect(try AgentCLI.resolve("aaaa", in: sessions).get().taskID == 34)
        #expect(throws: TaskError.self) { try AgentCLI.resolve("#35", in: sessions).get() }
        #expect(throws: TaskError.self) { try AgentCLI.resolve("bbbb", in: sessions).get() }
        #expect(throws: TaskError.self) { try AgentCLI.resolve("#99", in: sessions).get() }
        #expect(throws: TaskError.self) { try AgentCLI.resolve("aa", in: sessions).get() }
        #expect(try AgentCLI.resolve("bbbb2", in: sessions).get().state == "blocked")
    }

    @Test func refusesToMessageItselfABlockedSessionOrOneThatCannotTakeInput() {
        #expect(AgentCLI.promptRefusal(target: sessions[0], callerSessionID: "aaaa1111-0000") == "that is this session")
        #expect(AgentCLI.promptRefusal(target: sessions[1], callerSessionID: "x")?.contains("ask the user") == true)
        #expect(AgentCLI.promptRefusal(target: sessions[3], callerSessionID: nil)?.contains("cannot take a message") == true)
        #expect(AgentCLI.promptRefusal(target: sessions[0], callerSessionID: "other") == nil)
    }

    @Test func aMessageIsMarkedAsFromAnotherSessionWithHowToReply() {
        let framed = AgentCLI.framedPrompt("Which resellers?", fromSession: "12345678-aaaa", fromTask: 9, crook: "crook")
        #expect(framed.hasPrefix("[Message from another Shepherd session (session 12345678, task #9), not from the user."))
        #expect(framed.contains("session prompt #9") && framed.hasSuffix("\n\nWhich resellers?"))
        #expect(AgentCLI.framedPrompt("hi", fromSession: nil, fromTask: nil) == "hi")
    }

    @Test func settledMeansReadyOrBlockedAndTheListingDoesNotRepeatTheTaskNumber() {
        #expect(sessions[0].isSettled && sessions[1].isSettled && !sessions[2].isSettled)
        #expect(AgentCLI.describe(sessions[0]).contains("#34 Resellers") && !AgentCLI.describe(sessions[0]).contains("#34 #34"))
    }

    @Test func theServerPortComesFromTheEnvironmentThenTheConfigThenTheDefault() {
        #expect(AgentCLI.port(env: ["SHEPHERD_WEB_PORT": "18911"], configJSON: nil) == 18911)
        #expect(AgentCLI.port(env: [:], configJSON: Data(#"{"web":{"port":9000}}"#.utf8)) == 9000)
        #expect(AgentCLI.port(env: [:], configJSON: nil) == 8787)
    }

    @Test func theSkillNamesTheCommandsAndTheContextPointsAtIt() {
        let skill = AgentCLI.skill(crook: "/x/crook")
        #expect(skill.hasPrefix("---\nname: shepherd") && skill.contains("/x/crook session prompt") && skill.contains("SHEPHERD_SESSION_ID"))
        let context = taskContext(TaskFile.create(id: 7, title: "T"), crook: "/x/crook")
        #expect(context.contains("`/x/crook --skill`"))
    }
}
