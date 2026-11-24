#!/usr/bin/env bash
# Prüft /readyz von außen (über Domain bzw. url der Umgebung). Der eigentliche Health-Gate mit Rollback
# läuft auf dem Host; dieser Schritt zeigt, dass die App auch über DNS, TLS und Caddy erreichbar ist.
#   Umgebung: CONFIG, ENVIRONMENT
set -euo pipefail
URL=$(jq -r --arg e "$ENVIRONMENT" '.environments[$e] | .url // (if .domain then "https://" + .domain else "" end)' <<<"$CONFIG")
if [ -z "$URL" ]; then
  echo "Keine Domain/url für $ENVIRONMENT konfiguriert, Health-Check von außen übersprungen."
  exit 0
fi
for _ in $(seq 1 20); do
  if curl -fsS -m 10 "${URL%/}/readyz" >/dev/null; then echo "✓ ${URL%/}/readyz erreichbar"; exit 0; fi
  sleep 6
done
echo "::error::${URL%/}/readyz ist von außen nicht erreichbar (DNS, TLS oder Caddy prüfen). Auf dem Host lief der Health-Check grün."
exit 1
