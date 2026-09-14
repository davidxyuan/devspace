import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { loadConfig } from "./config.js";
import { createReviewCheckpointManager } from "./review-checkpoints.js";
import { ProcessSessionManager } from "./process-sessions.js";
import { createMcpServer } from "./server.js";
import { SqliteWorkspaceStore } from "./workspace-store.js";
import { WorkspaceRegistry } from "./workspaces.js";

interface Session {
  client: Client;
  server: ReturnType<typeof createMcpServer>;
}

test("three independent MCP conversations can work concurrently in one checkout when paths do not conflict", async () => {
  const root = await mkdtemp(join(tmpdir(), "devspace-server-concurrency-"));
  const project = join(root, "project");
  const agentDir = join(root, "agent");
  const stateDir = join(root, ".state");
  await mkdir(join(project, "parallel", "a"), { recursive: true });
  await mkdir(join(project, "parallel", "b"), { recursive: true });
  await mkdir(join(project, "parallel", "c"), { recursive: true });
  await mkdir(agentDir, { recursive: true });
  await writeFile(join(agentDir, "AGENTS.md"), "global instructions\n");
  await writeFile(join(project, "AGENTS.md"), "project instructions\n");
  await writeFile(join(project, "parallel", "a", "input.txt"), "alpha\n");

  const config = loadConfig({
    DEVSPACE_CONFIG_DIR: join(root, ".config"),
    DEVSPACE_ALLOWED_ROOTS: root,
    DEVSPACE_WORKTREE_ROOT: join(root, ".worktrees"),
    DEVSPACE_AGENT_DIR: agentDir,
    DEVSPACE_WIDGETS: "full",
    DEVSPACE_TOOL_MODE: "full",
    DEVSPACE_SUBAGENTS: "0",
    DEVSPACE_OAUTH_OWNER_TOKEN: "test-owner-token-that-is-long-enough",
    PORT: "1",
  });
  const store = new SqliteWorkspaceStore(stateDir);
  const workspaces = new WorkspaceRegistry(config, store);
  const reviewCheckpoints = createReviewCheckpointManager();
  const processSessions = new ProcessSessionManager();
  const sessions: Session[] = [];

  async function createSession(name: string): Promise<Session> {
    const server = createMcpServer(
      config,
      workspaces,
      reviewCheckpoints,
      processSessions,
      () => [],
      [],
    );
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name, version: "1.0.0" });
    await Promise.all([client.connect(clientTransport), server.connect(serverTransport)]);
    const session = { client, server };
    sessions.push(session);
    return session;
  }

  async function open(client: Client, conversation: string): Promise<string> {
    const result = await client.callTool({
      name: "open_workspace",
      arguments: { path: project },
      _meta: { "openai/session": conversation },
    } as Parameters<Client["callTool"]>[0]);
    assert.notEqual(result.isError, true);
    const structured = result.structuredContent as Record<string, unknown> | undefined;
    assert.equal(typeof structured?.workspaceId, "string");
    return structured?.workspaceId as string;
  }

  async function runDelay(client: Client, workspaceId: string, workingDirectory: string, label: string) {
    const result = await client.callTool({
      name: "bash",
      arguments: {
        workspaceId,
        workingDirectory,
        command: `node -e "setTimeout(()=>console.log('${label}'),900)"`,
        timeout: 5,
      },
    });
    assert.notEqual(result.isError, true, `${label} shell call failed`);
  }

  try {
    const [sessionA, sessionB, sessionC] = await Promise.all([
      createSession("parallel-chat-a"),
      createSession("parallel-chat-b"),
      createSession("parallel-chat-c"),
    ]);
    const [workspaceA, workspaceB, workspaceC] = await Promise.all([
      open(sessionA.client, "chat-a"),
      open(sessionB.client, "chat-b"),
      open(sessionC.client, "chat-c"),
    ]);
    assert.equal(new Set([workspaceA, workspaceB, workspaceC]).size, 3, "independent conversations unexpectedly shared one workspace record");

    const startedAt = Date.now();
    await Promise.all([
      (async () => {
        const read = await sessionA.client.callTool({
          name: "read",
          arguments: { workspaceId: workspaceA, path: "parallel/a/input.txt" },
        });
        assert.notEqual(read.isError, true);
        await runDelay(sessionA.client, workspaceA, "parallel/a", "chat-a-done");
      })(),
      (async () => {
        const write = await sessionB.client.callTool({
          name: "write",
          arguments: { workspaceId: workspaceB, path: "parallel/b/output.txt", content: "beta\n" },
        });
        assert.notEqual(write.isError, true);
        await runDelay(sessionB.client, workspaceB, "parallel/b", "chat-b-done");
      })(),
      runDelay(sessionC.client, workspaceC, "parallel/c", "chat-c-done"),
    ]);
    const elapsedMs = Date.now() - startedAt;

    assert.equal(await readFile(join(project, "parallel", "b", "output.txt"), "utf8"), "beta\n");
    assert.ok(elapsedMs < 2200, `three independent conversations appear serialized; elapsed=${elapsedMs}ms`);
    console.log(`PASS: 3 MCP conversations completed independent read/write/test work concurrently in ${elapsedMs} ms.`);
  } finally {
    for (const session of sessions) {
      await session.client.close().catch(() => undefined);
      await session.server.close().catch(() => undefined);
    }
    store.close();
    await rm(root, { recursive: true, force: true });
  }
});
