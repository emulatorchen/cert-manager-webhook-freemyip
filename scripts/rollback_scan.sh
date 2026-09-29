#!/usr/bin/env bash
# scripts/rollback_scan.sh — undo one release's vulnerability scan on the pages
# that show it, when that release is withdrawn.
#
# Each release commits its scan as "Record the <version> vulnerability scan".
# Withdrawing that version restores, in each file, the scan block exactly as it
# was in the parent of that commit — the previous release's scan, or the
# placeholder if there was none. Only the block between the markers is touched,
# so any other edit made to the file since is kept.
#
# It changes nothing when the block no longer shows <version>: a newer release
# has replaced it since, and withdrawing an old version must not roll the page
# back past a release that is still live.
#
# Usage: rollback_scan.sh <version> <file> [<file> ...]
# Needs full git history of the default branch (checkout fetch-depth: 0).

set -euo pipefail

VERSION="${1:?usage: rollback_scan.sh <version> <file> [<file>...]}"
shift
[ "$#" -ge 1 ] || { echo "rollback_scan.sh: no target files given" >&2; exit 1; }

# The version reaches a git --grep pattern and a fixed-string match below.
printf '%s' "$VERSION" | grep -qE '^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$' \
  || { echo "rollback_scan.sh: '$VERSION' is not a plain version string" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
BEGIN='<!-- scan:begin -->'
END='<!-- scan:end -->'
PLACEHOLDER='_Populated by the release workflow. Until the first release publishes one, there
is no scan to show here._'

block() {  # print the lines strictly between the markers of file $1
  awk -v b="$BEGIN" -v e="$END" '
    index($0, e) { inb = 0 }
    inb          { print }
    index($0, b) { inb = 1 }
  ' "$1"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for f in "$@"; do
  [ -f "$f" ] || { echo "rollback_scan.sh: $f does not exist" >&2; exit 1; }

  # render_scan.sh writes the image reference as `<image>:<version>`, so this
  # exact form identifies a block that describes <version> and nothing else.
  if ! block "$f" | grep -qF ":${VERSION}\`,"; then
    echo "rollback_scan.sh: $f does not show ${VERSION} — left unchanged"
    continue
  fi

  commit=$(git log -F --grep="Record the ${VERSION} vulnerability scan" \
             --format=%H -- "$f" | head -1)
  if [ -n "$commit" ] && git cat-file -e "${commit}^:${f}" 2>/dev/null; then
    git show "${commit}^:${f}" > "$tmp/prev"
    block "$tmp/prev" > "$tmp/scan.md"
    src="the block before ${commit:0:7}"
  else
    # Shows the version but was never recorded by a release — put back the
    # placeholder rather than leave a withdrawn version on the page.
    printf '%s\n' "$PLACEHOLDER" > "$tmp/scan.md"
    src="the placeholder"
  fi
  [ -s "$tmp/scan.md" ] || printf '%s\n' "$PLACEHOLDER" > "$tmp/scan.md"

  # apply_scan.sh re-checks the block for markup, markers and URL schemes, so a
  # restored block is held to the same rule as a freshly rendered one.
  "$HERE/apply_scan.sh" "$tmp/scan.md" "$f" >/dev/null
  echo "rollback_scan.sh: $f restored to ${src}"

  if block "$f" | grep -qF ":${VERSION}\`,"; then
    echo "rollback_scan.sh: $f still shows ${VERSION} after the rollback" >&2
    exit 1
  fi
done
