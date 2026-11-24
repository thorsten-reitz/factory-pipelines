#!/bin/sh
# factory-backup backup [tag] | restore <latest|YYYY-MM-DD[THH:MM]> | verify | check
#
# Läuft im Backup-Container, gestartet von factory-host. Erwartet:
#   /etc/factory/delivery.json   Konfiguration der App (state, backup.retention)
#   /run/secrets/app/            Secrets der App als Dateien (RESTIC_REPOSITORY, RESTIC_PASSWORD,
#                                AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, Datenbank-URL …)
#   /data/<volume>               Volumes aus state (beim Restore beschreibbar)
#   PROJECT_ENV                  z. B. shop-production; restic-Host-Name, trennt Apps im selben Repository
set -eu
CONFIG=/etc/factory/delivery.json
SECRETS=/run/secrets/app

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "FEHLER: $*"; exit 1; }

[ -f "$CONFIG" ] || die "$CONFIG fehlt"
[ -n "${PROJECT_ENV:-}" ] || die "PROJECT_ENV fehlt"
if [ -d "$SECRETS" ]; then
  for f in "$SECRETS"/*; do
    [ -f "$f" ] || continue
    k=$(basename "$f")
    case "$k" in ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;; esac
    v=$(cat "$f"; printf x); v=${v%x}
    export "$k=$v"
  done
fi
[ -n "${RESTIC_REPOSITORY:-}" ] || die "RESTIC_REPOSITORY fehlt in den Secrets"
[ -n "${RESTIC_PASSWORD:-}" ] || die "RESTIC_PASSWORD fehlt in den Secrets"
export RESTIC_REPOSITORY RESTIC_PASSWORD
export RESTIC_CACHE_DIR=/tmp/restic-cache

HOST="$PROJECT_ENV"

items() { jq -r '.state[]? | [.type, (.service // .name), (.urlEnv // "DATABASE_URL")] | @tsv' "$CONFIG"; }
url_of() { eval "printf '%s' \"\${$1:-}\""; }
pg_path() { echo "/postgres/$1.dump"; }

ensure_repo() {
  log "Prüfe restic-Repository $(printf '%s' "$RESTIC_REPOSITORY" | sed -E 's#//[^@/]*@#//#')"
  restic cat config >/dev/null 2>&1 && return 0
  log "restic-Repository anlegen: $RESTIC_REPOSITORY"
  restic init >/dev/null
}

# Snapshot-ID für einen Pfad: neuester Stand, optional bis zu einem Zeitpunkt
snapshot_for() {
  path="$1"; when="$2"
  if [ "$when" = latest ]; then
    restic snapshots --json --host "$HOST" --path "$path" | jq -r 'sort_by(.time) | last | .short_id // empty'
  else
    case "$when" in *T*) limit="$when:59" ;; *) limit="${when}T23:59:59" ;; esac
    restic snapshots --json --host "$HOST" --path "$path" \
      | jq -r --arg l "$limit" '[.[] | select(.time[0:19] <= $l)] | sort_by(.time) | last | .short_id // empty'
  fi
}

do_backup() {
  tag="${1:-manual}"
  ensure_repo
  items | while IFS="$(printf '\t')" read -r type name urlenv; do
    case "$type" in
      postgres)
        url=$(url_of "$urlenv"); [ -n "$url" ] || die "$urlenv fehlt in den Secrets"
        log "Sichere Datenbank $name"
        pg_dump --format=custom --no-owner "$url" \
          | restic backup --quiet --host "$HOST" --tag "$tag" --stdin --stdin-filename "postgres/$name.dump" \
          || die "Sicherung der Datenbank $name fehlgeschlagen"
        ;;
      volume)
        [ -d "/data/$name" ] || die "Volume $name ist nicht eingebunden"
        log "Sichere Volume $name"
        restic backup --quiet --host "$HOST" --tag "$tag" "/data/$name" || die "Sicherung von Volume $name fehlgeschlagen"
        ;;
    esac
  done
  daily=$(jq -r '.backup.retention.daily // 7' "$CONFIG")
  weekly=$(jq -r '.backup.retention.weekly // 4' "$CONFIG")
  monthly=$(jq -r '.backup.retention.monthly // 12' "$CONFIG")
  log "Aufräumen: $daily täglich, $weekly wöchentlich, $monthly monatlich"
  restic forget --quiet --host "$HOST" --group-by host,paths \
    --keep-daily "$daily" --keep-weekly "$weekly" --keep-monthly "$monthly" --prune
  log "Backup fertig"
}

do_restore() {
  when="${1:-latest}"
  items | while IFS="$(printf '\t')" read -r type name urlenv; do
    case "$type" in
      postgres)
        url=$(url_of "$urlenv"); [ -n "$url" ] || die "$urlenv fehlt in den Secrets"
        snap=$(snapshot_for "$(pg_path "$name")" "$when"); [ -n "$snap" ] || die "Kein Snapshot für Datenbank $name ($when)"
        log "Datenbank $name aus Snapshot $snap zurückspielen"
        restic dump "$snap" "$(pg_path "$name")" | pg_restore --clean --if-exists --no-owner --single-transaction -d "$url" \
          || die "Restore der Datenbank $name fehlgeschlagen"
        ;;
      volume)
        snap=$(snapshot_for "/data/$name" "$when"); [ -n "$snap" ] || die "Kein Snapshot für Volume $name ($when)"
        log "Volume $name aus Snapshot $snap zurückspielen"
        restic restore "$snap" --target / --include "/data/$name" --delete --quiet || die "Restore von Volume $name fehlgeschlagen"
        ;;
    esac
  done
  log "Restore fertig"
}

# Restore-Test: neuester Stand in eine Wegwerf-Datenbank bzw. einen Wegwerf-Ordner, dann Plausibilität
do_verify() {
  restic check --read-data-subset=5% >/dev/null || die "restic check meldet Fehler im Repository"
  items | while IFS="$(printf '\t')" read -r type name urlenv; do
    case "$type" in
      postgres)
        snap=$(snapshot_for "$(pg_path "$name")" latest); [ -n "$snap" ] || die "Kein Snapshot für Datenbank $name"
        log "Restore-Test Datenbank $name (Snapshot $snap)"
        rm -rf /tmp/verify-pg && mkdir -p /tmp/verify-pg /tmp/verify-sock && chown postgres:postgres /tmp/verify-pg /tmp/verify-sock
        su postgres -s /bin/sh -c "initdb -D /tmp/verify-pg -U postgres --auth=trust >/dev/null && pg_ctl -D /tmp/verify-pg -o \"-c listen_addresses='' -k /tmp/verify-sock\" -w start >/dev/null" \
          || die "Wegwerf-Datenbank startet nicht"
        restic dump "$snap" "$(pg_path "$name")" > /tmp/verify.dump
        createdb -h /tmp/verify-sock -U postgres verify
        pg_restore --no-owner -h /tmp/verify-sock -U postgres -d verify /tmp/verify.dump >/dev/null \
          || { su postgres -s /bin/sh -c "pg_ctl -D /tmp/verify-pg stop -m fast" >/dev/null; die "Dump von $name lässt sich nicht einspielen"; }
        tables=$(psql -h /tmp/verify-sock -U postgres -d verify -tAc "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')")
        su postgres -s /bin/sh -c "pg_ctl -D /tmp/verify-pg stop -m fast" >/dev/null
        rm -rf /tmp/verify-pg /tmp/verify.dump
        [ "${tables:-0}" -gt 0 ] || die "Datenbank $name: Snapshot enthält keine Tabellen"
        log "Datenbank $name: $tables Tabellen eingespielt"
        ;;
      volume)
        snap=$(snapshot_for "/data/$name" latest); [ -n "$snap" ] || die "Kein Snapshot für Volume $name"
        log "Restore-Test Volume $name (Snapshot $snap)"
        rm -rf /tmp/verify-vol && mkdir -p /tmp/verify-vol
        restic restore "$snap" --target /tmp/verify-vol --quiet || die "Volume $name lässt sich nicht zurückspielen"
        expected=$(restic ls --json "$snap" | jq -s '[.[] | select(.struct_type == "node" and .type == "file")] | length')
        actual=$(find /tmp/verify-vol -type f | wc -l | tr -d ' ')
        rm -rf /tmp/verify-vol
        [ "$expected" = "$actual" ] || die "Volume $name: $actual statt $expected Dateien zurückgespielt"
        log "Volume $name: $actual Dateien zurückgespielt"
        ;;
    esac
  done
  log "Restore-Test bestanden"
}

# Ergebnis an den Watchdog melden (healthchecks.io): Erfolg an die URL, Fehlschlag an <URL>/fail.
# Die URLs kommen aus den Secrets der App; ohne URL wird nichts gemeldet.
ping() {
  [ -n "$1" ] || return 0
  curl -fsS -m 10 --retry 3 "${1%/}$2" >/dev/null 2>&1 || log "Meldung an den Watchdog fehlgeschlagen"
}
reported() {
  url="$1"; shift
  if ( "$@" ); then ping "$url" ""; else ping "$url" /fail; exit 1; fi
}

case "${1:-}" in
  backup) shift; reported "${HC_PING_URL_BACKUP:-}" do_backup "${1:-manual}" ;;
  restore) shift; reported "${HC_PING_URL_RESTORE:-}" do_restore "${1:-latest}" ;;
  verify) reported "${HC_PING_URL_RESTORE_TEST:-}" do_verify ;;
  check) restic check ;;
  *) echo "Aufruf: factory-backup backup [tag] | restore <latest|YYYY-MM-DD[THH:MM]> | verify | check" >&2; exit 2 ;;
esac
