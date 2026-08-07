#!/usr/bin/env bash
# Hardening for a single-node public Eliza Hub (the topology created by a plain
# `docker compose up` on one server, as opposed to deployment/hetzner-staging).
#
#   bash deployment/single-node/harden.sh <server-ssh-target>
#
# Applies, idempotently:
#   1. Postgres for Merge Steward (the JSON store is single-process staging only)
#   2. Nightly local backups: full Forgejo dumps (3-day window, they are large)
#      plus small steward database dumps (30-day window)
#   3. A weekly restore drill, because an unrehearsed backup is a hypothesis
#   4. A health watchdog that restarts failed services and can alert
#   5. Unattended security upgrades
#
# It never deletes repository data and can be re-run safely.
set -euo pipefail

TARGET="${1:?usage: harden.sh <server-ssh-target>}"
SSH=(ssh -o StrictHostKeyChecking=accept-new "$TARGET")

echo "[1/5] Merge Steward on Postgres"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
cd /opt/eliza-hub

if ! grep -q '^MERGE_STEWARD_DATABASE_URL=' .env.merge-steward.local 2>/dev/null; then
  PGPASS="$(openssl rand -hex 24)"
  printf 'POSTGRES_PASSWORD=%s\nMERGE_STEWARD_DATABASE_URL=postgres://steward:%s@steward-db:5432/steward\n' \
    "$PGPASS" "$PGPASS" >> .env.merge-steward.local
  chmod 600 .env.merge-steward.local
fi

# Postgres service + steward wiring, layered on the committed compose files.
cat > compose.postgres.yml <<'YML'
services:
  steward-db:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: steward
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}"
      POSTGRES_DB: steward
    volumes:
      - steward-db-data:/var/lib/postgresql/data
    networks: [forgejo]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U steward"]
      interval: 10s
      timeout: 5s
      retries: 10

  merge-steward:
    environment:
      DATABASE_URL: "${MERGE_STEWARD_DATABASE_URL}"
    depends_on:
      steward-db:
        condition: service_healthy

volumes:
  steward-db-data:
YML

set -a; source .env.merge-steward.local; set +a
COMPOSE=(docker compose -f compose.yml -f compose.override.yml -f compose.merge-steward.yml -f compose.postgres.yml)
"${COMPOSE[@]}" up -d steward-db
# Wait for the database to accept connections before migrating.
for _ in $(seq 1 30); do
  docker compose -f compose.yml -f compose.postgres.yml exec -T steward-db pg_isready -U steward >/dev/null 2>&1 && break
  sleep 2
done
"${COMPOSE[@]}" run --rm --entrypoint sh merge-steward -c 'npm run migrate' 2>&1 | tail -3
"${COMPOSE[@]}" up -d
REMOTE

echo "[2/5] Nightly backups (Forgejo dumps 3 days, steward database 30 days)"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
install -d -m 700 /var/backups/eliza-hub
cat > /usr/local/bin/eliza-hub-backup <<'SCRIPT'
#!/usr/bin/env bash
# Nightly Eliza Hub backup. Forgejo's own dump captures repositories, the
# database, config, and attachments as one consistent archive.
set -euo pipefail
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="/var/backups/eliza-hub"
install -d -m 700 "$DEST"

# /data itself is root-owned; dump into a git-writable subdirectory.
docker exec eliza-forgejo-local sh -c 'install -d -o git -g git /data/backup-staging'
docker exec -u git -w /data/backup-staging eliza-forgejo-local \
  forgejo dump --file "/data/backup-staging/dump-${STAMP}.zip" --type zip >/dev/null
docker cp "eliza-forgejo-local:/data/backup-staging/dump-${STAMP}.zip" "${DEST}/forgejo-${STAMP}.zip"
docker exec eliza-forgejo-local rm -f "/data/backup-staging/dump-${STAMP}.zip"

if docker ps --format '{{.Names}}' | grep -q '^eliza-hub-steward-db-1$'; then
  docker exec eliza-hub-steward-db-1 pg_dump -U steward steward | gzip > "${DEST}/steward-${STAMP}.sql.gz"
fi

# Retention. Full Forgejo dumps include every repository, so they are large
# (gigabytes); keep a short window of them and a longer one of the small
# database dumps. Sized so a single-node 150G disk cannot fill from backups.
find "$DEST" -name 'forgejo-*.zip' -type f -mtime +2 -delete
find "$DEST" -name 'steward-*.sql.gz' -type f -mtime +30 -delete
SCRIPT
chmod 700 /usr/local/bin/eliza-hub-backup

cat > /etc/systemd/system/eliza-hub-backup.service <<'UNIT'
[Unit]
Description=Eliza Hub nightly backup
[Service]
Type=oneshot
ExecStart=/usr/local/bin/eliza-hub-backup
UNIT

cat > /etc/systemd/system/eliza-hub-backup.timer <<'UNIT'
[Unit]
Description=Run the Eliza Hub backup nightly
[Timer]
OnCalendar=*-*-* 03:30:00 UTC
Persistent=true
[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now eliza-hub-backup.timer >/dev/null
REMOTE

echo "[3/5] Weekly restore drill"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
# A drill nobody runs is a script, not a guarantee. Schedule it against the
# checked-out copy so it tracks the repository rather than a stale install.
cat > /etc/systemd/system/eliza-hub-restore-drill.service <<'UNIT'
[Unit]
Description=Eliza Hub restore drill
[Service]
Type=oneshot
ExecStart=/bin/bash /opt/eliza-hub/deployment/single-node/restore-drill.sh --local
UNIT

cat > /etc/systemd/system/eliza-hub-restore-drill.timer <<'UNIT'
[Unit]
Description=Rehearse an Eliza Hub restore weekly
[Timer]
OnCalendar=Sun *-*-* 05:00:00 UTC
Persistent=true
[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now eliza-hub-restore-drill.timer >/dev/null
REMOTE

echo "[4/5] Health watchdog"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
cat > /usr/local/bin/eliza-hub-healthcheck <<'SCRIPT'
#!/usr/bin/env bash
# Single-node health watchdog. Checks each surface, restarts a container that
# is failing its check, and reports. Set ELIZA_HUB_ALERT_WEBHOOK in
# /etc/default/eliza-hub to receive alerts (any endpoint accepting a JSON
# {"content": "..."} body, which covers Discord and Slack-compatible hooks).
set -uo pipefail
[ -f /etc/default/eliza-hub ] && . /etc/default/eliza-hub

problems=()

check() {
  local name="$1" container="$2" probe="$3"
  if eval "$probe" >/dev/null 2>&1; then
    return 0
  fi
  problems+=("$name")
  logger -t eliza-hub-health "unhealthy: $name — restarting $container"
  docker restart "$container" >/dev/null 2>&1 || true
  sleep 10
  if eval "$probe" >/dev/null 2>&1; then
    logger -t eliza-hub-health "recovered: $name"
    return 0
  fi
  logger -t eliza-hub-health "STILL UNHEALTHY after restart: $name"
  return 1
}

unrecovered=()
check forgejo eliza-forgejo-local \
  'curl -fsS -m 10 http://127.0.0.1:3000/api/healthz' || unrecovered+=("forgejo")
# docker ps -a, not docker ps: a stopped container is exactly the failure this
# watchdog exists to catch, and listing only running ones would skip it.
if docker ps -a --format '{{.Names}}' | grep -q '^eliza-hub-merge-steward-1$'; then
  check merge-steward eliza-hub-merge-steward-1 \
    'curl -fsS -m 10 http://127.0.0.1:8787/health' || unrecovered+=("merge-steward")
fi
if docker ps -a --format '{{.Names}}' | grep -q '^eliza-hub-steward-db-1$'; then
  check steward-db eliza-hub-steward-db-1 \
    'docker exec eliza-hub-steward-db-1 pg_isready -U steward' || unrecovered+=("steward-db")
fi

# Disk is the other thing that silently kills a forge: repositories and
# backups both grow without asking.
usage="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
if [ "${usage:-0}" -ge 85 ]; then
  unrecovered+=("disk ${usage}% full")
  logger -t eliza-hub-health "disk usage ${usage}%"
fi

if [ "${#unrecovered[@]}" -gt 0 ] && [ -n "${ELIZA_HUB_ALERT_WEBHOOK:-}" ]; then
  msg="Eliza Hub on $(hostname): ${unrecovered[*]}"
  curl -fsS -m 10 -X POST "$ELIZA_HUB_ALERT_WEBHOOK" \
    -H 'Content-Type: application/json' \
    --data "$(printf '{"content":"%s"}' "$msg")" >/dev/null 2>&1 || true
fi

[ "${#unrecovered[@]}" -eq 0 ]
SCRIPT
chmod 700 /usr/local/bin/eliza-hub-healthcheck
[ -f /etc/default/eliza-hub ] || printf '# ELIZA_HUB_ALERT_WEBHOOK=https://...\n' > /etc/default/eliza-hub

cat > /etc/systemd/system/eliza-hub-health.service <<'UNIT'
[Unit]
Description=Eliza Hub health watchdog
[Service]
Type=oneshot
ExecStart=/usr/local/bin/eliza-hub-healthcheck
UNIT

cat > /etc/systemd/system/eliza-hub-health.timer <<'UNIT'
[Unit]
Description=Run the Eliza Hub health watchdog every five minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now eliza-hub-health.timer >/dev/null
REMOTE

echo "[5/5] Unattended security upgrades"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -qy unattended-upgrades >/dev/null
systemctl enable --now unattended-upgrades >/dev/null
REMOTE

echo
echo "Status:"
"${SSH[@]}" 'docker ps --format "  {{.Names}}: {{.Status}}"
  printf "  backup timer: %s\n" "$(systemctl is-active eliza-hub-backup.timer)"
  printf "  health timer: %s\n" "$(systemctl is-active eliza-hub-health.timer)"'
