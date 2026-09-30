#!/usr/bin/env bash
# scripts/withdraw/plan.sh — find everything VERSION left behind, and list it.
#
# Runs before the approval and changes nothing. The person approving is shown
# what exists and what will happen to it, not asked to approve a version number.
#
# Env:     VERSION, HUB_REPO, REPO, OWNER, GH_TOKEN, ACTOR
#          DIGEST   optional; the release passes the digest it pushed
# Outputs: version hub_repo digest prev found

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need VERSION HUB_REPO REPO OWNER GH_TOKEN ACTOR
plain "$VERSION" || die "'${VERSION}' is not a plain version string"
printf '%s' "$HUB_REPO" | grep -qE '^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$' \
  || die "DOCKERHUB_REPOSITORY '${HUB_REPO}' is not owner/name"
ghcr="ghcr.io/$(lower "$REPO")"
hub="docker.io/${HUB_REPO}"
printf '%s' "$GH_TOKEN" | docker login ghcr.io -u "$ACTOR" --password-stdin >/dev/null 2>&1 \
  || warn "could not log in to ghcr.io; a private package would look absent"

# The index digest: what latest, the child manifests and the attestation records
# are all keyed on. The release knows it; a manual withdrawal looks it up, on
# Docker Hub first and then on ghcr (a re-run after a partial withdrawal).
digest="${DIGEST:-}"
[ -n "$digest" ] || digest=$(digest_of "${hub}:${VERSION}")
[ -n "$digest" ] || digest=$(digest_of "${ghcr}:${VERSION}")
if [ -n "$digest" ] && ! is_digest "$digest"; then die "'${digest}' is not a sha256 digest"; fi

# The release that is live once this one is gone: the highest remaining published
# version. Drafts, pre-releases and chart-releaser's own releases do not count.
# A failed listing stops here. Read as "no earlier release", it would delete
# latest instead of moving it back.
tags=$(gh release list --repo "$REPO" --exclude-drafts --exclude-pre-releases \
         --limit 100 --json tagName --jq '.[].tagName') || die "cannot list the releases"
prev=$(printf '%s\n' "$tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -vxF "v${VERSION}" \
         | sed 's/^v//' | sort -V | tail -1)

found=0
summary "## Withdrawing \`${VERSION}\`" "" \
  "Undone in this order, the reverse of how it was published, so nothing is ever" \
  "advertised after the thing it points at is gone." "" \
  "| # | What | Now | Action |" "|---|---|---|---|"
row() { summary "| $1 | $2 | $3 | $4 |"; }

# 0. What describes the release: the Docker Hub page, the gh-pages page sources
#    and the CVE issues. Published last, so undone first.
if live=$(hub_page_live); then
  if printf '%s\n' "$live" | shows_version; then
    row 0 "Docker Hub page" "shows the ${VERSION} scan" "**restore** ${prev:+the v${prev} scan}${prev:-the page without a scan}"; found=1
  else
    row 0 "Docker Hub page" "does not show ${VERSION}" "left alone"
  fi
else
  row 0 "Docker Hub page" "unreadable" "checked again when the step runs"
fi
row 0 "gh-pages page sources" "-" "**restore** anything ${VERSION} changed that nothing has changed since"
if issues=$(gh issue list --repo "$REPO" --label security --state open --limit 200 --json body \
              --jq "[.[] | select(.body | contains(\"**Detected in release:** \`v${VERSION}\`\"))] | length"); then
  row 0 "CVE issues opened by v${VERSION}" "${issues} open" "**close**, or re-point to the live release when it has the same finding"
  [ "$issues" = "0" ] || found=1
else
  row 0 "CVE issues opened by v${VERSION}" "unreadable" "checked again when the step runs"
fi
row 0 "\"Still present in release v${VERSION}\" comments" "-" "**delete**"

# 1. latest, on either registry.
if [ -n "$digest" ]; then
  moved=""
  for img in "$ghcr" "$hub"; do
    [ "$(digest_of "${img}:latest")" = "$digest" ] && moved="${moved} ${img%%/*}"
  done
  if [ -n "$moved" ]; then
    row 1 "\`latest\` on${moved}" "points at ${VERSION}" "**move back** to ${prev:-nothing: no earlier release, so it is deleted}"; found=1
  else
    row 1 "\`latest\`" "points elsewhere" "left alone"
  fi
else
  row 1 "\`latest\`" "image not found" "nothing to do"
fi

# 2. The releases, their tags and the Latest marker.
for name in "v${VERSION}" "${CHART}-${VERSION}"; do
  if gh release view "$name" --repo "$REPO" >/dev/null 2>&1; then
    row 2 "release \`${name}\`" "published" "**delete**, with its git tag"; found=1
  else
    row 2 "release \`${name}\`" "absent" "nothing to do"
  fi
done
row 2 "\"Latest release\" marker" "-" "**moves to** ${prev:+v}${prev:-nothing, no earlier release}"

# 3. The chart repository index.
if idx=$(index_yaml); then
  if printf '%s\n' "$idx" | grep -qE "^[[:space:]]+version: ${VERSION}\$"; then
    row 3 "Helm index entry and .tgz" "advertised" "**remove**"; found=1
  else
    row 3 "Helm index entry" "not advertised" "nothing to do"
  fi
else
  row 3 "Helm index entry" "unreadable" "checked again when the step runs"
fi

# 4, 5, 6. The artefacts, and the proof of them.
if [ -n "$digest" ]; then
  row 4 "ghcr chart and image" "digest \`${digest}\`" "**delete**, with every child manifest and the provenance referrer"
  code=$(curl -s -o /dev/null -w '%{http_code}' --retry 3 --max-time 30 \
           "https://hub.docker.com/v2/repositories/${HUB_REPO}/tags/${VERSION}/")
  immutable=""
  if [ "$code" = "200" ]; then
    immutable=$(curl -s --retry 3 --max-time 30 "https://hub.docker.com/v2/repositories/${HUB_REPO}/" \
      | jq -r --arg v "$VERSION" '.immutable_tags_settings | select(.enabled == true) | .rules[]? as $r | select($v | test($r)) | $r' \
      | head -1)
  fi
  if [ "$code" != "200" ]; then
    row 5 "Docker Hub \`${VERSION}\`" "no version tag" "nothing to do"
    row 6 "attestation records" "for \`${digest}\`" "**delete**"
  elif [ -n "$immutable" ]; then
    row 5 "Docker Hub \`${VERSION}\`" "immutable (rule \`${immutable}\`)" "**stays**: Docker Hub lets no one delete it"
    row 6 "attestation records" "for \`${digest}\`" "kept, because the image is still served"
  else
    row 5 "Docker Hub \`${VERSION}\`" "published" "**delete**"
    row 6 "attestation records" "for \`${digest}\`" "**delete**"
  fi
  found=1
else
  row 4 "ghcr and Docker Hub images" "not found on either registry" "nothing to do"
fi

summary "" "Nobody can undo the Sigstore transparency-log entry or the gh-pages git history." ""
if [ "$found" = "1" ]; then
  summary "**The next approval undoes everything marked above. It publishes nothing.**" "" \
    "Review deployments → release-approval → Approve and deploy."
else
  summary "Nothing from ${VERSION} is published. There is nothing to withdraw."
fi

output version "$VERSION"
output hub_repo "$HUB_REPO"
output digest "$digest"
output prev "$prev"
output found "$found"
