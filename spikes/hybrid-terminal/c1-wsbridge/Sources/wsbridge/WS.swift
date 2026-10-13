import Foundation

struct WSFrame { var fin: Bool; var op: UInt8; var payload: [UInt8] }
enum WSParse { case frame(WSFrame), need, fail(UInt16, String) }

/// Incremental RFC 6455 parser for client->server frames. Never allocates for a payload before the
/// declared length has been checked against `maxPayload`, and uses a read offset so a burst of tiny frames
/// is linear, not quadratic.
final class WSParser {
    private var buf = [UInt8]()
    private var pos = 0
    let maxPayload: Int
    init(maxPayload: Int) { self.maxPayload = maxPayload }

    func feed(_ d: Data) { buf.append(contentsOf: d) }
    var buffered: Int { buf.count - pos }

    func next() -> WSParse {
        let avail = buf.count - pos
        if avail < 2 { return .need }
        let b0 = buf[pos], b1 = buf[pos + 1]
        let fin = b0 & 0x80 != 0
        if b0 & 0x70 != 0 { return .fail(1002, "reserved bits set") }
        let op = b0 & 0x0f
        switch op { case 0, 1, 2, 8, 9, 10: break; default: return .fail(1002, "bad opcode") }
        if b1 & 0x80 == 0 { return .fail(1002, "client frames must be masked") }
        var len = Int(b1 & 0x7f)
        var hdr = 2
        if len == 126 {
            if avail < 4 { return .need }
            len = Int(buf[pos + 2]) << 8 | Int(buf[pos + 3]); hdr = 4
        } else if len == 127 {
            if avail < 10 { return .need }
            var l: UInt64 = 0
            for i in 0..<8 { l = l << 8 | UInt64(buf[pos + 2 + i]) }
            if l >> 63 != 0 { return .fail(1002, "bad length") }
            if l > UInt64(maxPayload) { return .fail(1009, "frame too large") }
            len = Int(l); hdr = 10
        }
        if op >= 8 && (len > 125 || !fin) { return .fail(1002, "bad control frame") }
        if len > maxPayload { return .fail(1009, "frame too large") }
        if avail < hdr + 4 + len { return .need }
        let m = pos + hdr
        var payload = [UInt8](repeating: 0, count: len)
        for i in 0..<len { payload[i] = buf[m + 4 + i] ^ buf[m + (i & 3)] }
        pos += hdr + 4 + len
        if pos > 65536 { buf.removeFirst(pos); pos = 0 }
        return .frame(WSFrame(fin: fin, op: op, payload: payload))
    }
}

func encodeFrame(op: UInt8, _ payload: [UInt8]) -> Data {
    var d = Data([0x80 | op])
    if payload.count < 126 { d.append(UInt8(payload.count)) }
    else if payload.count < 65536 { d.append(126); d.append(UInt8(payload.count >> 8)); d.append(UInt8(payload.count & 0xff)) }
    else { d.append(127); for i in (0..<8).reversed() { d.append(UInt8((UInt64(payload.count) >> UInt64(i * 8)) & 0xff)) } }
    d.append(contentsOf: payload)
    return d
}
