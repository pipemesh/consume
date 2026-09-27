#!/usr/bin/env bash
# The run proves who it is with its own GitHub OIDC token; the pipemesh_run
# handle only names the job run it was dispatched for. PipeMesh answers with
# what that job's consumes: grants — nothing else (DESIGN-V59 §7).
set -euo pipefail

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "::error::pipemesh/consume needs an OIDC token: add 'permissions: { id-token: write }' to the job"
  exit 1
fi
if [ -z "${PM_RUN:-}" ]; then
  echo "::error::no pipemesh_run — this workflow must be dispatched by PipeMesh and declare the pipemesh_run input"
  exit 1
fi

urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
PM_URL=${PM_URL%/}
token=$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$(urlencode "$PM_URL")" \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["value"])')
echo "::add-mask::$token"

query="run=$(urlencode "$PM_RUN")"
if [ -n "${PM_ONLY:-}" ]; then query="$query&artifacts=$(urlencode "$PM_ONLY")"; fi
work=$(mktemp -d)
code=$(curl -sS -o "$work/entries.tsv" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $token" "$PM_URL/api/actions/inputs?$query" || echo 000)
if [ "$code" != 200 ]; then
  echo "::error::PipeMesh refused (HTTP $code): $(cat "$work/entries.tsv" 2>/dev/null)"
  exit 1
fi

mkdir -p "$PM_PATH"
while IFS=$'\t' read -r var type value digest url; do
  [ -n "$var" ] || continue
  if [ "$type" = file ]; then
    if [[ "$url" == "$PM_URL"* ]]; then
      curl -fsS -H "Authorization: Bearer $token" "$url" -o "$work/entry.tar.gz"
    else
      curl -fsS "$url" -o "$work/entry.tar.gz"
    fi
    tar -xzf "$work/entry.tar.gz" -C "$PM_PATH"
    if [ "$PM_PATH" != "." ]; then value="${PM_PATH%/}/$value"; fi
  fi
  echo "$var=$value" >> "$GITHUB_ENV"
  echo "[pipemesh] $var=$value ($digest)"
done < "$work/entries.tsv"

{
  echo 'manifest<<PIPEMESH_MANIFEST_EOF'
  cut -f1-4 "$work/entries.tsv"
  echo 'PIPEMESH_MANIFEST_EOF'
} >> "$GITHUB_OUTPUT"
