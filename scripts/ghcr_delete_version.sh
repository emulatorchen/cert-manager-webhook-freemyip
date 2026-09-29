#!/usr/bin/env bash
# scripts/ghcr_delete_version.sh — remove one published version from a ghcr
# package completely, not just its tag.
#
# A multi-platform image is an index plus one manifest per platform plus the
# buildx attestation manifests, and ghcr lists every one of those as its own
# package version — only the index carries the version tag. Deleting just the
# tagged version leaves the children behind, untagged but still pullable by
# digest, and leaves the provenance referrer (tagged sha256-<hex>) pointing at a
# digest that no longer has a tag. Withdrawn means all of it.
#
# Order: the index first, so nothing tagged ever points at a missing child;
# then the children; then the referrer.
#
# Usage: ghcr_delete_version.sh <owner> <package> <version>
#   <package> is URL-encoded as the API wants it, e.g. charts%2Fname
# Env:    GH_TOKEN — classic PAT with read:packages and delete:packages
#
# Exits non-zero on any failure it cannot prove harmless, so the caller can stop
# before touching another registry and leave the two still matching.

set -uo pipefail

OWNER="${1:?usage: ghcr_delete_version.sh <owner> <package> <version>}"
PKG="${2:?}"
VERSION="${3:?}"
: "${GH_TOKEN:?GH_TOKEN (read:packages, delete:packages) is required}"

for v in "$OWNER" "$VERSION"; do
  printf '%s' "$v" | grep -qE '^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$' \
    || { echo "ghcr_delete_version.sh: '$v' is not a plain name" >&2; exit 1; }
done
printf '%s' "$PKG" | grep -qE '^[0-9A-Za-z][0-9A-Za-z._%-]{0,127}$' \
  || { echo "ghcr_delete_version.sh: '$PKG' is not a plain package name" >&2; exit 1; }

api="users/${OWNER}/packages/container/${PKG}/versions"

if ! all=$(gh api --paginate "$api" 2>&1); then
  case "$all" in *"404"*) echo "${PKG}: no such package, nothing to delete"; exit 0 ;; esac
  echo "ghcr_delete_version.sh: cannot list ${PKG}: ${all}" >&2
  exit 1
fi
# --paginate concatenates JSON arrays; flatten them into one.
all=$(printf '%s' "$all" | jq -s 'add // []')

index=$(printf '%s' "$all" | jq -r --arg v "$VERSION" \
  '.[] | select(.metadata.container.tags | index($v)) | "\(.id) \(.name)"' | head -1)
if [ -z "$index" ]; then
  echo "${PKG}: ${VERSION} not present"
  exit 0
fi
index_id=${index%% *}
index_digest=${index#* }

# Children of the index, read from the index itself before it is deleted.
ref="ghcr.io/${OWNER}/$(printf '%s' "$PKG" | sed 's/%2F/\//g'):${VERSION}"
children=$(docker buildx imagetools inspect --raw "$ref" 2>/dev/null \
             | jq -r '.manifests[]?.digest' 2>/dev/null || true)

del() {  # id, label
  if gh api -X DELETE "${api}/$1" >/dev/null 2>&1; then
    echo "deleted ${PKG} $2"
  else
    echo "ghcr_delete_version.sh: could not delete ${PKG} $2 (version id $1)" >&2
    return 1
  fi
}

failed=0
del "$index_id" "${VERSION} (index ${index_digest})" || failed=1

for d in $children; do
  id=$(printf '%s' "$all" | jq -r --arg d "$d" '.[] | select(.name == $d) | .id' | head -1)
  if [ -n "$id" ]; then
    del "$id" "child ${d}" || failed=1
  fi
done

# attest-build-provenance stores its referrer under the fallback tag
# sha256-<hex of the subject digest>.
referrer_tag="sha256-${index_digest#sha256:}"
rid=$(printf '%s' "$all" | jq -r --arg t "$referrer_tag" \
  '.[] | select(.metadata.container.tags | index($t)) | .id' | head -1)
if [ -n "$rid" ]; then
  del "$rid" "provenance referrer ${referrer_tag}" || failed=1
fi

exit "$failed"
