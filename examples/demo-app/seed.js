// Synthetische Daten für staging (environments.staging.data = "seed"). Läuft bei jedem staging-Deploy
// nach den Migrationen, deshalb idempotent: legt nur an, was fehlt. Keine echten Personendaten.
const { Pool } = require("pg");

(async () => {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  await pool.query("insert into notes(text) select 'beispiel-aus-seed' where not exists (select 1 from notes where text = 'beispiel-aus-seed')");
  console.log("seed up to date");
  await pool.end();
})().catch((err) => { console.error(err); process.exit(1); });
