import Foundation

/// Finds the `claude` executable. A Ghostty tab starts the command through a bare login shell that has
/// not read the user's `.zshrc`, so `~/.local/bin` (where Claude Code installs itself) is usually not
/// on its PATH; an absolute path always works.
public enum ClaudeLocator {
    public static func find(
        pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        let fromPath = pathEnvironment.split(separator: ":").map { "\($0)/claude" }
        let usual = [
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".claude/local/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return (fromPath + usual).first(where: isExecutable) ?? "claude"
    }
}
