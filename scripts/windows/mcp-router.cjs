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
    service: route.service || route.kind || inferService(route.name),
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

const connectionWarnCount = Math.max(10, Number(config.routerConnectionWarnCount || 50));
const connectionCriticalCount = Math.max(connectionWarnCount + 1, Number(config.routerConnectionCriticalCount || 200));
const suspectIdleMs = Math.max(60_000, Number(config.routerSuspectIdleSeconds || 300) * 1000);
const idleSocketCleanupMs = Math.max(15_000, Number(config.routerIdleSocketCleanupSeconds || 120) * 1000);
const cleanupSweepMs = Math.min(30_000, Math.max(5_000, Math.floor(idleSocketCleanupMs / 4)));
const clientSockets = new Map();
const activeRequests = new Map();
let nextClientId = 1;
let nextRequestId = 1;
const connectionCounters = {
  requestsStarted: 0,
  requestsCompleted: 0,
  requestsAborted: 0,
  upstreamsDestroyed: 0,
  idleClientSocketsDestroyed: 0,
  lastCleanupAt: null,
};

function routeService(route) {
  return route && route.service ? route.service : inferService(route && route.name);
}

function markSocketActivity(socket) {
  const record = clientSockets.get(socket);
  if (record) {
    record.lastActivityAt = Date.now();
    record.idleConfirmations = 0;
  }
}

function connectionSnapshot() {
  const now = Date.now();
  const serviceNames = Array.from(new Set(routes.map(routeService).filter(Boolean)));
  const services = Object.fromEntries(serviceNames.map((service) => [service, {
    activeRequests: 0,
    suspectRequests: 0,
    oldestRequestSeconds: 0,
    longestIdleSeconds: 0,
  }]));
  for (const request of activeRequests.values()) {
    const service = request.service || "unknown";
    if (!services[service]) services[service] = { activeRequests: 0, suspectRequests: 0, oldestRequestSeconds: 0, longestIdleSeconds: 0 };
    const ageSeconds = Math.max(0, Math.floor((now - request.startedAt) / 1000));
    const idleSeconds = Math.max(0, Math.floor((now - request.lastActivityAt) / 1000));
    services[service].activeRequests += 1;
    services[service].oldestRequestSeconds = Math.max(services[service].oldestRequestSeconds, ageSeconds);
    services[service].longestIdleSeconds = Math.max(services[service].longestIdleSeconds, idleSeconds);
    if (now - request.lastActivityAt >= suspectIdleMs) services[service].suspectRequests += 1;
  }
  const openClientSockets = clientSockets.size;
  const idleClientSockets = Array.from(clientSockets.values()).filter((item) => item.activeRequests === 0).length;
  const maxActive = Math.max(0, ...Object.values(services).map((item) => item.activeRequests));
  const totalSuspect = Object.values(services).reduce((sum, item) => sum + item.suspectRequests, 0);
  const level = maxActive >= connectionCriticalCount || totalSuspect >= connectionCriticalCount ? "RED"
    : maxActive >= connectionWarnCount || totalSuspect > 0 ? "YELLOW"
    : "GREEN";
  const reason = level === "RED" ? "connection count or stale-request evidence is critical"
    : level === "YELLOW" ? "connection count or stale-request evidence needs attention"
    : "connection activity is within expected bounds";
  return {
    level,
    reason,
    openClientSockets,
    idleClientSockets,
    activeRequests: activeRequests.size,
    services,
    thresholds: {
      warnCount: connectionWarnCount,
      criticalCount: connectionCriticalCount,
      suspectIdleSeconds: Math.floor(suspectIdleMs / 1000),
      idleSocketCleanupSeconds: Math.floor(idleSocketCleanupMs / 1000),
      idleSocketConfirmations: 2,
    },
    cleanup: { ...connectionCounters },
  };
}

function slug(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function inferService(name) {
  if (String(name || "").startsWith("hermes_chatgpt")) return "hermes";
  if (String(name || "").startsWith("devspace_chatgpt")) return "devspace";
  return "";
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
  if (route.service === "hermes") {
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
      connections: connectionSnapshot(),
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
  const requestId = nextRequestId++;
  const now = Date.now();
  const service = routeService(route) || "unknown";
  const clientRecord = clientSockets.get(req.socket);
  if (clientRecord) {
    clientRecord.activeRequests += 1;
    clientRecord.lastActivityAt = now;
    clientRecord.lastService = service;
    clientRecord.idleConfirmations = 0;
  }
  const requestRecord = {
    id: requestId,
    service,
    route: route.name,
    startedAt: now,
    lastActivityAt: now,
    finished: false,
  };
  activeRequests.set(requestId, requestRecord);
  connectionCounters.requestsStarted += 1;
  const markRequestActivity = () => {
    requestRecord.lastActivityAt = Date.now();
    markSocketActivity(req.socket);
  };
  const finishRequest = (reason) => {
    if (requestRecord.finished) return;
    requestRecord.finished = true;
    activeRequests.delete(requestId);
    const socketRecord = clientSockets.get(req.socket);
    if (socketRecord) {
      socketRecord.activeRequests = Math.max(0, socketRecord.activeRequests - 1);
      socketRecord.lastActivityAt = Date.now();
    }
    if (reason === "completed") connectionCounters.requestsCompleted += 1;
    else connectionCounters.requestsAborted += 1;
  };

  req.on("data", markRequestActivity);

  let upstreamResponse = null;
  const destroyUpstream = () => {
    let destroyed = false;
    if (upstreamResponse && !upstreamResponse.destroyed) { upstreamResponse.destroy(); destroyed = true; }
    if (!upstream.destroyed) { upstream.destroy(); destroyed = true; }
    if (destroyed) {
      connectionCounters.upstreamsDestroyed += 1;
      connectionCounters.lastCleanupAt = new Date().toISOString();
    }
  };

  const upstream = http.request(
    {
      host: route.targetHost,
      port: route.targetPort,
      method: req.method,
      path,
      headers,
    },
    (upRes) => {
      upstreamResponse = upRes;
      upRes.on("data", markRequestActivity);
      if (isWellKnown && upRes.statusCode === 200) {
        let body = "";
        upRes.on("data", (chunk) => { body += chunk; });
        upRes.on("end", () => {
          try {
            const meta = JSON.parse(body);
            const publicUrl = config.publicBaseUrl ? new URL(config.publicBaseUrl) : null;
            const origin = publicUrl ? publicUrl.origin : `http://${publicHost}`;
            const prefix = route.prefix;
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
          if (res.destroyed || res.writableEnded) return;
          res.writeHead(upRes.statusCode, { ...upRes.headers, "content-length": Buffer.byteLength(body), "x-mcp-router-target": route.name });
          res.end(body);
        });
        return;
      }
      if (res.destroyed || res.writableEnded) {
        destroyUpstream();
        return;
      }
      res.writeHead(upRes.statusCode || 502, { ...upRes.headers, "x-mcp-router-target": route.name });
      upRes.pipe(res);
    },
  );

  upstream.on("socket", (socket) => socket.setKeepAlive(true, 30_000));
  req.once("aborted", () => { destroyUpstream(); finishRequest("aborted"); });
  res.once("finish", () => finishRequest("completed"));
  res.once("close", () => {
    if (!res.writableEnded) { destroyUpstream(); finishRequest("aborted"); }
  });

  upstream.on("error", (err) => {
    if (res.destroyed || res.writableEnded) return;
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

server.on("connection", (socket) => {
  socket.setKeepAlive(true, 30_000);
  const record = {
    id: nextClientId++,
    connectedAt: Date.now(),
    lastActivityAt: Date.now(),
    activeRequests: 0,
    idleConfirmations: 0,
    lastService: "",
  };
  clientSockets.set(socket, record);
  socket.on("data", () => markSocketActivity(socket));
  socket.once("close", () => clientSockets.delete(socket));
});

const idleCleanupTimer = setInterval(() => {
  const now = Date.now();
  for (const [socket, record] of clientSockets.entries()) {
    if (record.activeRequests > 0 || socket.destroyed) {
      record.idleConfirmations = 0;
      continue;
    }
    if (now - record.lastActivityAt < idleSocketCleanupMs) {
      record.idleConfirmations = 0;
      continue;
    }
    record.idleConfirmations += 1;
    if (record.idleConfirmations < 2) continue;
    socket.destroy();
    connectionCounters.idleClientSocketsDestroyed += 1;
    connectionCounters.lastCleanupAt = new Date().toISOString();
  }
}, cleanupSweepMs);
idleCleanupTimer.unref();

server.on("error", (error) => {
  if (error.code === "EADDRINUSE") {
    console.error(`FIXED PORT CONFLICT: MCP router requires http://${listenHost}:${listenPort}. Stop the owning process or explicitly reconfigure the router and every dependent route/client; the router will not move automatically.`);
  } else {
    console.error(`mcp-router failed: ${error.message}`);
  }
  process.exitCode = 1;
});

server.listen(listenPort, listenHost, () => {
  console.log(`mcp-router listening on http://${listenHost}:${listenPort}`);
});
