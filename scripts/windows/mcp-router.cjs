const fs = require("fs");
const http = require("http");
const os = require("os");

const configPath = process.argv[2];
const config = configPath ? JSON.parse(fs.readFileSync(configPath, "utf8").replace(/^\uFEFF/, "")) : {};
const devspaceEnabled = config.devspaceEnabled !== false;
const hermesEnabled = Boolean(config.hermesEnabled && config.hermesPort);
const devspacePort = Number(config.port || 7676);
const hermesPort = Number(config.hermesPort || 4750);
const listenHost = "127.0.0.1";
const listenPort = Number(config.routerPort || 8765);
const machineSlug = slug(config.machineSlug || os.hostname());

const configuredRoutes = Array.isArray(config.mcpRoutes) ? config.mcpRoutes : [];
const generatedRoutes = configuredRoutes.length
  ? configuredRoutes
  : [
      ...(devspaceEnabled ? [{ name: "devspace_chatgpt", targetPort: devspacePort }] : []),
      ...(hermesEnabled ? [{ name: "hermes_chatgpt", targetPort: hermesPort }] : []),
    ];
const routes = generatedRoutes
  .filter((route) => route && route.enabled !== false)
  .map((route) => ({
    name: route.name,
    prefix: route.prefix || `/${machineSlug}/${route.name}`,
    targetHost: route.targetHost || "127.0.0.1",
    targetPort: Number(route.targetPort),
    hostHeader: route.hostHeader || route.upstreamHostHeader || route.targetHostHeader || null,
  }))
  .sort((a, b) => b.prefix.length - a.prefix.length);
const defaultRoute = routes[0];

if (!defaultRoute) {
  throw new Error("No MCP routes configured.");
}

function slug(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function legacyRoute(url) {
  if (devspaceEnabled && url === "/mcp") {
    return { route: { name: "devspace_chatgpt", targetHost: "127.0.0.1", targetPort: devspacePort }, path: "/mcp" };
  }
  if (hermesEnabled && (url === "/hermes/mcp" || url.startsWith("/hermes/"))) {
    return { route: { name: "hermes_chatgpt", targetHost: "127.0.0.1", targetPort: hermesPort }, path: url.slice("/hermes".length) || "/" };
  }
  return null;
}

function pickRoute(url) {
  for (const route of routes) {
    if (url === route.prefix || url.startsWith(route.prefix + "/")) {
      const stripped = url.slice(route.prefix.length) || "/";
      // OAuth endpoints: ChatGPT expects /authorize under prefix, DevSpace has them at root.
      const oauthPaths = ["/authorize", "/token", "/revoke", "/register"];
      if (oauthPaths.includes(stripped)) {
        return { route, path: stripped, isOauth: true };
      }
      return { route, path: stripped };
    }
  }
  // .well-known OAuth discovery: ChatGPT looks for /<prefix>/path.
  if (url.startsWith("/.well-known/oauth-authorization-server/")) {
    const prefix = url.slice("/.well-known/oauth-authorization-server".length) || "/";
    for (const route of routes) {
      if (prefix === route.prefix || prefix.startsWith(route.prefix + "/") || prefix === "/" + machineSlug + "/" + route.name) {
        return { route, path: "/.well-known/oauth-authorization-server" };
      }
    }
  }
  return legacyRoute(url) || { route: defaultRoute, path: url };
}

function upstreamHostHeader(route, publicHost) {
  if (route.hostHeader) return String(route.hostHeader);
  // hermes-gpt is intentionally loopback-bound and rejects the public tunnel Host header.
  // Preserve DevSpace's public Host behavior for OAuth/resource metadata, but talk to
  // Hermes with the same Host header a direct local tunnel would use.
  if (route.name === "hermes_chatgpt") {
    return `${route.targetHost}:${route.targetPort}`;
  }
  return publicHost || `${route.targetHost}:${route.targetPort}`;
}

function status(res) {
  const publicHost = config.publicBaseUrl ? new URL(config.publicBaseUrl).host : null;
  const body = JSON.stringify(
    {
      ok: true,
      machine: machineSlug,
      routes: Object.fromEntries(routes.map((route) => [route.name, `${route.prefix}/* -> http://${route.targetHost}:${route.targetPort}/*`])),
      hostHeaders: Object.fromEntries(routes.map((route) => [route.name, upstreamHostHeader(route, publicHost)])),
      examples: Object.fromEntries(routes.map((route) => [route.name, `${route.prefix}/mcp`])),
    },
    null,
    2,
  );
  res.writeHead(200, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

const server = http.createServer((req, res) => {
  if (req.url === "/__router/status") return status(res);

  const { route, path } = pickRoute(req.url || "/");
  const publicHost = config.publicBaseUrl ? new URL(config.publicBaseUrl).host : `${route.targetHost}:${route.targetPort}`;
  const headers = { ...req.headers, host: upstreamHostHeader(route, publicHost) };
  for (const name of ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"]) {
    delete headers[name];
  }

  const isWellKnown = path === "/.well-known/oauth-authorization-server";

  const upstream = http.request(
    {
      host: route.targetHost,
      port: route.targetPort,
      method: req.method,
      path,
      headers,
    },
    (upRes) => {
      if (isWellKnown && upRes.statusCode === 200) {
        let body = "";
        upRes.on("data", (chunk) => { body += chunk; });
        upRes.on("end", () => {
          try {
            const meta = JSON.parse(body);
            const publicUrl = config.publicBaseUrl ? new URL(config.publicBaseUrl) : null;
            const origin = publicUrl ? publicUrl.origin : `http://${publicHost}`;
            const prefix = `/${machineSlug}/${route.name}`;
            const fixUrl = (url) => {
              if (!url) return url;
              const u = new URL(url);
              return `${origin}${prefix}${u.pathname}`;
            };
            meta.authorization_endpoint = fixUrl(meta.authorization_endpoint);
            meta.token_endpoint = fixUrl(meta.token_endpoint);
            meta.revocation_endpoint = fixUrl(meta.revocation_endpoint);
            meta.registration_endpoint = fixUrl(meta.registration_endpoint);
            body = JSON.stringify(meta);
          } catch {}
          res.writeHead(upRes.statusCode, { ...upRes.headers, "content-length": Buffer.byteLength(body), "x-mcp-router-target": route.name });
          res.end(body);
        });
        return;
      }
      res.writeHead(upRes.statusCode || 502, { ...upRes.headers, "x-mcp-router-target": route.name });
      upRes.pipe(res);
    },
  );

  upstream.on("error", (err) => {
    const body = JSON.stringify({ ok: false, target: route.name, error: err.message });
    res.writeHead(502, {
      "content-type": "application/json; charset=utf-8",
      "content-length": Buffer.byteLength(body),
      "x-mcp-router-target": route.name,
    });
    res.end(body);
  });

  req.pipe(upstream);
});

server.listen(listenPort, listenHost, () => {
  console.log(`mcp-router listening on http://${listenHost}:${listenPort}`);
});
