#!/usr/bin/env bash
# One-shot provisioning of a public single-node Eliza Hub on a fresh Ubuntu
# 24.04 host.
#
#   bash deployment/single-node/deploy.sh <server-ip> <domain>
#
# Installs Docker and Caddy, clones this repository to /opt/eliza-hub, starts
# Forgejo behind Caddy, and generates the webhook secret. Idempotent: safe to
# re-run. Requires root SSH access to the host, and a DNS A record pointing
# <domain> at <server-ip> before Caddy can issue a TLS certificate.
#
# Run deployment/single-node/harden.sh afterwards for Postgres-backed Merge
# Steward, nightly backups, and unattended security upgrades.
set -euo pipefail

SERVER_IP="${1:?usage: deploy.sh <server-ip> <domain>}"
DOMAIN="${2:?usage: deploy.sh <server-ip> <domain>}"
SSH=(ssh -o StrictHostKeyChecking=accept-new "root@${SERVER_IP}")

echo "[1/6] Base packages + Docker"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -qy ca-certificates curl git ufw
install -m 0755 -d /etc/apt/keyrings
[ -f /etc/apt/keyrings/docker.asc ] || curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -qy docker-ce docker-ce-cli containerd.io docker-compose-plugin caddy || {
  # caddy lives in its own repo on ubuntu
  apt-get install -qy docker-ce docker-ce-cli containerd.io docker-compose-plugin
  apt-get install -qy debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q && apt-get install -qy caddy
}
ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
yes | ufw enable >/dev/null || true
REMOTE

echo "[2/6] Clone/update elizaOS/hub"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
if [ -d /opt/eliza-hub/.git ]; then git -C /opt/eliza-hub pull -q origin main
else git clone -q https://github.com/elizaOS/hub /opt/eliza-hub; fi
REMOTE

echo "[3/6] Environment (generated once, kept across runs)"
"${SSH[@]}" bash -s <<REMOTE
set -euo pipefail
cd /opt/eliza-hub
if [ ! -f .env.merge-steward.local ]; then
  WEBHOOK_SECRET=\$(openssl rand -hex 24)
  printf 'FORGEJO_WEBHOOK_SECRET=%s\nFORGEJO_STEWARD_TOKEN=pending\n' "\$WEBHOOK_SECRET" > .env.merge-steward.local
  chmod 600 .env.merge-steward.local
fi
# Production URL overrides for the public domain
cat > compose.override.yml <<'YML'
services:
  server:
    environment:
      FORGEJO__server__DOMAIN: "${DOMAIN}"
      FORGEJO__server__ROOT_URL: "https://${DOMAIN}/"
YML
REMOTE

echo "[4/6] Caddy reverse proxy with automatic TLS"
"${SSH[@]}" bash -s <<REMOTE
set -euo pipefail
cat > /etc/caddy/Caddyfile <<'CADDY'
${DOMAIN} {
	reverse_proxy 127.0.0.1:3000
	encode gzip
}
CADDY
systemctl reload caddy || systemctl restart caddy
REMOTE

echo "[5/6] Start the stack (Forgejo + Merge Steward)"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
cd /opt/eliza-hub
set -a; source .env.merge-steward.local; set +a
docker compose -f compose.yml -f compose.override.yml up -d
# steward comes up after the token exists (second run wires it)
if [ "${FORGEJO_STEWARD_TOKEN}" != "pending" ]; then
  docker compose -f compose.yml -f compose.override.yml -f compose.merge-steward.yml up -d --build
fi
REMOTE

echo "[6/6] Status"
"${SSH[@]}" 'docker ps --format "{{.Names}}: {{.Status}}"; curl -s -o /dev/null -w "local forgejo: %{http_code}\n" http://127.0.0.1:3000/'
echo
echo "Next (after DNS ${DOMAIN} -> ${SERVER_IP} is live):"
echo "  1. https://${DOMAIN} should serve with TLS (Caddy fetches the cert on first request)."
echo "  2. Create the admin account:"
echo "       ssh root@${SERVER_IP} docker exec -u git eliza-forgejo-local \\"
echo "         forgejo admin user create --admin --username ADMIN --password PASS --email you@example.com"
echo "  3. Harden the node (Postgres steward, backups, security updates):"
echo "       bash deployment/single-node/harden.sh root@${SERVER_IP}"
