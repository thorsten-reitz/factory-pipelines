#!/usr/bin/env bash
# Prüfschritte des Selbsttests gegen die App demo-staging auf dem Runner-Host.
#   check.sh healthy <image-ref>   läuft die erwartete Version, und ist /health in Ordnung?
#   check.sh seed-data | fill | wipe | seeded
set -euo pipefail
BASE=http://127.0.0.1:5101
TOKEN=$(cat /run/secrets/demo-staging/HEALTH_TOKEN)
status() { sudo -u deploy /opt/factory/bin/factory-host status demo-staging; }

case "$1" in
  healthy)
    want="$2"
    out=$(status)
    echo "$out"
    got=$(head -1 <<<"$out" | jq -r .image)
    [ "$got" = "$want" ] || { echo "::error::Es läuft $got statt $want"; exit 1; }
    body=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/health")
    echo "$body" | jq .
    [ "$(jq -r .status <<<"$body")" = ok ] || { echo "::error::/health nicht ok"; exit 1; }
    [ "$(jq -r .commit <<<"$body")" = "$GITHUB_SHA" ] || { echo "::error::falscher Commit in /health"; exit 1; }
    ;;
  seed-data)
    curl -fsS "$BASE/notes" | jq -e 'any(.[]; .text == "beispiel-aus-seed")' >/dev/null || { echo "::error::Seed-Daten fehlen"; exit 1; }
    echo "Seed-Daten vorhanden"
    ;;
  fill)
    curl -fsS -X POST -d '{"text":"vor-dem-backup"}' "$BASE/notes" >/dev/null
    curl -fsS -X PUT --data-binary 'inhalt-vor-dem-backup' "$BASE/files/backup.txt" >/dev/null
    ;;
  wipe)
    docker exec demo-staging-db-1 psql -U app -d app -c 'delete from notes' >/dev/null
    docker exec demo-staging-app-1 rm -f /data/uploads/backup.txt
    [ "$(curl -fsS "$BASE/notes" | jq length)" = 0 ] || { echo "::error::Daten nicht gelöscht"; exit 1; }
    ;;
  seeded)
    curl -fsS "$BASE/notes" | jq -e 'any(.[]; .text == "vor-dem-backup")' >/dev/null || { echo "::error::Notiz fehlt nach dem Restore"; exit 1; }
    [ "$(curl -fsS "$BASE/files/backup.txt")" = inhalt-vor-dem-backup ] || { echo "::error::Datei fehlt nach dem Restore"; exit 1; }
    echo "Daten nach dem Restore vollständig"
    ;;
  *) echo "Unbekannt: $1" >&2; exit 2 ;;
esac
