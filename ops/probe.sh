#!/usr/bin/env bash
# Probes a URL once per second and appends "<time> <url> <http code>" to a log (000 = no answer in 1s).
# Usage: probe.sh <logfile> <url>   (stop it with kill)
LOG=$1; URL=$2
while true; do
  code=$(curl -sk -o /dev/null -m 1 -w '%{http_code}' "$URL" || true)
  echo "$(date +%H:%M:%S) $URL $code" >>"$LOG"
  sleep 1
done
