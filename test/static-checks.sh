#!/bin/sh
# Checks that need no running stack, each in a container so nothing has to
# be installed here: the compose files parse, the shell scripts are lint
# clean, and cloud-init accepts the provisioning file.
set -eu

cd "$(dirname "$0")/.."

echo "== compose config"
# .env.example's secrets are blank, which compose.yaml refuses: fill a copy
# in, as a real server's .env is.
mkdir -p test/.state
rm -f test/.state/example.env
scripts/gen-secrets.sh test/.state/example.env >/dev/null
ENV_FILE=test/.state/example.env docker compose --env-file test/.state/example.env -f compose.yaml config -q
ENV_FILE=test/test.env docker compose --env-file test/test.env -f compose.yaml -f compose.local.yaml config -q
ENV_FILE=test/e2e.env docker compose --env-file test/e2e.env -f compose.yaml -f compose.local.yaml -f compose.e2e.yaml config -q

echo "== only caddy publishes ports"
# Docker's firewall rules come before ufw's, so a published port is open to
# the internet whatever ufw says (unless daemon.json keeps it local): refuse
# one anywhere but Caddy before it reaches a server. Caddy's are checked to
# be seen, so "none" elsewhere can't mean "not read".
ENV_FILE=test/.state/example.env docker compose --env-file test/.state/example.env -f compose.yaml --profile cluster config --format json |
  python3 -I -c '
import json, sys
services = json.load(sys.stdin)["services"]
published = {name: s.get("ports", []) for name, s in services.items()}
assert published.get("caddy"), "caddy publishes no ports - is this the right file?"
others = {name: ports for name, ports in published.items() if ports and name != "caddy"}
if others:
    sys.exit(f"only caddy may publish ports, but: {others}")
print("ok: " + ", ".join(sorted(published)))
'

echo "== shellcheck"
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 \
  backup/backup.sh backup/restore.sh backup/restore-drill.sh scripts/gen-secrets.sh scripts/deploy.sh scripts/maintenance.sh scripts/secrets.sh \
  test/run-local.sh test/run-remote.sh test/static-checks.sh test/e2e-stack.sh

echo "== cloud-init schema"
docker run --rm -v "$PWD/provision:/p:ro" ubuntu:24.04 sh -c \
  'apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloud-init >/dev/null 2>&1 && cloud-init schema --config-file /p/cloud-init.yaml --annotate'

echo "all static checks passed"
