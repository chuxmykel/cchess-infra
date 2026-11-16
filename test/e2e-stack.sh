#!/bin/sh
# The stack the app's end-to-end tests play against (compose.e2e.yaml):
#
#   test/e2e-stack.sh up      build, migrate, seed, and wait for the api
#   test/e2e-stack.sh check   the api answers, and e2e_main can sign in
#   test/e2e-stack.sh logs    the api's and the seeders' logs
#   test/e2e-stack.sh down    stop it, and throw its database away
#
# The api is on http://127.0.0.1:$E2E_API_PORT (3100 unless set), clear of a
# dev backend on 3000. cchess-be comes from ../cchess-be, or $CCHESS_BE_DIR.
set -eu

cd "$(dirname "$0")/.."
export ENV_FILE=test/e2e.env
export COMPOSE_PROJECT_NAME=cchess-e2e
export E2E_API_PORT="${E2E_API_PORT:-3100}"
compose() {
  docker compose --env-file "$ENV_FILE" -f compose.yaml -f compose.local.yaml -f compose.e2e.yaml "$@"
}
api="http://127.0.0.1:$E2E_API_PORT"

case "${1:-}" in
  up)
    compose up -d --build --wait api
    echo "e2e api on $api"
    ;;
  check)
    curl -fsS "$api/health" >/dev/null
    curl -fsS -X POST "$api/auth/login" -H 'Content-Type: application/json' \
      -d '{"usernameOrEmail":"e2e_main","password":"password"}' >/dev/null
    echo "ok: $api answers, and e2e_main signs in"
    ;;
  logs)
    compose logs --no-color migrate seed api
    ;;
  down)
    compose down -v --remove-orphans
    ;;
  *)
    echo "usage: $0 up|check|logs|down" >&2
    exit 2
    ;;
esac
