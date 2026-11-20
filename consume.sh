#!/usr/bin/env bash
# The run proves who it is with its own GitHub OIDC token; the pipemesh_run
# handle only names the job run it was dispatched for. Pipemesh answers with
# what that job's consumes: grants — nothing else (DESIGN-V59 §7).
# It calls the instance's runtime surface, /api/runtime/actions (DESIGN-V121
# §8), which instances have answered since 2026-10-28. With registry-login,
# it also asks for a login to Pipemesh's registry (DESIGN-V142 §3) for the
# job's whole reach: pull on the images it consumes, push on its oci keys'
# places.
set -euo pipefail

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "::error::pipemesh/consume needs an OIDC token: add 'permissions: { id-token: write }' to the job"
  exit 1
fi
if [ -z "${PM_RUN:-}" ]; then
  echo "::error::no pipemesh_run — this workflow must be dispatched by Pipemesh and declare the pipemesh_run input"
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
trap 'rm -rf "$work"' EXIT
code=$(curl -sS -o "$work/entries.tsv" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $token" "$PM_URL/api/runtime/actions/inputs?$query" || echo 000)
if [ "$code" != 200 ]; then
  echo "::error::Pipemesh refused (HTTP $code): $(cat "$work/entries.tsv" 2>/dev/null)"
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

if [ "${PM_REGISTRY_LOGIN:-false}" != true ]; then exit 0; fi
# 409: Pipemesh hasn't matched this run to its job yet, which a push needs
# (only the run Pipemesh dispatched pushes); it takes a few seconds.
for attempt in $(seq 1 24); do
  code=$(curl -sS -D "$work/login.headers" -o "$work/login.tsv" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $token" "$PM_URL/api/runtime/actions/images/credential?run=$(urlencode "$PM_RUN")" || echo 000)
  [ "$code" = 409 ] && [ "$attempt" -lt 24 ] || break
  sleep 5
done
if [ "$code" != 200 ]; then
  echo "::error::Pipemesh refused a registry login (HTTP $code): $(cat "$work/login.tsv" 2>/dev/null)"
  exit 1
fi
registry=$(grep -i '^pipemesh-registry:' "$work/login.headers" | tail -n 1 | cut -d: -f2- | tr -d ' \r' || true)
IFS=$'\t' read -r user pass < "$work/login.tsv" || [ -n "$user" ]
pass=${pass%$'\r'}
if [ -z "$registry" ] || [ -z "$user" ] || [ -z "$pass" ]; then
  echo "::error::$PM_URL answered no registry login: it may predate registry logins for GitHub Actions runs"
  exit 1
fi
echo "::add-mask::$pass"
refused=$(grep -i '^pipemesh-push-refused:' "$work/login.headers" | tail -n 1 | cut -d: -f2- | sed 's/^ *//' | tr -d '\r' || true)
if [ -n "$refused" ]; then
  echo "::warning::this login only pulls: $refused"
fi
{
  echo "registry=$registry"
  echo "registry-username=$user"
  echo "registry-password=$pass"
} >> "$GITHUB_OUTPUT"
if command -v docker >/dev/null 2>&1; then
  printf '%s' "$pass" | docker login "$registry" -u "$user" --password-stdin >/dev/null
  echo "[pipemesh] docker logged in to $registry (valid 15 minutes)"
else
  echo "[pipemesh] no docker here: log in to $registry with this step's outputs registry-username and registry-password, e.g."
  echo "[pipemesh]   crane auth login $registry -u \"\$USER\" -p \"\$PASS\""
fi
