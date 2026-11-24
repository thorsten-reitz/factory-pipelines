#!/usr/bin/env bash
# Richtet einen Deploy-Host (Stufe compose) ein. Läuft als root, mehrfach ausführen ist ok.
# Wird von templates/cloud-init/compose-host.yaml aufgerufen; von Hand nur in Ausnahmefällen.
#
#   host/install.sh --pubkey "ssh-ed25519 AAAA... deploy" [Optionen]
#
#   --pubkey KEY             öffentlicher Deploy-Schlüssel (privater Teil liegt als DEPLOY_SSH_KEY in Infisical)
#   --allow LISTE            Apps, die der Schlüssel verändern darf: "*" (Standard) oder "app-staging,app-production"
#   --sites-dir DIR          Caddy-Site-Dateien (Standard /etc/caddy/sites.d; Factory-Server: /etc/software-factory/sites.d)
#   --caddy-reload CMD       Befehl zum Neuladen von Caddy (Standard "systemctl reload caddy"; Factory-Server: "true")
#   --secrets-provider P     infisical (Standard) | file (nur Tests)
#   --infisical-domain URL   Standard https://eu.infisical.com
#   --backup-image IMG       Standard ghcr.io/thorsten-reitz/factory-pipelines/backup:v0
#   --no-systemd             Units nicht installieren (Tests in Containern)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Bitte als root ausführen" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

PUBKEY=""; ALLOW="*"; SITES_DIR=/etc/caddy/sites.d; CADDY_RELOAD="systemctl reload caddy"
SECRETS_PROVIDER=infisical; INFISICAL_DOMAIN=https://eu.infisical.com
BACKUP_IMAGE=ghcr.io/thorsten-reitz/factory-pipelines/backup:v0; SYSTEMD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --pubkey) PUBKEY="$2"; shift 2 ;;
    --allow) ALLOW="$2"; shift 2 ;;
    --sites-dir) SITES_DIR="$2"; shift 2 ;;
    --caddy-reload) CADDY_RELOAD="$2"; shift 2 ;;
    --secrets-provider) SECRETS_PROVIDER="$2"; shift 2 ;;
    --infisical-domain) INFISICAL_DOMAIN="$2"; shift 2 ;;
    --backup-image) BACKUP_IMAGE="$2"; shift 2 ;;
    --no-systemd) SYSTEMD=0; shift ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
done
[[ "$PUBKEY" =~ ^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || { echo "--pubkey fehlt oder ist kein öffentlicher SSH-Schlüssel" >&2; exit 2; }
[[ "$ALLOW" =~ ^(\*|[a-z0-9,-]+)$ ]] || { echo "--allow: ungültige Liste" >&2; exit 2; }
for cmd in docker jq curl flock; do command -v "$cmd" >/dev/null || { echo "$cmd fehlt" >&2; exit 1; }; done

echo "▶ Nutzer deploy"
id deploy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash deploy
usermod -aG docker deploy

echo "▶ Skripte nach /opt/factory"
install -d -m 0755 /opt/factory/bin /opt/factory/lib
install -m 0755 "$SRC"/bin/factory-host "$SRC"/bin/factory-secrets "$SRC"/bin/factory-site "$SRC"/bin/with-secrets /opt/factory/bin/
install -m 0644 "$SRC"/lib/common.sh /opt/factory/lib/

echo "▶ Einstellungen /etc/factory-host/host.env"
install -d -m 0755 /etc/factory-host
install -d -m 0700 /etc/factory-host/credentials
q() { printf '%q' "$1"; }
cat > /etc/factory-host/host.env <<EOF
# Erzeugt von host/install.sh. Gehört root; deploy darf nur lesen.
SRV_DIR=/srv
SECRETS_DIR=/run/secrets
FACTORY_BIN=/opt/factory/bin
SITES_DIR=$(q "$SITES_DIR")
CADDY_RELOAD=$(q "$CADDY_RELOAD")
SECRETS_PROVIDER=$(q "$SECRETS_PROVIDER")
INFISICAL_DOMAIN=$(q "$INFISICAL_DOMAIN")
CREDS_DIR=/etc/factory-host/credentials
TEST_SECRETS_DIR=/etc/factory-host/test-secrets
BACKUP_IMAGE=$(q "$BACKUP_IMAGE")
EOF
chmod 0644 /etc/factory-host/host.env

# Bootstrap-Identität aus cloud-init: Client-Secret mit systemd-creds verschlüsseln, Klartext löschen
if [ -f /etc/factory-host/bootstrap/infisical-client-secret ]; then
  echo "▶ Host-Identität verschlüsseln"
  install -m 0600 /etc/factory-host/bootstrap/infisical-client-id /etc/factory-host/credentials/infisical-client-id
  systemd-creds encrypt --name=infisical-client-secret /etc/factory-host/bootstrap/infisical-client-secret \
    /etc/factory-host/credentials/infisical-client-secret.cred
  shred -u /etc/factory-host/bootstrap/infisical-client-secret 2>/dev/null || rm -f /etc/factory-host/bootstrap/infisical-client-secret
  rm -f /etc/factory-host/bootstrap/infisical-client-id
fi

echo "▶ Ordner"
install -d -m 0755 -o deploy -g deploy /srv
install -d -m 0755 "$SITES_DIR"

echo "▶ SSH: Forced Command für deploy"
install -d -m 0700 -o deploy -g deploy /home/deploy/.ssh
LINE="command=\"/opt/factory/bin/factory-host --ssh --allow '$ALLOW'\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty $PUBKEY"
AUTH=/home/deploy/.ssh/authorized_keys
touch "$AUTH"
KEYPART=$(awk '{print $2}' <<<"$PUBKEY")
grep -v -F "$KEYPART" "$AUTH" > "$AUTH.tmp" || true
echo "$LINE" >> "$AUTH.tmp"
mv -f "$AUTH.tmp" "$AUTH"
chown deploy:deploy "$AUTH"; chmod 0600 "$AUTH"

echo "▶ sudo-Freigaben (nur factory-secrets und factory-site)"
cat > /etc/sudoers.d/factory-host <<'EOF'
deploy ALL=(root) NOPASSWD: /opt/factory/bin/factory-secrets *, /opt/factory/bin/factory-site *
EOF
chmod 0440 /etc/sudoers.d/factory-host
visudo -cf /etc/sudoers.d/factory-host >/dev/null

if [ "$SYSTEMD" = 1 ]; then
  echo "▶ systemd-Units"
  install -m 0644 "$SRC"/systemd/*.service "$SRC"/systemd/*.timer /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable factory-secrets-boot.service >/dev/null 2>&1
  systemctl enable --now factory-backup.timer factory-restore-test.timer factory-heartbeat.timer >/dev/null 2>&1
fi

echo "✓ Deploy-Host eingerichtet"
