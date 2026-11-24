#!/usr/bin/env bash
# Selbsttest Stufe k3s: k3d-Cluster mit Registry, Argo CD (gleiche Chart-Version wie templates/cloud-init/k3s-host.yaml),
# SeaweedFS als S3, Test-Secret statt Infisical, Root-Application auf einen Wegwerf-Deploy-Branch dieses Repos.
#   k3s-setup.sh <deploy-branch>
# Schreibt nach $GITHUB_OUTPUT: good, good2, broken (Image-Referenzen im Cluster), secrets, values
set -euo pipefail
BRANCH="${1:?Deploy-Branch fehlt}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/examples/demo-app"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"
NS=demo-staging

echo "::group::k3d-Cluster"
curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/v5.9.0/install.sh | TAG=v5.9.0 bash >/dev/null
k3d cluster create e2e --image rancher/k3s:v1.36.6-k3s1 --registry-create e2e-registry:0.0.0.0:5001 \
  -p "8081:80@loadbalancer" --k3s-arg "--secrets-encryption@server:0" --wait
REG=$(docker exec k3d-e2e-server-0 sh -c 'cat /etc/rancher/k3s/registries.yaml' | awk '/mirrors:/{m=1; next} m && /^  [^ ]/{gsub(/[" :]+$/,"",$1); gsub(/"/,"",$1); print $1; exit}')
[ -n "$REG" ] || { docker exec k3d-e2e-server-0 cat /etc/rancher/k3s/registries.yaml; echo "Registry im Cluster nicht gefunden"; exit 1; }
echo "Registry im Cluster: $REG"
echo "::endgroup::"

echo "::group::S3 und Argo CD"
# Im Netz des Clusters, per IP erreichbar (Docker-Namen löst das DNS im Cluster nicht auf)
docker run -d --name s3 --network k3d-e2e chrislusf/seaweedfs:4.50 server -dir=/data -s3 -s3.port=8333 -master.volumeSizeLimitMB=256 >/dev/null
S3_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' s3)
echo "S3 im Cluster-Netz: $S3_IP"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm install argo-cd argo/argo-cd --version 10.17.0 -n argocd --create-namespace --wait --timeout 10m \
  --set dex.enabled=false --set notifications.enabled=false --set-string 'configs.cm.timeout\.reconciliation=15s' >/dev/null
echo "::endgroup::"

echo "::group::Images"
docker build -q -t localhost:5001/factory-backup:test "$ROOT/images/backup" >/dev/null
docker build -q -t localhost:5001/demo:good  --build-arg GIT_COMMIT="$GITHUB_SHA" "$APP" >/dev/null
docker build -q -t localhost:5001/demo:good2 --build-arg GIT_COMMIT=cccccccccccccccccccccccccccccccccccccccc --build-arg APP_VERSION=0.2.0 "$APP" >/dev/null
docker build -q -t localhost:5001/demo:broken --build-arg GIT_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --build-arg BROKEN=1 "$APP" >/dev/null
for t in good good2 broken; do docker push -q "localhost:5001/demo:$t" >/dev/null; done
docker push -q localhost:5001/factory-backup:test >/dev/null
ref() { echo "$REG/demo@$(docker inspect --format '{{index .RepoDigests 0}}' "localhost:5001/demo:$1" | cut -d@ -f2)"; }
echo "::endgroup::"

echo "::group::Secrets und Root-Application"
PG_PW=$(openssl rand -hex 16); HEALTH=$(openssl rand -hex 16)
kubectl create namespace "$NS"
kubectl -n "$NS" create secret generic app-secrets \
  --from-literal=POSTGRES_PASSWORD="$PG_PW" \
  --from-literal=DATABASE_URL="postgres://app:$PG_PW@db:5432/app" \
  --from-literal=HEALTH_TOKEN="$HEALTH" \
  --from-literal=RESTIC_REPOSITORY="s3:http://$S3_IP:8333/backups/demo-staging-k3s" \
  --from-literal=RESTIC_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=AWS_ACCESS_KEY_ID=e2e --from-literal=AWS_SECRET_ACCESS_KEY=e2e-secret
kubectl apply -f - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: demo-staging-root, namespace: argocd }
spec:
  project: default
  source:
    repoURL: https://github.com/${GITHUB_REPOSITORY}.git
    targetRevision: ${BRANCH}
    path: argocd/staging
  destination: { server: https://kubernetes.default.svc, namespace: argocd }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    retry: { limit: 20, backoff: { duration: 10s, factor: 1, maxDuration: 10s } }
YAML
echo "::endgroup::"

{
  echo "good=$(ref good)"
  echo "good2=$(ref good2)"
  echo "broken=$(ref broken)"
  echo "secrets=$(jq -cn --arg h "$HEALTH" '{HEALTH_TOKEN: $h}')"
  echo "values=$(jq -cn --arg b "$REG/factory-backup:test" '{backup: {image: $b}}')"
} >> "$OUT"
