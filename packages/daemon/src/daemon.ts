import { mkdirSync } from "node:fs";
import { SessionManager } from "./manager.ts";
import { shepherdHome, socketPath } from "./paths.ts";
import { DaemonServer } from "./server.ts";

export async function runDaemon(): Promise<void> {
  mkdirSync(shepherdHome(), { recursive: true });
  const manager = new SessionManager();
  const server = new DaemonServer(manager, socketPath());
  await server.listen();
  process.stderr.write(`shepherd daemon listening on ${socketPath()} (pid ${process.pid})\n`);
  const stop = async () => {
    manager.shutdown();
    await server.close();
    process.exit(0);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}
