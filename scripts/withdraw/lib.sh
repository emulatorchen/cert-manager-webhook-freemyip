# shellcheck shell=bash
# scripts/withdraw/lib.sh — shared by every withdrawal step.
#
# The steps run in two places: as the rollback jobs of a release that failed
# before its Docker Hub version tag, in that same run, and as the manual
# "Withdraw a release" workflow. One copy of the logic, two callers. The
# workflows only decide which environment and which permissions each step gets.
#
# Every step is idempotent: run it twice and the second run finds nothing to do.
# Every gh call is judged by its exit status, because on an error gh prints the
# error body to stdout, and a fallback inside $( ) would keep that text as if it
# were the answer.

set -uo pipefail

SCAN_BEGIN='<!-- scan:begin -->'
SCAN_END='<!-- scan:end -->'
# SC2034: used by the scripts that source this file, not here.
# shellcheck disable=SC2034
CHART=cert-manager-webhook-freemyip

die()  { echo "::error::$*" >&2; exit 1; }
warn() { echo "::warning::$*"; }

# Required environment, by name.
need() { local v; for v in "$@"; do [ -n "${!v:-}" ] || die "$v is not set"; done; }

# Constrains anything that reaches a URL, a grep pattern or a shell word.
plain() { printf '%s' "$1" | grep -qE '^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$'; }
is_digest() { printf '%s' "$1" | grep -qE '^sha256:[0-9a-f]{64}$'; }

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; else printf '%s\n' "$@"; fi
}
output() {  # key value
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; else printf 'output %s=%s\n' "$1" "$2"; fi
}

# The digest an image reference resolves to, or nothing.
digest_of() { docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null || true; }

# A Docker Hub web-API token from HUB_USER and HUB_SECRET (a password or a PAT).
# Whitespace is trimmed, since a pasted newline breaks the JSON body in a way the
# API reports as nothing useful. Case is left exactly as stored.
hub_jwt() {
  local u p body
  u=$(printf '%s' "${HUB_USER:-}" | tr -d '[:space:]')
  p=$(printf '%s' "${HUB_SECRET:-}" | tr -d '[:space:]')
  if [ -z "$u" ] || [ -z "$p" ]; then die "Docker Hub username or credential is empty"; fi
  body=$(jq -n --arg u "$u" --arg p "$p" '{username:$u, password:$p}')
  curl -sf --retry 3 --max-time 30 -X POST "https://hub.docker.com/v2/users/login" \
    -H "Content-Type: application/json" -d "$body" | jq -r '.token // empty'
}

# The lines between the scan markers of stdin.
scan_block() { awk -v b="$SCAN_BEGIN" -v e="$SCAN_END" 'index($0,e){f=0} f{print} index($0,b){f=1}'; }

# Whether a scan block names VERSION's image: "`<image>:<version>`, scanned ...".
shows_version() { scan_block | grep -qF ":${VERSION}\`,"; }

# The scan block a release carries in its notes. Empty when the release has none.
# Fails when the notes cannot be read, so an outage never passes for "no scan".
release_scan() {  # tag
  local body
  body=$(gh release view "$1" --repo "$REPO" --json body --jq .body) || return 1
  printf '%s\n' "$body" | scan_block
}

# The Docker Hub page as it should read when PREV is the live release: the page
# source with PREV's scan between the markers, or the source unchanged when PREV
# has none. The block goes back through apply_scan.sh, so a restored scan meets
# the same injection checks as a freshly rendered one.
compose_hub_page() {  # out-file
  local s
  s=$(mktemp)
  if [ -n "${PREV:-}" ]; then
    release_scan "v${PREV}" > "$s" || die "cannot read the release notes of v${PREV}"
  fi
  cp docs/dockerhub_description.md "$1"
  if [ -s "$s" ]; then
    ./scripts/apply_scan.sh "$s" "$1" >/dev/null || die "could not compose the Docker Hub page"
  fi
  rm -f "$s"
}

# The live Docker Hub page, from the public API. Fails when it cannot be read.
hub_page_live() { curl -sf --retry 3 --max-time 30 "https://hub.docker.com/v2/repositories/${HUB_REPO}/" | jq -er '.full_description // ""'; }

# How many ghcr versions of a package carry the VERSION tag, or "unreadable".
ghcr_tagged() {  # package (URL-encoded)
  local out
  if out=$(gh api --paginate "users/${OWNER}/packages/container/$1/versions" \
             --jq "[.[] | select(.metadata.container.tags | index(\"${VERSION}\"))] | length" 2>/dev/null); then
    printf '%s\n' "$out" | awk '{s+=$1} END{print s+0}'
  elif printf '%s' "$out" | grep -q '"status":"404"'; then
    echo 0
  else
    echo unreadable
  fi
}

# The chart repository index on gh-pages, decoded. Empty when there is none;
# fails when it cannot be read.
index_yaml() {
  local out
  if out=$(gh api "repos/${REPO}/contents/index.yaml?ref=gh-pages" --jq '.content' 2>/dev/null); then
    printf '%s' "$out" | base64 -d
  elif printf '%s' "$out" | grep -q '"status":"404"'; then
    return 0
  else
    return 1
  fi
}

# Lowercase, as ghcr requires. Not ${x,,}: that needs bash 4, and the scripts are
# also run by hand on macOS.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
