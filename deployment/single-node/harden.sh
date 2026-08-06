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
#   3. Unattended security upgrades
#
# It never deletes repository data and can be re-run safely.
set -euo pipefail

TARGET="${1:?usage: harden.sh <server-ssh-target>}"
SSH=(ssh -o StrictHostKeyChecking=accept-new "$TARGET")

echo "[1/3] Merge Steward on Postgres"
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

echo "[2/3] Nightly backups (Forgejo dumps 3 days, steward database 30 days)"
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

echo "[3/3] Unattended security upgrades"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -qy unattended-upgrades >/dev/null
systemctl enable --now unattended-upgrades >/dev/null
REMOTE

echo
echo "Status:"
"${SSH[@]}" 'docker ps --format "  {{.Names}}: {{.Status}}"; systemctl is-active eliza-hub-backup.timer | sed "s/^/  backup timer: /"'
