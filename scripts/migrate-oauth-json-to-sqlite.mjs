import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
const Database = createRequire(resolve(process.cwd(), "package.json"))("better-sqlite3");

export function migrateOAuthJsonToSqlite(jsonPath, sqlitePath) {
  const snapshot = JSON.parse(readFileSync(jsonPath, "utf8"));
  if (
    snapshot?.version !== 1 ||
    !Array.isArray(snapshot.clients) ||
    !Array.isArray(snapshot.accessTokens) ||
    !Array.isArray(snapshot.refreshTokens)
  ) {
    throw new Error("Unsupported oauth-state.json format; expected version 1 arrays.");
  }

  const sqlite = new Database(sqlitePath);
  try {
    sqlite.pragma("foreign_keys = ON");
    const migrate = sqlite.transaction(() => {
      sqlite.exec(`
        create table if not exists oauth_clients (
          client_id text primary key, client_json text not null, issued_at integer not null
        );
        create table if not exists oauth_access_tokens (
          token_hash text primary key, client_id text not null, scopes_json text not null,
          expires_at integer not null, resource text,
          foreign key (client_id) references oauth_clients(client_id) on delete cascade
        );
        create table if not exists oauth_refresh_tokens (
          token_hash text primary key, client_id text not null, scopes_json text not null,
          expires_at integer not null, resource text,
          foreign key (client_id) references oauth_clients(client_id) on delete cascade
        );
      `);

      const expected = {
        clients: snapshot.clients.length,
        accessTokens: snapshot.accessTokens.length,
        refreshTokens: snapshot.refreshTokens.length,
      };
      const current = counts(sqlite);
      if (Object.values(current).some((count) => count !== 0)) {
        if (JSON.stringify(current) === JSON.stringify(expected) && snapshotMatches(sqlite, snapshot)) return current;
        throw new Error(`SQLite OAuth tables are not empty: ${JSON.stringify(current)}`);
      }

      const addClient = sqlite.prepare(
        "insert into oauth_clients (client_id, client_json, issued_at) values (?, ?, ?)",
      );
      for (const [clientId, client] of snapshot.clients) {
        if (!clientId || client?.client_id !== clientId) throw new Error("Invalid OAuth client entry.");
        addClient.run(clientId, JSON.stringify(client), client.client_id_issued_at ?? 0);
      }

      const importTokens = (entries, table) => {
        const add = sqlite.prepare(
          `insert into ${table} (token_hash, client_id, scopes_json, expires_at, resource)
           values (?, ?, ?, ?, ?)`,
        );
        for (const [hash, token] of entries) {
          if (!hash || !token?.clientId || !Array.isArray(token.scopes) || !Number.isInteger(token.expiresAt)) {
            throw new Error(`Invalid ${table} entry.`);
          }
          add.run(hash, token.clientId, JSON.stringify(token.scopes), token.expiresAt, token.resource ?? null);
        }
      };
      importTokens(snapshot.accessTokens, "oauth_access_tokens");
      importTokens(snapshot.refreshTokens, "oauth_refresh_tokens");

      const actual = counts(sqlite);
      if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        throw new Error(`OAuth migration count mismatch: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
      }
      return actual;
    });
    return migrate.immediate();
  } finally {
    sqlite.close();
  }
}

function counts(sqlite) {
  return {
    clients: sqlite.prepare("select count(*) count from oauth_clients").get().count,
    accessTokens: sqlite.prepare("select count(*) count from oauth_access_tokens").get().count,
    refreshTokens: sqlite.prepare("select count(*) count from oauth_refresh_tokens").get().count,
  };
}

function snapshotMatches(sqlite, snapshot) {
  return (
    snapshot.clients.every(([id, client]) =>
      sqlite.prepare("select client_json from oauth_clients where client_id = ?").get(id)?.client_json === JSON.stringify(client),
    ) &&
    [["oauth_access_tokens", snapshot.accessTokens], ["oauth_refresh_tokens", snapshot.refreshTokens]].every(
      ([table, entries]) => entries.every(([hash, token]) => {
        const row = sqlite.prepare(
          `select client_id, scopes_json, expires_at, resource from ${table} where token_hash = ?`,
        ).get(hash);
        return row &&
          row.client_id === token.clientId &&
          row.scopes_json === JSON.stringify(token.scopes) &&
          row.expires_at === token.expiresAt &&
          row.resource === (token.resource ?? null);
      }),
    )
  );
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  const [, , jsonPath, sqlitePath] = process.argv;
  if (!jsonPath || !sqlitePath) throw new Error("Usage: node migrate-oauth-json-to-sqlite.mjs <oauth-state.json> <devspace.sqlite>");
  console.log(JSON.stringify(migrateOAuthJsonToSqlite(jsonPath, sqlitePath)));
}
