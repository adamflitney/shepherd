import { defineConfig } from "vite";

// In dev, proxy the WebSocket to a running daemon so `pnpm dev` works against the real thing.
export default defineConfig({
  base: "./",
  build: { outDir: "dist", sourcemap: true, target: "es2022" },
  server: { proxy: { "/ws": { target: "ws://127.0.0.1:7330", ws: true } } },
});
