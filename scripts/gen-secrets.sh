#!/bin/sh
# Makes .env from .env.example (or the file named), filling in every secret
# still blank - the database password and both JWT secrets - with a long
# random value. Never overwrites one already set, so it's safe to run again.
#
#   scripts/gen-secrets.sh            .env
#   scripts/gen-secrets.sh path/.env  another file
set -eu

cd "$(dirname "$0")/.."
target=${1:-.env}
[ -f "$target" ] || cp .env.example "$target"
chmod 600 "$target"

for key in DB_PASSWORD JWT_ACCESS_SECRET JWT_REFRESH_SECRET; do
  if grep -q "^$key=$" "$target"; then
    # Hex, so it never needs quoting in a URL or a shell.
    value=$(openssl rand -hex 32)
    tmp=$(mktemp)
    awk -v k="$key" -v v="$value" '$0 == k "=" { print k "=" v; next } { print }' "$target" >"$tmp"
    cat "$tmp" >"$target"
    rm -f "$tmp"
    echo "set $key"
  fi
done
