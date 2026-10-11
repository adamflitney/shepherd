# @shepherd/desktop

Electron shell, currently a **spike** to decide whether Electron can replace the Swift menu-bar app.
It adds no UI of its own: the panel (`packages/web/panel.html`) and the dashboard (`packages/web/index.html`)
are the daemon's web client, loaded into native windows.

    pnpm install
    node node_modules/electron/install.js      # pnpm skips Electron's download script; run this once
    pnpm --filter @shepherd/web build          # the daemon serves the built client
    (cd ../daemon && node src/cli.ts daemon)   # in another terminal
    pnpm start                                 # menu-bar item + hotkey (default Hyper+W, SHEPHERD_HOTKEY to change)

- **Hotkey** shows a preloaded, frameless `type: 'panel'` window (a real non-activating NSPanel).
  Type to filter, Up/Down (or Ctrl-N/P) to move, Enter opens the dashboard on that session, Esc or
  clicking away dismisses it.
- **Menu bar** title shows the worst attention state (red blocked, green done, blue working).
- **Dashboard** is a normal window; the dock icon only appears while it is open.
- `pnpm spike` runs read-only automated checks and prints a report (see below). It never sends
  keystrokes to the OS; it types into the panel with input events delivered to its own webContents.

## Spike results (Electron 44.7, macOS, 2026-10-11)

Measured by `pnpm spike` against a daemon with two sessions:

| Check | Result |
|---|---|
| Hyper+W registered with `globalShortcut` | yes |
| Panel shown: window focused, page focused, `<input>` focused | yes, all |
| Frontmost app while the panel is shown | unchanged (Arc stayed frontmost): **the app is not activated** |
| Frontmost app after hide | unchanged, so focus "returns" because it never left |
| `show()` until the page has reset and focused its input (25 runs) | **p50 5.8 ms, max 11.5 ms** |
| Filter by typing, Esc hides, re-show clears the query | yes |
| Enter opens the dashboard on the chosen session, with its terminal rendered | yes |
| Picking again while the dashboard is open switches session in place | yes |
| Memory, physical footprint (`footprint`, what Activity Monitor shows), idle: panel preloaded + menu bar | **~90 MB** (main 39, GPU 21, network 8, panel renderer 22) |
| Same, with the dashboard open on a live terminal | **~217 MB** (GPU process grows to ~113, dashboard renderer ~32) |
| Daemon (separate process, Node) | ~56 MB |

**Swift comparison (measured 2026-10-11, same method):** the released `Shepherd.app` v0.8.2 (ad-hoc signed,
downloaded from GitHub Releases, run on this Mac with Herdr not installed, so it sat idle with its panel preloaded)
has a physical footprint of **21 MB**, steady over 30 s. So Electron is about **4x** at idle (~90 MB) and about **10x**
with the dashboard open (~217 MB). Not measured: the Swift app with live Herdr sessions, which will add a little.

**Correction:** an earlier run of the spike reported "406 MB" from Electron's `workingSetSize`, which counts shared
framework pages and overstates the cost; ignore it. (RSS is similarly misleading: the Swift app's RSS is 90 MB but
its footprint is 21 MB.)

## Still needs a human (not safe to automate)

Tick these on a real desktop before deciding:

1. The real Hyper+W chord (with your Karabiner mapping) shows the panel.
2. **With another app frontmost, typing goes into the panel** (not into the other app) and the other
   app's menu bar stays active.
3. Over a **full-screen app** and on **another Space**: the panel appears there, not on a different Space.
4. Esc / clicking elsewhere hides it and you can keep typing in the app you were in, with no flicker.
5. Enter opens the dashboard in front; closing it returns you to what you were doing.
