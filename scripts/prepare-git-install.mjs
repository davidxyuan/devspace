import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

if (process.env.DEVSPACE_SKIP_PREPARE === "1") {
  process.exit(0);
}

const root = dirname(fileURLToPath(new URL("../package.json", import.meta.url)));
const npmCommand = process.platform === "win32" ? "npm.cmd" : "npm";
const viteBin = join(
  root,
  "node_modules",
  ".bin",
  process.platform === "win32" ? "vite.cmd" : "vite",
);

if (!existsSync(viteBin)) {
  run(npmCommand, ["ci", "--include=dev", "--no-audit", "--no-fund"], {
    ...process.env,
    DEVSPACE_SKIP_PREPARE: "1",
    npm_config_global: "false",
  });
}

run(npmCommand, ["run", "build"], {
  ...process.env,
  npm_config_global: "false",
});

function run(command, args, env) {
  const result = spawnSync(command, args, {
    cwd: root,
    env,
    shell: process.platform === "win32",
    stdio: "inherit",
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}
