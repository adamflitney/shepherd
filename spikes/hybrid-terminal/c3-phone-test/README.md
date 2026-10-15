# Phone terminal test (C3, 2026-10-13)

Tests a terminal on a real phone through Tailscale: the spike bridge and holder (`../c1-wsbridge`) plus a purpose-built
xterm.js page (`web/index.html`).

- Build: `cd ../c1-wsbridge && swift build`.
- Vendor files the page expects under `<web dir>/vendor/`: `xterm.js` and `xterm.css` from `@xterm/xterm@5.5.0`, and
  `addon-fit.js` from `@xterm/addon-fit@0.10.0` (copy from `node_modules`; not committed).
- Replace `__WORK_DIR__` in `web/index.html` with the directory you pass to `--allow-cwd`.
- Run the holder: `ptyd daemon --home <dir>`. Run the bridge: `wsbridge --port <p> --holder <dir>/ptyd.sock
  --token-file <file> --allow-host <name>.<tailnet>.ts.net --owner <tailscale login> --allow-cwd <dir> --web <web dir>`.
- Expose it with `tailscale serve --bg --https=8443 http://127.0.0.1:<p>` (not 443 if Mobile Access uses it). Open
  `https://<name>.<tailnet>.ts.net:8443/#<token>` on the phone; `qr.swift` turns that link into a QR image.
- `probe.js` checks the WebSocket through the real proxy (valid token, wrong token, foreign Origin).
- Clean up: stop both processes, `tailscale serve --https=8443 off`, delete the token file.

Result so far: works, but the first version was clunky (keyboard hid the terminal; idle disconnects were silent). The page
here is the fixed version (thin header, controls hidden while the keyboard is up, disconnect banner, heartbeat and
auto-reconnect), not yet re-tested on a phone.
