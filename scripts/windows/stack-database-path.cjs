"use strict";
// Resolve paths through the installed runtime's public configuration/storage
// contract. Importing these modules must not open or migrate the database.
const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

async function resolveDatabase(cli, installDir) {
  let root = path.dirname(path.resolve(cli));
  while (!fs.existsSync(path.join(root, "package.json"))) {
    const parent = path.dirname(root);
    if (parent === root) throw new Error("Cannot identify DevSpace runtime package.");
    root = parent;
  }
  if (JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8")).name !== "@waishnav/devspace")
    throw new Error("Unrecognized DevSpace runtime package.");
  const load = file => import(pathToFileURL(path.join(root, "dist", file)).href);
  const cwd = process.cwd();
  try {
    process.chdir(path.dirname(path.resolve(cli)));
    const { loadConfig } = await load("config.js");
    const { devspaceConfigDir } = await load("user-config.js");
    const { databasePath } = await load("db/client.js");
    const configDir = path.resolve(devspaceConfigDir(process.env));
    if (fs.realpathSync.native(configDir).toLowerCase() !== fs.realpathSync.native(installDir).toLowerCase())
      throw new Error("Runtime configuration directory differs from the managed installation.");
    const stateDir = loadConfig(process.env).stateDir;
    if (typeof stateDir !== "string" || !path.isAbsolute(stateDir)) throw new Error("Runtime did not return an absolute state directory.");
    const db = path.resolve(databasePath(stateDir));
    if (path.dirname(db).toLowerCase() !== path.resolve(stateDir).toLowerCase() || path.basename(db) !== "devspace.sqlite")
      throw new Error("Unsupported database layout; activation requires a compatible rollback contract.");
    return db;
  } finally { process.chdir(cwd); }
}

if (require.main === module) {
  resolveDatabase(process.argv[2], process.argv[3]).then(value => process.stdout.write(JSON.stringify({ databasePath: value })))
    .catch(() => { console.error("Cannot verify DevSpace database/configuration paths; update blocked before activation."); process.exitCode = 1; });
}
module.exports = { resolveDatabase };
