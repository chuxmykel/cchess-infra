#!/bin/sh
# Dumps the database to /backups/cchess-<UTC time>.dump (pg_dump's custom
# format, compressed), keeps the newest $BACKUP_KEEP, and - when
# $RCLONE_REMOTE is set (e.g. "offsite:cchess-backups", the remote set up
# through RCLONE_CONFIG_OFFSITE_* in .env) - copies each one there too.
#
#   backup.sh          one backup now
#   backup.sh --loop   one every day at $BACKUP_HOUR (UTC), forever - and
#                      on day $RESTORE_DRILL_DAY of the month (1; empty for
#                      never), a restore drill after it (restore-drill.sh)
#
# Connection settings come from PGHOST/PGUSER/PGPASSWORD/PGDATABASE.
set -eu

BACKUP_DIR=${BACKUP_DIR:-/backups}
BACKUP_KEEP=${BACKUP_KEEP:-7}
BACKUP_HOUR=${BACKUP_HOUR:-3}
RCLONE_REMOTE=${RCLONE_REMOTE:-}
RESTORE_DRILL_DAY=${RESTORE_DRILL_DAY-1}

log() { echo "[backup] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

backup_once() {
  name="cchess-$(date -u +%Y%m%dT%H%M%SZ).dump"
  tmp="$BACKUP_DIR/.$name.partial"
  pg_dump --format=custom --no-owner --file="$tmp"
  mv "$tmp" "$BACKUP_DIR/$name"
  log "wrote $name ($(du -h "$BACKUP_DIR/$name" | cut -f1))"

  if [ -n "$RCLONE_REMOTE" ]; then
    rclone copyto "$BACKUP_DIR/$name" "$RCLONE_REMOTE/$name"
    log "copied $name to $RCLONE_REMOTE"
  fi

  # The names sort by time, so everything after the newest $BACKUP_KEEP
  # goes. Off-site copies are kept by the bucket's own lifecycle rule.
  # shellcheck disable=SC2012 # the names are this script's own, no spaces
  ls -1 "$BACKUP_DIR"/cchess-*.dump | sort -r | tail -n "+$((BACKUP_KEEP + 1))" |
    while read -r old; do
      rm -f "$old"
      log "removed $(basename "$old")"
    done
}

seconds_until_next_run() {
  now=$(date -u +%s)
  today=$(date -u +%Y-%m-%d)
  next=$(date -u -d "$today $(printf %02d "$BACKUP_HOUR"):00:00" +%s)
  if [ "$next" -le "$now" ]; then next=$((next + 86400)); fi
  echo $((next - now))
}

if [ "${1:-}" = "--loop" ]; then
  log "daily at $BACKUP_HOUR:00 UTC, keeping $BACKUP_KEEP"
  while true; do
    sleep "$(seconds_until_next_run)"
    # A failed run is logged and retried tomorrow rather than ending the loop.
    backup_once || log "FAILED"
    if [ -n "$RESTORE_DRILL_DAY" ] && [ "$(date -u +%d | sed "s/^0//")" = "$RESTORE_DRILL_DAY" ]; then
      restore-drill.sh || true
    fi
  done
else
  backup_once
fi
