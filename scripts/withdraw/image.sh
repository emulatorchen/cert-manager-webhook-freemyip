#!/usr/bin/env bash
# scripts/withdraw/image.sh — remove the Docker Hub version tag, where anyone can.
#
# A version tag matched by a tag-immutability rule can be neither overwritten nor
# deleted. That is what the rule is for, and nobody can take such a tag back. So
# it is checked, not attempted: an immutable tag is reported as staying, and the
# attestation records that prove it stay with it.
#
# A release rolling itself back never has this tag: it creates it last.
#
# Env:     VERSION, HUB_REPO, HUB_USER, HUB_PAT (the registry token)
# Outputs: removed  true once no Docker Hub version tag names the image

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need VERSION HUB_REPO
plain "$VERSION" || die "'${VERSION}' is not a plain version string"
code=$(curl -s -o /dev/null -w '%{http_code}' --retry 3 --max-time 30 \
         "https://hub.docker.com/v2/repositories/${HUB_REPO}/tags/${VERSION}/")
case "$code" in
  404) echo "${HUB_REPO}:${VERSION} does not exist, so there is nothing to remove"
       output removed true; exit 0 ;;
  200) ;;
  *)   die "could not check ${HUB_REPO}:${VERSION} (HTTP ${code})" ;;
esac

settings=$(curl -sf --retry 3 --max-time 30 "https://hub.docker.com/v2/repositories/${HUB_REPO}/" \
             | jq -c '.immutable_tags_settings // {}') || die "could not read the immutability settings"
if [ "$(printf '%s' "$settings" | jq -r '.enabled // false')" = "true" ]; then
  # Docker Hub rules are RE2; the ones this project uses are plain anchored
  # patterns that ERE reads the same way.
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    if printf '%s' "$VERSION" | grep -qE -- "$rule"; then
      warn "${HUB_REPO}:${VERSION} is immutable (rule ${rule}) and nobody can remove it. Everything else was withdrawn; this tag and its attestation records stay."
      summary "### \`${HUB_REPO}:${VERSION}\` stays" "" \
        "The tag-immutability rule \`${rule}\` stops deletion as well as overwrite." \
        "\`latest\` no longer points at it, and nothing this project publishes refers to it."
      output removed false
      exit 0
    fi
  done < <(printf '%s' "$settings" | jq -r '.rules[]?')
fi

need HUB_USER HUB_PAT
jwt=$(HUB_SECRET="$HUB_PAT" hub_jwt)
[ -n "$jwt" ] || die "could not authenticate to the Docker Hub API"
code=$(curl -s -o /dev/null -w '%{http_code}' --retry 3 --max-time 30 -X DELETE \
         "https://hub.docker.com/v2/repositories/${HUB_REPO}/tags/${VERSION}/" \
         -H "Authorization: Bearer ${jwt}")
case "$code" in
  20*|404) echo "deleted ${HUB_REPO}:${VERSION} (HTTP ${code})"; output removed true ;;
  *) die "deleting ${HUB_REPO}:${VERSION} returned HTTP ${code}" ;;
esac
