import Foundation

/// Reads `~/.shepherd/state/<session-uuid>.json` files written by the
/// Claude Code hooks ported from `shepherd-legacy`. Pure I/O at the edge -
/// `SessionProjection` and `reconcileAttention` stay data-in, data-out.
public struct HookStateStore {
    private let directory: URL
    private let now: () -> Date

    public init(
        directory: URL = URL(fileURLWithPath: (NSString(string: "~/.shepherd/state").expandingTildeInPath)),
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.now = now
    }

    public func state(forSessionUUID uuid: String) -> ParsedHookState? {
        let url = directory.appendingPathComponent("\(uuid).json")
        return parseHookStateFile(try? Data(contentsOf: url), now: now())
    }

    public func allStates() -> [String: ParsedHookState] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return [:]
        }

        var result: [String: ParsedHookState] = [:]
        for file in files where file.pathExtension == "json" {
            let uuid = file.deletingPathExtension().lastPathComponent
            guard let content = try? Data(contentsOf: file),
                  let parsed = parseHookStateFile(content, now: now()) else { continue }
            result[uuid] = parsed
        }
        return result
    }
}
