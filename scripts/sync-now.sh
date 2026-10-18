#!/usr/bin/env bash
# Calls pluggy-sync ?mode=${FINANCE_SYNC_MODE:-update}. Requires env FINANCE_SYNC_URL and FINANCE_SYNC_TOKEN.
# No secrets in repo. Prints HTTP status + JSON body.
set -Eeuo pipefail
set +x
: "${FINANCE_SYNC_URL:?FINANCE_SYNC_URL is required}"
[[ -n "${FINANCE_SYNC_TOKEN-}" ]] || { printf 'Configure FINANCE_SYNC_TOKEN.\n' >&2; exit 1; }
mode="${FINANCE_SYNC_MODE:-update}"
case "$mode" in update|backfill|full|drain) ;; *) printf "Modo inválido\n" >&2; exit 2;; esac
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
separator='?'
[[ "$FINANCE_SYNC_URL" == *\?* ]] && separator='&'
# Pass the token through stdin so it is absent from curl's process arguments.
status="$(printf 'Authorization: Bearer %s\n' "$FINANCE_SYNC_TOKEN" |
  curl --silent --show-error --max-time 170 --request POST --header @- \
    --output "$body_file" --write-out '%{http_code}' \
    "${FINANCE_SYNC_URL}${separator}mode=${mode}")"
printf 'HTTP %s\n' "$status"
python3 - "$body_file" <<'REDACT'
import os, sys
from pathlib import Path
body = Path(sys.argv[1]).read_text()
print(body.replace(os.environ["FINANCE_SYNC_TOKEN"], "[oculto]"))
REDACT
printf '\n'
[[ "$status" == 2?? ]]
