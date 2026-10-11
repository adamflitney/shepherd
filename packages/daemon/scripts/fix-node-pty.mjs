// pnpm drops the executable bit from node-pty's prebuilt spawn-helper, which makes every
// spawn fail with "posix_spawnp failed". Put it back.
import { chmodSync, existsSync, readdirSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";

const require = createRequire(import.meta.url);
const root = dirname(require.resolve("node-pty/package.json"));
const prebuilds = join(root, "prebuilds");
if (existsSync(prebuilds)) {
  for (const dir of readdirSync(prebuilds)) {
    const helper = join(prebuilds, dir, "spawn-helper");
    if (existsSync(helper)) chmodSync(helper, 0o755);
  }
}
