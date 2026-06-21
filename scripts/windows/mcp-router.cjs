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
      return { route, path: url.slice(route.prefix.length) || "/" };
    }
  }
  return legacyRoute(url) || { route: defaultRoute, path: url };
}

function status(res) {
  const body = JSON.stringify(
    {
      ok: true,
      machine: machineSlug,
      routes: Object.fromEntries(routes.map((route) => [route.name, `${route.prefix}/* -> http://${route.targetHost}:${route.targetPort}/*`])),
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
  const headers = { ...req.headers, host: `${route.targetHost}:${route.targetPort}` };
  for (const name of ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"]) {
    delete headers[name];
  }

  const upstream = http.request(
    {
      host: route.targetHost,
      port: route.targetPort,
      method: req.method,
      path,
      headers,
    },
    (upRes) => {
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
