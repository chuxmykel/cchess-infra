#!/bin/sh
# Restores a dump over the database: every table dropped and recreated from it.
#
#   restore.sh latest                       the newest in /backups
#   restore.sh cchess-20261110T030000Z.dump one of them by name
#
# Stop the api first (docker compose stop api): it keeps games in progress
# in memory, and would go on writing them over what's restored.
set -eu

BACKUP_DIR=${BACKUP_DIR:-/backups}
choice=${1:?usage: restore.sh latest|<file name>}

if [ "$choice" = "latest" ]; then
  # shellcheck disable=SC2012 # the names are backup.sh's own, no spaces
  file=$(ls -1 "$BACKUP_DIR"/cchess-*.dump 2>/dev/null | sort -r | head -n 1)
  [ -n "$file" ] || { echo "no backups in $BACKUP_DIR" >&2; exit 1; }
else
  file="$BACKUP_DIR/$(basename "$choice")"
fi
[ -f "$file" ] || { echo "no such backup: $file" >&2; exit 1; }

echo "[restore] restoring $(basename "$file") into $PGDATABASE"
pg_restore --clean --if-exists --no-owner --single-transaction --dbname="$PGDATABASE" "$file"
echo "[restore] done"
