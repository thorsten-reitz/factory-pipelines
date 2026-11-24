#!/usr/bin/env bash
# Neue Version veröffentlichen: Tag vX.Y.Z setzen, gleitenden Major-Tag (v0, v1 …) nachziehen,
# GitHub-Release anlegen. Der Workflow publish.yml baut dann das Backup-Image.
#   scripts/release.sh v0.1.0
set -euo pipefail
V="${1:?Aufruf: scripts/release.sh vX.Y.Z}"
[[ "$V" =~ ^v([0-9]+)\.[0-9]+\.[0-9]+$ ]] || { echo "Version im Format vX.Y.Z angeben" >&2; exit 2; }
MAJOR="v${BASH_REMATCH[1]}"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "Nur von main aus veröffentlichen" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Es gibt uncommittete Änderungen" >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main ist nicht auf dem Stand von origin/main" >&2; exit 1; }
STATE=$(gh run list --branch main --workflow self-test.yml --limit 1 --json headSha,conclusion --jq '.[0] | "\(.headSha) \(.conclusion)"')
[ "$STATE" = "$(git rev-parse HEAD) success" ] || { echo "Der Selbsttest auf diesem Commit ist nicht grün ($STATE)" >&2; exit 1; }
git tag -a "$V" -m "$V"
git tag -fa "$MAJOR" -m "$MAJOR → $V"
git push -q origin "$V"
git push -qf origin "$MAJOR"
gh release create "$V" --generate-notes --title "$V"
echo "Veröffentlicht: $V (und $MAJOR)"
