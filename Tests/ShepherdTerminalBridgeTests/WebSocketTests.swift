import Foundation
import Testing
@testable import ShepherdTerminalBridge

private func masked(_ op: UInt8, _ payload: [UInt8], fin: Bool = true, mask: [UInt8] = [1, 2, 3, 4]) -> Data {
    var d = Data([(fin ? 0x80 : 0) | op])
    if payload.count < 126 { d.append(0x80 | UInt8(payload.count)) }
    else { d.append(0x80 | 126); d.append(UInt8(payload.count >> 8)); d.append(UInt8(payload.count & 0xff)) }
    d.append(contentsOf: mask)
    for (i, b) in payload.enumerated() { d.append(b ^ mask[i & 3]) }
    return d
}

@Suite("WebSocket frames")
struct WebSocketFrameTests {
    @Test func acceptKeyMatchesTheRFCExample() {
        #expect(webSocketAccept(forKey: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func parsesAMaskedTextFrame() {
        let parser = WSParser(maxPayload: 1024)
        parser.feed(masked(1, Array("hello".utf8)))
        guard case .frame(let f) = parser.next() else { Issue.record("no frame"); return }
        #expect(f.op == 1 && f.fin && String(decoding: f.payload, as: UTF8.self) == "hello")
    }

    @Test func waitsForTheRestOfAFrameAndParsesBackToBackFrames() {
        let parser = WSParser(maxPayload: 1024)
        let wire = masked(2, [1, 2, 3]) + masked(2, [4, 5])
        parser.feed(wire.prefix(4))
        guard case .need = parser.next() else { Issue.record("expected need"); return }
        parser.feed(wire.dropFirst(4))
        guard case .frame(let a) = parser.next(), case .frame(let b) = parser.next() else { Issue.record("expected two frames"); return }
        #expect(a.payload == [1, 2, 3] && b.payload == [4, 5])
    }

    @Test func refusesUnmaskedReservedBitsBadOpcodesAndOversizedFrames() {
        func parse(_ bytes: [UInt8], max: Int = 1024) -> WSParse {
            let p = WSParser(maxPayload: max); p.feed(Data(bytes)); return p.next()
        }
        func code(_ r: WSParse) -> UInt16? { if case .fail(let c, _) = r { return c }; return nil }
        #expect(code(parse([0x81, 0x01, 0x41])) == 1002)                 // unmasked
        #expect(code(parse([0xc1, 0x81, 0, 0, 0, 0, 0x41])) == 1002)     // RSV1
        #expect(code(parse([0x83, 0x81, 0, 0, 0, 0, 0x41])) == 1002)     // reserved opcode
        #expect(code(parse([0x82, 0xff] + [UInt8](repeating: 0x7f, count: 8) + [0, 0, 0, 0])) == 1009)   // 2^63-ish length
        #expect(code(parse([0x82, 0xfe, 0x10, 0x00, 0, 0, 0, 0], max: 1024)) == 1009)   // 4096 > 1024, nothing allocated
        #expect(code(parse([0x09, 0x80, 0, 0, 0, 0])) == 1002)           // fragmented control frame
        #expect(code(parse([0x89, 0xfe, 0x00, 0x7e, 0, 0, 0, 0])) == 1002)  // control frame over 125 bytes
    }

    @Test func encodesTheThreeLengthForms() {
        #expect(encodeFrame(op: 2, [UInt8](repeating: 0, count: 5)).count == 2 + 5)
        #expect(encodeFrame(op: 2, [UInt8](repeating: 0, count: 300)).count == 4 + 300)
        #expect(encodeFrame(op: 2, [UInt8](repeating: 0, count: 70000)).count == 10 + 70000)
    }
}

@Suite("Origin check")
struct OriginTests {
    private func allowed(_ origin: String?, host: String) -> Bool {
        var h = ["host": host]
        if let origin { h["origin"] = origin }
        return webSocketOriginAllowed(headers: h)
    }

    @Test func nonBrowserClientsHaveNoOrigin() { #expect(allowed(nil, host: "localhost:8787")) }

    @Test func sameHostAndPortIsAllowed() {
        #expect(allowed("http://localhost:8787", host: "localhost:8787"))
        #expect(allowed("http://127.0.0.1:8787", host: "127.0.0.1:8787"))
        #expect(allowed("http://[::1]:8787", host: "[::1]:8787"))
    }

    @Test func anotherPortOnTheSameHostIsRefused() {
        #expect(!allowed("http://localhost:3000", host: "localhost:8787"))
        #expect(!allowed("http://localhost", host: "localhost:8787"))
    }

    @Test func behindTailscaleServeTheDefaultPortStandsInForAMissingOne() {
        #expect(allowed("https://mac.tail1234.ts.net", host: "mac.tail1234.ts.net"))
        #expect(allowed("https://mac.tail1234.ts.net:8443", host: "mac.tail1234.ts.net:8443"))
        #expect(!allowed("https://mac.tail1234.ts.net:8443", host: "mac.tail1234.ts.net"))
    }

    @Test func aDifferentHostOrAnOddSchemeIsRefused() {
        #expect(!allowed("https://evil.example", host: "localhost:8787"))
        #expect(!allowed("file://localhost", host: "localhost"))
        #expect(!allowed("null", host: "localhost:8787"))
    }

    @Test func splitsHostAndPort() {
        #expect(splitHostPort("localhost:8787") == (host: "localhost", port: 8787))
        #expect(splitHostPort("localhost") == (host: "localhost", port: nil))
        #expect(splitHostPort("[::1]:8787") == (host: "::1", port: 8787))
        #expect(splitHostPort("[::1]") == (host: "::1", port: nil))
    }
}
