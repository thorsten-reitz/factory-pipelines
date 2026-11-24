#!/usr/bin/env bash
# Stufe k3s: Deploy, Rollback und Restore über den Branch $DEPLOY_BRANCH (GitOps mit Argo CD).
#
#   argocd/<umgebung>/application.json   Argo-Application dieser Umgebung (Chart aus factory-pipelines, Werte inline)
#   state/<umgebung>/good.json           zuletzt erfolgreich ausgerollte Application
#   state/<umgebung>/previous-good.json  die davor (Ziel eines manuellen Rollbacks)
#
# Argo CD synchronisiert argocd/<umgebung>/ (Bootstrap: templates/cloud-init/k3s-host.yaml). Die Pipeline braucht
# keinen Zugang zum Cluster: Erfolg heißt, dass /health von außen den ausgerollten Commit meldet.
#
#   Umgebung: VERB, ENVIRONMENT, CONFIG, IMAGE, COMMIT, SNAPSHOT, INFISICAL_PROJECT_ID, GH_TOKEN, GITHUB_REPOSITORY,
#             DEPLOY_BRANCH, PIPELINES_REPO, PIPELINES_SHA, K3S_SECRETS, HEALTH_TIMEOUT, RUN_ID, HEALTH_TOKEN
set -euo pipefail
: "${GH_TOKEN:?github-token fehlt (contents: write für den Deploy-Branch)}"
BRANCH="${DEPLOY_BRANCH:-factory-deploy}"
EXTRA_VALUES="${K3S_VALUES:-}"
[ -n "$EXTRA_VALUES" ] || EXTRA_VALUES='{}'
TIMEOUT="${HEALTH_TIMEOUT:-600}"
PROJECT=$(jq -r '.project' <<<"$CONFIG")
NAME="$PROJECT-$ENVIRONMENT"
URL=$(jq -r --arg e "$ENVIRONMENT" '.environments[$e] | .url // (if .domain then "https://" + .domain else "" end)' <<<"$CONFIG")
[ -n "$URL" ] || { echo "::error::Stufe k3s braucht environments.$ENVIRONMENT.domain (oder url): der Erfolg wird über /health geprüft."; exit 1; }
URL="${URL%/}"
[ -n "${HEALTH_TOKEN:-}" ] || echo "::warning::HEALTH_TOKEN fehlt in den Secrets der Umgebung; /health wird ohne Token abgefragt"

APP_FILE="argocd/$ENVIRONMENT/application.json"
GOOD="state/$ENVIRONMENT/good.json"
PREV="state/$ENVIRONMENT/previous-good.json"

# ---------- Deploy-Branch ----------
STATE=$(mktemp -d); trap 'rm -rf "$STATE"' EXIT
REMOTE="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
  git clone -q --depth 20 --branch "$BRANCH" "$REMOTE" "$STATE"
else
  echo "Deploy-Branch $BRANCH anlegen"
  git -C "$STATE" init -q
  git -C "$STATE" checkout -q --orphan "$BRANCH"
  git -C "$STATE" remote add origin "$REMOTE"
  printf '# %s\n\nVon factory-pipelines verwaltet: welcher Stand in welcher Umgebung läuft. Nicht von Hand ändern.\n' "$BRANCH" > "$STATE/README.md"
fi
git -C "$STATE" config user.name "github-actions[bot]"
git -C "$STATE" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
mkdir -p "$STATE/argocd/$ENVIRONMENT" "$STATE/state/$ENVIRONMENT"

publish() {
  local msg="$1" try
  git -C "$STATE" add -A
  git -C "$STATE" diff --cached --quiet && { echo "Keine Änderung am Deploy-Branch"; return 0; }
  git -C "$STATE" commit -q -m "$msg"
  for try in 1 2 3 4 5; do
    git -C "$STATE" push -q origin "HEAD:$BRANCH" 2>/dev/null && { echo "✓ $msg"; return 0; }
    sleep $((try * 2))
    git -C "$STATE" pull -q --rebase origin "$BRANCH"
  done
  echo "::error::Push auf $BRANCH fehlgeschlagen"; return 1
}

# Wartet, bis /health den Commit meldet (status ok/degraded). Rückgabe 1 nach Ablauf der Zeit.
wait_for_commit() {
  local want="$1" limit="$2" deadline body got status
  deadline=$(( $(date +%s) + limit ))
  echo "Warte bis zu ${limit}s, bis $URL/health Commit ${want:0:7} meldet"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    body=$(curl -fsS -m 10 -H "Authorization: Bearer ${HEALTH_TOKEN:-}" "$URL/health" 2>/dev/null || true)
    got=$(jq -r '.commit // empty' <<<"$body" 2>/dev/null || true)
    status=$(jq -r '.status // empty' <<<"$body" 2>/dev/null || true)
    if [ -n "$got" ] && { [[ "$want" == "$got"* ]] || [[ "$got" == "$want"* ]]; } && [ ${#got} -ge 7 ] \
       && { [ "$status" = ok ] || [ "$status" = degraded ]; }; then
      echo "✓ /health: Commit ${got:0:7}, Status $status"
      return 0
    fi
    sleep 10
  done
  echo "Letzte Antwort von /health: ${body:-keine}"
  return 1
}

commit_of() { jq -r '.spec.source.helm.valuesObject.commit' "$1"; }

# ---------- Werte für das Chart aus delivery.json ----------
build_application() {
  local proj='{}' registry pre_deploy=false
  if [ -f deploy/k3s/values.yaml ]; then proj=$(yq -o=json '.' deploy/k3s/values.yaml); fi
  registry="${IMAGE%%/*}"
  [ "$ENVIRONMENT" = production ] && [ -f "$STATE/$GOOD" ] && pre_deploy=true
  jq -n \
    --argjson cfg "$CONFIG" --argjson proj "$proj" \
    --arg env "$ENVIRONMENT" --arg name "$NAME" --arg commit "$COMMIT" --arg image "$IMAGE" \
    --arg registry "$registry" --arg owner "${GITHUB_REPOSITORY%%/*}" --arg infisical "${INFISICAL_PROJECT_ID:-}" \
    --arg secrets "${K3S_SECRETS:-infisical}" --argjson preDeploy "$pre_deploy" --argjson extra "$EXTRA_VALUES" \
    --arg repo "https://github.com/${PIPELINES_REPO}.git" --arg rev "$PIPELINES_SHA" '
    ($cfg.environments[$env]) as $e
    | ([$cfg.state[] | select(.type == "postgres")][0]) as $pg
    | ($registry == "ghcr.io") as $ghcr
    | {
        project: $cfg.project, environment: $env, commit: $commit, delivery: ($cfg | tojson),
        image: {repository: ($image | split("@")[0]), digest: ($image | split("@")[1]),
                pullSecret: (if $ghcr then "registry-pull" else "" end)},
        ingress: {host: ($e.domain // "")},
        secrets: {provider: $secrets,
                  infisical: {projectId: $infisical, environmentSlug: $env,
                              pullTokenKey: (if $ghcr then "GHCR_PULL_TOKEN" else "" end), pullUser: $owner}},
        postgres: {enabled: ($pg != null), service: ($pg.service // "db")},
        volumes: [ $cfg.state[] | select(.type == "volume") | .name as $n
                   | (([$proj.volumes // [] | .[] | select(.name == $n)][0]) // {}) + {name: $n} ],
        backup: {enabled: ($cfg.backup.enabled and (($cfg.state | length) > 0)), preDeploy: $preDeploy,
                 restoreTest: {enabled: ($cfg.backup.restoreTest == "weekly")}},
        seed: {enabled: ($env == "staging" and ($e.data // "seed") == "seed")}
      } as $gen
    | ($proj * $gen * $extra) as $values
    | {
        apiVersion: "argoproj.io/v1alpha1", kind: "Application",
        metadata: {name: $name, namespace: "argocd", finalizers: ["resources-finalizer.argocd.argoproj.io"]},
        spec: {
          project: "default",
          destination: {server: "https://kubernetes.default.svc", namespace: $name},
          source: {repoURL: $repo, targetRevision: $rev, path: "charts/factory-app",
                   helm: {releaseName: $cfg.project, valuesObject: $values}},
          syncPolicy: {automated: {prune: true, selfHeal: true},
                       syncOptions: ["CreateNamespace=true", "RespectIgnoreDifferences=true"],
                       retry: {limit: 5, backoff: {duration: "10s", factor: 2, maxDuration: "3m"}}},
          ignoreDifferences: [{group: "apps", kind: "Deployment", name: "app", jsonPointers: ["/spec/replicas"]}]
        }
      }'
}

# ---------- Aktionen ----------
case "$VERB" in
  deploy)
    [[ "$IMAGE" =~ @sha256:[a-f0-9]{64}$ ]] || { echo "::error::Ungültige Image-Referenz: '$IMAGE'"; exit 1; }
    build_application > "$STATE/$APP_FILE"
    publish "deploy $ENVIRONMENT: ${COMMIT:0:7} (${IMAGE##*@sha256:})"
    if wait_for_commit "$COMMIT" "$TIMEOUT"; then
      [ -f "$STATE/$GOOD" ] && ! cmp -s "$STATE/$GOOD" "$STATE/$APP_FILE" && cp "$STATE/$GOOD" "$STATE/$PREV"
      cp "$STATE/$APP_FILE" "$STATE/$GOOD"
      publish "erfolgreich $ENVIRONMENT: ${COMMIT:0:7}"
      exit 0
    fi
    if [ -f "$STATE/$GOOD" ]; then
      echo "::error::Neuer Stand wird nicht gesund, zurück auf den letzten guten Stand"
      cp "$STATE/$GOOD" "$STATE/$APP_FILE"
      publish "zurückgerollt $ENVIRONMENT: ${COMMIT:0:7} nicht gesund"
      wait_for_commit "$(commit_of "$STATE/$GOOD")" "$TIMEOUT" \
        && { echo "::error::Deploy fehlgeschlagen, der letzte gute Stand läuft wieder"; exit 1; }
      echo "::error::Deploy fehlgeschlagen und auch der letzte gute Stand meldet sich nicht gesund. Bitte sofort prüfen."
      exit 1
    fi
    echo "::error::Erster Deploy von $NAME fehlgeschlagen (kein guter Stand zum Zurückrollen)"
    exit 1
    ;;
  rollback)
    [ -f "$STATE/$PREV" ] || { echo "::error::Kein vorheriger guter Stand für $NAME vorhanden"; exit 1; }
    cp "$STATE/$PREV" "$STATE/$APP_FILE"
    cp "$STATE/$GOOD" "$STATE/$PREV.tmp"; cp "$STATE/$APP_FILE" "$STATE/$GOOD"; mv "$STATE/$PREV.tmp" "$STATE/$PREV"
    publish "rollback $ENVIRONMENT: auf $(commit_of "$STATE/$APP_FILE" | cut -c1-7)"
    wait_for_commit "$(commit_of "$STATE/$APP_FILE")" "$TIMEOUT" || { echo "::error::Rollback ausgeführt, aber die Version meldet sich nicht gesund"; exit 1; }
    ;;
  restore)
    [ -f "$STATE/$APP_FILE" ] || { echo "::error::$NAME ist noch nicht deployt"; exit 1; }
    ID=$(printf '%s' "${RUN_ID:-$(date +%s)}" | tr -c 'a-z0-9' '-' | cut -c1-40)
    jq --arg id "$ID" --arg snap "${SNAPSHOT:-latest}" \
      '.spec.source.helm.valuesObject.restore = {id: $id, snapshot: $snap}' "$STATE/$APP_FILE" > "$STATE/$APP_FILE.tmp"
    mv "$STATE/$APP_FILE.tmp" "$STATE/$APP_FILE"
    publish "restore $ENVIRONMENT: ${SNAPSHOT:-latest} (Job restore-$ID)"
    # Der Restore-Job hält die App an: erst warten, bis sie weg ist, dann bis sie wieder gesund ist
    deadline=$(( $(date +%s) + 600 ))
    while [ "$(date +%s)" -lt "$deadline" ] && curl -fsS -m 5 "$URL/readyz" >/dev/null 2>&1; do sleep 5; done
    curl -fsS -m 5 "$URL/readyz" >/dev/null 2>&1 && { echo "::error::Die App wurde nicht angehalten, der Restore-Job ist offenbar nicht gestartet"; exit 1; }
    echo "App angehalten, Restore läuft"
    wait_for_commit "$(commit_of "$STATE/$APP_FILE")" "$TIMEOUT" || { echo "::error::Nach dem Restore ist die App nicht wieder gesund"; exit 1; }
    echo "App wieder gesund. Ob der Restore selbst erfolgreich war, meldet der Job restore-$ID an HC_PING_URL_RESTORE (ein Fehlschlag wird zum Incident)."
    ;;
  *) echo "::error::Unbekannte Aktion: $VERB"; exit 1 ;;
esac
