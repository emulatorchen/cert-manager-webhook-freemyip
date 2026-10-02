#!/usr/bin/env bash
# scripts/withdraw/packages.sh — remove VERSION's chart, then its image, from ghcr.
#
# Chart before image: the chart is what points at the image. Each goes
# completely: the tagged index, every child manifest ghcr lists as its own
# version, and the provenance referrer.
#
# With the run's own GITHUB_TOKEN. GitHub gives the repository whose workflow
# published a package the admin role on it, and with that a run's token can
# delete the package's versions: this repository's two packages, for one run.
#
# Env: VERSION, OWNER, ACTOR, GH_TOKEN

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need VERSION OWNER ACTOR GH_TOKEN
plain "$VERSION" || die "'${VERSION}' is not a plain version string"
# Reading each index to find its children needs pull access to a package that
# may be private.
printf '%s' "$GH_TOKEN" | docker login ghcr.io -u "$ACTOR" --password-stdin >/dev/null \
  || die "could not log in to ghcr.io"
# A refusal means the repository has lost its admin role on the package
# (Package settings → Manage Actions access). It stops before the Docker Hub
# step, so the registries still match.
if ! ./scripts/ghcr_delete_version.sh "$(lower "$OWNER")" "charts%2F${CHART}" "$VERSION" \
   || ! ./scripts/ghcr_delete_version.sh "$(lower "$OWNER")" "$CHART" "$VERSION"; then
  die "ghcr deletion failed. Check that ${REPO:-this repository} has the Admin role under each package's Manage Actions access. Docker Hub was not touched."
fi
