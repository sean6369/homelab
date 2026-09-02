#!/usr/bin/env bash
#
# Nightly backup: create a Borg archive on Oracle, prune, then ping Kuma.
# Any failure aborts before the ping, so a missed ping = an alert.
#
set -euo pipefail

# --- configuration -------------------------------------------------------
export BORG_RSH="ssh -i /home/seanlsk/.ssh/borg_oracle"
export BORG_PASSCOMMAND="cat /home/seanlsk/.borg-passphrase"
export BORG_REPO="ssh://borg@100.127.86.10/srv/borg/leedon2server"

KUMA_PUSH_URL="$(cat /etc/borg-kuma-url 2>/dev/null || true)"

# --- what to back up -----------------------------------------------------
# Paths grow as services return in Phase 5.
BACKUP_PATHS=(
    /etc/netplan
    /etc/ssh
    /home/seanlsk/homelab
    /srv/backup/staging          # Newsapp database dumps
    /home/seanlsk/immich/data    # Immich library + its own .sql.gz dumps
)

# --- dump databases ------------------------------------------------------
# pg_dump runs INSIDE the container, so the client version can never skew
# from the server. Connects over the container's Unix socket (trust auth),
# so no password and no SOPS decryption is needed in an unattended job.
# Immich is deliberately NOT dumped here. It runs its own scheduled pg_dump
# into UPLOAD_LOCATION/backups as .sql.gz, and the supported restore path is
# Immich's own UI (handles the search_path rewrite, migrations, rollback).
# See homelab-setup-v3.md — Immich section.
echo "=== pg_dump: $(date -Iseconds) ==="
STAGING=/srv/backup/staging

# -Fc  custom format: pg_restore can do selective and parallel restores
# -Z 0 no pg_dump compression: compressed output changes every byte on any
#      change, which defeats Borg's chunker and stores a whole new copy
#      nightly. Borg compresses on its own.
/usr/bin/docker exec -i newsapp-db \
    pg_dump -U newsapp -Fc -Z 0 newsapp > "$STAGING/newsapp.dump.tmp"

# Validate before replacing the previous good dump. pg_restore -l reads the
# archive's table of contents; it fails on a truncated or corrupt file.
# It must read a real file, not a pipe — pg_restore seeks, and /dev/stdin
# on a redirect is not seekable.
/usr/bin/docker cp "$STAGING/newsapp.dump.tmp" newsapp-db:/tmp/verify.dump
/usr/bin/docker exec newsapp-db pg_restore -l /tmp/verify.dump > /dev/null
/usr/bin/docker exec newsapp-db rm /tmp/verify.dump

mv "$STAGING/newsapp.dump.tmp" "$STAGING/newsapp.dump"
chmod 600 "$STAGING/newsapp.dump"
ls -lh "$STAGING/newsapp.dump"

# --- create --------------------------------------------------------------
echo "=== borg create: $(date -Iseconds) ==="
borg create \
    --stats \
    --compression zstd \
    --exclude-caches \
    "::{hostname}-{now}" \
    "${BACKUP_PATHS[@]}"

# --- prune ---------------------------------------------------------------
echo "=== borg prune: $(date -Iseconds) ==="
borg prune \
    --list \
    --glob-archives '{hostname}-*' \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6

echo "=== borg compact: $(date -Iseconds) ==="
borg compact

# --- mirror to object storage (copy 2, runs on Oracle) -------------------
echo "=== bucket sync: $(date -Iseconds) ==="
ssh -i /home/seanlsk/.ssh/oracle_sync \
    -T \
    -o BatchMode=yes \
    -o ConnectTimeout=30 \
    ubuntu@100.127.86.10

# --- notify --------------------------------------------------------------
if [ -n "$KUMA_PUSH_URL" ]; then
    curl -fsS --retry 3 --max-time 30 "$KUMA_PUSH_URL" > /dev/null
    echo "=== kuma pinged ==="
fi

echo "=== done: $(date -Iseconds) ==="
