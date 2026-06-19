import { eq } from "drizzle-orm";
import { openDatabase } from "./db/client.js";
import { workspaceSessions, } from "./db/schema.js";
export class SqliteWorkspaceStore {
    database;
    constructor(stateDir) {
        this.database = openDatabase(stateDir);
        this.migrate();
    }
    createSession(input) {
        const now = new Date().toISOString();
        const session = {
            id: input.id,
            root: input.root,
            status: "active",
            mode: input.mode ?? "checkout",
            sourceRoot: input.sourceRoot,
            baseRef: input.baseRef,
            baseSha: input.baseSha,
            managed: input.managed ?? false,
            createdAt: now,
            lastUsedAt: now,
        };
        this.database.db
            .insert(workspaceSessions)
            .values({
            id: session.id,
            root: session.root,
            status: session.status,
            mode: session.mode,
            sourceRoot: session.sourceRoot ?? null,
            baseRef: session.baseRef ?? null,
            baseSha: session.baseSha ?? null,
            managed: String(session.managed),
            createdAt: session.createdAt,
            lastUsedAt: session.lastUsedAt,
        })
            .run();
        return session;
    }
    getSession(id) {
        const row = this.database.db
            .select()
            .from(workspaceSessions)
            .where(eq(workspaceSessions.id, id))
            .get();
        return row ? rowToWorkspaceSession(row) : undefined;
    }
    touchSession(id) {
        this.database.db
            .update(workspaceSessions)
            .set({ lastUsedAt: new Date().toISOString() })
            .where(eq(workspaceSessions.id, id))
            .run();
    }
    close() {
        this.database.close();
    }
    migrate() {
        this.database.sqlite.exec(`
      create table if not exists workspace_sessions (
        id text primary key,
        root text not null,
        status text not null default 'active',
        mode text not null default 'checkout',
        source_root text,
        base_ref text,
        base_sha text,
        managed text not null default 'false',
        created_at text not null,
        last_used_at text not null
      );

      create index if not exists workspace_sessions_root_idx
        on workspace_sessions(root, last_used_at desc);

      create index if not exists workspace_sessions_status_idx
        on workspace_sessions(status, last_used_at desc);

      create table if not exists loaded_agent_files (
        workspace_session_id text not null,
        path text not null,
        content_hash text not null,
        content text not null,
        loaded_at text not null,
        last_seen_at text not null,
        primary key (workspace_session_id, path),
        foreign key (workspace_session_id)
          references workspace_sessions(id)
          on delete cascade
      );

      create index if not exists loaded_agent_files_path_idx
        on loaded_agent_files(path);
    `);
        this.addColumnIfMissing("workspace_sessions", "mode", "text not null default 'checkout'");
        this.addColumnIfMissing("workspace_sessions", "source_root", "text");
        this.addColumnIfMissing("workspace_sessions", "base_ref", "text");
        this.addColumnIfMissing("workspace_sessions", "base_sha", "text");
        this.addColumnIfMissing("workspace_sessions", "managed", "text not null default 'false'");
    }
    addColumnIfMissing(table, column, definition) {
        const columns = this.database.sqlite.prepare(`pragma table_info(${table})`).all();
        if (columns.some((existingColumn) => existingColumn.name === column))
            return;
        this.database.sqlite.exec(`alter table ${table} add column ${column} ${definition}`);
    }
}
export function createWorkspaceStore(stateDir) {
    return new SqliteWorkspaceStore(stateDir);
}
function rowToWorkspaceSession(row) {
    return {
        id: row.id,
        root: row.root,
        status: row.status,
        mode: row.mode === "worktree" ? "worktree" : "checkout",
        sourceRoot: row.sourceRoot ?? undefined,
        baseRef: row.baseRef ?? undefined,
        baseSha: row.baseSha ?? undefined,
        managed: row.managed === "true",
        createdAt: row.createdAt,
        lastUsedAt: row.lastUsedAt,
    };
}
