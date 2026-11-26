#!/bin/sh
# Whether the api is up and its certificate isn't about to run out - for a
# cron job or an uptime service's keyword check, from anywhere:
#
#   scripts/check.sh api.chux.dev       (MIN_CERT_DAYS, default 14)
#
# Prints what it found; exits 1 if /health doesn't answer OK, or the
# certificate expires within MIN_CERT_DAYS - Caddy renews 30 days ahead, so
# that's a renewal failing, long before players see it.
set -eu
domain=${1:?usage: check.sh <domain>}
min_days=${MIN_CERT_DAYS:-14}

status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$domain/health" || echo 000)
expires=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null |
  openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -z "$expires" ]; then
  echo "$domain: no certificate read (health $status)"
  exit 1
fi
# GNU date reads it with -d, BSD (macOS) with -j -f.
expiry=$(date -d "$expires" +%s 2>/dev/null || date -j -f '%b %e %T %Y %Z' "$expires" +%s)
days=$(( (expiry - $(date +%s)) / 86400 ))
echo "$domain: health $status, certificate good for $days more days"
[ "$status" = 200 ] && [ "$days" -ge "$min_days" ]
