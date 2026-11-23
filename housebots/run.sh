#!/bin/sh
# Starts one opponent per HOUSE_BOTS entry - username:time:mode, mode
# "rated" or "casual" (guests can only play casual), e.g.
#   HOUSE_BOTS=housebot_blitz:5+0:rated,housebot_casual:5+0:casual
# - each restarted a few seconds after it exits, for as long as this runs.
# Every account signs in with HOUSE_BOT_PASSWORD. They play at
# HOUSE_BOT_LEVEL (default medium) with a short pause before each move.
set -eu
: "${HOUSE_BOTS:?set HOUSE_BOTS in .env}"
: "${HOUSE_BOT_PASSWORD:?set HOUSE_BOT_PASSWORD in .env}"
export BOT_PASSWORD="$HOUSE_BOT_PASSWORD"
export EXPO_PUBLIC_SERVER_URL="${HOUSE_BOT_SERVER:-http://api:3000}"
level="${HOUSE_BOT_LEVEL:-medium}"

run_bot() {
  user=$1 time=$2 mode=$3
  casual=
  [ "$mode" = casual ] && casual=--casual
  while true; do
    # shellcheck disable=SC2086 # $casual is meant to vanish when empty
    node opponent.js --user "$user" --time "$time" $casual \
      --level "$level" --delay 800 --games 1000000 || true
    sleep 5
  done
}

echo "$HOUSE_BOTS" | tr ',' '\n' | while IFS=: read -r user time mode; do
  [ -n "$user" ] && run_bot "$user" "$time" "${mode:-rated}" &
done
wait
