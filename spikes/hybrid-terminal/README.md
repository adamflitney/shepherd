# Hybrid terminal spikes (2026-10-12)

Throwaway code from the spikes behind `docs/dashboard.md`. Findings are in that doc; nothing here is meant to ship.

| Dir | Spike | What it is |
|---|---|---|
| `a-ptyd/` | A | Swift PTY holder daemon (`openpty` + `posix_spawn`), attach/detach, ring replay, `claude --resume` restore, headless SwiftTerm snapshot (`snap`) |
| `c1-wsbridge/` | C1 | Swift HTTP + hand-rolled WebSocket bridge to the holder, with the Host/Origin/token/Tailscale-identity gate, attack tests in `t/`, patched holder (bounded writes, terminal-mode tracking) |
| `c2-wkwebview-host/` | C2 | Tiny WKWebView host app: Edit menu, link and drop handlers, key handling |
| `c3-phone-test/` | C3 | xterm.js page for a phone, `probe.js` for the Tailscale proxy check, and `qr.swift`; the bridge gained a `--web <dir>` static option (see its README) |
| `c2-web-client-fixes.patch` | C2 | Page-side fixes (Shift+Enter, image paste, links, selection) as a patch against `origin/browser-terminal` |

The `t/` tests need Node with `ws` and `@xterm/headless` installed under `$TMPDIR/node`. Build the Swift packages with
`swift build`. Not wired into the repo's `Package.swift`.
