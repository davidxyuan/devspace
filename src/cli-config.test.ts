import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { loadDevspaceFiles } from "./user-config.js";
import { writeTestDevspaceConfig } from "./test-support/config.js";

test("config set shellPath stores a path with spaces and clears it", (t) => {
  const configDir = mkdtempSync(join(tmpdir(), "devspace-cli-shell-test-"));
  t.after(() => rmSync(configDir, { recursive: true, force: true }));
  const env = { ...process.env, DEVSPACE_CONFIG_DIR: configDir };
  const shellPath = join(configDir, "Custom Git", "bash.exe");

  const setShell = (value: string) =>
    execFileSync(process.execPath, ["bin/devspace.js", "config", "set", "shellPath", value], { env });

  assert.match(setShell("null").toString(), /already unset/);
  setShell(shellPath);
  assert.equal(loadDevspaceFiles(env).config.tools.shellPath, shellPath);
  setShell("null");
  assert.equal(loadDevspaceFiles(env).config.tools.shellPath, undefined);
});

test("config set tells users to restart the running server", () => {
  const configDir = mkdtempSync(join(tmpdir(), "devspace-cli-config-test-"));

  try {
    const env = { ...process.env, ...writeTestDevspaceConfig(configDir) };

    const stdout = execFileSync(
      "node",
      ["bin/devspace.js", "config", "set", "publicBaseUrl", "https://example.com"],
      { encoding: "utf8", env },
    );

    assert.match(stdout, /Updated .*config\.jsonc/);
    assert.match(stdout, /Restart `devspace serve` to apply this change/);
    assert.equal(loadDevspaceFiles(env).config.server.publicBaseUrl, "https://example.com");
  } finally {
    rmSync(configDir, { recursive: true, force: true });
  }
});
