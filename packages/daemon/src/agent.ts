import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface AgentLaunch {
  sessionId: string;
  resume: boolean;
  prompt?: string;
}

export interface AgentSpec {
  command: string;
  args(launch: AgentLaunch): string[];
  /** True when a conversation with this id exists on disk and can be resumed. */
  canResume(cwd: string, sessionId: string): boolean;
}

/** Claude Code encodes a project directory as its path with every non-alphanumeric char as "-". */
export function claudeProjectDir(cwd: string, home = homedir()): string {
  return join(home, ".claude", "projects", cwd.replace(/[^a-zA-Z0-9]/g, "-"));
}

export const claudeAgent: AgentSpec = {
  command: "claude",
  args({ sessionId, resume, prompt }) {
    const args = resume ? ["--resume", sessionId] : ["--session-id", sessionId];
    if (prompt) args.push(prompt);
    return args;
  },
  canResume(cwd, sessionId) {
    return existsSync(join(claudeProjectDir(cwd), `${sessionId}.jsonl`));
  },
};
