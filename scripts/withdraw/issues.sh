#!/usr/bin/env bash
# scripts/withdraw/issues.sh — take back the CVE list VERSION published as issues.
#
# The release opens one [SECURITY] issue per finding and comments on the ones
# already open. Both are statements about the withdrawn image. An issue it opened
# is closed, unless the same finding is in the live release's scan. Then the
# issue is still true and is re-pointed at that release. Its "still present"
# comments are deleted.
#
# "Live" means PREV's scan, read from PREV's release notes: the same source the
# Docker Hub page is restored from, so the two cannot disagree.
#
# Env: VERSION, PREV (may be empty), REPO, GH_TOKEN

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need VERSION REPO GH_TOKEN
live=""
if [ -n "${PREV:-}" ]; then
  s=$(release_scan "v${PREV}") || die "cannot read the release notes of v${PREV}"
  live=$(printf '%s\n' "$s" | grep -oE '(CVE|GHSA|GO)-[0-9A-Za-z-]+' | sort -u)
fi
marker="**Detected in release:** \`v${VERSION}\`"
failed=0

issues=$(gh issue list --repo "$REPO" --label security --state open --limit 200 \
           --json number,title,body) || die "cannot list the security issues"
while IFS= read -r n; do
  [ -n "$n" ] || continue
  title=$(printf '%s' "$issues" | jq -r --argjson n "$n" '.[] | select(.number == $n) | .title')
  cve=$(printf '%s' "$title" | grep -oE '(CVE|GHSA|GO)-[0-9A-Za-z-]+' | head -1)
  if [ -n "$cve" ] && [ -n "${PREV:-}" ] && printf '%s\n' "$live" | grep -qxF "$cve"; then
    body=$(printf '%s' "$issues" | jq -r --argjson n "$n" '.[] | select(.number == $n) | .body')
    body=${body//"$marker"/"**Detected in release:** \`v${PREV}\`"}
    if gh issue edit "$n" --repo "$REPO" --body "$body" >/dev/null \
       && gh issue comment "$n" --repo "$REPO" \
            --body "Release \`v${VERSION}\` was withdrawn. This finding is also in \`v${PREV}\`, which is live again, so the issue stays open." >/dev/null; then
      echo "#${n} ${cve}: re-pointed at v${PREV}"
    else
      echo "::error::could not re-point #${n}"; failed=1
    fi
  elif gh issue close "$n" --repo "$REPO" --reason "not planned" \
         --comment "Opened by release \`v${VERSION}\`, which has been withdrawn. The release now live does not contain this finding." >/dev/null; then
    echo "#${n} ${cve}: closed"
  else
    echo "::error::could not close #${n}"; failed=1
  fi
done < <(printf '%s' "$issues" | jq -r --arg m "$marker" '.[] | select(.body | contains($m)) | .number')

# Comments the release added to issues older than it.
comments=$(gh api --paginate "repos/${REPO}/issues/comments?per_page=100" \
             --jq ".[] | select(.user.login == \"github-actions[bot]\") | select(.body | startswith(\"Still present in release \`v${VERSION}\`\")) | .id") \
  || die "cannot list the issue comments"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if gh api -X DELETE "repos/${REPO}/issues/comments/${id}" >/dev/null 2>&1; then
    echo "deleted comment ${id}"
  else
    echo "::error::could not delete comment ${id}"; failed=1
  fi
done <<< "$comments"

exit "$failed"
