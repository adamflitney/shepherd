# @shepherd/web

Browser client for the daemon: session list with attention state, a terminal pane per session, a
new-session dialog. Vanilla TypeScript + Vite, no framework yet.

    pnpm install && pnpm --filter @shepherd/web build     # the daemon serves dist/
    pnpm --filter @shepherd/web dev                       # vite dev server, proxies /ws to 127.0.0.1:7330

`src/rpc.ts` is the reconnecting WebSocket client, `src/terminal.ts` the xterm.js / ghostty-web adapter,
`src/main.ts` the app. Note that ghostty-web's WASM is loaded from our own origin (`?url` import) because
its default inlines it as a `data:` URL, which the page's CSP blocks.
