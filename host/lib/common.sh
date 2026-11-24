# shellcheck shell=bash
# Gemeinsame Funktionen der Host-Skripte. Wird von factory-host, factory-secrets und factory-site geladen.

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "FEHLER: $*"; exit 1; }

# Host-Einstellungen aus /etc/factory-host/host.env (gehört root, für deploy nur lesbar)
load_host_env() {
  local f="${FACTORY_HOST_ENV:-/etc/factory-host/host.env}"
  # shellcheck disable=SC1090
  [ -f "$f" ] && . "$f"
  : "${SRV_DIR:=/srv}"
  : "${SECRETS_DIR:=/run/secrets}"
  : "${FACTORY_BIN:=/opt/factory/bin}"
  : "${SITES_DIR:=/etc/caddy/sites.d}"
  : "${CADDY_RELOAD:=systemctl reload caddy}"
  : "${SECRETS_PROVIDER:=infisical}"
  : "${INFISICAL_DOMAIN:=https://eu.infisical.com}"
  : "${CREDS_DIR:=/etc/factory-host/credentials}"
  : "${TEST_SECRETS_DIR:=/etc/factory-host/test-secrets}"
  : "${BACKUP_IMAGE:=ghcr.io/thorsten-reitz/factory-pipelines/backup:v0}"
  : "${KAMAL_PROXY_IMAGE:=basecamp/kamal-proxy:v0.10.2}"
  : "${KEEP_RELEASES:=5}"
  : "${HEALTH_TIMEOUT:=120}"
  : "${USE_SUDO:=1}"
}

valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; }
valid_env() { [[ "$1" =~ ^(staging|production)$ ]]; }
valid_image() { [[ "$1" =~ ^[a-z0-9./:_-]+@sha256:[a-f0-9]{64}$ ]]; }
valid_domain() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{4,5}$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; }
valid_secret_key() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
valid_snapshot() { [[ "$1" =~ ^(latest|[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2})?)$ ]]; }

# Steht <name> in der Liste erlaubter Apps des SSH-Schlüssels? Liste: "*" oder "a-staging,a-production"
allowed() {
  local name="$1" list="$2" item
  [ "$list" = "*" ] && return 0
  IFS=',' read -ra items <<<"$list"
  for item in "${items[@]}"; do [ "$item" = "$name" ] && return 0; done
  return 1
}

# Meldet /health denselben Commit wie ausgerollt? Kurze und lange SHAs gelten als gleich.
commit_matches() {
  local expected="$1" reported="$2"
  [ -n "$expected" ] && [ -n "$reported" ] || return 1
  [[ "$expected" == "$reported"* || "$reported" == "$expected"* ]] && [ ${#reported} -ge 7 ]
}

# Bewertet die Antwort von /health: 0 = in Ordnung (ok oder degraded und richtiger Commit)
health_ok() {
  local json="$1" expected="$2" status reported
  status=$(jq -r '.status // empty' <<<"$json" 2>/dev/null) || return 1
  reported=$(jq -r '.commit // empty' <<<"$json" 2>/dev/null)
  case "$status" in ok|degraded) ;; *) log "Health: status '$status'"; return 1 ;; esac
  if [ -n "$expected" ] && ! commit_matches "$expected" "$reported"; then
    log "Health: Commit '$reported' statt '$expected'"
    return 1
  fi
  return 0
}

# Ein Wert aus einer JSON-Datei, leer wenn nicht vorhanden
json_get() { jq -r "$2 // empty" "$1"; }

as_root() { if [ "$USE_SUDO" = 1 ] && [ "$(id -u)" -ne 0 ]; then sudo -n "$@"; else "$@"; fi; }
