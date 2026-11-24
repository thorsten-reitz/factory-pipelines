const test = require("node:test");
const assert = require("node:assert/strict");
const { overallStatus, timed } = require("../health");

test("down, sobald eine kritische Komponente ausfällt", () => {
  assert.equal(overallStatus({ db: { status: "down", critical: true }, mail: { status: "ok", critical: false } }), "down");
});

test("degraded bei einer unkritischen Komponente", () => {
  assert.equal(overallStatus({ db: { status: "ok", critical: true }, mail: { status: "down", critical: false } }), "degraded");
});

test("ok, wenn alles läuft", () => {
  assert.equal(overallStatus({ db: { status: "ok", critical: true } }), "ok");
});

test("timed meldet Zeitüberschreitung als down", async () => {
  const r = await timed(() => new Promise(() => {}), { timeoutMs: 50 });
  assert.equal(r.status, "down");
  assert.match(r.error, /timeout/);
});
