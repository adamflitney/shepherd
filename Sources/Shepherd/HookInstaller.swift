import Foundation
import ShepherdCore

/// Installs/uninstalls Shepherd's bundled Claude Code hook scripts and
/// registers/removes them in `~/.claude/settings.json`. Pure decision logic
/// (`stripShepherdHooks`/`insertShepherdHooks`) lives in ShepherdCore and is
/// fully tested there; this is the thin, untested-by-unit-tests I/O edge -
/// same tier as `UnixSocketTransport` or `AppleScriptTerminalActivator`. Backs
/// up settings.json before every write, since it's a live file Claude Code
/// itself depends on.
enum HookInstaller {
    static let settingsURL = URL(fileURLWithPath: (NSString(string: "~/.claude/settings.json").expandingTildeInPath))
    static let hooksDirectory = URL(fileURLWithPath: (NSString(string: "~/.claude/hooks").expandingTildeInPath))

    private static let bundledScripts = [
        ("shepherd-log-event", "sh"),
        ("shepherd-write-state", "sh"),
        ("shepherd_write_state", "py"),
    ]

    static func isInstalled() -> Bool {
        guard let settings = readSettings(),
              case .object(let root) = settings,
              case .object(let hooksByEvent)? = root["hooks"] else { return false }

        return hooksByEvent.values.contains { entries in
            guard case .array(let entryList) = entries else { return false }
            return entryList.contains { entry in
                guard case .object(let fields) = entry, case .array(let hookList)? = fields["hooks"] else { return false }
                return hookList.contains { hook in
                    guard case .object(let hookFields) = hook, case .string(let command)? = hookFields["command"] else { return false }
                    return shepherdHookMarkers.contains { command.contains($0) }
                }
            }
        }
    }

    static func install() throws {
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        for (name, ext) in bundledScripts {
            guard let bundled = locateBundledScript(name: name, ext: ext) else {
                continue
            }
            let destination = hooksDirectory.appendingPathComponent("\(name).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: bundled, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }

        let existing = readSettings() ?? .object([:])
        try writeSettings(insertShepherdHooks(existing, hooksDirectory: hooksDirectory.path))
    }

    static func uninstall() throws {
        guard let existing = readSettings() else { return }
        try writeSettings(stripShepherdHooks(existing))
    }

    /// Finds the bundled hook scripts without ever touching `Bundle.module`
    /// directly: its generated accessor calls `fatalError` if neither of its
    /// two hardcoded paths resolves, which would crash the whole app the
    /// first time "Install Hooks" is clicked after `.build` gets cleaned.
    /// `scripts/install.sh` copies the resource bundle into the standard
    /// `Contents/Resources/` location - checked first and, in a real
    /// install, always sufficient. The `.build` path is a dev-only fallback
    /// for `swift run`, where it's guaranteed to exist because that's the
    /// exact build currently running.
    private static func locateBundledScript(name: String, ext: String) -> URL? {
        let resourcesCandidate = Bundle.main.resourceURL?.appendingPathComponent("Shepherd_Shepherd.bundle")
        let topLevelCandidate = Bundle.main.bundleURL.appendingPathComponent("Shepherd_Shepherd.bundle")

        for candidate in [resourcesCandidate, topLevelCandidate].compactMap({ $0 }) {
            if let bundle = Bundle(path: candidate.path),
               let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "HookScripts") {
                return url
            }
        }

        #if DEBUG
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "HookScripts")
        #else
        return nil
        #endif
    }

    private static func readSettings() -> JSONValue? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func writeSettings(_ value: JSONValue) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("shepherd-backup")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: settingsURL, to: backup)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: settingsURL, options: .atomic)
    }
}
