// Einfache Migrationen: migrations/*.sql in Namensreihenfolge, jede genau einmal, jede in einer Transaktion.
// Konvention: rückwärtsverträglich (Expand/Contract), damit ein App-Rollback ohne DB-Rollback funktioniert.
const fs = require("node:fs");
const path = require("node:path");

const DIR = path.join(__dirname, "migrations");
const files = () => fs.readdirSync(DIR).filter((f) => f.endsWith(".sql")).sort();

async function applied(pool) {
  await pool.query("create table if not exists schema_migrations (name text primary key, applied_at timestamptz not null default now())");
  return new Set((await pool.query("select name from schema_migrations")).rows.map((r) => r.name));
}

async function pendingMigrations(pool) {
  const done = await applied(pool);
  return files().filter((f) => !done.has(f));
}

async function migrate(pool) {
  for (const name of await pendingMigrations(pool)) {
    const client = await pool.connect();
    try {
      await client.query("begin");
      await client.query(fs.readFileSync(path.join(DIR, name), "utf8"));
      await client.query("insert into schema_migrations(name) values ($1)", [name]);
      await client.query("commit");
      console.log(`migration applied: ${name}`);
    } catch (err) {
      await client.query("rollback");
      throw err;
    } finally {
      client.release();
    }
  }
}

module.exports = { pendingMigrations };

if (require.main === module) {
  const { Pool } = require("pg");
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  migrate(pool)
    .then(() => { console.log("migrations up to date"); return pool.end(); })
    .catch((err) => { console.error(err); process.exit(1); });
}
