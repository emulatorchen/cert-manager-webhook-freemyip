#!/usr/bin/env bash
# scripts/withdraw/attestations.sh — remove the attestation records for the digest.
#
# Last: a record for an image that is already gone is harmless for the moment it
# takes to get here. Removing it first would leave a live image without its
# proof. The Sigstore transparency-log entry behind it is append-only and stays.
#
# Env: DIGEST, OWNER, GH_TOKEN

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need DIGEST OWNER GH_TOKEN
is_digest "$DIGEST" || die "'${DIGEST}' is not a sha256 digest"
if out=$(gh api -X DELETE "users/${OWNER}/attestations/digest/${DIGEST}" 2>&1); then
  echo "attestation records for ${DIGEST} deleted"
else
  case "$out" in
    *404*) echo "no attestation records for ${DIGEST}" ;;
    *) die "could not delete the attestation records for ${DIGEST}: ${out}" ;;
  esac
fi
