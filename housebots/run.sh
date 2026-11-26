#!/bin/sh
# Starts one opponent per HOUSE_BOTS entry - username:time:mode[:level],
# mode "rated" or "casual" (guests can only play casual), level "easy",
# "medium" or "hard" - HOUSE_BOT_LEVEL (default medium) when left out, e.g.
#   HOUSE_BOTS=housebot_blitz:5+0:rated:hard,housebot_casual:5+0:casual
# - each restarted a few seconds after it exits, for as long as this runs.
# Any number can share a time control: the api never pairs two accounts
# marked as bots (README, "House bots").
# Every account signs in with HOUSE_BOT_PASSWORD, and plays with a short
# pause before each move.
set -eu
: "${HOUSE_BOTS:?set HOUSE_BOTS in .env}"
: "${HOUSE_BOT_PASSWORD:?set HOUSE_BOT_PASSWORD in .env}"
export BOT_PASSWORD="$HOUSE_BOT_PASSWORD"
export EXPO_PUBLIC_SERVER_URL="${HOUSE_BOT_SERVER:-http://api:3000}"
default_level="${HOUSE_BOT_LEVEL:-medium}"

run_bot() {
  user=$1 time=$2 mode=$3 level=$4
  casual=
  [ "$mode" = casual ] && casual=--casual
  while true; do
    # shellcheck disable=SC2086 # $casual is meant to vanish when empty
    node opponent.js --user "$user" --time "$time" $casual \
      --level "$level" --delay 800 --games 1000000 || true
    sleep 5
  done
}

entries=$(echo "$HOUSE_BOTS" | tr ',' '\n')

# Every entry checked first: a mistyped one stops it here, saying which,
# rather than leaving a bot failing and restarting forever.
echo "$entries" | while IFS=: read -r user time mode level; do
  [ -n "$user" ] || continue
  case "${mode:-rated}" in
    rated | casual) ;;
    *) echo "HOUSE_BOTS: $user's mode is \"$mode\" - rated or casual" >&2; exit 1 ;;
  esac
  case "${level:-$default_level}" in
    easy | medium | hard) ;;
    *) echo "HOUSE_BOTS: $user's level is \"${level:-$default_level}\" - easy, medium or hard" >&2; exit 1 ;;
  esac
done

echo "$entries" | while IFS=: read -r user time mode level; do
  [ -n "$user" ] && run_bot "$user" "$time" "${mode:-rated}" "${level:-$default_level}" &
done
wait
