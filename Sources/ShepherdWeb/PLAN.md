# ShepherdWeb — plan

Origin: Adam found [devswha/herdr-web-ui](https://github.com/devswha/herdr-web-ui) (MIT), a much
more mature browser/mobile client for Herdr, and asked for a look at what we should borrow for
ShepherdWeb — our own prototype mobile web view (see `Sources/ShepherdWeb/`, and the
`Agent Tasks/shepherd-mobile-web-prototype.md` task note for how we got here). This records what
was actually found in their source (not just their README) and what to do with it.

## Prior art: herdr-web-ui

Full-featured React/Vite/Bun app (xterm.js, WebSocket, service worker), not a prototype. Read in
full: `DESIGN.md` (their own extracted design system — colors, spacing, every component), plus
`src/components/{PromptCard,KeyBar,Sidebar}.tsx`, `src/lib/{push,notifications}.ts`,
`src/components/QrCode.tsx`.

**Architecturally different from us, and worth naming why**: their approval/question UI
(`PromptCard.tsx`) reads a structured `InteractivePrompt` object (title, question, typed
`options[]` with `label`/`description`, `multi_select`, `custom_option_index`, a content hash to
detect staleness) — almost certainly parsed from Claude Code's own transcript/stream-json output,
not screen-scraped. Our `respond(keys:)` approach instead parses options out of `peek()`'s raw
terminal text with a regex (`parseNumberedOptions` in `Public/index.html`), because we don't have
(and don't want to build, for a prototype) a transcript parser. This is a real, permanent
difference in foundation, not a gap to close — but it means our answer-matching is heuristic where
theirs is exact, which matters for one decision below (prompt staleness).

### Patterns worth taking

- **Options as full-width rows with a description line**, not bare buttons — `.prompt-card-option`
  shows the number, the label, and the option's description underneath in dimmed text. We only show
  the label today.
- **A `(Recommended)` suffix becomes a tag**, not left in the label text.
- **`multi_select` is a real, handled case**: checkboxes + a `Submit (N)` button, not an assumption
  that every question is single-choice. Claude Code's own `AskUserQuestion` already carries a
  `multiSelect` boolean in its `tool_input` (confirmed in our own hook payload capture) — we
  currently ignore it entirely.
- **Stale-prompt detection**: they hash the prompt's content; answering against a prompt that
  changed server-side between render and tap gets rejected (`409 prompt_changed`) with "the prompt
  changed — re-read" rather than silently sending a now-wrong key. We should want this *more* than
  they do, not less (see Decisions).
- **A broader, semantically-labeled key row** (`KeyBar.tsx`): Esc, Tab, Ctrl (one-shot modifier),
  arrows, `^C` — not just digits. Our own folder-trust-dismiss case (`down`, `enter`) is a concrete
  example of a real prompt our current generic fallback (digits 1-5 + esc only) cannot drive at all.
- **Two-line roster rows**: title alone on line one, status + workspace + cwd on line two. We
  already have title + badge + one-line `summary`, but never surface `workingDirectory` — which
  session this is, project-wise, is real at-a-glance information we're dropping.
- **Status written as a short word, not just a color** (`READY`/`RUN`/`INPUT`/`DONE`) — we already
  do this (`BLOCKED`/`WORKING`/etc. as text), just worth keeping as we touch this code.
- **PWA install + push notifications** (`src/pwa.ts`, `public/sw.js`, `src/lib/push.ts`,
  `src/lib/notifications.ts`): service worker, Add-to-Home-Screen, and real Web Push so you're
  alerted with the phone locked, not only while the tab is open and its SSE connection is live. This
  is the single biggest capability gap between us and them, and the original motivating use case for
  building ShepherdWeb at all.
- **QR code for onboarding a new phone** (`QrCode.tsx`): inline SVG from the `qrcode-generator` npm
  package, dark-on-white always (phone cameras read inverted codes unreliably).

### Explicitly not adopting (and why)

- **A full terminal emulator (xterm.js-equivalent)** — justified for them because they already parse
  full PTY/transcript output; for us it would mean building a terminal emulator with no payoff,
  since `peek()`'s one-shot snapshot is enough for "can I tell what to approve/answer."
- **File browser, SSH/multi-machine management** — real features of theirs, irrelevant to Adam's
  single-Mac home setup and the "what needs me right now" triage use case ShepherdWeb exists for.
- **Command palette, settings dialog (theme/density/etc.), i18n** — polish for a product with many
  users; skip for a single-user prototype unless it earns its keep later.
- **tsk's kanban task board idea** (from the same source note) — a genuinely separate feature
  (task management, not session approval/reply). Tracked as its own future idea, not folded in here.

## Decisions

- **Adopt the visual direction, not the literal palette.** Match the shape of their design system
  (one chrome/accent color; status always written as a word, never color-only; two-line rows;
  tonal-shift-plus-hairline depth, shadows reserved for overlays) rather than their specific amber
  tokens. Our own dark theme already does some of this (status dot + text, dark surfaces); this is
  about finishing it and keeping it coherent as we add features, not a redesign.
- **Verify-before-send, not confirm-before-send.** Their own button taps fire immediately with no
  confirmation dialog — confirmation only guards a *different*, riskier path (a typed numeric
  shortcut in chat, ambiguous until confirmed). Direct tap-to-approve stays one-tap for us too. But
  because our option text comes from regex-parsing a screen snapshot rather than a verified
  structured answer, we're more exposed to the screen having moved on by the time you tap than they
  are. So: re-`peek()` immediately before sending a parsed-option key, diff it against the snapshot
  the button was generated from, and refuse + re-render (not silently send) if it changed. This is
  their `prompt_changed` guard, ported to our heuristic foundation where it's more necessary, not
  less.
- **Push notifications are real engineering, not a quick add — scope it as its own phase.** Web
  Push needs VAPID (ECDSA P-256 JWT signing) and payload encryption (ECDH + HKDF + AES-128-GCM per
  RFC 8291). No third-party dependency needed — `CryptoKit` covers the primitives (`P256.Signing`,
  `P256.KeyAgreement`, `AES.GCM`) — but we write the Web Push wire format ourselves. Don't
  underscope this against the "quick win" framing from the earlier conversation.

## Current file map (for a session with no memory of building this)

Everything lives under `Sources/ShepherdWeb/`:
- `main.swift` — process entry; picks real `HerdrSessionBackend` vs. `--fake` demo backend, starts
  `HTTPServer`.
- `HTTPServer.swift` — the hand-rolled HTTP/1.1 + SSE server (`Network.framework`, no third-party
  dependency — a project-wide constraint, see root `README.md`'s Dependencies section).
- `SessionsAPI.swift` — routes requests onto `SessionBackend` (from `ShepherdCore`/`ShepherdHerdr`);
  `SessionWire` here is the JSON shape sent to the browser (currently: `id`, `title`, `agent`,
  `attention_kind`, `blocker`, `summary`, `options`, `is_focused`, `can_prompt`, `can_respond` — no
  `working_directory` yet, see Phase A).
- `DemoSessions.swift` — `--fake` seed data, including the three demo blocked-shapes (plain
  question, `AskUserQuestion`, permission prompt) used for UI iteration without a live Herdr.
- `StaticFiles.swift` — serves `Public/` (kept out of `main.swift` deliberately: a top-level `let`
  in `main.swift` only initializes once execution reaches its line, and `main.swift` blocks forever
  on `Task.sleep` right after starting the server, so anything declared below that line there would
  never initialize).
- `WebPushCrypto.swift`, `PushService.swift`, `PushAPI.swift` — Web Push (see Phase C).
- `Public/index.html` — the entire client: vanilla JS, no build step, no framework. Session list +
  per-card expand/collapse state (`selected` Set), peek fetch/cache (`peekCache`), numbered-option
  parsing (`parseNumberedOptions`, regex over peek text), the `keyrow` (currently hardcoded
  `["1","2","3","4","5","esc"]`).

Upstream of ShepherdWeb, these also changed to support it and are shared with the native app:
`ShepherdCore/AttentionState.swift` (`options: [String]?` field), `ShepherdCore/SessionBackend.swift`
(`respond(_:keys:)`), `ShepherdHerdr/HookState.swift` (`question`/`options`/`summary` decode fields),
`Sources/Shepherd/HookScripts/shepherd_write_state.py` (extracts them from the real hook payload).

Status of real-session testing, the one open bug fixed along the way (Herdr's `pane.read` response
nesting), and the one known-but-unchased rough edge (a real session's expanded card can silently
re-collapse on identity churn) are tracked in `Agent Tasks/shepherd-mobile-web-prototype.md`
(Obsidian), not duplicated here.

## Roadmap

### Phase A — cheap, high-value UI fixes (no new infrastructure) — DONE
- [x] Show `workingDirectory` (or its last path component) on a session row's second line.
      `SessionWire.workingDirectory`/`wire(_:)` in `SessionsAPI.swift`; rendered in `replyCard()` via
      a new `lastPathComponent()` helper and `.cwd` row in `Public/index.html`, visible collapsed.
- [x] Surface `AskUserQuestion`'s `multiSelect`: checkboxes + a `Submit (N)` button when true,
      single-tap buttons when false. Threaded end-to-end: `extract_ask_user_question` in
      `shepherd_write_state.py` now reads `questions[0].multiSelect` → `multi_select` in the hook
      JSON → `HookDetailWire`/`ParsedHookState.multiSelect` in `HookState.swift` →
      `AttentionState.optionsAllowMultiple` (new field, `ShepherdCore/AttentionState.swift`) →
      `SessionWire.optionsAllowMultiple` (`options_allow_multiple` on the wire) →
      `Public/index.html`'s new multi-select branch in `replyCard()` (`multiChoices` per-session
      `Set`, `sendMultiRespond()` sends the chosen digits + `"enter"` in one `respond` call).
      Verified live against a new `demo:multi-choice` fake session via chrome-devtools: checkbox
      toggling updates `Submit (N)`, submit resolves the session.
- [x] Strip a `(Recommended)` suffix out of an option label into a small tag.
      Client-side `splitRecommended()`/`optionLabelNode()` in `Public/index.html`, applied to both
      the single-select and multi-select option buttons. Confirmed real (not speculative): the
      `AskUserQuestion` tool's own guidance instructs appending "(Recommended)" to a label.
- [x] Broaden the generic (no-parsed-options) key row from `1 2 3 4 5 esc` to add `↑`/`↓`/`⏎`
      (sending `up`/`down`/`enter`), so the folder-trust-style unnumbered dialog is drivable.
      Client-side only, `Public/index.html`'s `keyrow` construction; no backend change needed.
- [x] Verify-before-send: `verifyAndRespond()` in `Public/index.html` re-peeks and re-parses before
      sending a digit built from `parseNumberedOptions` (the `needsPermission` branch only — the
      `AskUserQuestion` branch's options are already structured, not screen-scraped, so didn't need
      this); on a label mismatch it updates `peekCache` and re-renders instead of sending.

All five verified together in-browser (chrome-devtools) against the `--fake` backend; full test
suite still green (253 tests, the one pre-existing live-integration flake aside — see the Obsidian
task note). Nothing committed yet.

### Phase B — PWA foundation — DONE
- [x] Web manifest + icon set (`Public/manifest.webmanifest`, `icon-192/512.png`,
      `apple-touch-icon.png`, plus the iOS `apple-mobile-web-app-*` meta tags in `index.html`), so
      "Add to Home Screen" gives a standalone app. Icons were generated once with a stdlib-only
      Python script (ring + dot in the status-blue on the page's dark background) — no image tooling
      dependency; regenerate by editing that script if the design changes. `StaticFiles.swift` gained
      `webmanifest`/`png`/`svg` content types.
- [x] visualViewport-driven sticky action bar: keyrow + reply box + Send now live in a `.replybar`
      (`position: sticky; bottom: var(--kb)`), with `--kb` (keyboard height = layout height − visual
      viewport height − offsetTop) kept current by a `visualViewport` listener. `.card` switched from
      `overflow: hidden` to `overflow: clip` because `hidden` makes the card a scroll container and
      silently disables sticky. **Unverified on a real iOS keyboard** — devtools can't open one; check
      on the phone.
- [x] Related fix found along the way: `render()` rebuilds every node on each SSE tick, which would
      drop focus (and the keyboard) from a reply box mid-typing. It now holds the render while a
      `textarea` is focused and flushes 300ms after blur (the delay lets a "Send reply" tap land).
- [x] Minimal service worker (`Public/sw.js`): network-first for the shell with cache fallback
      (deliberately not cache-first — stale-page caching already bit us once), `/api/*` and SSE never
      cached. Decides the old open question: network-first.

**Caveat that matters for Phase C**: service workers (and Web Push) only work in a secure context —
https or `localhost`. Over a plain `http://<lan-ip>:8787` the page registers no worker (silent no-op)
and Add to Home Screen works but with no offline shell. Verified on localhost only. Phase C will need
real HTTPS for the phone (e.g. Tailscale `serve`/`cert`, or a locally-trusted cert) — add that to the
Phase C scope before starting it.

### Phase C — push notifications — BUILT; real-transition push awaiting a live check
- [x] Server identity + storage: `WebPushCrypto.swift` (`VAPIDKeys`, persisted at
      `~/.shepherd/web-push/vapid.key`, mode 0600 — regenerating it would orphan every subscription)
      and `PushService.swift` (subscriptions persisted to `subscriptions.json`; same endpoint
      re-subscribing replaces rather than duplicates; a 404/410 from the push service drops it).
- [x] Endpoints (`PushAPI.swift`): `GET /api/push/key`, `POST /api/push/subscribe|unsubscribe|test`.
- [x] Client: `sw.js` `push` + `notificationclick` handlers (tap focuses the app and expands that
      session's card, or opens `/?session=<id>`); header "Enable alerts" / "Alerts on" / "Test"
      control in `index.html` (hidden when `PushManager` is missing, e.g. a plain Safari tab on iOS —
      push there needs the installed Home Screen app). The page re-POSTs its subscription on every
      load so a lost server store self-heals.
- [x] Notify policy: `runPushNotifier` reuses `ShepherdUI`'s `notificationsToFire` (push once per
      *transition into* blocked/done), seeded from a first snapshot so a server restart never
      announces sessions that were already waiting.
- [x] Web Push crypto, hand-written on `CryptoKit` (no dependency): RFC 8291 aes128gcm + RFC 8292
      VAPID (ES256, `rawRepresentation` = the r||s form JWS wants). Tests in
      `Tests/ShepherdWebTests/WebPushCryptoTests.swift`: RFC 8291 Appendix A ECDH secret and body,
      a browser-side decrypt round trip, and a verified-signature check on the VAPID JWT.
      **Gotcha:** a first attempt at pinning the RFC body failed because the vector had been copied
      through a summarising fetch and was corrupted (it decoded to a record with no room for the
      padding delimiter). The RFC's intermediate values (IKM/CEK/nonce) were re-derived independently
      and matched; if the vector is ever re-pinned, copy it from the RFC text itself.
- [x] Verified on a real iPhone: Enable alerts → permission → Test push arrives.
- [ ] Verify an organic push (a real session going blocked/done) and tap-to-open on the phone.
- VAPID `sub` is the project URL, not an email: it is sent to Apple/Google with every push.
- HTTPS: solved with Tailscale — `tailscale serve --bg 8787` fronts the server at
  `https://macbook1.stern-saturation.ts.net` (tailnet-only, persistent across restarts of the server;
  `tailscale serve --https=443 off` removes it). The origin is part of a PWA's identity: renaming the
  machine/tailnet means re-adding the Home Screen app and re-enabling alerts.

### Phase D — nice-to-haves, unordered
- [ ] QR code on the server's startup log / a `/qr` route, for onboarding a new phone onto the LAN
      URL without typing it. Needs a from-scratch QR encoder (Reed-Solomon ECC + matrix placement)
      to keep the no-third-party-dependency rule — real but bounded work; lower priority than it
      sounds, since typing a short LAN URL once isn't actually painful.
- [ ] Live-updating peek instead of a one-shot snapshot (poll on an interval while a card is
      expanded, or push diffs over the existing SSE stream) — closer to their "live terminal" feel
      without building a terminal emulator.

## Open questions / not yet decided

- Exact visual tokens (colors/spacing) if we do a real styling pass in Phase A — "match the shape,
  not the palette" above is a direction, not a spec.
- Whether Phase C's real engineering cost is worth it versus a cheaper notification channel (e.g.
  nothing — just rely on being physically near the Mac to hear its existing menu-bar notification
  sound, and treat ShepherdWeb as pull-only). Flagging rather than deciding: Adam should weigh in
  before Phase C starts, since it's the most expensive item here by a wide margin.
- Productionizing: ShepherdWeb is still a hand-started process (`nohup`). Push is only useful if it is
  always running, so it needs launchd or to live in the menu bar app. Not decided.
- Push when the Mac is asleep: the server can't notify while the Mac sleeps. Unaddressed.
