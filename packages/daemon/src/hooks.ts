// Registering shepherd's hooks in a Claude Code settings.json, without disturbing anyone else's.

export interface HookCommands {
  /** Forwards hook events to the daemon (attention state). */
  event: string;
  /** Injects task context when a session starts. */
  sessionStart: string;
}

interface HookEntry {
  matcher?: string;
  hooks?: { type?: string; command?: string }[];
}
type Settings = { hooks?: Record<string, HookEntry[]> } & Record<string, unknown>;

/** A command is ours if it runs one of these scripts. */
const OURS = [/src\/hook-cli\.ts/, /src\/cli\.ts"? hook session-start/];
const isOurs = (command: string | undefined) => !!command && OURS.some((re) => re.test(command));

const EVENT_HOOKS: { event: string; matcher?: string }[] = [
  { event: "Notification", matcher: "" },
  { event: "PermissionRequest", matcher: "" },
  { event: "Stop" },
  { event: "UserPromptSubmit" },
  { event: "PostToolUse", matcher: "" }, // a finished tool is how we learn a permission was answered
  { event: "SessionEnd" },
];

export function stripHooks(settings: Settings): Settings {
  const out: Settings = structuredClone(settings);
  const hooks = out.hooks;
  if (!hooks) return out;
  for (const [event, entries] of Object.entries(hooks)) {
    if (!Array.isArray(entries)) continue;
    hooks[event] = entries.flatMap((entry) => {
      if (!Array.isArray(entry.hooks)) return [entry];
      const rest = entry.hooks.filter((h) => !isOurs(h.command));
      return rest.length ? [{ ...entry, hooks: rest }] : [];
    });
    if (hooks[event]!.length === 0) delete hooks[event];
  }
  if (Object.keys(hooks).length === 0) delete out.hooks;
  return out;
}

/** Idempotent: removes our old entries first, leaves every other tool's entries alone. */
export function installHooks(settings: Settings, commands: HookCommands): Settings {
  const out = stripHooks(settings);
  const hooks = (out.hooks ??= {});
  const add = (event: string, command: string, matcher?: string) => {
    (hooks[event] ??= []).push({ ...(matcher !== undefined ? { matcher } : {}), hooks: [{ type: "command", command }] });
  };
  for (const h of EVENT_HOOKS) add(h.event, commands.event, h.matcher);
  add("SessionStart", commands.sessionStart, "startup|resume|clear|compact");
  return out;
}

/** Events that currently have one of our hooks registered. */
export function installedEvents(settings: Settings): string[] {
  return Object.entries(settings.hooks ?? {})
    .filter(([, entries]) => Array.isArray(entries) && entries.some((e) => e.hooks?.some((h) => isOurs(h.command))))
    .map(([event]) => event)
    .sort();
}
