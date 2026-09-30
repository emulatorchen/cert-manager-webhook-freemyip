#!/usr/bin/env bash
# scripts/withdraw/records.sh — remove VERSION's releases, tags and chart index entry.
#
# Both releases: ours, v<version>, which carries the scan in its notes, and the
# one chart-releaser makes for itself. The Latest marker was set explicitly by
# the release, so it is handed back explicitly rather than left to GitHub.
#
# The index is edited through the contents API rather than a push: every
# checkout here keeps no credential, and a destructive job is the last place to
# start holding a pushable one in a shell.
#
# Env: VERSION, PREV (may be empty), REPO, GH_TOKEN

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need VERSION REPO GH_TOKEN
plain "$VERSION" || die "'${VERSION}' is not a plain version string"
command -v yq >/dev/null 2>&1 || die "yq is not available on this runner"

if was_latest=$(gh api "repos/${REPO}/releases/latest" --jq '.tag_name' 2>/dev/null); then :; else was_latest=""; fi
for name in "v${VERSION}" "${CHART}-${VERSION}"; do
  if ! gh release view "$name" --repo "$REPO" >/dev/null 2>&1; then
    echo "release ${name} not present"
    continue
  fi
  gh release delete "$name" --repo "$REPO" --cleanup-tag --yes || die "could not delete release ${name}"
  echo "deleted release ${name} and its tag"
done
# A tag can outlive its release when an earlier attempt failed between the two.
for name in "v${VERSION}" "${CHART}-${VERSION}"; do
  if gh api "repos/${REPO}/git/ref/tags/${name}" >/dev/null 2>&1; then
    gh api -X DELETE "repos/${REPO}/git/refs/tags/${name}" >/dev/null || die "could not delete tag ${name}"
    echo "deleted tag ${name}"
  fi
done
if [ "$was_latest" = "v${VERSION}" ] && [ -n "${PREV:-}" ]; then
  gh release edit "v${PREV}" --repo "$REPO" --latest >/dev/null || die "could not mark v${PREV} as the latest release"
  echo "v${PREV} is the latest release again"
fi

# The chart repository index and the .tgz beside it.
work=$(mktemp -d)
if meta=$(gh api "repos/${REPO}/contents/index.yaml?ref=gh-pages" 2>/dev/null); then
  sha=$(printf '%s' "$meta" | jq -r '.sha')
  printf '%s' "$meta" | jq -r '.content' | base64 -d > "${work}/index.yaml"
  before=$(yq ".entries[\"${CHART}\"] | length" "${work}/index.yaml")
  V="$VERSION" yq -i "del(.entries[\"${CHART}\"][] | select(.version == strenv(V)))" "${work}/index.yaml"
  after=$(yq ".entries[\"${CHART}\"] | length" "${work}/index.yaml")
  if [ "$before" != "$after" ]; then
    gh api -X PUT "repos/${REPO}/contents/index.yaml" \
      -f message="Withdraw ${VERSION} from the chart repository index" \
      -f content="$(base64 < "${work}/index.yaml" | tr -d '\n')" \
      -f sha="$sha" -f branch=gh-pages >/dev/null || die "could not update index.yaml"
    echo "removed ${VERSION} from index.yaml (${before} -> ${after} entries)"
  else
    echo "index.yaml does not advertise ${VERSION}"
  fi
elif printf '%s' "$meta" | grep -q '"status":"404"'; then
  echo "no index.yaml on gh-pages"
else
  die "cannot read index.yaml on gh-pages"
fi

tgz="${CHART}-${VERSION}.tgz"
if tsha=$(gh api "repos/${REPO}/contents/${tgz}?ref=gh-pages" --jq '.sha' 2>/dev/null); then
  gh api -X DELETE "repos/${REPO}/contents/${tgz}" \
    -f message="Withdraw ${tgz}" -f sha="$tsha" -f branch=gh-pages >/dev/null || die "could not delete ${tgz}"
  echo "deleted ${tgz} from gh-pages"
fi

# Read back: success has to mean what the step's name says.
idx=$(index_yaml) || die "cannot read index.yaml back"
if printf '%s\n' "$idx" | grep -qE "^[[:space:]]+version: ${VERSION}\$"; then
  die "index.yaml still advertises ${VERSION} after the update"
fi
rm -rf "$work"
