import Foundation

/// A scalar or inline list read from / written to a frontmatter field.
public enum FrontmatterValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case list([String])
}

/// Round-tripping frontmatter. Unknown fields, comments, blank lines and the body are kept exactly
/// as written (including CRLF line endings); `set` rewrites only the entry it is told to change.
public struct Frontmatter: Sendable {
    private struct Entry: Sendable {
        var key: String?  // nil for comments and blank lines
        var lines: [String]
    }

    private var entries: [Entry]
    public var body: String
    public private(set) var hasFrontmatter: Bool
    private let eol: String

    private init(entries: [Entry], body: String, hasFrontmatter: Bool, eol: String) {
        self.entries = entries
        self.body = body
        self.hasFrontmatter = hasFrontmatter
        self.eol = eol
    }

    public static func parse(_ text: String) -> Frontmatter {
        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        let lines = text.components(separatedBy: eol)
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else {
            return Frontmatter(entries: [], body: text, hasFrontmatter: false, eol: eol)
        }
        var entries: [Entry] = []
        for line in lines[1..<close] {
            if let (key, _) = keyLine(line) {
                entries.append(Entry(key: key, lines: [line]))
            } else if let last = entries.last, last.key != nil, line.first?.isWhitespace == true || line.hasPrefix("- ") {
                entries[entries.count - 1].lines.append(line)  // continuation of a block value
            } else {
                entries.append(Entry(key: nil, lines: [line]))
            }
        }
        let body = lines[(close + 1)...].joined(separator: eol)
        return Frontmatter(entries: entries, body: body, hasFrontmatter: true, eol: eol)
    }

    public func serialize() -> String {
        let lines = entries.flatMap(\.lines)
        if !hasFrontmatter && lines.isEmpty { return body }
        let head = lines.isEmpty ? "" : lines.joined(separator: eol) + eol
        return "---\(eol)\(head)---\(eol)\(body)"
    }

    public var keys: [String] { entries.compactMap(\.key) }

    public func get(_ key: String) -> FrontmatterValue? {
        guard let entry = entries.first(where: { $0.key == key }), entry.lines.count == 1,
              let (_, rest) = Self.keyLine(entry.lines[0]) else { return nil }
        return Self.parseValue(Self.stripComment(rest, trim: true))
    }

    public mutating func set(_ key: String, _ value: FrontmatterValue?) {
        let idx = entries.firstIndex(where: { $0.key == key })
        guard let value else {
            if let idx { entries.remove(at: idx) }
            return
        }
        guard let idx else {
            entries.append(Entry(key: key, lines: ["\(key): \(Self.format(value))"]))
            hasFrontmatter = true
            return
        }
        let rest = Self.keyLine(entries[idx].lines[0])?.rest ?? ""
        let withoutComment = Self.stripComment(rest, trim: false)
        let comment = String(rest.dropFirst(withoutComment.count))  // spacing + "# ..."
        entries[idx] = Entry(key: key, lines: ["\(key): \(Self.format(value))\(comment)"])
    }

    // MARK: - parsing helpers

    /// `key: rest` where key is `[A-Za-z_][\w-]*` and the colon is followed by whitespace or the end.
    private static func keyLine(_ line: String) -> (key: String, rest: String)? {
        guard let first = line.first, first.isLetter && first.isASCII || first == "_" else { return nil }
        var i = line.startIndex
        while i < line.endIndex, line[i].isASCII, line[i].isLetter || line[i].isNumber || line[i] == "_" || line[i] == "-" {
            i = line.index(after: i)
        }
        guard i < line.endIndex, line[i] == ":" else { return nil }
        let key = String(line[line.startIndex..<i])
        let after = line.index(after: i)
        if after == line.endIndex { return (key, "") }
        guard line[after].isWhitespace else { return nil }
        return (key, String(line[line.index(after: after)...]))
    }

    /// The value with any trailing ` # comment` removed (and the spacing before it, unless `trim`).
    private static func stripComment(_ raw: String, trim: Bool) -> String {
        var quote: Character?
        var prev: Character?
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if let q = quote {
                if c == "\\" && q == "\"" {
                    i = raw.index(after: i)  // skip the escaped character
                    if i >= raw.endIndex { break }
                } else if c == q {
                    quote = nil
                }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" && (prev == nil || prev!.isWhitespace) {
                return finish(String(raw[raw.startIndex..<i]), trim: trim)
            }
            prev = raw[i]
            i = raw.index(after: i)
        }
        return finish(raw, trim: trim)
    }

    private static func finish(_ s: String, trim: Bool) -> String {
        if trim { return s.trimmingCharacters(in: .whitespaces) }
        var out = s
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out
    }

    private static func parseValue(_ raw: String) -> FrontmatterValue {
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .list([]) }
            return .list(splitList(inner).map { scalarString(String($0).trimmingCharacters(in: .whitespaces)) })
        }
        let s = scalarString(raw)
        if let n = Int(raw), String(n) == raw { return .int(n) }
        return .string(s)
    }

    private static func splitList(_ inner: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var quote: Character?
        var iter = inner.makeIterator()
        while let c = iter.next() {
            if let q = quote {
                cur.append(c)
                if c == "\\" && q == "\"" {
                    if let next = iter.next() { cur.append(next) }
                } else if c == q {
                    quote = nil
                }
            } else if c == "\"" || c == "'" {
                quote = c
                cur.append(c)
            } else if c == "," {
                parts.append(cur)
                cur = ""
            } else {
                cur.append(c)
            }
        }
        parts.append(cur)
        return parts
    }

    /// Unquotes a scalar; numbers stay as their text (the caller decides whether it is an int).
    private static func scalarString(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            if let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
                return obj
            }
            return String(s.dropFirst().dropLast())
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    // MARK: - formatting

    private static func needsQuotes(_ s: String) -> Bool {
        if s.isEmpty || s != s.trimmingCharacters(in: .whitespaces) { return true }
        if let n = Int(s), String(n) == s { return true }
        if ["true", "false", "null", "~"].contains(s.lowercased()) { return true }
        if let first = s.first, "[]{}&*!|>'\"%@`#,-".contains(first) { return true }
        if s.contains(": ") || s.hasSuffix(":") || s.contains(" #") { return true }
        if s.contains(where: { ",]\"'".contains($0) }) { return true }
        if s.contains(where: { $0.isNewline }) { return true }
        return false
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    private static func format(_ v: FrontmatterValue) -> String {
        switch v {
        case .int(let n): return String(n)
        case .string(let s): return needsQuotes(s) ? quote(s) : s
        case .list(let items): return "[" + items.map { needsQuotes($0) ? quote($0) : $0 }.joined(separator: ", ") + "]"
        }
    }
}
