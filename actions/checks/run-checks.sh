#!/usr/bin/env bash
# Führt "install" und alle "checks" aus .factory/setup.json aus. Ein fehlgeschlagener Check bricht
# nicht sofort ab: alle laufen, die Zusammenfassung zeigt jeden, der Exit-Code ist 1, wenn einer rot ist.
set -uo pipefail
SETUP=.factory/setup.json
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

[ -f "$SETUP" ] || { echo "::error::$SETUP fehlt. Ohne Checks gilt nichts als geprüft."; exit 1; }
CHECKS=$(jq -er '.checks | select(type == "object") | to_entries | map(select((.value | type) == "string" and (.value | length) > 0)) | select(length > 0) | .[] | [.key, .value] | @tsv' "$SETUP") \
  || { echo "::error::$SETUP enthält keine Checks (\"checks\": {\"name\": \"befehl\"})."; exit 1; }

# actionlint ist auf den Runnern nicht vorinstalliert, wird aber für Plattform-Checks gebraucht
if grep -q actionlint <<<"$CHECKS" && ! command -v actionlint >/dev/null; then
  echo "▶ actionlint installieren"
  ( cd "$RUNNER_TEMP" && bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/v1.7.7/scripts/download-actionlint.bash) 1.7.7 >/dev/null ) \
    && echo "$RUNNER_TEMP" >> "$GITHUB_PATH" && export PATH="$RUNNER_TEMP:$PATH"
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
