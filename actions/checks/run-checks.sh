#!/usr/bin/env bash
# Führt "install" und alle "checks" aus .factory/setup.json aus. Ein fehlgeschlagener Check bricht
# nicht sofort ab: alle laufen, die Zusammenfassung zeigt jeden, der Exit-Code ist 1, wenn einer rot ist.
set -uo pipefail
SETUP=.factory/setup.json
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

[ -f "$SETUP" ] || { echo "::error::$SETUP fehlt. Ohne Checks gilt nichts als geprüft."; exit 1; }
CHECKS=$(jq -er '.checks | select(type == "object") | to_entries | map(select((.value | type) == "string" and (.value | length) > 0)) | select(length > 0) | .[] | [.key, .value] | @tsv' "$SETUP") \
  || { echo "::error::$SETUP enthält keine Checks (\"checks\": {\"name\": \"befehl\"})."; exit 1; }

# Werkzeuge der Plattform-Checks (conventions/README.md der Factory) sind auf den Runnern nicht
# vorinstalliert. Installiert wird nur, was ein Check tatsächlich verwendet, in festen Versionen.
TOOLS="${RUNNER_TEMP:-/tmp}/factory-tools"
mkdir -p "$TOOLS"; export PATH="$TOOLS:$PATH"; [ -n "${GITHUB_PATH:-}" ] && echo "$TOOLS" >> "$GITHUB_PATH"
uses() { grep -q "$1" <<<"$CHECKS" && ! command -v "$1" >/dev/null; }
if uses actionlint; then
  echo "▶ actionlint 1.7.7 installieren"
  ( cd "$TOOLS" && bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/v1.7.7/scripts/download-actionlint.bash) 1.7.7 >/dev/null )
fi
if uses check-jsonschema; then
  echo "▶ check-jsonschema 0.33.0 installieren"
  pipx install -q "check-jsonschema==0.33.0" >/dev/null
fi
if uses hadolint; then
  echo "▶ hadolint 2.12.0 installieren"
  curl -fsSL -o "$TOOLS/hadolint" https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64 && chmod +x "$TOOLS/hadolint"
fi

INSTALL=$(jq -r '.install // empty' "$SETUP")
if [ -n "$INSTALL" ]; then
  echo "▶ install: $INSTALL"
  bash -c "$INSTALL" || { echo "::error::install fehlgeschlagen: $INSTALL"; exit 1; }
fi

FAILED=0
{ echo "### Checks"; echo; echo "| Check | Befehl | Ergebnis |"; echo "|---|---|---|"; } >> "$SUMMARY"
while IFS=$'\t' read -r NAME CMD; do
  [ -z "$NAME" ] && continue
  echo "::group::$NAME: $CMD"
  if bash -c "$CMD" </dev/null; then RESULT="✅"; else RESULT="❌ Exit $?"; FAILED=1; echo "::error::Check '$NAME' fehlgeschlagen"; fi
  echo "::endgroup::"
  echo "| $NAME | \`$CMD\` | $RESULT |" >> "$SUMMARY"
done <<< "$CHECKS"
exit $FAILED
