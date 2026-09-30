#!/usr/bin/env bash
# scripts/dockerhub_page.sh — set the Docker Hub page from a file, and prove it.
#
# Replaces a reusable workflow and a third-party action. Environment secrets
# never reached the reusable workflow's job — it read the account password as
# empty on release #6 and again during the 0.1.1 rollback — so the page is now
# written by a step in a top-level job, which does receive its environment's
# secrets. Doing it with one documented API call here, instead of through an
# action, also means the account password is handed to code reviewed in this
# repository and to nothing else.
#
# Usage: dockerhub_page.sh <owner/repo> <readme-file>
# Env:   HUB_USER, HUB_PW  — the Docker ID and the account PASSWORD (the Hub web
#                            API returns 403 for access tokens)
#        VCS_URL           — the source link shown on the page (optional)
#
# The page is only as good as what Docker Hub stores, so it is read back and
# compared with what was sent; any difference fails.

set -uo pipefail

REPO="${1:?usage: dockerhub_page.sh <owner/repo> <readme-file>}"
README="${2:?}"
SHORT="cert-manager DNS-01 webhook solver for freemyip.com — Let's Encrypt wildcards on k8s"
: "${HUB_USER:?HUB_USER is not set}"
: "${HUB_PW:?HUB_PW is not set}"

printf '%s' "$REPO" | grep -qE '^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$' \
  || { echo "dockerhub_page.sh: '$REPO' is not owner/name" >&2; exit 1; }
[ -s "$README" ] || { echo "dockerhub_page.sh: $README is missing or empty" >&2; exit 1; }
n=$(wc -c < "$README" | tr -d ' ')
[ "$n" -le 25000 ] || { echo "dockerhub_page.sh: $README is ${n} bytes; Docker Hub's limit is 25000" >&2; exit 1; }

# A pasted secret with a trailing newline breaks the JSON body in a way the API
# reports as nothing useful; refuse it here, by name, without printing it.
for pair in "HUB_USER:$HUB_USER" "HUB_PW:$HUB_PW"; do
  name=${pair%%:*}; val=${pair#*:}
  if [ "$(printf '%s' "$val" | tr -d '[:space:]')" != "$val" ]; then
    echo "dockerhub_page.sh: $name contains whitespace — re-save it with none" >&2; exit 1
  fi
done
# Reported, never corrected and never fatal: Docker Hub wants the lowercase ID
# today, and the value is passed exactly as stored in case that changes.
if [ "$HUB_USER" != "$(printf '%s' "$HUB_USER" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "::warning::DOCKERHUB_USERNAME contains uppercase. Docker Hub currently requires the lowercase Docker ID."
fi

login=$(jq -n --arg u "$HUB_USER" --arg p "$HUB_PW" '{username:$u, password:$p}')
jwt=$(curl -sf --retry 3 --max-time 30 -X POST "https://hub.docker.com/v2/users/login" \
        -H "Content-Type: application/json" -d "$login" | jq -r '.token // empty')
[ -n "$jwt" ] || { echo "dockerhub_page.sh: could not authenticate to Docker Hub" >&2; exit 1; }

body=$(jq -n --rawfile full "$README" --arg short "$SHORT" --arg vcs "${VCS_URL:-}" \
         '{full_description:$full, description:$short} + (if $vcs == "" then {} else {vcs_url:$vcs} end)')
code=$(curl -s -o /dev/null -w '%{http_code}' --retry 3 --max-time 30 -X PATCH \
         "https://hub.docker.com/v2/repositories/${REPO}/" \
         -H "Authorization: Bearer ${jwt}" -H "Content-Type: application/json" -d "$body")
case "$code" in
  2*) echo "Docker Hub accepted the page (HTTP ${code})" ;;
  *)  echo "dockerhub_page.sh: Docker Hub refused the page (HTTP ${code})" >&2; exit 1 ;;
esac

# Read back over the public API. $( ) strips trailing newlines on both sides.
got=$(curl -sf --retry 3 --max-time 30 "https://hub.docker.com/v2/repositories/${REPO}/") \
  || { echo "dockerhub_page.sh: could not read the page back" >&2; exit 1; }
want_full=$(cat "$README")
got_full=$(printf '%s' "$got" | jq -r '.full_description // ""')
got_short=$(printf '%s' "$got" | jq -r '.description // ""')
fail=0
[ "$got_full" = "$want_full" ] || { echo "dockerhub_page.sh: the page does not match ${README} (sent ${#want_full} chars, page has ${#got_full})" >&2; fail=1; }
[ "$got_short" = "$SHORT" ]    || { echo "dockerhub_page.sh: the short description is '${got_short}'" >&2; fail=1; }
if [ -n "${VCS_URL:-}" ] && [ "$(printf '%s' "$got" | jq -r '.vcs_url // ""')" != "$VCS_URL" ]; then
  echo "dockerhub_page.sh: vcs_url did not take" >&2; fail=1
fi
[ "$fail" = "0" ] || exit 1
echo "Docker Hub page matches ${README} (${#want_full} characters)"
