#!/usr/bin/env bash
# scripts/apply_scan.sh — drop a rendered scan block into the pages that show it.
#
# Replaces everything between <!-- scan:begin --> and <!-- scan:end --> in each
# file given. Kept separate from render_scan.sh so the rendering can be checked
# on its own, and so this can be run by hand against a saved report.
#
# Usage: apply_scan.sh <scan.md> <file> [<file> ...]
#
# Exits non-zero if a file has no marker pair — silently leaving a page
# un-updated is the failure mode this whole change exists to remove.

set -euo pipefail

SCAN="${1:?usage: apply_scan.sh <scan.md> <file> [<file>...]}"
shift
[ -s "$SCAN" ] || { echo "apply_scan.sh: $SCAN is missing or empty" >&2; exit 1; }
[ "$#" -ge 1 ] || { echo "apply_scan.sh: no target files given" >&2; exit 1; }

BEGIN='<!-- scan:begin -->'
END='<!-- scan:end -->'

# Checked here as well as in render_scan.sh, on purpose. This is the step that
# actually writes to pages people read, and it must hold even if the block was
# produced by something else, by hand, or by a future caller. A block carrying
# markup could phish on the rendered page; a block carrying an end marker would
# escape its own section and take the rest of the file with it.
if grep -q '[<>]' "$SCAN"; then
  echo "apply_scan.sh: $SCAN contains angle brackets — refusing to write markup into a page" >&2
  exit 1
fi
if grep -qiE 'scan:(begin|end)' "$SCAN"; then
  echo "apply_scan.sh: $SCAN contains a scan marker — it would escape its own block" >&2
  exit 1
fi
if grep -qiE 'javascript:|vbscript:|data:|file:' "$SCAN"; then
  echo "apply_scan.sh: $SCAN contains a dangerous URL scheme" >&2
  exit 1
fi

changed=0
for f in "$@"; do
  [ -f "$f" ] || { echo "apply_scan.sh: $f does not exist" >&2; exit 1; }
  grep -qF "$BEGIN" "$f" || { echo "apply_scan.sh: $f has no ${BEGIN}" >&2; exit 1; }
  grep -qF "$END"   "$f" || { echo "apply_scan.sh: $f has no ${END}" >&2; exit 1; }

  tmp="${f}.scan.tmp"
  # awk rather than sed: the replacement is a multi-line file whose content is
  # arbitrary markdown, and feeding that through sed's replacement syntax is how
  # a stray & or \ silently corrupts a page.
  awk -v begin="$BEGIN" -v end="$END" -v scan="$SCAN" '
    index($0, begin) { print; while ((getline line < scan) > 0) print line; close(scan); skip = 1; next }
    index($0, end)   { skip = 0 }
    !skip
  ' "$f" > "$tmp"

  if cmp -s "$f" "$tmp"; then
    rm -f "$tmp"
    echo "apply_scan.sh: $f already current"
  else
    mv "$tmp" "$f"
    echo "apply_scan.sh: $f updated"
    changed=1
  fi

  # The markers must survive, or the next release has nowhere to write.
  if ! grep -qF "$BEGIN" "$f" || ! grep -qF "$END" "$f"; then
    echo "apply_scan.sh: $f lost its markers — refusing to leave it in that state" >&2
    exit 1
  fi
done

# Reported, not fatal: a release that changes nothing on the page is a normal
# outcome, and the caller decides whether that means "skip the commit".
[ "$changed" = "1" ] || echo "apply_scan.sh: nothing changed"
exit 0
