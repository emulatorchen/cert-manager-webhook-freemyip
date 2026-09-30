#!/usr/bin/env bash
# scripts/withdraw/latest.sh — move latest back off VERSION, on both registries.
#
# Moved back, not deleted: withdrawing a bad release leaves users on the previous
# good one, as if the bad one had never shipped. Touched only on a registry where
# latest still points at VERSION's digest. With no earlier release it is removed
# on Docker Hub; on ghcr it goes with the version's package entry in packages.sh.
#
# ghcr first, as on publication: its tags are the overwritable ones.
#
# Env: DIGEST (may be empty), PREV (may be empty), HUB_REPO, REPO, ACTOR,
#      GH_TOKEN, HUB_USER, HUB_PAT (the registry token)

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

if [ -z "${DIGEST:-}" ]; then
  echo "no image for this version, so latest cannot point at it"
  exit 0
fi
need HUB_REPO REPO ACTOR GH_TOKEN HUB_USER HUB_PAT
is_digest "$DIGEST" || die "'${DIGEST}' is not a sha256 digest"
ghcr="ghcr.io/$(lower "$REPO")"
hub="docker.io/${HUB_REPO}"

user=$(printf '%s' "$HUB_USER" | tr -d '[:space:]')
printf '%s' "$HUB_PAT" | tr -d '[:space:]' | docker login docker.io -u "$user" --password-stdin >/dev/null \
  || die "could not log in to Docker Hub"
printf '%s' "$GH_TOKEN" | docker login ghcr.io -u "$ACTOR" --password-stdin >/dev/null \
  || die "could not log in to ghcr.io"

for img in "$ghcr" "$hub"; do
  if [ "$(digest_of "${img}:latest")" != "$DIGEST" ]; then
    echo "${img}:latest does not point at this version, so it is left alone"
    continue
  fi
  if [ -n "${PREV:-}" ]; then
    want=$(digest_of "${img}:${PREV}")
    [ -n "$want" ] || die "${img}:${PREV} does not resolve, so latest has nowhere to go back to"
    docker buildx imagetools create --tag "${img}:latest" "${img}@${want}" \
      || die "could not move ${img}:latest back to ${PREV}"
    [ "$(digest_of "${img}:latest")" = "$want" ] \
      || die "${img}:latest does not resolve to ${PREV} after moving it"
    echo "${img}:latest -> ${PREV} (${want})"
  elif [ "$img" = "$hub" ]; then
    jwt=$(HUB_SECRET="$HUB_PAT" hub_jwt)
    [ -n "$jwt" ] || die "could not authenticate to the Docker Hub API"
    code=$(curl -s -o /dev/null -w '%{http_code}' --retry 3 --max-time 30 -X DELETE \
             "https://hub.docker.com/v2/repositories/${HUB_REPO}/tags/latest/" \
             -H "Authorization: Bearer ${jwt}")
    case "$code" in
      20*|404) echo "${hub}:latest removed: there is no earlier release" ;;
      *) die "deleting ${hub}:latest returned HTTP ${code}" ;;
    esac
  else
    echo "${ghcr}:latest has no earlier release to move to; it goes with the version's package"
  fi
done
