#!/usr/bin/env node
// Claude Code hook entry point: forwards one hook payload to the daemon. It is deliberately tiny
// (no node-pty, no xterm) because it runs on every tool call, and it never fails: a hook that
// errors or hangs would hurt the session it is only meant to observe.
import net from "node:net";
import { socketPath } from "./paths.ts";

const DEADLINE_MS = 800;
const timer = setTimeout(() => process.exit(0), DEADLINE_MS);
timer.unref();

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c: string) => (input += c));
process.stdin.on("end", () => {
  let payload: unknown;
  try {
    payload = JSON.parse(input);
  } catch {
    return process.exit(0);
  }
  const socket = net.connect(socketPath());
  socket.on("error", () => process.exit(0)); // daemon not running
  socket.on("data", () => process.exit(0)); // any reply means it was received
  socket.on("connect", () => {
    socket.write(`${JSON.stringify({ id: 1, method: "hook.event", params: { payload, shepherdSessionId: process.env.SHEPHERD_SESSION_ID } })}\n`);
  });
});
