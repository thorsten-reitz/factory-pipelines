# factory-pipelines

Wiederverwendbare CI/CD-Workflows, Host-Skripte und Vorlagen für Projekte der [Software Factory](https://github.com/thorsten-reitz/software-factory). Umsetzung der Betriebskonventionen aus [`docs/proposals/betriebskonventionen.md`](https://github.com/thorsten-reitz/software-factory/blob/main/docs/proposals/betriebskonventionen.md).

> **Version 0.1:** Stufe **compose** (Docker Compose + Caddy auf einer VM). Kamal und k3s folgen in 0.2 und 0.3.

## Was ein Projekt davon hat

Im Projekt liegen nur ein kurzer Aufruf und eine Konfigurationsdatei:

```yaml
# .github/workflows/delivery.yml   (Vorlage: templates/delivery.yml)
jobs:
  delivery:
    uses: thorsten-reitz/factory-pipelines/.github/workflows/delivery.yml@v0.1.0
    with:
      config: .factory/delivery.json
```

Damit läuft bei jedem PR und jedem Push auf `main`:

1. **Konfiguration:** `.factory/delivery.json` wird gegen [`schema/delivery.schema.json`](schema/delivery.schema.json) geprüft. Ein Tippfehler bricht sofort mit klarer Meldung ab.
2. **Checks:** `install` und alle `checks` aus `.factory/setup.json`, dieselben, die `factory-verify` in der Factory ausführt.
3. **Image und Test-Umgebung:** Image bauen, mit Wegwerf-Diensten aus `deploy/compose.test.yml` starten, `/livez` und `/readyz` prüfen, den Befehl `e2e` aus `.factory/setup.json` gegen die laufende App ausführen. Optional Sicherheits-Scan.
4. **staging** (Push auf `main`, `autoDeploy`): das Image wird nach GHCR gepusht und mit seinem Digest auf den Host gebracht.
5. **production:** derselbe Digest, nach Freigabe an der GitHub-Umgebung `production`.

Von Hand (Actions → delivery → Run workflow): `deploy`, `rollback` oder `restore` für staging oder production.

## Ablauf eines Deploys

```
GitHub Actions                                Host (Nutzer deploy, Forced Command)
──────────────                                ────────────────────────────────────
Secrets per OIDC aus Infisical
  (DEPLOY_HOST, DEPLOY_SSH_KEY …)
Bündel: compose.yml, delivery.json,   ──ssh──▶ factory-host: Bündel prüfen
        release.json (Image@Digest)            factory-secrets: Secrets → /run/secrets/<app>/ (tmpfs)
                                               Image ziehen (Registry-Token nur für diesen Pull)
                                               production: Backup vor dem Deploy
                                               Migrationen (Dienst "migrate")
                                               Umschalten, docker compose up
                                               Health-Gate: /readyz, /health (Status + Commit)
                                                 grün → Caddy-Site, alte Releases aufräumen
                                                 rot  → automatischer Rollback auf die vorige Version
Health-Check von außen über die Domain
Kommentar im PR bzw. Issue "deploy-failed"
```

Der SSH-Schlüssel kann nur `deploy`, `rollback`, `restore` und `status` auslösen, keine Shell. Mit `--allow` lässt er sich auf bestimmte Apps beschränken.

## Konventionen für das Projekt

| Datei | Zweck |
|---|---|
| `.factory/delivery.json` | Betriebsschalter, Schema: [`schema/delivery.schema.json`](schema/delivery.schema.json), Beispiel: [`templates/delivery.example.json`](templates/delivery.example.json) |
| `.factory/setup.json` | `install`, `checks`, optional `e2e` (bekommt `BASE_URL`) |
| `Dockerfile` | nimmt `ARG GIT_COMMIT` und `ARG APP_VERSION` an und gibt sie über `/health` aus |
| `deploy/compose.yml` | staging/production, Vorlage: [`templates/compose.yml`](templates/compose.yml) |
| `deploy/compose.test.yml` | Test-Umgebung in CI, Vorlage: [`templates/compose.test.yml`](templates/compose.test.yml) |
| `.github/workflows/delivery.yml` | Aufruf, Vorlage: [`templates/delivery.yml`](templates/delivery.yml) |
| `.github/CODEOWNERS` | Review für `.github/`, `.factory/delivery.json`, `deploy/` |

**Health-Endpunkte** (jede App):

| Endpunkt | Prüft | Antwort |
|---|---|---|
| `/livez` | nur den Prozess | 200 |
| `/readyz` | kritische Abhängigkeiten, Migrationen aktuell | 200 oder 503, ohne Details |
| `/health` | jede Hauptkomponente, nur mit `Authorization: Bearer $HEALTH_TOKEN` | JSON, siehe unten |

```json
{ "status": "ok | degraded | down", "version": "1.8.2", "commit": "a1b2c3d…",
  "checks": { "db": { "status": "ok", "critical": true, "latencyMs": 4 } } }
```

`down`, sobald eine kritische Komponente ausfällt, `degraded` bei einer unkritischen. Der Deploy gilt nur als erfolgreich, wenn `status` nicht `down` ist und `commit` zum ausgerollten Commit passt.

**Secrets:** Namen in Infisical je Umgebung (`staging`, `production`):

| Name | Zweck |
|---|---|
| `DEPLOY_HOST`, `DEPLOY_SSH_KEY`, `DEPLOY_HOST_KEY` | Ziel-Host, privater Deploy-Schlüssel, öffentlicher Host-Schlüssel (`ssh-ed25519 AAAA…`) |
| `HEALTH_TOKEN` | Zugang zu `/health` |
| `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Backup-Ziel, z. B. `s3:https://<endpoint>/<bucket>/<projekt>/<umgebung>` |
| `HC_PING_URL`, `HC_PING_URL_BACKUP`, `HC_PING_URL_RESTORE_TEST` | Heartbeats an healthchecks.io (optional) |
| alle App-Secrets | z. B. `DATABASE_URL`, `POSTGRES_PASSWORD` |

In GitHub stehen nur die Variablen `INFISICAL_PROJECT_ID` und `INFISICAL_IDENTITY_ID`, keine Secrets.

## Infisical einrichten (einmal pro Projekt)

1. Projekt in Infisical Cloud **EU** (`https://eu.infisical.com`) mit den Umgebungen `staging` und `production` (Slugs genau so).
2. Maschinen-Identität für GitHub mit **OIDC Auth**: Issuer und Discovery-URL `https://token.actions.githubusercontent.com`, Audience `https://github.com/<owner>`, Subject je Umgebung `repo:<owner>/<repo>:environment:staging` bzw. `…:environment:production`. Lesezugriff nur auf die jeweilige Umgebung.
   **Achtung:** Repos, die nach dem 15. Juli 2026 angelegt wurden, haben ein Subject mit IDs (`repo:<owner>@<id>/<repo>@<id>:…`). Das richtige Präfix zeigt `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` (`sub_claim_prefix`).
3. Maschinen-Identität je Host mit **Universal Auth**, Lesezugriff auf die Umgebungen, die auf dem Host laufen.
4. Im GitHub-Repo die Variablen `INFISICAL_PROJECT_ID` und `INFISICAL_IDENTITY_ID` setzen.

## Host einrichten

Neuen Server mit [`templates/cloud-init/compose-host.yaml`](templates/cloud-init/compose-host.yaml) als User-Data anlegen. cloud-init installiert Docker, Caddy, die Infisical-CLI und ruft [`host/install.sh`](host/install.sh) auf. Ein SSH-Login ist dafür nicht nötig.

Auf dem **Factory-Server** (dort läuft Caddy schon als Teil der Factory) einmalig:

```bash
curl -fsSL https://github.com/thorsten-reitz/factory-pipelines/archive/refs/tags/v0.1.0.tar.gz | tar -xz -C /opt
/opt/factory-pipelines-0.1.0/host/install.sh --pubkey "ssh-ed25519 AAAA… deploy" \
  --sites-dir /etc/software-factory/sites.d --caddy-reload true
```

Der Runner der Factory übernimmt neue Site-Dateien aus `sites.d` beim nächsten Durchlauf.

Was der Host danach tut:

| Unit | Wann | Was |
|---|---|---|
| `factory-secrets-boot.service` | beim Start, vor Docker | Secrets aller Apps nach `/run/secrets/` |
| `factory-backup.timer` | täglich 03:00–04:00 | Backup aller Apps (restic → S3), alte Stände nach `backup.retention` aufräumen |
| `factory-restore-test.timer` | sonntags | neuester Stand in Wegwerf-Datenbank bzw. -Ordner, Plausibilität |
| `factory-heartbeat.timer` | alle 5 Minuten | Heartbeat an healthchecks.io, nur wenn `/readyz` grün ist |

**Host-Identität:** Das Client-Secret aus der User-Data wird beim ersten Start mit `systemd-creds` verschlüsselt und im Klartext gelöscht. Die User-Data bleibt beim Anbieter abrufbar, deshalb danach in Infisical ein neues Client-Secret erzeugen und das alte widerrufen. Das neue kommt per `systemd-creds encrypt` auf den Host. Ein Ablauf ohne diesen Schritt ist für eine spätere Version vorgesehen.

## Backup und Restore

- Was gesichert wird, steht in `state`: Postgres (`pg_dump` → `restic backup --stdin`) und Volumes. Ein restic-Repository pro Projekt und Umgebung.
- Täglich per Timer, in production zusätzlich vor jedem Deploy. Aufbewahrung nach `backup.retention` (Standard 7 täglich, 4 wöchentlich, 12 monatlich).
- Restore: Actions → delivery → Run workflow → `restore`, Umgebung, Snapshot `latest` oder ein Datum (`2026-11-20`, `2026-11-20T14:00`: neuester Stand bis dahin). production braucht die Freigabe an der Umgebung.
- Das restic-Passwort liegt in Infisical **und** offline. Ohne Offline-Kopie sind die Backups bei Verlust des Infisical-Zugangs wertlos.

## Selbsttest

[`self-test.yml`](.github/workflows/self-test.yml) prüft jede Änderung:

- **lint:** actionlint, shellcheck, [bats-Tests](tests/host.bats) der Host-Skripte, Schema, Compose-Dateien
- **delivery:** der echte `delivery.yml` mit der [Demo-App](examples/demo-app): Konfiguration, Checks, Image, Test-Umgebung, E2E
- **host-e2e:** der Runner als Deploy-Host (lokale Registry, MinIO als S3, Test-Secrets): Deploy, kaputtes Image mit automatischem Rollback, manueller Rollback, Backup, Restore, Restore-Test

Nicht im Selbsttest, erst im Pilotprojekt geprüft: die echte Anbindung an Infisical (OIDC in Actions, Universal Auth auf dem Host), GHCR-Pull mit Token, Caddy mit echter Domain.

## Versionen

`scripts/release.sh vX.Y.Z` setzt den Tag, zieht den Major-Tag (`v0`) nach und legt das Release an; `publish.yml` baut das Backup-Image (`ghcr.io/thorsten-reitz/factory-pipelines/backup:vX.Y.Z`). Projekte pinnen eine genaue Version, Renovate schlägt Updates als PR vor ([`templates/renovate.json`](templates/renovate.json)).

Der Workflow lädt seine Actions aus genau dem Commit, den das Projekt aufruft (über `job_workflow_sha` im OIDC-Token). Version von Workflow und Actions können so nicht auseinanderlaufen.

## Grenzen von 0.1

- Nur Stufe `compose`. `kamal` und `k3s` werden geprüft, aber nicht deployt.
- Ein Image pro Projekt, eine Plattform (die erste aus `image.platforms`).
- Point-in-Time-Recovery (`state[].pitr`) noch nicht umgesetzt.
- Watchdog-Probe per GitHub Actions und Alloy-Konfiguration für Observability fehlen noch.
- Secrets-Rotation wird erst beim nächsten Deploy bzw. Neustart wirksam.

## Lizenz

MIT
