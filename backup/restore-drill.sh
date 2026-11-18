#!/bin/sh
# A restore drill: proof that the newest backup can actually be restored.
# The newest off-site copy (the newest dump here when no RCLONE_REMOTE is
# set) is restored into a throwaway database beside the real one - never
# over it - checked against the real one, then thrown away. Players aren't
# affected; the restore only adds load while it runs.
#
#   restore-drill.sh          once now (docker compose exec backup restore-drill.sh)
#
# backup.sh --loop runs it after the day's backup on $RESTORE_DRILL_DAY of
# each month. It passes when the restore works, the schema has every
# migration the real database has, and the backup holds users and games
# (no more than there are now). It says how long the restore took: about
# how long a real recovery would keep the server down.
set -eu

BACKUP_DIR=${BACKUP_DIR:-/backups}
RCLONE_REMOTE=${RCLONE_REMOTE:-}
DRILL_DB=${DRILL_DB:-cchess_restore_drill}
work=$(mktemp -d)
# Postgres's own notices ("does not exist, skipping") aren't the drill's.
export PGOPTIONS='-c client_min_messages=warning'

log() { echo "[restore-drill] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
fail() { log "FAILED: $*"; exit 1; }
cleanup() {
  dropdb --if-exists "$DRILL_DB" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# One number from a query, in the database named.
count() { psql -d "$1" -tAc "$2"; }

if [ -n "$RCLONE_REMOTE" ]; then
  name=$(rclone lsf --include 'cchess-*.dump' "$RCLONE_REMOTE" | sort | tail -n 1)
  [ -n "$name" ] || fail "no backups in $RCLONE_REMOTE"
  rclone copyto "$RCLONE_REMOTE/$name" "$work/$name"
  file="$work/$name"
  log "fetched $name from $RCLONE_REMOTE"
else
  # shellcheck disable=SC2012 # the names are backup.sh's own, no spaces
  file=$(ls -1 "$BACKUP_DIR"/cchess-*.dump 2>/dev/null | sort -r | head -n 1)
  [ -n "$file" ] || fail "no backups in $BACKUP_DIR"
  name=$(basename "$file")
  log "no RCLONE_REMOTE: drilling the copy on this server, $name"
fi

dropdb --if-exists "$DRILL_DB"
createdb "$DRILL_DB"
started=$(date +%s)
pg_restore --no-owner --single-transaction --dbname="$DRILL_DB" "$file" ||
  fail "pg_restore of $name"
seconds=$(($(date +%s) - started))

live_migrations=$(count "$PGDATABASE" 'SELECT count(*) FROM migrations')
drill_migrations=$(count "$DRILL_DB" 'SELECT count(*) FROM migrations')
[ "$drill_migrations" = "$live_migrations" ] ||
  fail "$drill_migrations migrations in the backup, $live_migrations in the database"

for table in users games; do
  live=$(count "$PGDATABASE" "SELECT count(*) FROM $table")
  drill=$(count "$DRILL_DB" "SELECT count(*) FROM $table")
  [ "$drill" -le "$live" ] || fail "$drill $table in the backup, more than the $live there are now"
  [ "$live" = 0 ] || [ "$drill" -gt 0 ] || fail "no $table in the backup, $live in the database"
  log "$table: $drill in the backup, $live now"
done

newest=$(count "$DRILL_DB" "SELECT coalesce(max(\"createdAt\")::text, 'none') FROM games")
log "passed: $name restored in ${seconds}s; its newest game is from $newest"
