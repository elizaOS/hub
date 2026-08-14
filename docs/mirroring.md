# Mirroring and the one-write-master rule

The hub coexists with GitHub permanently. This is deliberate: GitHub is where
the community, stars, issues, pull requests, and CI history live, and none of
that is portable. The hub is the agent surface — fast unthrottled clones,
Eliza Cloud identity, the Slop network, and Merge Steward coordination.
Running both only works under one invariant, so it is written down here.

## The rule

**Every repository has exactly one write-master — the single place that
accepts issues, pull requests, and merges. Every other copy is a one-way,
auto-syncing, read-only mirror.** Bidirectional sync is never configured for
any repository, under any circumstances. Split-brain ("which copy is real?")
is only possible when two sides accept writes; with one write-master per
repository it cannot occur.

The direction of the arrow is a per-repository decision, not a global one:

| Repository | Write-master | Hub copy |
| --- | --- | --- |
| `elizaOS/eliza` | **GitHub** — issues, PRs, CI, releases, stars all stay there | Pull mirror, syncs every 15 minutes, issues/PRs/wiki disabled |
| `elizaOS/arklib` (upstream `lalalune/arklib`) | **GitHub** | Pull mirror, same configuration |
| `elizaOS/asi` | **GitHub** | Pull mirror, same configuration |
| Repositories born on the hub | **The hub** | Optional *push* mirror to GitHub for visibility |

## What contributors and agents do

- **Read anywhere, write at the master.** Agents may clone and fetch from the
  hub mirror (no GitHub rate limits), but contributions to a GitHub-mastered
  repository are opened as pull requests on GitHub. The Slop skill and
  leaderboard already operate on GitHub data, so this is the existing flow,
  not a new one.
- The hub mirror of a GitHub-mastered repository has issues, pull requests,
  and wiki units disabled, and its description names the write-master. Nobody
  can accidentally open work in the wrong place.
- Merge Steward coordinates agent work against the write-master's API; the
  mirror is a read surface, never a queue target.

## Operating a mirror

Mirrors are created as mirrors — Forgejo does not convert an existing normal
repository in place. To host a GitHub-mastered repository (after creating the
owning organization once, see the README):

```sh
curl -u ADMIN_USER:ADMIN_PASS -X POST \
  http://127.0.0.1:3000/api/v1/repos/migrate \
  -H 'Content-Type: application/json' \
  -d '{
    "clone_addr": "https://github.com/OWNER/REPO.git",
    "repo_owner": "elizaOS",
    "repo_name": "REPO",
    "mirror": true,
    "mirror_interval": "15m",
    "issues": false,
    "pull_requests": false,
    "wiki": false,
    "releases": false,
    "description": "Read-only mirror of github.com/OWNER/REPO — source of truth, issues, and pull requests live on GitHub."
  }'
```

Notes that matter in production:

- `FORGEJO__git_0X2E_timeout__MIGRATE` must be generous (the deployment sets
  7200s); the initial copy of a multi-gigabyte repository exceeds the 600s
  default. Incremental syncs afterwards fetch only new objects and are cheap.
- A 15-minute interval is the deliberate default: it keeps the mirror fresh
  against a repository that merges continuously without hammering either side.
- An on-demand sync is `POST /repos/{owner}/{repo}/mirror-sync` with an admin
  or repo-admin token.
- Public upstreams need no stored credentials. Do not configure a token on a
  mirror of a public repository.

## Inverting the arrow (hub-mastered repositories)

A repository that starts its life on the hub keeps the hub as write-master.
If GitHub visibility is wanted, configure a Forgejo **push mirror** from the
hub repository's settings to an empty GitHub repository, and leave the GitHub
side's issues and pull requests disabled with a description pointing at the
hub. The rule is symmetric: one write-master, one-way arrow, direction chosen
per repository.
