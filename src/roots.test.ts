import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { editFileTool, readFileTool, writeFileTool } from "./pi-tools.js";
import { AccessDeniedError, assertAllowedPath, expandHomePath, resolveAllowedPath } from "./roots.js";

const home = homedir();

assert.equal(expandHomePath("~"), home);
assert.equal(expandHomePath("~/personal/devspace"), resolve(home, "personal", "devspace"));
assert.equal(expandHomePath("~user/project"), "~user/project");
assert.equal(expandHomePath("$HOME/project"), "$HOME/project");

assert.equal(
  assertAllowedPath("~/personal/devspace", [join(home, "personal")]),
  resolve(home, "personal", "devspace"),
);

assert.equal(
  assertAllowedPath("~/personal/devspace", ["~/personal"]),
  resolve(home, "personal", "devspace"),
);

assert.equal(
  resolveAllowedPath("~/file.txt", "/workspace", ["/workspace"]),
  resolve("/workspace", "~/file.txt"),
);

if (process.platform === "win32") {
  assert.throws(
    () => assertAllowedPath("C:\\Users\\Administrator", ["G:\\Projects\\Dev\\Github\\devspace"]),
    /Path is outside allowed roots/,
  );
}

const fixture = mkdtempSync(join(tmpdir(), "devspace-roots-test-"));
try {
  const allowed = join(fixture, "allowed");
  const outside = join(fixture, "outside");
  const inside = join(allowed, "inside");
  mkdirSync(inside, { recursive: true });
  mkdirSync(outside);
  writeFileSync(join(outside, "sentinel.txt"), "outside unchanged\n");
  writeFileSync(join(inside, "sample.txt"), "inside original\n");
  const linkType = process.platform === "win32" ? "junction" : "dir";
  symlinkSync(outside, join(allowed, "escape"), linkType);
  symlinkSync(inside, join(allowed, "inside-link"), linkType);
  const alias = join(fixture, "allowed-alias");
  symlinkSync(allowed, alias, linkType);
  const dangling = join(allowed, "dangling");
  symlinkSync(join(outside, "missing"), dangling, linkType);

  for (const path of ["escape", "escape/sentinel.txt", "escape/new/nested.txt", "dangling", "dangling/new.txt"]) {
    assert.throws(() => resolveAllowedPath(path, allowed, [allowed]), AccessDeniedError);
  }
  assert.throws(() => assertAllowedPath(join(dangling, "new.txt"), [dangling]), AccessDeniedError);
  assert.throws(() => assertAllowedPath(join(outside, "sentinel.txt"), [allowed]), AccessDeniedError);

  for (const path of ["inside-link/sample.txt", "inside-link/new/nested.txt", "new/nested.txt"]) {
    assert.equal(resolveAllowedPath(path, allowed, [allowed]), resolve(allowed, path));
  }
  assert.equal(assertAllowedPath(join(alias, "inside", "sample.txt"), [alias]), join(alias, "inside", "sample.txt"));
  const missingRoot = join(allowed, "missing-root");
  assert.equal(assertAllowedPath(join(missingRoot, "new.txt"), [missingRoot]), join(missingRoot, "new.txt"));
  assert.equal(assertAllowedPath(join(alias, "new", "file.txt"), [alias]), join(alias, "new", "file.txt"));
  assert.throws(() => assertAllowedPath(join(alias, "escape", "new.txt"), [alias]), AccessDeniedError);

  if (process.platform !== "win32") {
    const fileLink = join(allowed, "file-link.txt");
    symlinkSync(join(outside, "sentinel.txt"), fileLink, "file");
    assert.throws(() => assertAllowedPath(fileLink, [allowed]), AccessDeniedError);
  }

  const context = { cwd: allowed, root: allowed };
  await assert.rejects(readFileTool({ path: "escape/sentinel.txt" }, context), AccessDeniedError);
  await assert.rejects(writeFileTool({ path: "escape/new/nested.txt", content: "escaped" }, context), AccessDeniedError);
  await assert.rejects(editFileTool({ path: "escape/sentinel.txt", edits: [{ oldText: "unchanged", newText: "changed" }] }, context), AccessDeniedError);
  await assert.rejects(writeFileTool({ path: "dangling/new.txt", content: "escaped" }, context), AccessDeniedError);
  assert.equal(readFileSync(join(outside, "sentinel.txt"), "utf8"), "outside unchanged\n");
  assert.equal(existsSync(join(outside, "new")), false);
  assert.equal(existsSync(join(outside, "missing")), false);

  const read = await readFileTool({ path: "inside-link/sample.txt" }, context);
  assert.equal(read.isError, undefined, JSON.stringify(read.content));
  assert.match(read.content.map((item) => item.type === "text" ? item.text : "").join("\n"), /inside original/);
  const written = await writeFileTool({ path: "new/nested.txt", content: "created\n" }, context);
  assert.equal(written.isError, undefined, JSON.stringify(written.content));
  const edited = await editFileTool({ path: "inside-link/sample.txt", edits: [{ oldText: "original", newText: "edited" }] }, context);
  assert.equal(edited.isError, undefined, JSON.stringify(edited.content));
  assert.equal(readFileSync(join(inside, "sample.txt"), "utf8"), "inside edited\n");
  assert.equal(readFileSync(join(allowed, "new", "nested.txt"), "utf8"), "created\n");
} finally {
  assert.equal(dirname(fixture), resolve(tmpdir()));
  assert.ok(basename(fixture).startsWith("devspace-roots-test-"));
  rmSync(fixture, { recursive: true, force: true });
}

console.log("roots: canonical containment and Pi read/write/edit checks passed");
