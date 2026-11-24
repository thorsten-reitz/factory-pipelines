#!/usr/bin/env bash
# Startet die Test-Umgebung (Compose-Datei aus environments.test.services) mit dem frisch gebauten
# Image, prüft /livez und /readyz und führt danach den Befehl "e2e" aus .factory/setup.json aus.
#   Umgebung: IMAGE, SERVICES, BASE_URL
set -euo pipefail
[ -f "$SERVICES" ] || { echo "::error::Test-Umgebung: $SERVICES fehlt (environments.test.services)."; exit 1; }
export IMAGE
P=factory-test
dc() { docker compose -p "$P" -f "$SERVICES" "$@"; }
cleanup() {
  local code=$?
  if [ $code -ne 0 ]; then echo "::group::Logs der Test-Umgebung"; dc logs --no-color --tail 200 || true; echo "::endgroup::"; fi
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  exit $code
}
trap cleanup EXIT

echo "▶ Test-Umgebung starten ($SERVICES)"
dc up -d

echo "▶ Health: $BASE_URL/livez und /readyz"
for path in livez readyz; do
  ok=0
  for _ in $(seq 1 90); do
    if curl -fsS -m 5 "$BASE_URL/$path" >/dev/null; then ok=1; break; fi
    sleep 2
  done
  [ $ok -eq 1 ] || { echo "::error::/$path antwortet nicht mit 200"; exit 1; }
done

E2E=$(jq -r '.e2e // empty' .factory/setup.json 2>/dev/null || true)
if [ -n "$E2E" ]; then
  INSTALL=$(jq -r '.install // empty' .factory/setup.json)
  [ -n "$INSTALL" ] && { echo "▶ install: $INSTALL"; bash -c "$INSTALL"; }
  echo "▶ e2e: $E2E (BASE_URL=$BASE_URL)"
  BASE_URL="$BASE_URL" bash -c "$E2E"
else
  echo "Kein \"e2e\"-Befehl in .factory/setup.json, nur Health geprüft."
fi
