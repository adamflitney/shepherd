<img src="Resources/icon-preview/icon.png" width="96" height="96" alt="shepherd icon">

# shepherd

A native macOS menu-bar app for [Herdr](https://herdr.dev), a terminal workspace manager for AI coding agents. Herdr shows you which of your agent sessions need attention, but only while you're looking at a terminal. shepherd answers "which of my agents need me?" at a glance from the menu bar, and lets you switch to, create, or quickly ask something of a session without ever opening a terminal.

## What it does

- **Menu bar dashboard** — the icon shows your worst-case attention state across all sessions (blocked/done/working/idle/unknown) at a glance. Click it to see the full list.
- **Quick switcher** — press a global hotkey (Hyper+W) from any app to pop up a searchable panel and jump straight to a session, fully keyboard-driven.
- **Project picker** — from the same panel, fuzzy-search your projects (frecency-ranked) and start a new session in one, instead of hunting for the right directory.
- **Inline quick-answer** — type a question directly into the panel and get an answer without switching to a terminal at all. If the question turns out to need real work, shepherd spawns a real session for it automatically and sends your question in.
- **Notifications** — get notified when a session becomes blocked or finishes, so you don't have to keep the panel open to watch for it.

## Dependencies

- **macOS 14+**
- **[Herdr](https://herdr.dev)** — shepherd talks to Herdr's local socket API; it has no functionality without a running Herdr instance.
- **[Claude Code CLI](https://claude.com/claude-code)** (`claude`) on your `PATH` — used both for the sessions Herdr manages and for shepherd's own inline quick-answer feature.
- **Swift 6 toolchain** (Xcode 16+) to build from source. No third-party Swift package dependencies.

## Getting started

```bash
swift build
swift test
swift run Shepherd -- --fake   # runs against seeded demo data, no Herdr required
```

To install as a real menu-bar app:

```bash
scripts/install.sh
```

This builds a release binary, assembles `Shepherd.app`, ad-hoc code-signs it, and installs it to `/Applications`.
