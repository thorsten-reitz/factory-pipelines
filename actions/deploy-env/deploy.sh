#!/usr/bin/env bash
# Schickt ein Bündel (compose.yml, delivery.json, release.json, ggf. Registry-Token) per SSH an den Host.
# Auf dem Host nimmt es der Forced Command factory-host entgegen; der SSH-Schlüssel kann nichts anderes.
#   Umgebung: VERB, ENVIRONMENT, CONFIG, IMAGE, COMPOSE_FILE, SNAPSHOT, COMMIT, INFISICAL_PROJECT_ID,
#             REGISTRY_TOKEN, REGISTRY_USER, DEPLOY_HOST, DEPLOY_SSH_KEY, [DEPLOY_HOST_KEY, DEPLOY_USER, DEPLOY_PORT]
set -euo pipefail
: "${DEPLOY_HOST:?DEPLOY_HOST fehlt in den Secrets der Umgebung}"
: "${DEPLOY_SSH_KEY:?DEPLOY_SSH_KEY fehlt in den Secrets der Umgebung}"
USER_NAME="${DEPLOY_USER:-deploy}"
PORT="${DEPLOY_PORT:-22}"

case "$VERB" in
  deploy) [[ "$IMAGE" =~ ^[a-z0-9./:_-]+@sha256:[a-f0-9]{64}$ ]] || { echo "::error::Ungültige Image-Referenz: '$IMAGE'"; exit 1; } ;;
  rollback|restore) ;;
  *) echo "::error::Unbekannte Aktion: $VERB"; exit 1 ;;
esac
[ "$VERB" = deploy ] && { [ -f "$COMPOSE_FILE" ] || { echo "::error::$COMPOSE_FILE fehlt"; exit 1; }; }
TIER=$(jq -r '.tier' <<<"$CONFIG")
[ "$TIER" = compose ] || { echo "::error::Stufe '$TIER' wird in dieser Version noch nicht deployt (nur compose)."; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bundle"
install -m 600 /dev/null "$WORK/key"
printf '%s\n' "$DEPLOY_SSH_KEY" > "$WORK/key"

SSH_OPTS=(-i "$WORK/key" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o IdentitiesOnly=yes)
if [ -n "${DEPLOY_HOST_KEY:-}" ]; then
  if [ "$PORT" = 22 ]; then HOSTNAME_ENTRY="$DEPLOY_HOST"; else HOSTNAME_ENTRY="[$DEPLOY_HOST]:$PORT"; fi
  printf '%s %s\n' "$HOSTNAME_ENTRY" "$DEPLOY_HOST_KEY" > "$WORK/known_hosts"
  SSH_OPTS+=(-o UserKnownHostsFile="$WORK/known_hosts" -o StrictHostKeyChecking=yes)
else
  echo "::warning::DEPLOY_HOST_KEY fehlt: Der Host-Schlüssel wird nicht geprüft. Trag den öffentlichen Host-Schlüssel in Infisical ein."
  SSH_OPTS+=(-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR)
fi

PROJECT=$(jq -r '.project' <<<"$CONFIG")
if [ "$VERB" = deploy ]; then cp "$COMPOSE_FILE" "$WORK/bundle/compose.yml"; fi
printf '%s' "$CONFIG" > "$WORK/bundle/delivery.json"
jq -n --arg verb "$VERB" --arg project "$PROJECT" --arg env "$ENVIRONMENT" --arg image "$IMAGE" \
      --arg commit "$COMMIT" --arg snapshot "$SNAPSHOT" --arg infisical "$INFISICAL_PROJECT_ID" \
  '{protocol: 1, verb: $verb, project: $project, environment: $env, image: $image, commit: $commit,
    snapshot: $snapshot, infisicalProjectId: $infisical}' > "$WORK/bundle/release.json"
if [ "$VERB" = deploy ] && [ -n "$REGISTRY_TOKEN" ]; then
  REGISTRY="${IMAGE%%/*}"
  jq -n --arg r "$REGISTRY" --arg u "$REGISTRY_USER" --arg t "$REGISTRY_TOKEN" '{registry: $r, user: $u, token: $t}' \
    > "$WORK/bundle/registry.json"
fi

echo "▶ $VERB $PROJECT-$ENVIRONMENT auf $DEPLOY_HOST"
tar -C "$WORK/bundle" -czf - . | ssh "${SSH_OPTS[@]}" "$USER_NAME@$DEPLOY_HOST" "$VERB"
