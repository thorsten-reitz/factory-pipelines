#!/usr/bin/env bash
# Prüft die delivery.json, ergänzt Standardwerte und schreibt die Ergebnisse nach $GITHUB_OUTPUT.
#   config.sh <pfad/zur/delivery.json> <schema-ordner>
set -euo pipefail
CONFIG="$1"
SCHEMA_DIR="$2"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

[ -f "$CONFIG" ] || { echo "::error::$CONFIG nicht gefunden. Lege die Datei mit /init an oder kopiere templates/delivery.example.json."; exit 1; }

echo "Prüfe $CONFIG gegen das Schema"
pipx run --spec "check-jsonschema==0.33.0" check-jsonschema --schemafile "$SCHEMA_DIR/delivery.schema.json" "$CONFIG"

REPO="${GITHUB_REPOSITORY:-local/project}"
DEFAULT_PROJECT=$(basename "$REPO" | tr '[:upper:]_.' '[:lower:]--' | cut -c1-40)

CFG=$(jq -c -s --arg p "$DEFAULT_PROJECT" '
  (.[0] * .[1]) as $c
  | $c + {project: ($c.project // $p)}
  | .environments |= with_entries(
      if .key == "staging" then .value = ({autoDeploy: true, data: "seed"} + .value)
      elif .key == "production" then .value = ({approval: true} + .value)
      elif .key == "test" then .value = ({e2e: true, services: "deploy/compose.test.yml", url: "http://localhost:8080"} + .value)
      else . end)
  | .state |= map(if .type == "postgres" then ({urlEnv: "DATABASE_URL", pitr: false} + .) else . end)
' "$SCHEMA_DIR/defaults.json" "$CONFIG")

if jq -e '[.state[] | select(.pitr == true)] | length > 0' <<<"$CFG" >/dev/null; then
  echo "::error::state[].pitr: Point-in-Time-Recovery ist in dieser Version noch nicht umgesetzt. Bitte auf false setzen."
  exit 1
fi

LANGUAGE=en
if [ -f .factory/setup.json ]; then
  case "$(jq -r '.language // "de"' .factory/setup.json 2>/dev/null | tr '[:upper:]' '[:lower:]')" in
    de|de-*) LANGUAGE=de ;;
  esac
else
  LANGUAGE=de
fi

REGISTRY=$(jq -r '.image.registry' <<<"$CFG")
IMAGE="$REGISTRY/$(tr '[:upper:]' '[:lower:]' <<<"$REPO")"

{
  echo "config=$CFG"
  echo "project=$(jq -r '.project' <<<"$CFG")"
  echo "tier=$(jq -r '.tier' <<<"$CFG")"
  echo "language=$LANGUAGE"
  echo "image=$IMAGE"
  echo "staging=$(jq -r '.environments | has("staging")' <<<"$CFG")"
  echo "production=$(jq -r '.environments | has("production")' <<<"$CFG")"
  echo "deploy_on_push=$(jq -r '(.environments.staging.autoDeploy // false) or (.environments | has("production"))' <<<"$CFG")"
} >> "$OUT"

echo "Konfiguration in Ordnung: Projekt $(jq -r '.project' <<<"$CFG"), Stufe $(jq -r '.tier' <<<"$CFG"), Sprache $LANGUAGE"
