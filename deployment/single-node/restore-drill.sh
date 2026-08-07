#!/usr/bin/env bash
# Prove that a single-node backup can actually be restored.
#
#   bash deployment/single-node/restore-drill.sh <server-ssh-target> [archive]
#
# A backup nobody has restored is a hypothesis. This drill takes the newest
# Forgejo dump (or one you name), and without touching the running instance:
#
#   - extracts the smallest repository and the database dump to a scratch dir
#   - runs git fsck against the restored repository
#   - clones from it and confirms a real working tree comes out
#   - confirms the database dump defines the tables that carry accounts,
#     repositories, tokens, and webhooks, and contains row data
#
# It reads the archive and writes only under /tmp. It never stops a container,
# never writes to /opt, and never modifies live data.
set -euo pipefail

TARGET="${1:?usage: restore-drill.sh <server-ssh-target> [archive]}"
ARCHIVE="${2:-}"
SSH=(ssh -o StrictHostKeyChecking=accept-new "$TARGET")

"${SSH[@]}" ARCHIVE="$ARCHIVE" bash -s <<'REMOTE'
set -euo pipefail
DRILL=/tmp/eliza-hub-restore-drill
ARCHIVE="${ARCHIVE:-}"
if [ -z "$ARCHIVE" ]; then
  ARCHIVE="$(ls -t /var/backups/eliza-hub/forgejo-*.zip 2>/dev/null | head -1)"
fi
[ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] || { echo "no Forgejo backup archive found" >&2; exit 1; }
echo "archive: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

rm -rf "$DRILL"; mkdir -p "$DRILL"

# Full dumps exceed 4 GiB, so use a zip64-capable reader rather than unzip.
# Restore the smallest repository: the drill proves the pipeline, and
# extracting the largest would cost minutes and gigabytes to prove the same.
SMALLEST="$(python3 - "$ARCHIVE" "$DRILL" <<'PY'
import sys, zipfile
archive, dest = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(archive)
sizes = {}
for info in z.infolist():
    parts = info.filename.split("/")
    if len(parts) > 2 and parts[0] == "repos" and parts[2].endswith(".git"):
        sizes["/".join(parts[:3])] = sizes.get("/".join(parts[:3]), 0) + info.file_size
if not sizes:
    raise SystemExit("no repositories in archive")
repo = min(sizes, key=sizes.get)
members = [n for n in z.namelist() if n.startswith(repo) or n in ("app.ini", "forgejo-db.sql")]
z.extractall(dest, members=members)
print(repo)
PY
)"
echo "restored repository: $SMALLEST"

echo "== git integrity"
git -C "$DRILL/$SMALLEST" fsck --no-progress --no-dangling
echo "  fsck clean"
echo "  commits: $(git -C "$DRILL/$SMALLEST" rev-list --count --all)"
echo "  head:    $(git -C "$DRILL/$SMALLEST" log -1 --format='%h %s')"

echo "== clone from the restored repository"
git clone -q "$DRILL/$SMALLEST" "$DRILL/clone"
files="$(find "$DRILL/clone" -type f -not -path '*/.git/*' | wc -l)"
[ "$files" -gt 0 ] || { echo "restored clone has no working tree files" >&2; exit 1; }
echo "  working tree files: $files"

echo "== database dump"
[ -s "$DRILL/forgejo-db.sql" ] || { echo "database dump missing or empty" >&2; exit 1; }
grep -oE 'CREATE TABLE IF NOT EXISTS .[a-z_]+' "$DRILL/forgejo-db.sql" \
  | sed 's/.*EXISTS .//' | sort -u > "$DRILL/tables.txt"
echo "  tables: $(wc -l < "$DRILL/tables.txt")"
missing=""
for t in user repository access_token webhook repo_unit; do
  grep -qx "$t" "$DRILL/tables.txt" || missing="$missing $t"
done
[ -z "$missing" ] || { echo "database dump missing tables:$missing" >&2; exit 1; }
echo "  account, repository, token, and webhook tables present"
inserts="$(grep -c 'INSERT INTO' "$DRILL/forgejo-db.sql" || true)"
[ "$inserts" -gt 0 ] || { echo "database dump contains no rows" >&2; exit 1; }
echo "  row statements: $inserts"

rm -rf "$DRILL"
echo
echo "restore drill passed"
REMOTE
