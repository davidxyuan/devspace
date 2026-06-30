import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { createServer as createHttpServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadConfig } from "./config.js";
import { createServer as createDevSpaceServer } from "./server.js";

const stateDir = mkdtempSync(join(tmpdir(), "devspace-server-auth-test-"));
const publicBaseUrl = "https://example.ngrok-free.dev/tyo/devspace_chatgpt";
const { app } = createDevSpaceServer(
  loadConfig({
    DEVSPACE_ALLOWED_ROOTS: process.cwd(),
    DEVSPACE_CONFIG_DIR: stateDir,
    DEVSPACE_LOG_REQUESTS: "0",
    DEVSPACE_OAUTH_OWNER_TOKEN: "test-owner-token-that-is-long-enough",
    DEVSPACE_PUBLIC_BASE_URL: publicBaseUrl,
    DEVSPACE_STATE_DIR: stateDir,
  }),
);
const httpServer = createHttpServer(app);

await new Promise<void>((resolve) => httpServer.listen(0, "127.0.0.1", resolve));

try {
  const address = httpServer.address();
  assert.equal(typeof address, "object");
  assert.ok(address);
  const { port } = address as AddressInfo;
  const baseUrl = `http://127.0.0.1:${port}`;

  const metadataResponse = await fetch(`${baseUrl}/.well-known/oauth-protected-resource/tyo/devspace_chatgpt/mcp`);
  assert.equal(metadataResponse.status, 200);
  const metadata = await metadataResponse.json();
  assert.equal(metadata.resource, `${publicBaseUrl}/mcp`);
  assert.deepEqual(metadata.authorization_servers, [`${publicBaseUrl}/`]);

  const unauthorizedResponse = await fetch(`${baseUrl}/mcp`);
  assert.equal(unauthorizedResponse.status, 401);
  assert.match(
    unauthorizedResponse.headers.get("www-authenticate") ?? "",
    /resource_metadata="https:\/\/example\.ngrok-free\.dev\/\.well-known\/oauth-protected-resource\/tyo\/devspace_chatgpt\/mcp"/,
  );
} finally {
  await new Promise<void>((resolve, reject) => {
    httpServer.close((error) => (error ? reject(error) : resolve()));
  });
}
