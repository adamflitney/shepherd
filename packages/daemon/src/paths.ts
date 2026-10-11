import { homedir } from "node:os";
import { join } from "node:path";

export function shepherdHome(): string {
  return process.env.SHEPHERD_HOME ?? join(homedir(), ".shepherd");
}

export function socketPath(): string {
  return join(shepherdHome(), "shepherd.sock");
}

export function tokenPath(): string {
  return join(shepherdHome(), "web-token");
}

/** Loopback port for the web client. */
export function webPort(): number {
  const n = Number(process.env.SHEPHERD_WEB_PORT);
  return Number.isInteger(n) && n >= 0 && n < 65536 && process.env.SHEPHERD_WEB_PORT ? n : 7330;
}
