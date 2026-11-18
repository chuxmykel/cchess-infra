#!/bin/sh
# Maintenance on a server - a deploy, a reboot - timed for when no live game
# is being played. It's announced with a time to begin, which the app's
# banner shows, and from the announcement cchess-be starts no new live game
# (no seek, challenge or rematch); the games in progress play out. Daily
# games start and carry on throughout.
#
#   scripts/maintenance.sh <ssh host> status            whether it's on, how long until it
#                                                       begins, and the live games left
#   scripts/maintenance.sh <ssh host> start [minutes]   announce it, to begin in [minutes]
#                                                       ($NOTICE_MINUTES, 5)
#   scripts/maintenance.sh <ssh host> drain [minutes]   announce it, then wait until it has
#                                                       begun and no live game is left,
#                                                       however long that takes
#   scripts/maintenance.sh <ssh host> end               end it: new live games start again
#
# Announced again while on, it keeps the time first given. Once on it stays
# on until it's finished: nothing here ends it but
# `end`, and the api's restart, which forgets it - after a deploy, or
# `drain` and then a reboot, there's nothing left to end. With the api not
# running (a first deploy), there's nothing to wait for.
set -eu

usage="usage: maintenance.sh <ssh host> status|start|drain|end [minutes]"
host=${1:?$usage}
action=${2:?$usage}
notice=${3:-${NOTICE_MINUTES:-5}}
poll_seconds=${POLL_SECONDS:-15}
remote_dir=${REMOTE_DIR:-/opt/cchess}
script="$(cd "$(dirname "$0")" && pwd)/maintenance-request.js"

case $notice in '' | *[!0-9]*) echo "minutes must be a whole number: $notice" >&2; exit 1 ;; esac

# The api's /internal/maintenance, from inside its container.
request() {
  # shellcheck disable=SC2029 # meant to expand here
  ssh "$host" "cd $remote_dir && docker compose exec -T -e METHOD=$1 -e BODY='${2:-}' api node -" <"$script"
}

api_running() {
  # shellcheck disable=SC2029
  [ -n "$(ssh "$host" "cd $remote_dir 2>/dev/null && docker compose ps --status running --quiet api 2>/dev/null" || true)" ]
}

field() { echo "$2" | sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p"; }

# Announces it, [minutes] ahead, or says why it can't be.
start() {
  if ! out=$(request PUT "{\"minutes\":${1:-$notice}}" 2>&1); then
    case $out in
      404*) echo "the api on $host has no maintenance yet (it's older than it) - deploy with FORCE=1 this once" >&2 ;;
      *) echo "$out" >&2 ;;
    esac
    exit 1
  fi
  echo "$out"
}

if ! api_running; then
  echo "the api isn't running on $host - no games to wait for"
  exit 0
fi

case $action in
  status)
    request GET
    ;;
  start)
    start "$notice"
    ;;
  end)
    request DELETE
    echo "maintenance ended on $host"
    ;;
  drain)
    start >/dev/null
    trap 'echo "stopped waiting - maintenance is still on, no new live games. Run this again to wait, or end it: scripts/maintenance.sh $host end" >&2; exit 1' INT TERM
    echo "maintenance announced on $host: no new live games from now"
    while :; do
      status=$(request GET)
      # The api restarted meanwhile and forgot it: announce it again, now.
      case $status in *'"startsAt":null'*) status=$(start 0) ;; esac
      # An api older than the notice says nothing of it: as good as begun.
      seconds=$(field secondsToStart "$status")
      seconds=${seconds:-0}
      games=$(field liveGames "$status")
      if [ "$seconds" = 0 ] && [ "$games" = 0 ]; then
        echo "maintenance has begun, and no live games are left"
        exit 0
      fi
      if [ "$seconds" != 0 ]; then
        echo "$games live game(s) on; it begins in $(((seconds + 59) / 60)) minute(s)"
      else
        echo "waiting for $games live game(s) to finish"
      fi
      sleep "$poll_seconds"
    done
    ;;
  *)
    echo "$usage" >&2
    exit 1
    ;;
esac
