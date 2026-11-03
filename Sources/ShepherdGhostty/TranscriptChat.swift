import Foundation

/// A chat-shaped reading of a Claude Code transcript: messages, tool calls and images in order, read from a byte
/// offset so a caller can poll for just what is new. Read-only; the terminal stays the source of truth.
public enum TranscriptChat {
    public struct Item: Equatable, Sendable, Encodable {
        public var id: String
        public var role: String          // "user" | "assistant"
        public var kind: String          // "text" | "tool" | "result" | "image"
        public var text: String?
        public var tool: String?
        public var toolUseID: String?
        public var mediaType: String?
        public var data: String?         // base64, images only
    }

    public struct Page: Equatable, Sendable, Encodable {
        public var items: [Item]
        public var offset: UInt64
    }

    static let firstWindow: UInt64 = 512 * 1024
    static let maxImageBytes = 1_500_000
    static let maxResultCharacters = 1_500

    /// Items after `offset`, or the end of the file when there is none. Only whole lines are consumed, so a line still
    /// being written is picked up on the next call.
    public static func read(at url: URL, after offset: UInt64?) -> Page {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Page(items: [], offset: offset ?? 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var start = offset ?? (size > firstWindow ? size - firstWindow : 0)
        if start > size { start = 0 }  // the file was replaced
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return Page(items: [], offset: start) }
        var chunk = data[data.startIndex...lastNewline]
        let consumed = UInt64(chunk.count)
        if offset == nil, start > 0, let firstNewline = chunk.firstIndex(of: 0x0A) {
            chunk = chunk[chunk.index(after: firstNewline)...]  // a partial first line
        }
        var items: [Item] = []
        var n = 0
        for line in chunk.split(separator: 0x0A, omittingEmptySubsequences: true) {
            n += 1
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            items.append(contentsOf: parse(obj, idPrefix: "\(start)-\(n)"))
        }
        return Page(items: items, offset: start + consumed)
    }

    static func parse(_ obj: [String: Any], idPrefix: String) -> [Item] {
        guard let type = obj["type"] as? String, type == "user" || type == "assistant",
              obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true,
              let message = obj["message"] as? [String: Any] else { return [] }
        let role = type
        if let s = message["content"] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || isHarnessNoise(t) ? [] : [Item(id: idPrefix, role: role, kind: "text", text: t)]
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var out: [Item] = []
        for (i, b) in blocks.enumerated() {
            let id = "\(idPrefix).\(i)"
            switch b["type"] as? String {
            case "text":
                let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !isHarnessNoise(t) { out.append(Item(id: id, role: role, kind: "text", text: t)) }
            case "tool_use":
                let name = b["name"] as? String ?? "tool"
                out.append(Item(id: id, role: role, kind: "tool", text: toolSummary(name, b["input"] as? [String: Any] ?? [:]),
                                tool: name, toolUseID: b["id"] as? String))
            case "tool_result":
                out.append(Item(id: id, role: role, kind: "result", text: clip(resultText(b["content"])), toolUseID: b["tool_use_id"] as? String))
                for (j, img) in imageItems(b["content"], role: role, id: id).enumerated() { _ = j; out.append(img) }
            case "image":
                out.append(contentsOf: imageItems([b], role: role, id: id))
            default:
                continue  // thinking and anything newer: the terminal shows them
            }
        }
        return out
    }

    private static func imageItems(_ content: Any?, role: String, id: String) -> [Item] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.enumerated().compactMap { i, b in
            guard (b["type"] as? String) == "image", let src = b["source"] as? [String: Any],
                  (src["type"] as? String) == "base64", let data = src["data"] as? String, data.utf8.count <= maxImageBytes else { return nil }
            return Item(id: "\(id).img\(i)", role: role, kind: "image", mediaType: src["media_type"] as? String ?? "image/png", data: data)
        }
    }

    private static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    private static func clip(_ s: String) -> String {
        s.count > maxResultCharacters ? String(s.prefix(maxResultCharacters)) + "…" : s
    }

    /// Command echoes and reminders the harness injects as user text; the terminal shows them dimmed, chat leaves them out.
    private static func isHarnessNoise(_ t: String) -> Bool {
        t.hasPrefix("<system-reminder>") || t.hasPrefix("<command-name>") || t.hasPrefix("<local-command-") || t.hasPrefix("<command-message>")
    }

    private static func toolSummary(_ tool: String, _ input: [String: Any]) -> String {
        func s(_ key: String) -> String? { (input[key] as? String).map { $0.count > 200 ? String($0.prefix(200)) + "…" : $0 } }
        switch tool {
        case "Bash": return s("description") ?? s("command") ?? ""
        case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit": return s("file_path") ?? ""
        case "Grep", "Glob": return s("pattern") ?? ""
        case "WebFetch": return s("url") ?? ""
        case "WebSearch": return s("query") ?? ""
        case "Agent", "Task": return s("description") ?? ""
        default: return s("description") ?? s("command") ?? s("file_path") ?? s("query") ?? ""
        }
    }
}
