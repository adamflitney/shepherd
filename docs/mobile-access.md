# Mobile access — design notes

Shepherd's phone view: see which agent sessions need you, read what an agent said, answer prompts,
reply, start new sessions, and get push notifications — from a phone, over Tailscale. This document is
the current-state design: how it fits together, why it's built this way, what was rejected, and what is
still unverified. For setup instructions see the [README](../README.md#mobile-access).

## Prior art

[devswha/herdr-web-ui](https://github.com/devswha/herdr-web-ui) (MIT) is a much more mature browser/mobile
client for Herdr (React/Vite/Bun, xterm.js, WebSocket, service worker). Its source was read in full
(`DESIGN.md`, `PromptCard.tsx`, `KeyBar.tsx`, `push.ts`, `notifications.ts`, `QrCode.tsx`) rather than just
its README. It reads a *structured* prompt object (title, typed options, `multi_select`, a content hash
for staleness), almost certainly parsed from Claude Code's transcript; we instead parse numbered options
out of the pane's raw text, because we have no transcript parser. That difference is permanent, and is why
we added a stale-screen guard (below).

**Adopted:** options as rows with a `(Recommended)` tag; `multiSelect` as checkboxes + Submit; a broader
key row (arrows, Enter, Esc) for dialogs that aren't numbered; a working-directory line per session;
status always written as a word; PWA install; real Web Push; QR onboarding.
**Not adopted:** a terminal emulator (a periodic text snapshot is enough to decide what to approve),
file browser, SSH/multi-machine, command palette, settings dialog, i18n — all out of scope for a
single-Mac "what needs me right now" tool.

## How it fits together

```
phone (installed web app) ──HTTPS──▶ Tailscale ──▶ `tailscale serve` ──▶ 127.0.0.1:<port>
                                      (identity stamped)                       │
                                                                  MobileAccessServer (inside Shepherd.app)
                                                                               │
                                                          SessionBackend ◀─────┘  (the same Herdr
                                                                                   connection the app uses)
```

Package layout:

| Target | Role |
|---|---|
| `ShepherdCore` | Domain model, `SessionBackend`, config (`WebConfig`). No Herdr/AppKit knowledge. |
| `ShepherdHerdr` | Herdr socket adapter, hook-state parsing. |
| `ShepherdUI` | View models + SwiftUI; also the shared `notificationsToFire` policy. |
| `ShepherdWebKit` | The server as a library: HTTP, API, push, keep-awake, Tailscale setup, the web client (`Public/`). |
| `Shepherd` | The menu bar app; hosts `MobileAccessServer` and the Mobile Access window. |
| `ShepherdWeb` | Thin dev harness over `ShepherdWebKit` (`swift run ShepherdWeb [--fake]`). |

`ShepherdWebKit`:
- `MobileAccessServer.swift` — public entry point: start/stop unit (listener + push notifier + keep-awake)
  and the setup API the window uses (`status()`, `enableTailscaleServe()`, `disableTailscaleServe()`,
  `sendTestNotification()`); `MobileAccessStatus.nextStep` drives the checklist.
- `HTTPServer.swift` — hand-rolled HTTP/1.1 + SSE over `Network.framework` (no third-party dependency, a
  project-wide rule). Binds loopback only; takes a `gate` run before every request.
- `AccessPolicy.swift`, `Tailscale.swift`, `MobileAccessSetup.swift` — who may call; CLI discovery and
  `tailscale status --json`; reading `tailscale serve status --json` and choosing an HTTPS port.
- `SessionsAPI.swift`, `NewSession.swift`, `PushAPI.swift` — HTTP routes; the start-directory allow-list.
- `PushService.swift`, `WebPushCrypto.swift` — subscriptions, the notifier, RFC 8291/8292 on CryptoKit.
- `KeepAwake.swift` — sleep assertion. `StaticFiles.swift` — serves `Public/`.
- `Public/` — the client: vanilla JS, no build step (`index.html`, `sw.js`, manifest, icons).

App side (`Sources/Shepherd/`): `MobileAccessModel.swift`, `MobileAccessView.swift` (checklist + QR),
the menu item in `StatusItemController`, lifecycle in `AppDelegate`. Upstream changes shared with the
native app: `AttentionState.options`/`optionsAllowMultiple`, `SessionBackend.respond(_:keys:)`, hook decode
fields in `HookState.swift`, and `shepherd_write_state.py` (extracts question/options/permission summary).

## Security model

The server is an unauthenticated way to approve permission prompts and type into agents, so who can reach it
is the whole story.

- **Loopback only** (`127.0.0.1`, pinned with `requiredLocalEndpoint`). Nothing on the network reaches it
  directly. This also avoids macOS's "accept incoming connections" dialog.
- **Identity comes from Tailscale.** `tailscale serve` stamps `Tailscale-User-Login` on each request and
  strips any client-supplied copy (verified: a forged header sent through the proxy is overridden). The
  gate accepts only the Mac owner's login (from `tailscale status --json`); refuses
  `Tailscale-Funnel-Request` (public internet); refuses proxied requests with no user (tagged devices).
  A direct loopback request is trusted — a local process can already read `~/.shepherd`.
- The gate runs in front of the SSE stream too (`/api/events` bypasses the router).
- **Start-directory allow-list.** `POST /api/sessions` only starts a session in a directory the server
  itself listed (default folder + configured git projects, minus exclusions), compared on symlink-resolved
  paths — never a path taken from the request.
- Off by default (`web.enabled`).

## Behaviour worth knowing

- **Setup (`tailscale serve`).** `tailscale serve`'s config is global to the machine, so shepherd reuses its
  own entry or takes the first free HTTPS port (443, 8443, 10000) and never replaces someone else's.
  Disabling removes only its own. If Serve or HTTPS isn't enabled for the tailnet the CLI prints an admin
  link and waits; that output is parsed into an action the window shows.
- **Notifications.** One shared `notificationsToFire` (once per transition into blocked/done). The phone also
  gets working→idle (`notifyOnFinishedWork`): Herdr reports a finished run you have *seen* as `idle` and an
  unseen one as `done`, so the Mac (where you are) shouldn't ping on idle but a phone should. The Mac's
  Notifications toggle doesn't silence the phone. Optional `alertsOnlyWhenAway` holds pushes while there is
  recent keyboard/mouse input; blocked/done stay pending (retried every 20s), a finished run is dropped.
  The first snapshot only seeds state, so a restart never announces sessions that were already waiting.
- **Keep-awake.** A `PreventUserIdleSystemSleep` assertion while any session is working *or blocked*
  (60s release grace): a sleeping Mac stalls working agents and can't receive an answer to a blocked one.
  Idle/done sessions don't hold it (there are nearly always some). A closed laptop lid still sleeps.
- **Session screen.** The client polls the open session's screen every 2s and renders it readably:
  rule runs become dividers, `⏺` lines are bold, hard-wrapped prose is re-joined (only when the previous
  line filled the width, so code/tables are untouched), Claude Code's input box and status bar are dropped,
  and its model/usage line is shown in the header (hidden while the keyboard is open).
- **Answering.** Structured questions come from the hook payload; permission options are parsed from the
  screen. A button built from screen text re-peeks and compares before sending
  ("verify-before-send") and refuses if the screen changed. Direct taps stay one-tap; no confirm dialog.
- **Sending.** Optimistic: the box clears and shows "Sending…"; the text is restored on failure.
- **PWA.** iOS only offers push to a page added to the Home Screen. The service worker is network-first
  for the shell (cache-first caused stale pages) and never caches `/api/*` or the stream; it needs a
  secure context, which Tailscale's HTTPS provides. The origin is part of the app's identity: renaming the
  machine or tailnet means re-adding the Home Screen app and re-enabling alerts.
- **Push crypto.** VAPID key persisted at `~/.shepherd/web-push/vapid.key` (mode 0600; regenerating would
  orphan every subscription); subscriptions in `subscriptions.json`, pruned on 404/410. The VAPID `sub` is
  the project URL, not an email, since it goes to Apple/Google with every push.

## Decisions, and what was rejected

- **Embedded in the app, not a separate LaunchAgent.** (Reverses an earlier choice made for dev-iteration
  reasons.) A new user has one app that already runs at login and holds the Herdr connection, and the
  release zip has no toolchain for an install script. `scripts/install-web.sh` remains for headless use;
  don't run both (same port).
- **Tailscale only.** It provides HTTPS, identity and remote access at once. *Rejected for now:* our own
  pairing token for non-Tailscale use — iOS Home Screen apps don't share cookies with Safari, so pairing
  needs real-device work, and it duplicates what Tailscale gives.
- **Bind all interfaces for plain-http LAN use** — rejected: no auth, and push/service workers need HTTPS.
- **`NWParameters.requiredInterfaceType = .loopback`** — tried first; the socket still showed `*:port`.
- **A confirmation dialog before approving** — rejected in favour of verify-before-send (herdr-web-ui's own
  taps are also immediate).
- **From-scratch QR encoder** — unnecessary: CoreImage's `CIQRCodeGenerator` is a system framework.
- **Reusing `ShepherdConfig.isExcluded`** for the allow-list — it is a plain string-prefix match that fails
  through a symlink (`/var` vs `/private/var`); the web path resolves symlinks. The menu bar picker still
  has that weakness.

## Gotchas worth remembering

- A top-level `let` in `main.swift` only initializes when execution reaches it, and `main.swift` blocks
  forever on the server — keep shared state in other files.
- `Bundle.module`'s accessor `fatalError`s inside an `.app` when its bundle isn't where it expects;
  assets are found manually (`StaticFiles.swift`) and `build-app.sh` fails if the bundle is missing.
- An SSE `for await` that wraps another stream in a second `Task` tripped a Swift 6 isolation check; iterate
  the backend's stream directly.
- The web client is served from a copied resource bundle: rebuild before restarting or you serve stale files.
  A page loaded while the server restarts falls back to the service worker's cache — reload once more.
- Chrome DevTools always renders with Chromium, so WebKit-only layout bugs can't be reproduced there.
- When copying a spec's test vector (RFC 8291 Appendix A), copy it from the RFC text, not a summarising
  fetch — the first attempt here was corrupted; the intermediate values were re-derived to prove the code.

## Not yet verified / open gaps

- The release zip hasn't been installed on a clean Mac; Gatekeeper behaviour for an ad-hoc-signed,
  non-notarized app that opens a listener is untested.
- Tapping a push notification to open that session's card hasn't been confirmed on a phone; the on-screen
  keyboard behaviour of the full-screen session view was checked on a phone only by the user's own use.
- The iOS "Add to Home Screen" hint (plain Safari tab) is only exercised on a desktop browser.
- If the app quits or crashes the phone view goes down with it (the old LaunchAgent restarted itself);
  `tailscale serve`'s entry stays, so the phone shows a bad gateway until Shepherd is back.
- The hand-rolled HTTP server is part of a shipped product: loopback + the gate limit exposure, but it
  isn't hardened against malformed or oversized requests.
- Only the Mac owner's Tailscale login is accepted (no shared-tailnet / multi-user Macs).
- Stale push subscriptions (e.g. a deleted Home Screen app) are only pruned when the push service reports
  404/410, so "phones with alerts" can overstate.
- Once everything is idle/done the Mac can sleep after 60s, and a follow-up can't be sent from the phone
  until it wakes. A blocked session left unanswered holds the sleep assertion with no time cap.

## Optional / nice to have

- A max-hold on the keep-awake assertion for a long-unanswered blocked session.
- Show the "auto mode on" status line in the session header.
- Frecency ordering in the new-session picker (the app keeps visit history in its own UserDefaults).
- Option descriptions under each option label (herdr-web-ui shows them).
- Separate idea, not part of this feature: a task-board view ("tsk" in the source note).

## Development

- Server + client only: `swift run ShepherdWeb --fake --port 8788` (demo sessions, no Herdr needed), then
  open `http://localhost:8788`. `--no-keep-awake` and `--alerts-only-when-away` mirror the settings.
- The whole app: `swift run Shepherd -- --fake`; add `--show-mobile-access` to open the window at launch.
- After editing `Public/`, rebuild (`swift build`) — the server serves the copied resource bundle.
- Tests: `swift test`. `ShepherdWebTests` cover the push crypto (against RFC 8291 values), the access
  policy, the Tailscale parsing and port planning, the start-directory allow-list, the notifier and
  keep-awake logic. One live-integration test in `ShepherdHerdrTests` depends on the real Herdr's state
  and is known to be flaky.
