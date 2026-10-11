import { describe, expect, it } from "vitest";
import { installedEvents, installHooks, stripHooks } from "../src/hooks.ts";

const commands = { event: 'node "/r/packages/daemon/src/hook-cli.ts"', sessionStart: 'node "/r/packages/tasks/src/cli.ts" hook session-start' };
const foreign = { type: "command", command: "~/.claude/hooks/other-tool.sh" };

describe("installHooks", () => {
  it("adds our hooks to empty settings", () => {
    const s = installHooks({}, commands);
    expect(installedEvents(s)).toEqual(["Notification", "PermissionRequest", "PostToolUse", "SessionEnd", "SessionStart", "Stop", "UserPromptSubmit"]);
    expect(s.hooks!.SessionStart).toEqual([{ matcher: "startup|resume|clear|compact", hooks: [{ type: "command", command: commands.sessionStart }] }]);
    expect(s.hooks!.Stop).toEqual([{ hooks: [{ type: "command", command: commands.event }] }]);
  });

  it("is idempotent, even when the paths change", () => {
    const once = installHooks({}, commands);
    expect(installHooks(once, commands)).toEqual(once);
    const moved = installHooks(once, { ...commands, event: 'node "/elsewhere/packages/daemon/src/hook-cli.ts"' });
    expect(moved.hooks!.Stop).toHaveLength(1);
    expect(JSON.stringify(moved)).not.toContain('"/r/packages/daemon');
  });

  it("leaves other settings and other tools' hooks alone", () => {
    const base = { model: "opus", hooks: { Stop: [{ hooks: [foreign] }], PreToolUse: [{ matcher: "Bash", hooks: [foreign] }] } };
    const s = installHooks(base, commands);
    expect(s.model).toBe("opus");
    expect(s.hooks!.PreToolUse).toEqual(base.hooks.PreToolUse);
    expect(s.hooks!.Stop).toHaveLength(2);
    expect(s.hooks!.Stop![0]).toEqual({ hooks: [foreign] });
  });

  it("uninstall removes only ours, and drops emptied events and the hooks key", () => {
    const base = { hooks: { Stop: [{ hooks: [foreign] }] } };
    expect(stripHooks(installHooks(base, commands))).toEqual(base);
    expect(stripHooks(installHooks({ a: 1 }, commands))).toEqual({ a: 1 });
  });

  it("removes our hook from an entry that also has a foreign hook, keeping the foreign one", () => {
    const mixed = { hooks: { Stop: [{ hooks: [foreign, { type: "command", command: commands.event }] }] } };
    expect(stripHooks(mixed)).toEqual({ hooks: { Stop: [{ hooks: [foreign] }] } });
  });

  it("does not mutate its input", () => {
    const base = { hooks: { Stop: [{ hooks: [foreign] }] } };
    const copy = structuredClone(base);
    installHooks(base, commands);
    stripHooks(base);
    expect(base).toEqual(copy);
  });
});
