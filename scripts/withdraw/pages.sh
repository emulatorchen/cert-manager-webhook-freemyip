#!/usr/bin/env bash
# scripts/withdraw/pages.sh — undo VERSION's changes to the gh-pages page sources.
#
# The release writes each page source with the message "Add|Update <name> for
# <version>". Each one is put back as it was before that commit, or removed if
# the release added it, but only while it still holds exactly what that release
# wrote. A later release's page is never touched.
#
# Needs the gh-pages history: run from a checkout, it fetches the branch itself.
#
# Env: VERSION, REPO, GH_TOKEN

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need VERSION REPO GH_TOKEN
plain "$VERSION" || die "'${VERSION}' is not a plain version string"
if ! git fetch --quiet origin gh-pages; then
  echo "no gh-pages branch, so there is nothing to roll back"
  exit 0
fi

work=$(mktemp -d)
for name in index.html robots.txt sitemap.xml; do
  c=$(git log origin/gh-pages -F --grep="${name} for ${VERSION}" --format=%H -- "$name" | head -1)
  if [ -z "$c" ]; then
    echo "${name}: not changed by ${VERSION}"
    continue
  fi
  cur=$(git rev-parse -q --verify "origin/gh-pages:${name}") || cur=""
  if [ "$cur" != "$(git rev-parse "${c}:${name}")" ]; then
    echo "${name}: changed again after ${VERSION}, so it is left as it is"
    continue
  fi
  sha=$(gh api "repos/${REPO}/contents/${name}?ref=gh-pages" --jq '.sha') || die "cannot read ${name} on gh-pages"
  if git cat-file -e "${c}^:${name}" 2>/dev/null; then
    git show "${c}^:${name}" > "${work}/${name}"
    gh api -X PUT "repos/${REPO}/contents/${name}" \
      -f message="Withdraw ${name} changes from ${VERSION}" \
      -f content="$(base64 < "${work}/${name}" | tr -d '\n')" \
      -f sha="$sha" -f branch=gh-pages >/dev/null || die "could not restore ${name}"
    echo "${name}: restored to its content before ${VERSION}"
  else
    gh api -X DELETE "repos/${REPO}/contents/${name}" \
      -f message="Withdraw ${name}, added by ${VERSION}" \
      -f sha="$sha" -f branch=gh-pages >/dev/null || die "could not remove ${name}"
    echo "${name}: removed, it was added by ${VERSION}"
  fi
done
rm -rf "$work"
