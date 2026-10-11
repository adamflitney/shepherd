import { existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ClientHub } from "./hub.ts";
import { SessionManager } from "./manager.ts";
import { shepherdHome, socketPath, tokenPath, webPort } from "./paths.ts";
import { DaemonServer } from "./server.ts";
import { loadOrCreateToken, WebServer } from "./web.ts";

/** The built web client, if `pnpm --filter @shepherd/web build` has been run. */
function defaultStaticDir(): string | undefined {
  const dist = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "web", "dist");
  return existsSync(join(dist, "index.html")) ? dist : undefined;
}

export async function runDaemon(): Promise<void> {
  mkdirSync(shepherdHome(), { recursive: true });
  const manager = new SessionManager();
  const hub = new ClientHub(manager);
  const server = new DaemonServer(manager, socketPath(), hub);
  await server.listen();
  process.stderr.write(`shepherd daemon listening on ${socketPath()} (pid ${process.pid})\n`);

  let web: WebServer | undefined;
  if (!process.env.SHEPHERD_NO_WEB) {
    const extra = (process.env.SHEPHERD_ALLOWED_HOSTS ?? "").split(",").map((h) => h.trim()).filter(Boolean);
    web = new WebServer({ hub, token: loadOrCreateToken(tokenPath()), port: webPort(), staticDir: defaultStaticDir(), allowedHosts: extra });
    const port = await web.listen();
    process.stderr.write(`web client on http://127.0.0.1:${port}/ (run \`shepctl web\` for the link)\n`);
  }

  const stop = async () => {
    manager.shutdown();
    hub.closeAll();
    await web?.close();
    await server.close();
    process.exit(0);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}
