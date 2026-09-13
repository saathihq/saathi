#!/usr/bin/env bash
#
# Deploys both halves of Saathi to one VPS behind Caddy:
#
#   the site  ->  rsync site/ to /var/www/saathi, served statically
#   the API   ->  build the backend image on the server, (re)start the container on 127.0.0.1:8787
#
#   SAATHI_SERVER=user@host scripts/deploy.sh            # both
#   SAATHI_SERVER=user@host scripts/deploy.sh --site     # the static site only (fast)
#   SAATHI_SERVER=user@host scripts/deploy.sh --api      # the backend only
#   SAATHI_SERVER=user@host scripts/deploy.sh --env      # ...and upload backend/.env as backend.env
#
# There is deliberately no default target. A public repo that ships `root@<address>` as a default
# has published where the server is and that it is reached as root — to every reader and every fork.
#
#   export SAATHI_SERVER=root@saathi.dev        # ssh target; prefer the hostname over a raw IP
#   export SAATHI_SITE_HOST=saathi.dev          # optional, defaults below
#   export SAATHI_API_HOST=api.saathi.dev       # optional, defaults below
#
# DNS (Porkbun, where saathi.dev is registered): two A records, both pointing at the same server.
#   saathi.dev       A   <server ip>
#   api.saathi.dev   A   <server ip>
# Caddy provisions certificates for both once the records resolve.
set -euo pipefail

if [[ -z "${SAATHI_SERVER:-}" ]]; then
  cat >&2 <<'USAGE'
SAATHI_SERVER is not set — this script has no default deploy target on purpose.

  export SAATHI_SERVER=root@saathi.dev        # ssh target, host or user@host
  export SAATHI_SITE_HOST=saathi.dev          # optional (default: saathi.dev)
  export SAATHI_API_HOST=api.saathi.dev       # optional (default: api.saathi.dev)

Then run this script again.
USAGE
  exit 2
fi

SERVER="$SAATHI_SERVER"
SITE_HOST="${SAATHI_SITE_HOST:-saathi.dev}"
API_HOST="${SAATHI_API_HOST:-api.saathi.dev}"
REMOTE_DIR=/opt/saathi
SITE_DIR=/var/www/saathi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DO_SITE=1
DO_API=1
UPLOAD_ENV=0
for arg in "$@"; do
  case "$arg" in
    --site) DO_API=0 ;;
    --api)  DO_SITE=0 ;;
    --env)  UPLOAD_ENV=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# A stale generated contract would deploy a backend whose route list disagrees with the clients'.
# Cheap to check here, confusing to debug later.
echo "▸ checking the generated contract is current"
node "$REPO_DIR/contract/generate.mjs" --check

if [[ $DO_SITE -eq 1 ]]; then
  echo "▸ syncing site/ to $SERVER:$SITE_DIR  (served at https://$SITE_HOST)"
  ssh "$SERVER" "mkdir -p $SITE_DIR"
  # --delete so a file removed from the repo actually disappears from the server.
  rsync -az --delete "$REPO_DIR/site/" "$SERVER:$SITE_DIR/"
fi

if [[ $DO_API -eq 1 ]]; then
  echo "▸ syncing source to $SERVER:$REMOTE_DIR/src"
  ssh "$SERVER" "mkdir -p $REMOTE_DIR/src"
  rsync -az --delete \
    --exclude node_modules --exclude dist --exclude .git --exclude '.env' \
    --exclude macos --exclude windows --exclude site --exclude .build \
    "$REPO_DIR/" "$SERVER:$REMOTE_DIR/src/"

  if [[ $UPLOAD_ENV -eq 1 ]]; then
    echo "▸ uploading backend/.env as $REMOTE_DIR/backend.env"
    scp -q "$REPO_DIR/backend/.env" "$SERVER:$REMOTE_DIR/backend.env"
    ssh "$SERVER" "chmod 600 $REMOTE_DIR/backend.env"
  fi

  echo "▸ building the image and starting the container"
  ssh "$SERVER" bash -s <<'REMOTE'
set -euo pipefail
cd /opt/saathi
[[ -f backend.env ]] || { echo "missing /opt/saathi/backend.env (run once with --env)" >&2; exit 1; }
cp src/backend/deploy/docker-compose.yml docker-compose.yml
docker build -q -f src/backend/Dockerfile -t saathi-backend:latest src >/dev/null
docker compose up -d --remove-orphans
sleep 2
curl -sf http://127.0.0.1:8787/health && echo "  backend healthy on 127.0.0.1:8787"
docker image prune -f >/dev/null
REMOTE
fi

echo "▸ ensuring the Caddy site blocks exist"
# Copied straight across rather than read from the synced source tree: a --site-only run never
# syncs src/, and the first such run would otherwise look for a template that is not there yet.
ssh "$SERVER" "mkdir -p $REMOTE_DIR"
scp -q "$REPO_DIR/deploy/Caddyfile.saathi" "$SERVER:$REMOTE_DIR/Caddyfile.saathi.template"

ssh "$SERVER" bash -s -- "$SITE_HOST" "$API_HOST" "$REMOTE_DIR" <<'REMOTE'
set -euo pipefail
SITE_HOST="$1"; API_HOST="$2"; REMOTE_DIR="$3"
if grep -qE "^${SITE_HOST}[[:space:]]*\{" /etc/caddy/Caddyfile 2>/dev/null; then
  echo "  Caddy already serves $SITE_HOST — leaving the existing block alone"
else
  cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak-$(date +%Y%m%d-%H%M%S)"
  { echo; sed -e "s/__SITE_HOST__/$SITE_HOST/g" -e "s/__API_HOST__/$API_HOST/g" \
      "$REMOTE_DIR/Caddyfile.saathi.template"; } >> /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile >/dev/null
  systemctl reload caddy
  echo "  added the Caddy site blocks for $SITE_HOST and $API_HOST"
fi
REMOTE

echo "▸ done"
# `if`, not `[[ … ]] && echo` — under `set -e` a false test as the last command in an && list
# exits the script with status 1, which would report a successful deploy as a failed one.
if [[ $DO_SITE -eq 1 ]]; then echo "   https://$SITE_HOST"; fi
if [[ $DO_API  -eq 1 ]]; then echo "   https://$API_HOST/health"; fi
