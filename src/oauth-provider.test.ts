import { strict as assert } from "node:assert";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Response } from "express";
import type { AuthorizationParams } from "@modelcontextprotocol/sdk/server/auth/provider.js";
import { SingleUserOAuthProvider, type OAuthConfig } from "./oauth-provider.js";

const ownerToken = "owner-token-for-oauth-state-test";
const resourceServerUrl = new URL("https://devspace.example.test/mcp");
const redirectUri = "https://chatgpt.com/aip/g-test/oauth/callback";
const resource = new URL("https://devspace.example.test/mcp");

const config: OAuthConfig = {
  ownerToken,
  accessTokenTtlSeconds: 3600,
  refreshTokenTtlSeconds: 30 * 24 * 60 * 60,
  scopes: ["devspace"],
  allowedRedirectHosts: ["chatgpt.com"],
};

const authorizationParams: AuthorizationParams = {
  redirectUri,
  codeChallenge: "test-code-challenge",
  scopes: ["devspace"],
  state: "test-state",
  resource,
};

const stateDir = mkdtempSync(join(tmpdir(), "devspace-oauth-state-"));

try {
  const provider = new SingleUserOAuthProvider(config, resourceServerUrl, stateDir);
  const client = provider.clientsStore.registerClient({
    client_name: "ChatGPT",
    redirect_uris: [redirectUri],
  });

  const authorizationCode = await authorizeAndCaptureCode(provider, client);
  const tokens = await provider.exchangeAuthorizationCode(
    client,
    authorizationCode,
    undefined,
    redirectUri,
    resource,
  );
  assert.ok(tokens.refresh_token);

  const restartedProvider = new SingleUserOAuthProvider(config, resourceServerUrl, stateDir);
  assert.deepEqual(
    restartedProvider.clientsStore.getClient(client.client_id)?.redirect_uris,
    [redirectUri],
  );

  const accessInfo = await restartedProvider.verifyAccessToken(tokens.access_token);
  assert.equal(accessInfo.clientId, client.client_id);
  assert.deepEqual(accessInfo.scopes, ["devspace"]);
  assert.equal(accessInfo.resource?.href, resource.href);

  const refreshedTokens = await restartedProvider.exchangeRefreshToken(
    client,
    tokens.refresh_token,
    ["devspace"],
    resource,
  );
  const restartedAgainProvider = new SingleUserOAuthProvider(config, resourceServerUrl, stateDir);
  const refreshedAccessInfo = await restartedAgainProvider.verifyAccessToken(
    refreshedTokens.access_token,
  );

  assert.equal(refreshedAccessInfo.clientId, client.client_id);
  assert.deepEqual(refreshedAccessInfo.scopes, ["devspace"]);
} finally {
  rmSync(stateDir, { recursive: true, force: true });
}

const expiredStateDir = mkdtempSync(join(tmpdir(), "devspace-oauth-expired-state-"));
try {
  const expiredClientId = "devspace-expired-token-client";
  writeFileSync(
    join(expiredStateDir, "oauth-state.json"),
    JSON.stringify(
      {
        version: 1,
        clients: [
          [
            expiredClientId,
            {
              client_id: expiredClientId,
              client_id_issued_at: Math.floor(Date.now() / 1000) - 3600,
              client_name: "ChatGPT",
              redirect_uris: [redirectUri],
              token_endpoint_auth_method: "none",
              grant_types: ["authorization_code", "refresh_token"],
              response_types: ["code"],
            },
          ],
        ],
        accessTokens: [
          [
            "expired-access-token-hash",
            {
              clientId: expiredClientId,
              scopes: ["devspace"],
              expiresAt: 1,
              resource: resource.href,
            },
          ],
        ],
        refreshTokens: [],
      },
      null,
      2,
    ),
    "utf8",
  );

  const provider = new SingleUserOAuthProvider(config, resourceServerUrl, expiredStateDir);
  assert.equal(provider.clientsStore.getClient(expiredClientId)?.client_name, "ChatGPT");

  const persisted = JSON.parse(
    readFileSync(join(expiredStateDir, "oauth-state.json"), "utf8"),
  ) as { accessTokens: unknown[] };
  assert.deepEqual(persisted.accessTokens, []);
} finally {
  rmSync(expiredStateDir, { recursive: true, force: true });
}

async function authorizeAndCaptureCode(
  provider: SingleUserOAuthProvider,
  client: ReturnType<SingleUserOAuthProvider["clientsStore"]["registerClient"]>,
): Promise<string> {
  let redirectTarget: string | undefined;
  const response = {
    req: {
      method: "POST",
      body: {
        owner_token: ownerToken,
      },
    },
    status() {
      return this;
    },
    setHeader() {
      return this;
    },
    send() {
      return this;
    },
    redirect(status: number, url: string) {
      assert.equal(status, 302);
      redirectTarget = url;
      return this;
    },
  } as unknown as Response;

  await provider.authorize(client, authorizationParams, response);
  assert.ok(redirectTarget);

  const redirectedUrl = new URL(redirectTarget);
  assert.equal(redirectedUrl.searchParams.get("state"), authorizationParams.state);

  const code = redirectedUrl.searchParams.get("code");
  assert.ok(code);
  return code;
}
