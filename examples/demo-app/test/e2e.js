// E2E gegen eine laufende App (BASE_URL). Läuft in CI gegen die Test-Umgebung.
const assert = require("node:assert/strict");
const BASE = (process.env.BASE_URL || "http://localhost:8080").replace(/\/$/, "");
const TOKEN = process.env.HEALTH_TOKEN || "test-health-token";

(async () => {
  assert.equal((await fetch(`${BASE}/livez`)).status, 200, "/livez");
  assert.equal((await fetch(`${BASE}/readyz`)).status, 200, "/readyz");
  assert.equal((await fetch(`${BASE}/health`)).status, 401, "/health ohne Token");
  const health = await (await fetch(`${BASE}/health`, { headers: { authorization: `Bearer ${TOKEN}` } })).json();
  assert.equal(health.status, "ok", JSON.stringify(health));
  assert.ok(health.checks.db && health.checks.storage, "Checks für db und storage");

  const created = await fetch(`${BASE}/notes`, { method: "POST", body: JSON.stringify({ text: "e2e" }) });
  assert.equal(created.status, 201);
  const notes = await (await fetch(`${BASE}/notes`)).json();
  assert.ok(notes.some((n) => n.text === "e2e"), "Notiz gespeichert");

  assert.equal((await fetch(`${BASE}/files/e2e.txt`, { method: "PUT", body: "hallo" })).status, 201);
  assert.equal(await (await fetch(`${BASE}/files/e2e.txt`)).text(), "hallo");
  console.log("E2E bestanden");
})().catch((err) => { console.error(err); process.exit(1); });
