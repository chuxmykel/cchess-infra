#!/bin/sh
# The smoke tests against a deployed server, over its public URL and ssh:
#
#   test/run-remote.sh <ssh host> <https base URL>
#   ALLOW_DESTRUCTIVE=1 test/run-remote.sh cchess-do-sim https://192.168.1.181
#
# Without ALLOW_DESTRUCTIVE=1 only the read-only checks run. With it, the
# api is restarted and stopped and a backup is restored over the database,
# taking away anything written meanwhile: a test server only, never one
# with real players. When the server's CADDY_TLS is "internal", its CA is
# fetched and trusted for the run, as test/run-local.sh does.
set -eu

cd "$(dirname "$0")/.."
export REMOTE_HOST="${1:?usage: run-remote.sh <ssh host> <https base URL>}"
export BASE_URL="${2:?usage: run-remote.sh <ssh host> <https base URL>}"
export REMOTE_DIR="${REMOTE_DIR:-/opt/cchess}"
host=$(node -e 'console.log(new URL(process.argv[1]).host)' "$BASE_URL")
export HTTP_URL="http://$host"

[ -d node_modules/socket.io-client ] || npm install --no-audit --no-fund

# shellcheck disable=SC2029 # $REMOTE_DIR is meant to expand here
if ssh "$REMOTE_HOST" "grep -qx 'CADDY_TLS=internal' $REMOTE_DIR/.env"; then
  mkdir -p test/.state
  ca="test/.state/$REMOTE_HOST-caddy-root.crt"
  # shellcheck disable=SC2029
  ssh "$REMOTE_HOST" "cd $REMOTE_DIR && docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt -" 2>/dev/null |
    tar -xO >"$ca"
  export NODE_EXTRA_CA_CERTS="$ca"
fi

node --test --test-timeout=180000 "test/*.test.mjs"
