#!/bin/sh
# Each server's .env, kept encrypted on your machine as secrets/<name>.env -
# SOPS encrypts every value, for your age key: its public half worked out
# from your private key, or the keys in $SOPS_AGE_RECIPIENTS (comma-separated)
# when someone else should open them too. No .sops.yaml is needed, and the
# folder is git-ignored: encrypted or not, secrets aren't committed.
# scripts/deploy.sh decrypts a server's on your machine and sends it over
# ssh; the plain file lives only on the server, as before.
#
#   scripts/secrets.sh new <name>               from .env.example, the DB password and
#                                               JWT secrets generated (gen-secrets.sh)
#   scripts/secrets.sh import <ssh host> <name> from a server's own .env
#   scripts/secrets.sh edit <name>              open it decrypted in $EDITOR
#   scripts/secrets.sh show <name>              print it decrypted
#
# <name> is the ssh host deploy.sh is given, less any user@ - so
# `deploy.sh deploy@api.example.com` uses secrets/api.example.com.env.
set -eu

cd "$(dirname "$0")/.."
usage="usage: secrets.sh new <name> | import <ssh host> <name> | edit <name> | show <name>"
action=${1:?$usage}
command -v sops >/dev/null || { echo "needs sops (brew install sops age)" >&2; exit 1; }

# Where sops looks for your private key, unless $SOPS_AGE_KEY_FILE says.
if [ "$(uname)" = Darwin ]; then
  key_file=${SOPS_AGE_KEY_FILE:-$HOME/Library/Application Support/sops/age/keys.txt}
else
  key_file=${SOPS_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt}
fi

# Whom to encrypt for: $SOPS_AGE_RECIPIENTS, or your own key's public half.
recipients() {
  if [ -n "${SOPS_AGE_RECIPIENTS:-}" ]; then
    echo "$SOPS_AGE_RECIPIENTS"
  else
    [ -f "$key_file" ] || { echo "no age key at $key_file - make one: age-keygen -o \"$key_file\"" >&2; exit 1; }
    age-keygen -y "$key_file"
  fi
}

# Encrypts a plain file into secrets/<name>.env, refusing to replace one.
encrypt() {
  out="secrets/$2.env"
  [ ! -e "$out" ] || { echo "$out already exists - edit it instead" >&2; exit 1; }
  age=$(recipients)
  sops encrypt --age "$age" --input-type dotenv --output-type dotenv "$1" >"$out.partial"
  mv "$out.partial" "$out"
  echo "wrote $out"
}

tmp=$(mktemp)
chmod 600 "$tmp"
trap 'rm -f "$tmp"' EXIT

case $action in
  new)
    name=${2:?$usage}
    cp .env.example "$tmp"
    scripts/gen-secrets.sh "$tmp" >/dev/null
    encrypt "$tmp" "$name"
    echo "now set DOMAIN and CADDY_TLS: scripts/secrets.sh edit $name"
    ;;
  import)
    host=${2:?$usage}
    name=${3:?$usage}
    # shellcheck disable=SC2029 # meant to expand here
    ssh "$host" "cat ${REMOTE_DIR:-/opt/cchess}/.env" >"$tmp"
    encrypt "$tmp" "$name"
    ;;
  edit)
    sops edit --input-type dotenv --output-type dotenv "secrets/${2:?$usage}.env"
    ;;
  show)
    sops decrypt --input-type dotenv --output-type dotenv "secrets/${2:?$usage}.env"
    ;;
  *)
    echo "$usage" >&2
    exit 1
    ;;
esac
