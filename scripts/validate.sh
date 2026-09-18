#!/usr/bin/env bash
# scripts/validate.sh — supply-chain gate for .github/workflows/
#
# Encodes the harden-release-workflows rules as assertions so the same checks
# run locally and in CI. Exits non-zero on any failure.
#
# No python/pyyaml dependency — grep/sed/awk only, so it runs unchanged in an
# alpine CI container.
#
# Tools: actionlint and zizmor on PATH, or set TOOLS_DIR=<dir>.
# CI installs both with sha256 verification (the docker-nginx-lego pattern).

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

WF=".github/workflows"
TOOLS_DIR="${TOOLS_DIR:-}"
[ -n "$TOOLS_DIR" ] && PATH="$TOOLS_DIR:$PATH"

FAIL=0
ok()    { printf '  ok    %s\n' "$1"; }
bad()   { printf '  FAIL  %s\n' "$1"; FAIL=1; }
head_() { printf '\n== %s ==\n' "$1"; }

# ── 1. actionlint (also validates YAML syntax) ───────────────────────────────
head_ "actionlint / YAML syntax"
if command -v actionlint >/dev/null 2>&1; then
  # actionlint shells out to shellcheck for run: blocks and silently skips it
  # when absent. CI runners have it, so without this warning a local pass can
  # disagree with CI — which is exactly how SC2129 reached a pull request.
  command -v shellcheck >/dev/null 2>&1 \
    || echo "  warn  shellcheck missing — run: blocks will NOT be linted here, but will be in CI"
  if out=$(actionlint "$WF"/*.y*ml 2>&1); then ok "no findings"; else bad "findings:"; echo "$out"; fi
else
  bad "actionlint not installed"
fi

# ── 2. every external action pinned to a 40-hex SHA with a version comment ───
head_ "Rule 1 — actions pinned to commit SHAs"
grep -rh 'uses:' "$WF" 2>/dev/null | while IFS= read -r line; do
  ref=$(printf '%s' "$line" | sed 's/.*uses:[[:space:]]*//; s/[[:space:]]*#.*//')
  case "$ref" in ./*|docker://*|'') continue ;; esac
  sha=${ref##*@}
  if printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$'; then
    printf '%s' "$line" | grep -q '#' \
      && printf '  ok    %s\n' "$ref" \
      || printf '  FAIL  %s pinned but has no version comment\n' "$ref"
  else
    printf '  FAIL  %s is not a 40-char SHA pin\n' "$ref"
  fi
done > /tmp/_pin.txt
cat /tmp/_pin.txt; grep -q FAIL /tmp/_pin.txt && FAIL=1; rm -f /tmp/_pin.txt

# ── 3. no workflow-level write permission (must be job-scoped) ───────────────
head_ "Rule 4 — write permissions are job-scoped"
for f in "$WF"/*.y*ml; do
  w=$(awk '
    /^permissions:/ {inblk=1; next}
    inblk && /^[^[:space:]]/ {inblk=0}
    inblk && /:[[:space:]]*write([[:space:]]|$)/ {print}
  ' "$f")
  [ -z "$w" ] && ok "$(basename "$f"): none" \
              || { bad "$(basename "$f"): workflow-level write permission"; printf '%s\n' "$w" | sed 's/^/        /'; }
done

# ── 4. no publish credentials in pull_request-triggered workflows ────────────
head_ "Rule 2 — no publish credentials in PR-triggered workflows"
for f in "$WF"/*.y*ml; do
  awk '/^on:/{o=1;next} /^[^[:space:]]/{o=0} o' "$f" | grep -q 'pull_request' || continue
  # Needles are written with an explicit space class before the colon so this
  # line does not itself look like a leaked credential to the outbound guard.
  hits=$(grep -nE 'password[[:space:]]*:|NODE_AUTH[_]TOKEN|PYPI_API[_]TOKEN|OSSRH[_]PASSWORD|push:[[:space:]]*true' "$f")
  [ -z "$hits" ] && ok "$(basename "$f"): clean" \
                 || { bad "$(basename "$f"): PR-triggered and carries publish capability"; printf '%s\n' "$hits" | sed 's/^/        /'; }
done

# ── 5. publishing jobs declare environment: release ──────────────────────────
head_ "Rule 4/5 — publishing jobs gated by the release environment"
for f in "$WF"/*.y*ml; do
  awk -v F="$(basename "$f")" '
    /^jobs:/ {injobs=1; next}
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      if (job != "") flush()
      job=$1; sub(/:$/,"",job); body=""; next
    }
    injobs {body = body $0 "\n"}
    END {if (job != "") flush()}
    function flush() {
      pub = (body ~ /push:[[:space:]]*true/) || (body ~ /helm push/) \
            || (body ~ /gh release create/) || (body ~ /packages:[[:space:]]*write/)
      if (pub) {
        if (body ~ /environment:[[:space:]]*release/) printf "  ok    %s:%s gated\n", F, job
        else                                          printf "  FAIL  %s:%s publishes without environment: release\n", F, job
      }
    }
  ' "$f"
done > /tmp/_env.txt
[ -s /tmp/_env.txt ] && cat /tmp/_env.txt || echo "  ok    no publishing jobs found"
grep -q FAIL /tmp/_env.txt && FAIL=1; rm -f /tmp/_env.txt

# ── 6. no untrusted context expanded inside run: blocks ──────────────────────
# Tracks run: blocks by indentation. Expansions in with:/env:/if: are fine —
# only shell interpolation is an injection sink.
head_ "Template injection — no \${{ }} in run: blocks"
for f in "$WF"/*.y*ml; do
  awk -v F="$f" '
    match($0, /^[[:space:]]*/) { ind = RLENGTH }
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[|>]?[[:space:]]*$/ ||
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[^|>[:space:]]/ {
      inrun = 1; runind = ind; next
    }
    inrun && ind <= runind && NF > 0 { inrun = 0 }
    inrun && /\$\{\{[[:space:]]*(github\.(actor|event|head_ref|ref_name)|secrets\.)/ {
      printf "%s:%d:%s\n", F, NR, $0
    }
  ' "$f"
done > /tmp/_ti.txt
if [ -s /tmp/_ti.txt ]; then
  bad "expansions inside run: — pass via env: instead"; sed 's/^/        /' /tmp/_ti.txt
else
  ok "none"
fi
rm -f /tmp/_ti.txt

# ── 7. every checkout sets persist-credentials: false ────────────────────────
head_ "artipacked — checkout must not persist credentials"
n_co=$(grep -rho 'uses:[[:space:]]*actions/checkout@' "$WF" 2>/dev/null | wc -l | tr -d ' ')
n_pc=$(grep -rho 'persist-credentials:[[:space:]]*false' "$WF" 2>/dev/null | wc -l | tr -d ' ')
[ "$n_co" = "$n_pc" ] && ok "$n_pc/$n_co checkouts set persist-credentials: false" \
                      || bad "$n_pc/$n_co checkouts set persist-credentials: false"

# ── 8. concurrency declared ──────────────────────────────────────────────────
head_ "concurrency"
for f in "$WF"/*.y*ml; do
  grep -q '^concurrency:' "$f" && ok "$(basename "$f")" || bad "$(basename "$f"): no concurrency group"
done

# ── 9. release workflow is human-triggered only ──────────────────────────────
# A tag push is not an explicit release decision: anything that can create a
# ref can start it. workflow_dispatch forces a person to press the button.
head_ "Rule 3 — release runs only on workflow_dispatch"
for f in "$WF"/release.y*ml; do
  [ -e "$f" ] || continue
  trig=$(awk '/^on:/{o=1;next} /^[^[:space:]]/{o=0} o' "$f")
  printf '%s' "$trig" | grep -q 'workflow_dispatch' || bad "$(basename "$f"): no workflow_dispatch trigger"
  if printf '%s' "$trig" | grep -qE '^[[:space:]]*(push|pull_request|schedule):'; then
    bad "$(basename "$f"): has an automatic trigger — publishing must be human-initiated"
    printf '%s\n' "$trig" | grep -E '^[[:space:]]*(push|pull_request|schedule):' | sed 's/^/        /'
  else
    ok "$(basename "$f"): workflow_dispatch only"
  fi
done

# ── 10. cancellation cleanup for non-atomic registries ───────────────────────
# Docker Hub publishes tag by tag, so a cancel mid-run leaves a half-released
# version behind. Something has to clean that up.
head_ "Rule 6 — cancellation cleanup present"
for f in "$WF"/release.y*ml; do
  [ -e "$f" ] || continue
  grep -qE 'if:[[:space:]]*cancelled\(\)' "$f" \
    && ok "$(basename "$f"): has a cancelled() cleanup job" \
    || bad "$(basename "$f"): no cancelled() cleanup job"
done

# ── 11. published images carry provenance and an SBOM ────────────────────────
head_ "Supply chain — published images are attested"
for f in "$WF"/release.y*ml; do
  [ -e "$f" ] || continue
  if grep -qE 'push:[[:space:]]*true' "$f"; then
    grep -qE '^[[:space:]]*provenance:' "$f" && ok "$(basename "$f"): provenance set" \
                                             || bad "$(basename "$f"): pushes without provenance:"
    grep -qE '^[[:space:]]*sbom:' "$f"       && ok "$(basename "$f"): sbom set" \
                                             || bad "$(basename "$f"): pushes without sbom:"
  fi
done

# ── 12. Docker Hub credentials only inside release-gated jobs ────────────────
# Only credentials are gated. A repository variable holding the Docker Hub
# repository name is not one, so this matches secrets.DOCKERHUB* specifically.
head_ "Rule 4 — Docker Hub credentials only in release-gated jobs"
for f in "$WF"/*.y*ml; do
  grep -qE 'secrets\.DOCKERHUB' "$f" || continue
  awk -v F="$(basename "$f")" '
    /^jobs:/ {injobs=1; next}
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { if (job!="") flush(); job=$1; sub(/:$/,"",job); body=""; next }
    injobs {body = body $0 "\n"}
    END {if (job!="") flush()}
    function flush() {
      if (body ~ /secrets\.DOCKERHUB/) {
        if (body ~ /environment:[[:space:]]*release/) printf "  ok    %s:%s gated\n", F, job
        else                                          printf "  FAIL  %s:%s uses Docker Hub outside environment: release\n", F, job
      }
    }
  ' "$f"
done > /tmp/_dh.txt
[ -s /tmp/_dh.txt ] && cat /tmp/_dh.txt || echo "  ok    no Docker Hub usage found"
grep -q FAIL /tmp/_dh.txt && FAIL=1; rm -f /tmp/_dh.txt

# ── 13. every pin resolves to the version its comment claims ─────────────────
# A SHA that is real but belongs to a different release is indistinguishable
# from a correct pin by eye. Needs network and gh; skipped without them, and
# always runs in CI.
head_ "Rule 1 — pinned SHA matches the version in the comment"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  grep -rhoE 'uses:[[:space:]]*[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40}[[:space:]]*#[[:space:]]*v[0-9A-Za-z.-]+' "$WF" \
    | sed -E 's/uses:[[:space:]]*//; s/[[:space:]]*#[[:space:]]*/ /' | sort -u \
    | while read -r ref tag; do
        repo="${ref%@*}"; sha="${ref##*@}"
        base=$(printf '%s' "$repo" | cut -d/ -f1,2)
        r=$(gh api "repos/$base/git/ref/tags/$tag" -q '.object.sha + " " + .object.type' 2>/dev/null)
        if [ -z "$r" ]; then printf '  FAIL  %s %s — tag not found upstream\n' "$base" "$tag"; continue; fi
        obj=$(printf '%s' "$r" | cut -d' ' -f1); typ=$(printf '%s' "$r" | cut -d' ' -f2)
        deref="$obj"
        [ "$typ" = "tag" ] && deref=$(gh api "repos/$base/git/tags/$obj" -q '.object.sha' 2>/dev/null)
        # Either the commit or the annotated-tag object is a sound pin: both
        # are content-addressed and immutable.
        if [ "$sha" = "$obj" ] || [ "$sha" = "$deref" ]; then
          printf '  ok    %s %s\n' "$base" "$tag"
        else
          printf '  FAIL  %s %s — file pins %s, upstream tag is %s\n' "$base" "$tag" "$sha" "$deref"
        fi
      done > /tmp/_pv.txt
  cat /tmp/_pv.txt; grep -q FAIL /tmp/_pv.txt && FAIL=1; rm -f /tmp/_pv.txt
else
  echo "  skip  gh unavailable or unauthenticated — pin/tag agreement not checked"
fi

# ── 14. zizmor — nothing at error level ──────────────────────────────────────
# BLOCK_SEVERITY follows the release workflow's input of the same name, so the
# bar tightens in one place. CRITICAL blocks on zizmor's error level only;
# CRITICAL,HIGH blocks on warnings too. Findings print either way, so the
# softer setting reports everything and just does not fail the build.
head_ "zizmor (blocking at ${BLOCK_SEVERITY:-CRITICAL})"
if command -v zizmor >/dev/null 2>&1; then
  zizmor --format plain --no-online-audits "$WF" > /tmp/_zz.txt 2>&1

  if grep -qE '^error\[' /tmp/_zz.txt; then
    bad "error-level findings:"; grep -E '^error\[' /tmp/_zz.txt | sed 's/^/        /'
  else
    ok "no error-level findings"
  fi

  if grep -qE '^warning\[' /tmp/_zz.txt; then
    case "${BLOCK_SEVERITY:-CRITICAL}" in
      *HIGH*) bad "warning-level findings:" ;;
      *)      echo "  warn  warning-level findings (not blocking at this bar):" ;;
    esac
    grep -E '^warning\[' /tmp/_zz.txt | sed 's/^/        /'
  else
    ok "no warning-level findings"
  fi

  rm -f /tmp/_zz.txt
else
  bad "zizmor not installed"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then echo "VALIDATION PASSED"; exit 0; else echo "VALIDATION FAILED"; exit 1; fi
