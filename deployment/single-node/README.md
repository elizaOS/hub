# Single-Node Deployment

Scripts for running a public Eliza Hub on one server. This is the simplest
supported topology: Forgejo, Merge Steward, and Postgres in Compose on a single
host, with Caddy terminating TLS.

For the multi-host staging topology with Terraform, isolated Actions runners,
offsite backups, observability, and the production evidence gates, use
[`../hetzner-staging/`](../hetzner-staging/) instead.

## Requirements

- A fresh Ubuntu 24.04 host with root SSH access (2 vCPU / 4 GB RAM is enough
  to start; repositories dominate disk use, so size the disk for them)
- A DNS A record pointing your domain at the host, not proxied, so Caddy can
  complete the ACME HTTP challenge
- Inbound 22, 80, and 443 open

## Deploy

```sh
bash deployment/single-node/deploy.sh <server-ip> <domain>
```

Installs Docker and Caddy, clones the repository to `/opt/eliza-hub`, generates
the webhook secret, and starts Forgejo behind Caddy with automatic TLS.

Then create an administrator:

```sh
ssh root@<server-ip> docker exec -u git eliza-forgejo-local \
  forgejo admin user create --admin --username ADMIN --password PASS --email you@example.com
```

## Harden

```sh
bash deployment/single-node/harden.sh root@<server-ip>
```

Moves Merge Steward from the JSON queue store, which the service reports as
single-process staging only, onto Postgres with migrations applied; installs
nightly backups on a systemd timer; and enables unattended security upgrades.
Idempotent, and it never deletes repository data.

Backups land in `/var/backups/eliza-hub`: full Forgejo dumps kept for a short
window because they contain every repository, and small steward database dumps
kept for a month.

### Getting backups off the machine

A backup on the same disk is not a backup. Add at least one of:

- **Provider snapshots.** On Hetzner, `hcloud server enable-backup <server>`
  keeps rolling full-server images outside the server's disk for 20% of the
  server price. This is the least-effort protection against losing the host and
  is worth enabling immediately.
- **Encrypted offsite copies.** `../hetzner-staging/scripts/backup-offsite.sh`
  encrypts with age and ships through rclone; point it at
  `/var/backups/eliza-hub` and give it a remote (object storage in a different
  provider or region). `restore-offsite-check.sh` verifies what landed.

Neither is a backup until a restore has been rehearsed. `restore-drill.sh` in
the same directory performs that rehearsal.

## Actions runners

Forgejo Actions is enabled by the base configuration, but jobs queue forever
until a runner is registered. `compose.runner.yml` in this directory adds one
with the isolation the rest of this repository assumes: the runner never sees
the host Docker socket, neither service publishes a port, and jobs run in
containers rather than on the host.

Register it against an **organisation**, not the whole instance. On a hub with
open registration, an instance-scoped runner would execute code from any
repository anyone creates:

```sh
TOKEN=$(curl -s -u ADMIN:PASS \
  http://127.0.0.1:3000/api/v1/orgs/YOUR_ORG/actions/runners/registration-token \
  | sed 's/.*"token":"\([^"]*\)".*/\1/')

cd /opt/eliza-hub
set -a && source .env.merge-steward.local && set +a
RUNNER_REGISTRATION_TOKEN="$TOKEN" docker compose \
  -f compose.yml -f compose.override.yml \
  -f compose.merge-steward.yml -f compose.postgres.yml \
  -f deployment/single-node/compose.runner.yml up -d runner-docker runner
```

Turn Actions off for mirrored repositories whose real CI lives upstream
(`PATCH /api/v1/repos/OWNER/NAME` with `{"has_actions": false}`). A mirror of a
large monorepo will otherwise queue its entire upstream pipeline against a
single node, which fails slowly and tells you nothing.

Runner capacity is the expensive resource on a public instance. Treat untrusted
pull-request code as hostile: keep the runner org-scoped, size the host for the
concurrency you intend to allow, and meter it before opening it to everyone.

## Enabling Merge Steward

Merge Steward is optional; ordinary Git hosting does not need it. To enable
agent coordination, create a Forgejo API token for the bot account, set
`FORGEJO_STEWARD_TOKEN` in `/opt/eliza-hub/.env.merge-steward.local`, then
bring the stack up with the steward overlay:

```sh
cd /opt/eliza-hub
set -a && source .env.merge-steward.local && set +a
docker compose -f compose.yml -f compose.override.yml \
  -f compose.merge-steward.yml -f compose.postgres.yml up -d --build
```

Register a signed webhook per repository pointing at
`http://merge-steward:8787/api/webhooks/forgejo`, and register the repository
policy with `POST /api/repo-policies`. Live merge execution stays disabled
until the production gates in `docs/readiness.md` pass.
