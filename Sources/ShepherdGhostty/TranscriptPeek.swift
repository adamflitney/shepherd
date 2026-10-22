import Foundation

/// A readable look at the end of a Claude Code conversation, read from its transcript file. Ghostty's
/// scripting cannot read the screen, and the transcript says more than the screen does anyway.
public enum TranscriptPeek {
    /// Claude Code keeps each project's transcripts under a directory named after the project's path
    /// with every non-alphanumeric character replaced by "-".
    public static func transcriptURL(workingDirectory: String, sessionID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let encoded = String(workingDirectory.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return home.appendingPathComponent(".claude/projects/\(encoded)/\(sessionID).jsonl")
    }

    public struct Message: Equatable, Sendable {
        public let isUser: Bool
        public let text: String
    }

    /// The last few exchanges as plain text, newest last, at most `maxCharacters` long.
    public static func recentText(at url: URL, maxMessages: Int = 6, maxCharacters: Int = 4000) -> String {
        var out = recentMessages(at: url).suffix(maxMessages).map { $0.isUser ? "› \($0.text)" : $0.text }.joined(separator: "\n\n")
        if out.count > maxCharacters { out = "…" + out.suffix(maxCharacters - 1) }
        return out
    }

    /// The text messages of a transcript, oldest first. Only the tail of the file is read, so a
    /// multi-megabyte transcript costs the same as a short one.
    public static func recentMessages(at url: URL) -> [Message] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if size > window, !lines.isEmpty { lines.removeFirst() }  // a partial first line

        var messages: [Message] = []
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let text = plainText(message["content"]), !text.isEmpty else { continue }
            messages.append(Message(isUser: type == "user", text: text))
        }
        return messages
    }

    /// The whole conversation as plain text (who said what), newest messages kept when it is longer than
    /// `maxCharacters`. Reads the entire file, so it is for a deliberate "show me the transcript", not for polling.
    public static func conversationText(at url: URL, maxCharacters: Int = 60_000) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 60_000_000 else { return nil }
        var parts: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let text = plainText(message["content"]), !text.isEmpty else { continue }
            parts.append((type == "user" ? "You" : "Claude") + "\n" + text)
        }
        var out = parts.joined(separator: "\n\n")
        if out.count > maxCharacters { out = "… (earlier messages left out)\n\n" + out.suffix(maxCharacters) }
        return out
    }

    /// Text blocks only: tool calls and results are noise in a peek. Returns nil for a message that
    /// is nothing but tool traffic.
    private static func plainText(_ content: Any?) -> String? {
        if let s = content as? String { return clean(s) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { b -> String? in
            guard (b["type"] as? String) == "text", let t = b["text"] as? String else { return nil }
            return t
        }
        return texts.isEmpty ? nil : clean(texts.joined(separator: "\n"))
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
