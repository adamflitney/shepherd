import Foundation
import ShepherdCore

/// Seed data for `--fake`, deliberately including one of each blocked shape
/// this prototype is meant to exercise - a plain-text question (free-text
/// reply only), a numbered `AskUserQuestion` (labeled-button reply), and a
/// permission prompt with no structured options (raw peek text + a manual
/// key/digit send) - so the UX can be iterated on without a live Claude
/// Code session. Kept out of `main.swift`: top-level `let`s there run in
/// textual order at process start, so a top-level reference to this array
/// from a line above its own definition would crash on an uninitialized
/// read - a plain (non-`main.swift`) file's top-level `let`s don't have
/// that hazard.
let demoSessions: [Session] = [
    Session(
        id: SessionID(rawValue: "demo:question"),
        title: "yoto-club-api",
        agent: .claude,
        workingDirectory: URL(fileURLWithPath: "/Users/you/dev/yoto-club-api"),
        attention: AttentionState(kind: .blocked, blocker: .needsAnswer, summary: "Should the retry limit be configurable, or just fixed at 3?"),
        capabilities: [.focus, .prompt]
    ),
    Session(
        id: SessionID(rawValue: "demo:choice"),
        title: "shepherd",
        agent: .claude,
        workingDirectory: URL(fileURLWithPath: "/Users/you/dev/shepherd"),
        attention: AttentionState(kind: .blocked, blocker: .needsAnswer, summary: "Which color?", options: ["Red", "Blue (Recommended)", "Green"]),
        capabilities: [.focus, .prompt]
    ),
    Session(
        id: SessionID(rawValue: "demo:multi-choice"),
        title: "herdr",
        agent: .claude,
        workingDirectory: URL(fileURLWithPath: "/Users/you/dev/herdr"),
        attention: AttentionState(
            kind: .blocked,
            blocker: .needsAnswer,
            summary: "Which checks should block merge?",
            options: ["Lint", "Typecheck", "Tests (Recommended)", "Visual regression"],
            optionsAllowMultiple: true
        ),
        capabilities: [.focus, .prompt]
    ),
    Session(
        id: SessionID(rawValue: "demo:permission"),
        title: "warden",
        agent: .claude,
        workingDirectory: URL(fileURLWithPath: "/Users/you/dev/warden"),
        attention: AttentionState(kind: .blocked, blocker: .needsPermission, summary: "Bash: rm -rf build/"),
        capabilities: [.focus, .prompt]
    ),
    Session(
        id: SessionID(rawValue: "demo:working"),
        title: "yoto-web",
        agent: .claude,
        workingDirectory: URL(fileURLWithPath: "/Users/you/dev/yoto-web"),
        attention: AttentionState(kind: .working),
        capabilities: [.focus, .prompt]
    ),
]

/// Captured live from a real Claude Code permission prompt (see the
/// investigation that led to the digit-key approach), so "Show screen" on
/// the permission demo card previews the exact shape it'll actually be
/// reading when `respond(keys: ["1"])`/`["3"]` don't feel safe to press
/// blind.
let demoPermissionPeekText = """
⏺ Bash(rm -rf build/)

───────────────────────────────────────────
 Bash command
 rm -rf build/
 Remove the build output directory
───────────────────────────────────────────
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for rm commands in this project
   3. No, and tell Claude what to do differently

 Esc to cancel
"""

/// A plain-text question has no numbered options at all - the peek exists
/// only to show full surrounding context (what Claude said right before
/// asking), not anything actionable beyond the free-text reply box.
let demoQuestionPeekText = """
⏺ I've implemented the retry logic in RetryPolicy.swift. Before I wire it
  into the webhook handler:

  Should the retry limit be configurable, or just fixed at 3?

  (No response needed via terminal - type your answer below.)
"""

/// What Claude said just before an `AskUserQuestion` for the numbered-choice demo.
let demoChoicePeekText = """
⏺ I've added a theme setting to the preferences panel and wired it into
  the menu bar icon. The accent colour is still a placeholder, so I need
  a decision before I go further.

⏺ Read(Sources/Shepherd/Preferences.swift)
  ⎿ Read 84 lines

⏺ Update(Sources/Shepherd/Preferences.swift)
  ⎿ Added 12 lines, removed 2 lines

  Which color?

  ❯ 1. Red
    2. Blue (Recommended)
    3. Green
"""
