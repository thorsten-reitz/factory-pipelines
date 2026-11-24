// Bewertung der Komponenten-Checks nach der Health-Konvention (siehe README von factory-pipelines):
// "down", sobald eine kritische Komponente ausfällt, "degraded" bei einer unkritischen, sonst "ok".
function overallStatus(checks) {
  const values = Object.values(checks);
  if (values.some((c) => c.critical && c.status !== "ok")) return "down";
  if (values.some((c) => c.status !== "ok")) return "degraded";
  return "ok";
}

// Führt einen Check mit Zeitlimit aus und misst die Dauer
async function timed(fn, { critical = true, timeoutMs = 2000 } = {}) {
  const start = Date.now();
  let timer;
  try {
    await Promise.race([
      fn(),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`timeout after ${timeoutMs} ms`)), timeoutMs); }),
    ]);
    return { status: "ok", critical, latencyMs: Date.now() - start };
  } catch (err) {
    return { status: "down", critical, latencyMs: Date.now() - start, error: String(err.message || err) };
  } finally {
    clearTimeout(timer);
  }
}

module.exports = { overallStatus, timed };
