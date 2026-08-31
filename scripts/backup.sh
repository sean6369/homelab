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

KUMA_PUSH_URL=""     # filled in at step 6

# --- what to back up -----------------------------------------------------
# Paths grow as services return in Phase 5.
BACKUP_PATHS=(
    /etc/netplan
    /etc/ssh
    /home/seanlsk/homelab
)

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
