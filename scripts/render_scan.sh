#!/usr/bin/env bash
# scripts/render_scan.sh — turn a Trivy JSON report into the markdown block that
# goes on the GitHub README and the Docker Hub page.
#
# Docker Hub scans only one repository per account, so the scan it would have
# shown on the page is information this project otherwise loses. This renders
# the same thing from our own scan, in the same shape: the severity counts first,
# in Docker Hub's buckets and Docker Hub's order, then the findings behind them.
#
# SECURITY. Everything rendered below comes from outside this repository —
# package names out of somebody else's image layers, identifiers and text out of
# an advisory database — and it lands on two pages that people read and click.
# That is an injection sink, so it is treated as one:
#
#   1. Every field must match a strict allowlist, and a field that does not is
#      REPLACED, not escaped. No character from a rejected value reaches the
#      page, so there is no escaping bug left to get wrong.
#   2. The only link ever emitted is built here, from an identifier that has
#      already passed the allowlist, onto one hard-coded host. Nothing in the
#      input can introduce a URL.
#   3. The finished block is re-read before it is emitted and refused outright
#      if it contains markup, a code fence, a marker, or a link anywhere but
#      that one host — the ways content could break out of the block it is
#      confined to, or turn the page into a phishing surface.
#
# Usage: render_scan.sh <trivy.json> <image-ref> <scanned-date>
#
# Writes markdown to stdout. Exits non-zero if the input is unusable or if the
# rendered output fails its own check. An image with no findings is a valid
# result and renders as such.

# SC2016: the single-quoted strings below are markdown and jq programs, not
# shell. The backticks are markdown code spans and the $ are jq variables; both
# must reach their consumer literally.
# shellcheck disable=SC2016
set -uo pipefail

JSON="${1:?usage: render_scan.sh <trivy.json> <image-ref> <date>}"
IMAGE="${2:?}"
DATE="${3:?}"

[ -s "$JSON" ] || { echo "render_scan.sh: $JSON is missing or empty" >&2; exit 1; }
jq -e . "$JSON" >/dev/null 2>&1 || { echo "render_scan.sh: $JSON is not valid JSON" >&2; exit 1; }

# The image reference and the date are ours rather than the scanner's, but they
# are still interpolated into the page, so they are held to the same rule.
printf '%s' "$IMAGE" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9][A-Za-z0-9._-]*$' \
  || { echo "render_scan.sh: image reference is not a plain name:tag — '$IMAGE'" >&2; exit 1; }
printf '%s' "$DATE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
  || { echo "render_scan.sh: date is not YYYY-MM-DD — '$DATE'" >&2; exit 1; }

# Trivy reports the same CVE once per result set, so a finding in both the OS
# layer and the Go binary appears twice. De-duplicated ONCE here, and both the
# counts and the table below are derived from this same list — an earlier
# version counted the raw findings and listed the unique ones, so the summary
# said "High 2" above a table showing one.
#
# The allowlists are deliberately narrower than what these fields may legally
# hold. A package name needing a character outside this set is rarer than a
# package name chosen to contain one.
DEDUP=$(jq '
  def clean($s; $re; $fallback):
    if ($s | type) != "string" then $fallback
    elif ($s | length) == 0 then $fallback
    elif ($s | test($re)) then $s
    else $fallback end;

  [ .Results[]?.Vulnerabilities[]? ]
  | map({
      sev:  (if ((.Severity // "") | test("^(CRITICAL|HIGH|MEDIUM|LOW|UNKNOWN)$"))
             then .Severity else "UNKNOWN" end),
      rank: (if   .Severity == "CRITICAL" then 0
             elif .Severity == "HIGH"     then 1
             elif .Severity == "MEDIUM"   then 2
             elif .Severity == "LOW"      then 3
             else 4 end),
      id:   clean(.VulnerabilityID;  "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$";      "unprintable-id"),
      # Whether the identifier is genuinely an identifier decides whether it is
      # linked at all. A rejected value is shown as plain text: one hostile row
      # then degrades to something harmless instead of taking the whole report
      # down with it, which is what happened when every row was linked.
      ok:   ((.VulnerabilityID // "") | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")),
      pkg:  clean(.PkgName;          "^[A-Za-z0-9][A-Za-z0-9._/+@-]{0,127}$";  "unprintable-package"),
      cur:  clean(.InstalledVersion; "^[A-Za-z0-9][A-Za-z0-9._:+~-]{0,63}$";   ""),
      fix:  clean(.FixedVersion;     "^[A-Za-z0-9][A-Za-z0-9._:+~-]{0,63}$";   "")
    })
  | unique_by([.id, .pkg])
  | sort_by([.rank, .pkg, .id])
' "$JSON") || { echo "render_scan.sh: could not read findings from $JSON" >&2; exit 1; }

# Counts in Docker Hub's buckets and Docker Hub's order. Every severity is
# counted, not only the ones that block a release: the page is meant to show
# what is in the image, and a table that silently omitted MEDIUM would be a
# more misleading number than no table at all.
count() {
  printf '%s' "$DEDUP" | jq --arg s "$1" '[.[] | select(.sev == $s)] | length'
}
C=$(count CRITICAL); H=$(count HIGH); M=$(count MEDIUM); L=$(count LOW); U=$(count UNKNOWN)
TOTAL=$((C + H + M + L + U))

OUT=$(
  printf '## Vulnerability scan\n\n'
  printf '`%s`, scanned %s.\n\n' "$IMAGE" "$DATE"

  printf '| Critical | High | Medium | Low | Unknown |\n'
  printf '|---------:|-----:|-------:|----:|--------:|\n'
  printf '| %s | %s | %s | %s | %s |\n\n' "$C" "$H" "$M" "$L" "$U"

  if [ "$TOTAL" -eq 0 ]; then
    printf 'No known vulnerabilities in this image at the time of release.\n'
  else
    # Already sorted by severity then package, so the same image always renders
    # byte-identical text — otherwise every release would show a diff whether or
    # not anything actually changed. Fixed-in is the actionable column: an entry
    # with no fix is not something a rebuild would clear.
    #
    # The href is assembled from an identifier that has already passed the
    # allowlist, so the link target cannot come from the input.
    printf '| Severity | CVE | Package | Installed | Fixed in |\n'
    printf '|---|---|---|---|---|\n'
    printf '%s' "$DEDUP" | jq -r '
      .[]
      | "| \(.sev) | \(if .ok then "[" + .id + "](https://nvd.nist.gov/vuln/detail/" + .id + ")" else "`" + .id + "`" end) | `\(.pkg)` | \(if .cur == "" then "—" else "`" + .cur + "`" end) | \(if .fix == "" then "—" else "`" + .fix + "`" end) |"
    '
    printf '\n'
    printf 'Entries with no fix available are shown as —. Findings accepted deliberately\n'
    printf 'are listed in `.trivyignore` with the reason, and are excluded above.\n'
  fi
)

# The block may contain markdown text, one table, and links to one host. Anything
# else means a value got through that should not have, so refuse to emit rather
# than publish it and find out afterwards. Each check names what it caught.
fail() { echo "render_scan.sh: refusing to emit — $1" >&2; exit 1; }

if printf '%s' "$OUT" | grep -q '[<>]'; then
  fail "output contains angle brackets; HTML renders on both pages"
fi
if printf '%s' "$OUT" | grep -qF '```'; then
  fail "output contains a code fence, which would break out of the block"
fi
if printf '%s' "$OUT" | grep -qiE 'scan:(begin|end)'; then
  fail "output contains a scan marker, which would let it escape its block"
fi
if printf '%s' "$OUT" | grep -qiE 'javascript:|vbscript:|data:|file:'; then
  fail "output contains a dangerous URL scheme"
fi

# Every link must be the one built above. Anything else is a link the input chose.
bad=$(printf '%s' "$OUT" | grep -oE '\]\([^)]*\)' \
      | grep -vE '^\]\(https://nvd\.nist\.gov/vuln/detail/[A-Za-z0-9._-]+\)$' || true)
if [ -n "$bad" ]; then
  fail "unexpected link target: $(printf '%s' "$bad" | head -1)"
fi

printf '%s\n' "$OUT"
