import Foundation
import Testing
@testable import ShepherdHerdr

private func data(_ string: String) -> Data { Data(string.utf8) }
private func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

@Test func framerYieldsOneFrameForACompleteLine() {
    var framer = NDJSONFramer()
    let frames = framer.append(data("{\"id\":\"1\"}\n"))
    #expect(frames.map(string) == ["{\"id\":\"1\"}"])
}

@Test func framerBuffersAPartialFrameUntilItsNewlineArrives() {
    var framer = NDJSONFramer()
    #expect(framer.append(data("{\"id\":\"1")).isEmpty)
    let frames = framer.append(data("\"}\n"))
    #expect(frames.map(string) == ["{\"id\":\"1\"}"])
}

@Test func framerHandlesByteAtATimeArrival() {
    var framer = NDJSONFramer()
    let line = "{\"ok\":true}\n"
    var allFrames: [Data] = []
    for byte in Array(line.utf8) {
        allFrames += framer.append(Data([byte]))
    }
    #expect(allFrames.map(string) == ["{\"ok\":true}"])
}

@Test func framerSkipsBlankLines() {
    var framer = NDJSONFramer()
    let frames = framer.append(data("{\"a\":1}\n\n{\"b\":2}\n"))
    #expect(frames.map(string) == ["{\"a\":1}", "{\"b\":2}"])
}

@Test func framerReturnsMultipleFramesFromOneBurstInOrder() {
    var framer = NDJSONFramer()
    let burst = (0..<50).map { "{\"n\":\($0)}" }.joined(separator: "\n") + "\n"
    let frames = framer.append(data(burst)).map(string)
    #expect(frames.count == 50)
    #expect(frames.first == "{\"n\":0}")
    #expect(frames.last == "{\"n\":49}")
}

@Test func framerRetainsTrailingPartialFrameAcrossManyAppends() {
    var framer = NDJSONFramer()
    var frames: [Data] = []
    frames += framer.append(data("{\"a\":1}\n{\"b\":2}\n{\"c\":"))
    #expect(frames.map(string) == ["{\"a\":1}", "{\"b\":2}"])
    frames = framer.append(data("3}\n"))
    #expect(frames.map(string) == ["{\"c\":3}"])
}
