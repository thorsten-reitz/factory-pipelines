#!/usr/bin/env bash
# Meldet das Ergebnis: Erfolg als Kommentar am PR des Commits (und schließt ein offenes deploy-failed-Issue
# dieser Umgebung), Fehlschlag als Issue mit Label deploy-failed (eins pro Umgebung, weitere als Kommentar).
# Diese Issues bekommen nie das Label "factory": ob die Factory sich darum kümmert, entscheidet der Mensch.
#   Umgebung: GH_TOKEN, GITHUB_REPOSITORY, RESULT, VERB, ENVIRONMENT, LANGUAGE, IMAGE, COMMIT, RUN_URL
set -uo pipefail
REPO="$GITHUB_REPOSITORY"
MARK="<!-- factory-pipelines:deploy-failed:$ENVIRONMENT -->"
SHORT="${COMMIT:0:7}"
DIGEST="${IMAGE##*@}"; DIGEST="${DIGEST:0:19}"

if [ "$LANGUAGE" = de ]; then
  case "$VERB" in deploy) WHAT="Deploy" ;; rollback) WHAT="Rollback" ;; restore) WHAT="Restore" ;; esac
  OK_TITLE="✅ $WHAT nach **$ENVIRONMENT** erfolgreich"
  OK_BODY="Commit \`$SHORT\`${IMAGE:+, Image \`$DIGEST…\`}. Health-Check grün. [Lauf ansehen]($RUN_URL)"
  FAIL_TITLE="$WHAT nach $ENVIRONMENT fehlgeschlagen"
  FAIL_BODY="Der $WHAT von Commit \`$SHORT\` nach **$ENVIRONMENT** ist fehlgeschlagen. Beim Deploy wurde automatisch auf die vorige Version zurückgerollt, sofern es eine gab.

[Lauf mit Logs ansehen]($RUN_URL)

_Dieses Issue ist nicht an die Factory übergeben. Soll sie sich darum kümmern, füge das Label \`factory\` hinzu._"
  RECOVERED="Behoben: der $WHAT von \`$SHORT\` nach **$ENVIRONMENT** war erfolgreich. [Lauf]($RUN_URL)"
  AGAIN="Erneut fehlgeschlagen mit Commit \`$SHORT\`. [Lauf]($RUN_URL)"
else
  WHAT="${VERB^}"
  OK_TITLE="✅ $WHAT to **$ENVIRONMENT** succeeded"
  OK_BODY="Commit \`$SHORT\`${IMAGE:+, image \`$DIGEST…\`}. Health check green. [View run]($RUN_URL)"
  FAIL_TITLE="$WHAT to $ENVIRONMENT failed"
  FAIL_BODY="The $VERB of commit \`$SHORT\` to **$ENVIRONMENT** failed. A failed deploy was rolled back to the previous version automatically, if there was one.

[View run with logs]($RUN_URL)

_This issue is not handed to the factory. Add the \`factory\` label if it should take care of it._"
  RECOVERED="Resolved: the $VERB of \`$SHORT\` to **$ENVIRONMENT** succeeded. [Run]($RUN_URL)"
  AGAIN="Failed again with commit \`$SHORT\`. [Run]($RUN_URL)"
fi

OPEN=$(gh issue list -R "$REPO" --label deploy-failed --state open --json number,body \
  --jq "[.[] | select(.body | contains(\"$MARK\"))][0].number // empty" 2>/dev/null || true)

if [ "$RESULT" = success ]; then
  if [ "$VERB" = deploy ]; then
    PR=$(gh api "repos/$REPO/commits/$COMMIT/pulls" --jq '.[0].number // empty' 2>/dev/null || true)
    [ -n "$PR" ] && gh pr comment "$PR" -R "$REPO" --body "$OK_TITLE. $OK_BODY" >/dev/null || true
  fi
  [ -n "$OPEN" ] && gh issue close "$OPEN" -R "$REPO" --comment "$RECOVERED" >/dev/null || true
else
  if [ -n "$OPEN" ]; then
    gh issue comment "$OPEN" -R "$REPO" --body "$AGAIN" >/dev/null || true
  else
    gh label create deploy-failed -R "$REPO" --color B60205 --force >/dev/null 2>&1 || true
    printf '%s\n%s\n' "$MARK" "$FAIL_BODY" | gh issue create -R "$REPO" --label deploy-failed --title "$FAIL_TITLE" --body-file - >/dev/null || true
  fi
fi
exit 0
