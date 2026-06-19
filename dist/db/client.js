import { mkdirSync } from "node:fs";
import { join } from "node:path";
import Database from "better-sqlite3";
import { drizzle } from "drizzle-orm/better-sqlite3";
import * as schema from "./schema.js";
export function databasePath(stateDir) {
    return join(stateDir, "devspace.sqlite");
}
export function openDatabase(stateDir) {
    mkdirSync(stateDir, { recursive: true });
    const sqlite = new Database(databasePath(stateDir));
    sqlite.pragma("journal_mode = WAL");
    sqlite.pragma("foreign_keys = ON");
    return {
        sqlite,
        db: createDrizzleDatabase(sqlite),
        close: () => sqlite.close(),
    };
}
function createDrizzleDatabase(sqlite) {
    return drizzle(sqlite, { schema });
}
