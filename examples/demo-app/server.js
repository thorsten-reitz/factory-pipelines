// Beispiel-App für die Selbsttests von factory-pipelines. Bewusst ohne Framework.
//   GET  /livez            Prozess lebt
//   GET  /readyz           Datenbank erreichbar und Migrationen aktuell
//   GET  /health           Status pro Komponente (Bearer HEALTH_TOKEN)
//   GET  /notes, POST /notes {text}
//   GET  /files/:name, PUT /files/:name
const http = require("node:http");
const fs = require("node:fs/promises");
const path = require("node:path");
const { Pool } = require("pg");
const { overallStatus, timed } = require("./health");
const { pendingMigrations } = require("./migrate");

const PORT = Number(process.env.PORT || 3000);
const UPLOADS = process.env.UPLOADS_DIR || "/data/uploads";
const BROKEN = process.env.APP_BROKEN === "1";
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 5 });

const send = (res, code, body) => {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};
const readBody = (req) => new Promise((resolve, reject) => {
  const chunks = [];
  let size = 0;
  req.on("data", (c) => { size += c.length; if (size > 1_000_000) { reject(new Error("too large")); req.destroy(); } else chunks.push(c); });
  req.on("end", () => resolve(Buffer.concat(chunks)));
  req.on("error", reject);
});
const safeName = (name) => /^[A-Za-z0-9._-]{1,100}$/.test(name) && !name.startsWith(".");

async function ready() {
  if (BROKEN) throw new Error("broken build (APP_BROKEN=1)");
  await pool.query("select 1");
  if ((await pendingMigrations(pool)).length > 0) throw new Error("migrations pending");
}

async function health(req, res) {
  const expected = process.env.HEALTH_TOKEN;
  if (!expected || req.headers.authorization !== `Bearer ${expected}`) return send(res, 401, { error: "unauthorized" });
  const checks = {
    db: await timed(() => pool.query("select 1")),
    storage: await timed(async () => {
      const probe = path.join(UPLOADS, ".health-probe");
      await fs.writeFile(probe, String(Date.now()));
      await fs.rm(probe);
    }),
  };
  if (BROKEN) checks.app = { status: "down", critical: true, error: "broken build" };
  const status = overallStatus(checks);
  send(res, status === "down" ? 503 : 200, {
    status,
    version: process.env.APP_VERSION || "0.0.0",
    commit: process.env.APP_COMMIT || "",
    checks,
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://localhost");
    const [, first, second] = url.pathname.split("/");
    if (req.method === "GET" && url.pathname === "/livez") return send(res, 200, { status: "ok" });
    if (req.method === "GET" && url.pathname === "/readyz") {
      try { await ready(); return send(res, 200, { status: "ok" }); } catch { return send(res, 503, { status: "down" }); }
    }
    if (req.method === "GET" && url.pathname === "/health") return await health(req, res);
    if (first === "notes" && !second) {
      if (req.method === "GET") return send(res, 200, (await pool.query("select id, text from notes order by id")).rows);
      if (req.method === "POST") {
        const { text } = JSON.parse((await readBody(req)).toString() || "{}");
        if (typeof text !== "string" || !text) return send(res, 400, { error: "text required" });
        const { rows } = await pool.query("insert into notes(text) values ($1) returning id, text", [text]);
        return send(res, 201, rows[0]);
      }
    }
    if (first === "files" && second && safeName(second)) {
      const file = path.join(UPLOADS, second);
      if (req.method === "PUT") { await fs.writeFile(file, await readBody(req)); return send(res, 201, { name: second }); }
      if (req.method === "GET") {
        try { res.writeHead(200, { "content-type": "application/octet-stream" }); return res.end(await fs.readFile(file)); }
        catch { return send(res, 404, { error: "not found" }); }
      }
    }
    send(res, 404, { error: "not found" });
  } catch (err) {
    console.error(err);
    if (!res.headersSent) send(res, 500, { error: "internal error" });
  }
});

server.listen(PORT, "0.0.0.0", () => console.log(`demo-app listening on ${PORT} (commit ${process.env.APP_COMMIT || "?"})`));
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => server.close(() => pool.end().then(() => process.exit(0))));
