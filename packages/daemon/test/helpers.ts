import { claudeAgent, type AgentSpec } from "../src/agent.ts";

export async function waitFor<T>(fn: () => T | undefined | false, what = "condition", ms = 5000): Promise<T> {
  const start = Date.now();
  for (;;) {
    const v = fn();
    if (v) return v;
    if (Date.now() - start > ms) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 15));
  }
}

/** Stands in for Claude Code: prints the args it was given and the shepherd env, then echoes input. */
export function fakeAgent(resumable: Set<string> = new Set()): AgentSpec {
  return {
    command: "/bin/sh",
    args: (launch) => ["-c", 'echo "ARGS: $@"; echo "TASK=$SHEPHERD_TASK_ID SESSION=$SHEPHERD_SESSION_ID"; exec sh', "sh", ...claudeAgent.args(launch)],
    canResume: (_cwd, id) => resumable.has(id),
  };
}
