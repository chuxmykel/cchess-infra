#!/bin/sh
# Builds the api image from a cchess-be checkout for the server's CPU, sends
# it over ssh, and restarts the stack there - no registry needed.
#
#   scripts/deploy.sh deploy@api.example.com
#
# The server keeps the image just sent and the newest $KEEP_IMAGES before it
# (3 by default) to roll back to, each tagged by commit, and runs the one
# tagged cchess-be:current. To roll back:
#   ssh <host> 'docker tag cchess-be:<older commit> cchess-be:current &&
#     cd /opt/cchess && docker compose up -d --wait'
set -eu

host=${1:?usage: deploy.sh <ssh host>}
be_dir=${CCHESS_BE_DIR:-$(dirname "$0")/../../cchess-be}
remote_dir=${REMOTE_DIR:-/opt/cchess}
keep_images=${KEEP_IMAGES:-3}
infra_dir=$(cd "$(dirname "$0")/.." && pwd)

rev=$(git -C "$be_dir" rev-parse --short HEAD)
# The image is built from the working tree, so changes not committed would
# ship under a commit that doesn't hold them. ALLOW_DIRTY=1 (a test server)
# ships them anyway, tagged so the image is never taken for that commit.
if [ -n "$(git -C "$be_dir" status --porcelain)" ]; then
  if [ "${ALLOW_DIRTY:-}" != 1 ]; then
    echo "cchess-be has uncommitted changes - commit or stash them first (or ALLOW_DIRTY=1)" >&2
    exit 1
  fi
  rev="$rev-dirty"
fi

case $(ssh "$host" uname -m) in
  aarch64 | arm64) platform=linux/arm64 ;;
  x86_64) platform=linux/amd64 ;;
  *) echo "unknown server architecture" >&2; exit 1 ;;
esac

echo "building cchess-be:$rev for $platform"
docker buildx build --platform "$platform" --tag "cchess-be:$rev" --load "$be_dir"

echo "sending the image to $host"
docker save "cchess-be:$rev" | gzip | ssh "$host" 'gunzip | docker load'

echo "updating the stack in $remote_dir"
# .env stays on the server, never sent from here.
# Relative paths from inside the repo: macOS's openrsync ignores the "/./"
# marker GNU rsync uses to cut a --relative path short.
(cd "$infra_dir" && rsync -a --relative compose.yaml caddy backup "$host:$remote_dir/")
# The Caddyfile is mounted, not built in, so compose sees nothing to restart
# when it changes: Caddy is told to reload it instead, without dropping
# connections (compose.yaml mounts its folder, so the new file is seen).
# shellcheck disable=SC2029 # $rev and $remote_dir are meant to expand here
ssh "$host" "docker tag cchess-be:$rev cchess-be:current &&
  cd $remote_dir && docker compose up -d --build --wait --remove-orphans &&
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile"

# Each image is a few hundred MB, and a small server's disk fills in a few
# deploys: all but the newest $keep_images go - never the one just deployed,
# which a rollback can make older than the rest - then layers nothing uses
# any more, and the backup image's build cache.
# shellcheck disable=SC2029 # $keep_images and $rev are meant to expand here
ssh "$host" "docker image ls cchess-be --format '{{.CreatedAt}}|{{.Tag}}' |
    grep -v -e '|current\$' -e '|$rev\$' | sort -r | tail -n +$((keep_images + 1)) | cut -d'|' -f2 |
    while read -r tag; do docker image rm \"cchess-be:\$tag\" >/dev/null && echo \"removed cchess-be:\$tag\"; done
  docker image prune -f >/dev/null && docker builder prune -f >/dev/null"
echo "deployed cchess-be $rev"
