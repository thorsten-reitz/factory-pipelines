#!/usr/bin/env bash
# Selbsttest: macht den GitHub-Runner zu einem Deploy-Host (Stufe compose).
# Lokale Registry statt GHCR, SeaweedFS (S3-Gateway) statt S3, Secrets-Provider "file" statt Infisical.
# Schreibt nach $GITHUB_OUTPUT: good, broken (Image-Referenzen mit Digest), secrets (Test-Secrets für deploy-env).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/examples/demo-app"
COMMIT="${GITHUB_SHA:?}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

echo "::group::Registry und S3"
docker run -d --name registry -p 5000:5000 registry:2 >/dev/null
# Ohne konfigurierte Identitäten nimmt das S3-Gateway von SeaweedFS jede Anfrage an: genug für den Test
docker run -d --name s3 -p 8333:8333 chrislusf/seaweedfs:4.50 \
  server -dir=/data -s3 -s3.port=8333 -master.volumeSizeLimitMB=256 >/dev/null
for _ in $(seq 1 60); do curl -s -o /dev/null http://localhost:8333/ && break; sleep 1; done
curl -s -o /dev/null -w "S3-Gateway antwortet (HTTP %{http_code})\n" http://localhost:8333/
echo "::endgroup::"

echo "::group::Images bauen"
docker build -q -t factory-backup:test "$ROOT/images/backup" >/dev/null
docker build -q -t localhost:5000/demo:good --build-arg GIT_COMMIT="$COMMIT" "$APP" >/dev/null
docker build -q -t localhost:5000/demo:broken --build-arg GIT_COMMIT="$COMMIT" --build-arg BROKEN=1 "$APP" >/dev/null
docker push -q localhost:5000/demo:good >/dev/null
docker push -q localhost:5000/demo:broken >/dev/null
GOOD=$(docker inspect --format '{{index .RepoDigests 0}}' localhost:5000/demo:good)
BROKEN=$(docker inspect --format '{{index .RepoDigests 0}}' localhost:5000/demo:broken)
echo "good=$GOOD"; echo "broken=$BROKEN"
echo "::endgroup::"

echo "::group::sshd und Host einrichten"
sudo apt-get install -y -qq openssh-server >/dev/null
sudo systemctl start ssh
KEYDIR=$(mktemp -d)
ssh-keygen -q -t ed25519 -N '' -C deploy-e2e -f "$KEYDIR/id"
sudo "$ROOT/host/install.sh" --pubkey "$(cat "$KEYDIR/id.pub")" --secrets-provider file \
  --sites-dir /tmp/e2e-sites --caddy-reload true --backup-image factory-backup:test --no-systemd
echo "::endgroup::"

PG_PW=$(openssl rand -hex 16)
jq -n --arg pw "$PG_PW" --arg ht "$(openssl rand -hex 16)" --arg rp "$(openssl rand -hex 16)" '{
  POSTGRES_PASSWORD: $pw,
  DATABASE_URL: ("postgres://app:" + $pw + "@db:5432/app"),
  HEALTH_TOKEN: $ht,
  RESTIC_REPOSITORY: "s3:http://host.docker.internal:8333/backups/demo-staging",
  RESTIC_PASSWORD: $rp,
  AWS_ACCESS_KEY_ID: "e2e-access",
  AWS_SECRET_ACCESS_KEY: "e2e-secret-key-123"
}' > "$KEYDIR/demo-staging.json"
sudo install -d -m 0700 /etc/factory-host/test-secrets
sudo install -m 0600 "$KEYDIR/demo-staging.json" /etc/factory-host/test-secrets/demo-staging.json

HOSTKEY=$(sudo awk '{print $1" "$2}' /etc/ssh/ssh_host_ed25519_key.pub)
SECRETS=$(jq -cn --arg key "$(cat "$KEYDIR/id")" --arg hk "$HOSTKEY" \
  '{DEPLOY_HOST: "127.0.0.1", DEPLOY_SSH_KEY: $key, DEPLOY_HOST_KEY: $hk}')
rm -rf "$KEYDIR"
{
  echo "good=$GOOD"
  echo "broken=$BROKEN"
  echo "secrets=$SECRETS"
} >> "$OUT"
