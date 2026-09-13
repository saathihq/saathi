#!/usr/bin/env bash
#
# Deploys the Saathi API to a VPS behind Caddy.
#
# This is the SELF-HOSTING path. api.saathi.dev itself is deployed to Vercel (see vercel.json).
# Kept because "run your own backend" is a first-class option for an open-source companion that
# holds provider keys — the hosted default only means something if running your own genuinely works.
#
#   SAATHI_SERVER=user@host npm run deploy:selfhost
#   SAATHI_SERVER=user@host npm run deploy:selfhost -- --env   # ...and upload backend/.env once
#
# The website is a separate repository and is not deployed from here.
#
# There is deliberately no default target. A public repo that ships `root@<address>` as a default
# has published where the server is and that it is reached as root — to every reader and every fork.
#
#   export SAATHI_SERVER=root@your-box          # ssh target; prefer the hostname over a raw IP
#   export SAATHI_API_HOST=api.example.com      # optional, defaults to api.saathi.dev
#
# DNS: one A record for $SAATHI_API_HOST pointing at the server. Caddy provisions the certificate
# once it resolves.
set -euo pipefail

if [[ -z "${SAATHI_SERVER:-}" ]]; then
  cat >&2 <<'USAGE'
SAATHI_SERVER is not set — this script has no default deploy target on purpose.

  export SAATHI_SERVER=root@your-box          # ssh target, host or user@host
  export SAATHI_API_HOST=api.example.com      # optional (default: api.saathi.dev)

Then run this script again.
USAGE
  exit 2
fi

SERVER="$SAATHI_SERVER"
API_HOST="${SAATHI_API_HOST:-api.saathi.dev}"
REMOTE_DIR=/opt/saathi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

UPLOAD_ENV=0
for arg in "$@"; do
  case "$arg" in
    --env)  UPLOAD_ENV=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# A stale generated contract would deploy a backend whose route list disagrees with the clients'.
# Cheap to check here, confusing to debug later.
echo "▸ checking the generated contract is current"
node "$REPO_DIR/contract/generate.mjs" --check

  echo "▸ syncing source to $SERVER:$REMOTE_DIR/src"
  ssh "$SERVER" "mkdir -p $REMOTE_DIR/src"
  rsync -az --delete \
    --exclude node_modules --exclude dist --exclude .git --exclude '.env' \
    --exclude macos --exclude windows --exclude .build --exclude .vercel \
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
cp src/selfhost/docker-compose.yml docker-compose.yml
docker build -q -f src/selfhost/Dockerfile -t saathi-backend:latest src >/dev/null
docker compose up -d --remove-orphans
sleep 2
curl -sf http://127.0.0.1:8787/health && echo "  backend healthy on 127.0.0.1:8787"
docker image prune -f >/dev/null
REMOTE

echo "▸ ensuring the Caddy site block exists"
# Copied straight across rather than read from the synced source tree: a --site-only run never
# syncs src/, and the first such run would otherwise look for a template that is not there yet.
ssh "$SERVER" "mkdir -p $REMOTE_DIR"
scp -q "$REPO_DIR/selfhost/Caddyfile.saathi" "$SERVER:$REMOTE_DIR/Caddyfile.saathi.template"

ssh "$SERVER" bash -s -- "$API_HOST" "$REMOTE_DIR" <<'REMOTE'
set -euo pipefail
API_HOST="$1"; REMOTE_DIR="$2"
if grep -qE "^${API_HOST}[[:space:]]*\{" /etc/caddy/Caddyfile 2>/dev/null; then
  echo "  Caddy already serves $API_HOST — leaving the existing block alone"
else
  cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak-$(date +%Y%m%d-%H%M%S)"
  { echo; sed -e "s/__API_HOST__/$API_HOST/g" "$REMOTE_DIR/Caddyfile.saathi.template"; } \
    >> /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile >/dev/null
  systemctl reload caddy
  echo "  added the Caddy site block for $API_HOST"
fi
REMOTE

echo "▸ done — https://$API_HOST/health"
