#!/bin/sh
# Brings the whole stack up in Docker on this machine - the api built from
# ../cchess-be (or $CCHESS_BE_DIR), Caddy on https://localhost:8443 with its
# own local CA - runs the smoke tests against it, and takes it down again,
# volumes and all.
#
#   test/run-local.sh          up, test, down
#   KEEP=1 test/run-local.sh   leave it running afterwards, to look around
set -eu

cd "$(dirname "$0")/.."
export ENV_FILE=test/test.env
export COMPOSE_PROJECT_NAME=cchess-test
compose() { docker compose --env-file "$ENV_FILE" -f compose.yaml -f compose.local.yaml "$@"; }

cleanup() {
  status=$?
  if [ "${KEEP:-}" != 1 ]; then compose down -v --remove-orphans >/dev/null 2>&1 || true; fi
  exit $status
}
trap cleanup EXIT INT TERM

[ -d node_modules/socket.io-client ] || npm install --no-audit --no-fund

compose up -d --build --wait

# Trust Caddy's local CA, as a client trusts Let's Encrypt's on a server.
mkdir -p test/.state
compose cp caddy:/data/caddy/pki/authorities/local/root.crt test/.state/caddy-root.crt >/dev/null
export NODE_EXTRA_CA_CERTS=test/.state/caddy-root.crt

node --test --test-timeout=120000 "test/*.test.mjs"
