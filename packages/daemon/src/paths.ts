import { homedir } from "node:os";
import { join } from "node:path";

export function shepherdHome(): string {
  return process.env.SHEPHERD_HOME ?? join(homedir(), ".shepherd");
}

export function socketPath(): string {
  return join(shepherdHome(), "shepherd.sock");
}
