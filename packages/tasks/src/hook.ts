import { TaskStore } from "./store.ts";
import { taskContext } from "./task.ts";

interface SessionStartInput {
  session_id?: string;
  source?: string;
}

/**
 * SessionStart hook. Finds the task this session belongs to and returns the hook output that
 * injects the task's plan and log. A session that is not linked yet is linked when shepherd
 * started it for a task (SHEPHERD_TASK_ID), which also re-links after /clear, where the
 * session id changes but the pane keeps its environment.
 * Returns undefined when the session has no task.
 */
export function sessionStart(input: SessionStartInput, env: NodeJS.ProcessEnv, store: TaskStore): object | undefined {
  const sessionId = input.session_id;
  if (!sessionId) return undefined;
  let task = store.findBySession(sessionId);
  const envId = Number(env.SHEPHERD_TASK_ID);
  if (!task && Number.isInteger(envId) && envId > 0 && store.get(envId)) {
    task = store.update(envId, (t) => t.linkSession(sessionId));
  }
  if (!task) return undefined;
  return {
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: taskContext(task),
    },
  };
}
