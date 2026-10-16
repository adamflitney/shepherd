import Testing
@testable import ShepherdHolder

@Suite("Terminal mode tracking")
struct ModeTrackerTests {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func tracksModesSwitchedOnAndOff() {
        var t = ModeTracker()
        t.feed(bytes("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?2004h"))
        #expect(t.activeModes == [1000, 1049, 2004])
        t.feed(bytes("\u{1b}[?1000l"))
        #expect(t.activeModes == [1049, 2004])
    }

    @Test func handlesSeveralModesInOneSequence() {
        var t = ModeTracker()
        t.feed(bytes("\u{1b}[?1000;1006h"))
        #expect(t.activeModes == [1000, 1006])
    }

    @Test func handlesASequenceSplitAcrossReads() {
        var t = ModeTracker()
        t.feed(bytes("text\u{1b}[?10"))
        #expect(t.activeModes.isEmpty)
        t.feed(bytes("49h more"))
        #expect(t.activeModes == [1049])
    }

    @Test func ignoresUntrackedModesAndOtherEscapes() {
        var t = ModeTracker()
        t.feed(bytes("\u{1b}[?9999h\u{1b}[31mred\u{1b}[0m\u{1b}[2J"))
        #expect(t.activeModes.isEmpty)
    }

    @Test func restoreSequenceSwitchesModesBackOn() {
        #expect(ModeTracker.restoreSequence(for: [1049, 2004]) == Array("\u{1b}[?1049h\u{1b}[?2004h".utf8))
    }
}

@Suite("Frames")
struct FrameTests {
    @Test func roundTripsEveryKind() {
        var parser = HolderFrameParser()
        let frames: [HolderFrame] = [.input(Array("ls\r".utf8)), .resize(cols: 120, rows: 40), .detach]
        let out = parser.push(frames.flatMap { $0.encoded() })
        #expect(out == frames)
    }

    @Test func waitsForTheRestOfAFrame() {
        var parser = HolderFrameParser()
        let wire = HolderFrame.input(Array("hello".utf8)).encoded()
        #expect(parser.push(Array(wire[0..<3])).isEmpty)
        #expect(parser.push(Array(wire[3...])) == [.input(Array("hello".utf8))])
    }

    @Test func rejectsAnOversizedLengthWithoutWaitingForIt() {
        var parser = HolderFrameParser()
        #expect(parser.push([0, 0xff, 0xff, 0xff, 0xff]).isEmpty)
        #expect(parser.failed)
    }

    @Test func rejectsAnUnknownTypeAndABadResize() {
        var unknown = HolderFrameParser()
        _ = unknown.push([9, 0, 0, 0, 0])
        #expect(unknown.failed)
        var badResize = HolderFrameParser()
        _ = badResize.push([1, 0, 0, 0, 1, 7])
        #expect(badResize.failed)
    }
}

@Suite("Ring buffer")
struct RingBufferTests {
    @Test func keepsOnlyTheNewestBytes() {
        var ring = RingBuffer(capacity: 5)
        ring.append(Array("abc".utf8))
        ring.append(Array("defg".utf8))
        #expect(String(decoding: ring.bytes, as: UTF8.self) == "cdefg")
    }
}

@Suite("Claude command")
struct ClaudeCommandTests {
    @Test func startsOrResumesBySessionId() {
        #expect(ClaudeCommand.argv(claudePath: "/usr/bin/claude", sessionID: "abc", resume: false)[2] == "/usr/bin/claude --session-id abc; exit $?")
        #expect(ClaudeCommand.argv(claudePath: "/usr/bin/claude", sessionID: "abc", resume: true)[2] == "/usr/bin/claude --resume abc; exit $?")
    }

    @Test func quotesAwkwardArguments() {
        let a = ClaudeCommand.argv(claudePath: "/My Apps/claude", sessionID: "abc", resume: false, extra: ["--remote-control", "task: it's here"])
        #expect(a[2] == "'/My Apps/claude' --session-id abc --remote-control 'task: it'\\''s here'; exit $?")
    }
}
