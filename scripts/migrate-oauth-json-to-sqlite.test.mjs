import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Database from "better-sqlite3";
import { migrateOAuthJsonToSqlite } from "./migrate-oauth-json-to-sqlite.mjs";

const dir = mkdtempSync(join(tmpdir(), "devspace-oauth-migration-"));
const json = join(dir, "oauth-state.json");
const db = join(dir, "devspace.sqlite");
writeFileSync(json, JSON.stringify({
  version: 1,
  clients: [["client-1", { client_id: "client-1", client_id_issued_at: 123 }]],
  accessTokens: [["access-hash", { clientId: "client-1", scopes: ["devspace"], expiresAt: 999 }]],
  refreshTokens: [["refresh-hash", { clientId: "client-1", scopes: ["devspace"], expiresAt: 1999 }]],
}));

assert.deepEqual(migrateOAuthJsonToSqlite(json, db), { clients: 1, accessTokens: 1, refreshTokens: 1 });
assert.deepEqual(migrateOAuthJsonToSqlite(json, db), { clients: 1, accessTokens: 1, refreshTokens: 1 });
const sqlite = new Database(db, { readonly: true });
assert.equal(sqlite.prepare("select client_id from oauth_access_tokens").get().client_id, "client-1");
sqlite.close();

const badJson = join(dir, "bad-oauth-state.json");
const badDb = join(dir, "bad.sqlite");
writeFileSync(badJson, JSON.stringify({
  version: 1,
  clients: [["client-1", { client_id: "client-1", client_id_issued_at: 123 }]],
  accessTokens: [["bad", { clientId: "missing-client", scopes: ["devspace"], expiresAt: 999 }]],
  refreshTokens: [],
}));
assert.throws(() => migrateOAuthJsonToSqlite(badJson, badDb));
const rolledBack = new Database(badDb, { readonly: true });
assert.equal(
  rolledBack.prepare("select count(*) count from sqlite_master where type = 'table' and name like 'oauth_%'").get().count,
  0,
);
rolledBack.close();
console.log("OAuth JSON to SQLite migration tests passed.");
