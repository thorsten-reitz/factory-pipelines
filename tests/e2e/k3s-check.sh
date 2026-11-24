#!/usr/bin/env bash
# Prüfschritte des Selbsttests Stufe k3s (App demo im Namespace demo-staging, Ingress auf localhost:8081).
#   k3s-check.sh healthy <image-ref> <commit> | seed-data | fill | wipe | seeded | job <cronjob>
set -euo pipefail
NS=demo-staging
BASE=http://localhost:8081
TOKEN=$(kubectl -n "$NS" get secret app-secrets -o jsonpath='{.data.HEALTH_TOKEN}' | base64 -d)
k() { kubectl -n "$NS" "$@"; }

case "$1" in
  healthy)
    want_image="$2"; want_commit="$3"
    for _ in $(seq 1 60); do
      got=$(k get deployment app -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
      [ "$got" = "$want_image" ] && break
      sleep 5
    done
    [ "$got" = "$want_image" ] || { echo "::error::Deployment nutzt $got statt $want_image"; exit 1; }
    k rollout status deployment/app --timeout=300s
    body=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/health")
    echo "$body" | jq -c .
    [ "$(jq -r .status <<<"$body")" = ok ] || { echo "::error::/health nicht ok"; exit 1; }
    [ "$(jq -r .commit <<<"$body")" = "$want_commit" ] || { echo "::error::falscher Commit in /health"; exit 1; }
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
    k exec db-0 -- psql -U app -d app -c 'delete from notes' >/dev/null
    k exec deploy/app -- rm -f /data/uploads/backup.txt
    [ "$(curl -fsS "$BASE/notes" | jq length)" = 0 ] || { echo "::error::Daten nicht gelöscht"; exit 1; }
    ;;
  seeded)
    curl -fsS "$BASE/notes" | jq -e 'any(.[]; .text == "vor-dem-backup")' >/dev/null || { echo "::error::Notiz fehlt nach dem Restore"; exit 1; }
    [ "$(curl -fsS "$BASE/files/backup.txt")" = inhalt-vor-dem-backup ] || { echo "::error::Datei fehlt nach dem Restore"; exit 1; }
    job=$(k get jobs -o name | grep '^job.batch/restore-' | head -1)
    k wait --for=condition=complete "$job" --timeout=60s
    echo "Restore-Job erfolgreich, Daten vollständig"
    ;;
  job)
    name="$2-now-$(date +%s)"
    k create job "$name" --from="cronjob/$2"
    if ! k wait --for=condition=complete "job/$name" --timeout=300s; then k logs "job/$name" || true; exit 1; fi
    k logs "job/$name" | tail -5
    ;;
  *) echo "Unbekannt: $1" >&2; exit 2 ;;
esac
