#!/usr/bin/env bash
# scripts/withdraw/hub_page.sh — put the Docker Hub page back to the live release.
#
# Touched only while it shows VERSION's scan. It is then rewritten as the page
# source with PREV's scan, taken from PREV's release notes, or with no scan when
# PREV has none. Withdrawing an old version never touches a page that already
# describes a newer one.
#
# Env: VERSION, PREV (may be empty), HUB_REPO, REPO, GH_TOKEN,
#      HUB_USER, HUB_PW (the account password), VCS_URL

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need VERSION HUB_REPO REPO GH_TOKEN
live=$(hub_page_live) || die "cannot read the Docker Hub page"
if ! printf '%s\n' "$live" | shows_version; then
  echo "the Docker Hub page does not show ${VERSION}, so it is left alone"
  exit 0
fi

page=$(mktemp)
compose_hub_page "$page"
# dockerhub_page.sh writes the page and reads it back byte for byte.
./scripts/dockerhub_page.sh "$HUB_REPO" "$page" || die "could not restore the Docker Hub page"
echo "Docker Hub page restored to ${PREV:+the v}${PREV:-the page without a scan}"
