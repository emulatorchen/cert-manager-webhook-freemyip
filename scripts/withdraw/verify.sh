#!/usr/bin/env bash
# scripts/withdraw/verify.sh — prove from outside that VERSION is gone.
#
# Every place the version could have been published is read again, separately
# from the steps that removed it. The run fails if anything is still there, or
# if the release now live was disturbed. A green run means withdrawn, not "the
# steps ran".
#
# Each check is retried for a short while before it counts as a failure. The
# registries and the Docker Hub API can serve the old answer for a moment after
# a change, and one stale read failed the 0.1.1 withdrawal after every step had
# succeeded. The table goes to the log as well as the summary.
#
# Env: VERSION, PREV (may be empty), DIGEST (may be empty), HUB_REPO, REPO,
#      OWNER, ACTOR, GH_TOKEN, HUB_KEPT (true when an immutable tag stays)
#      STEPS  optional: one line naming each step's result, for the summary

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need VERSION HUB_REPO REPO OWNER GH_TOKEN
ghcr="ghcr.io/$(lower "$REPO")"
hub="docker.io/${HUB_REPO}"
if [ -n "${ACTOR:-}" ]; then
  printf '%s' "$GH_TOKEN" | docker login ghcr.io -u "$ACTOR" --password-stdin >/dev/null 2>&1 || true
fi
TRIES="${TRIES:-6}"
fails=0

summary "## Withdrawal of \`${VERSION}\`: verified from outside" ""
[ -z "${STEPS:-}" ] || summary "Steps: ${STEPS}" ""
summary "| Location | Observed | Result |" "|---|---|---|"

# check <label> <expected> <command...>: runs the command until it prints the
# expected value, or TRIES attempts 10 seconds apart have passed.
check() {
  local label=$1 want=$2 got i
  shift 2
  for ((i = 1; i <= TRIES; i++)); do
    got=$("$@" 2>/dev/null)
    [ "$got" = "$want" ] && break
    [ "$i" -lt "$TRIES" ] && sleep 10
  done
  if [ "$got" = "$want" ]; then
    summary "| ${label} | ${got} | ok |"; echo "ok    ${label}: ${got}"
  else
    summary "| ${label} | ${got} | **FAIL**, expected ${want} |"; echo "FAIL  ${label}: got [${got}] want [${want}]"
    fails=$((fails + 1))
  fi
}

present() { if "$@" >/dev/null 2>&1; then echo present; else echo absent; fi; }
advertised() {  # version -> count of index entries, or "unreadable"
  local idx
  idx=$(index_yaml) || { echo unreadable; return; }
  printf '%s\n' "$idx" | grep -cE "^[[:space:]]+version: $1\$"
}
hub_tag() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "https://hub.docker.com/v2/repositories/${HUB_REPO}/tags/$1/"; }
open_issues() {
  local b
  b=$(gh issue list --repo "$REPO" --label security --state open --limit 200 --json body --jq '.[].body') || { echo unreadable; return; }
  printf '%s\n' "$b" | grep -cF "**Detected in release:** \`v${VERSION}\`"
}
hub_page_shows() {
  local p
  p=$(hub_page_live) || { echo unreadable; return; }
  if printf '%s\n' "$p" | shows_version; then echo yes; else echo no; fi
}
latest_on() {  # image -> "moved off" or "still <version>"
  if [ "$(digest_of "$1:latest")" = "$DIGEST" ]; then echo "still ${VERSION}"; else echo "moved off"; fi
}
attestations() {
  local out
  if out=$(gh api "repos/${REPO}/attestations/${DIGEST}" --jq '.attestations | length' 2>/dev/null); then
    echo "$out"
  elif printf '%s' "$out" | grep -q '"status":"404"'; then
    echo 0
  else
    echo unreadable
  fi
}

check "chart index advertises ${VERSION}" 0 advertised "$VERSION"
check ".tgz for ${VERSION} on gh-pages" absent present gh api "repos/${REPO}/contents/${CHART}-${VERSION}.tgz?ref=gh-pages"
for name in "v${VERSION}" "${CHART}-${VERSION}"; do
  check "release ${name}" absent present gh release view "$name" --repo "$REPO"
  check "git tag ${name}" absent present gh api "repos/${REPO}/git/ref/tags/${name}"
done
check "open CVE issues opened by v${VERSION}" 0 open_issues
check "Docker Hub page shows ${VERSION}" no hub_page_shows
if [ "${HUB_KEPT:-}" = "true" ]; then
  check "Docker Hub ${VERSION} (immutable, stays)" 200 hub_tag "$VERSION"
else
  check "Docker Hub ${VERSION}" 404 hub_tag "$VERSION"
fi
check "ghcr image tagged ${VERSION}" 0 ghcr_tagged "$CHART"
check "ghcr chart tagged ${VERSION}" 0 ghcr_tagged "charts%2F${CHART}"
if [ -n "${DIGEST:-}" ]; then
  check "Docker Hub latest" "moved off" latest_on "$hub"
  check "ghcr latest" "moved off" latest_on "$ghcr"
  [ "${HUB_KEPT:-}" = "true" ] || check "attestation records for the digest" 0 attestations
fi

# The release now live must be untouched.
if [ -n "${PREV:-}" ]; then
  check "release v${PREV} (live)" present present gh release view "v${PREV}" --repo "$REPO"
  check "chart index advertises ${PREV}" 1 advertised "$PREV"
  check "Docker Hub ${PREV}" 200 hub_tag "$PREV"
fi

if [ "$fails" -gt 0 ]; then
  die "${fails} location(s) still hold ${VERSION}, or the live release was disturbed. Re-run once the cause is fixed; every step skips what is already gone."
fi
echo "${VERSION} is withdrawn everywhere it can be"
