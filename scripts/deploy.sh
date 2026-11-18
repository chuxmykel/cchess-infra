#!/bin/sh
# Builds the api image from a cchess-be checkout for the server's CPU, sends
# it over ssh, and restarts the stack there - no registry needed.
#
#   scripts/deploy.sh deploy@api.example.com
#
# The restart waits until no live game is being played: maintenance is
# announced to begin $NOTICE_MINUTES (5) on - the app's banner shows when,
# and no new live game starts from the announcement - and the deploy goes
# on once that time has come and the games in progress have finished,
# however long that takes (scripts/maintenance.sh drain). FORCE=1 restarts
# at once, games or not, for an emergency.
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

drained=
if [ "${FORCE:-}" = 1 ]; then
  echo "FORCE=1: restarting without waiting for live games"
else
  "$infra_dir/scripts/maintenance.sh" "$host" drain
  drained=1
fi
# Maintenance, once started, stays on until a deploy completes it: a failed
# one leaves it on, new games still refused, for the next to finish.
on_exit() {
  code=$?
  if [ "$code" != 0 ] && [ -n "$drained" ]; then
    echo "the deploy failed - maintenance is still on, so no new live games start. Fix it and deploy again, or end it: scripts/maintenance.sh $host end" >&2
  fi
}
trap on_exit EXIT

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
# Done: a restarted api has forgotten it, but one this deploy didn't need to
# restart would go on refusing new live games.
"$infra_dir/scripts/maintenance.sh" "$host" end >/dev/null
echo "deployed cchess-be $rev"
