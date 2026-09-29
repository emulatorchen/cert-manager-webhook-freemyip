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

# ── 4b. every job states its own permissions ─────────────────────────────────
#
# A job with no `permissions:` block inherits the workflow default. That is fine
# until someone widens the default for one job's benefit and silently widens
# every other job with it — the token escalation nobody reviews, because the
# diff touches one line far away from the job it affects. Stating them per job
# makes the blast radius of any such change exactly one job.
#
# Jobs that call a reusable workflow are held to it too. GitHub supports
# `permissions:` on them, and it matters more there: a called workflow can only
# narrow the token its caller hands it, so the caller's block is the ceiling
# for every job inside.
head_ "Permissions are declared per job, never inherited"
for f in "$WF"/*.y*ml; do
  awk -v F="$(basename "$f")" '
    /^jobs:/ {injobs=1; next}
    injobs && /^  #/ { next }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      if (job != "") flush()
      job=$1; sub(/:$/,"",job); perms=0; reusable=0; next
    }
    injobs && /^    permissions:/ { perms=1 }
    injobs && /^    uses:/ { reusable=1 }
    function flush() {
      if (perms) printf "  ok    %s:%s%s\n", F, job, (reusable ? " (reusable-workflow caller)" : "")
      else printf "  FAIL  %s:%s inherits the workflow default\n", F, job
    }
    END { if (job != "") flush() }
  ' "$f"
done > /tmp/_perm.txt
cat /tmp/_perm.txt; grep -q FAIL /tmp/_perm.txt && FAIL=1; rm -f /tmp/_perm.txt

# ── 4c. the published page is inert ──────────────────────────────────────────
#
# docs/pages/ is copied verbatim onto gh-pages by the release, so whatever is
# there is served from the project's own origin. A third-party script, an
# iframe, or a form on that page would be a credential-phishing surface wearing
# this project's URL — and it would arrive through an ordinary-looking docs
# commit rather than anything the release would question.
#
# Inline <script type="application/ld+json"> is structured metadata, carries no
# code, and is allowed. Everything else with a src, and every event handler, is
# not.
head_ "Published pages carry no executable or third-party content"
if [ -d docs/pages ]; then
  for f in docs/pages/*.html; do
    [ -e "$f" ] || continue
    bad=""
    grep -qiE '<script[^>]+src=' "$f"                         && bad="${bad} external-script"
    grep -qiE '<iframe|<object|<embed' "$f"                   && bad="${bad} embedded-frame"
    grep -qiE '<form|formaction=' "$f"                        && bad="${bad} form"
    grep -qiE ' on[a-z]+=' "$f"                               && bad="${bad} inline-event-handler"
    grep -qiE 'javascript:|vbscript:' "$f"                    && bad="${bad} script-url"
    # rel="stylesheet" specifically. A canonical or alternate <link> carries no
    # code and is exactly what the page is supposed to have.
    grep -qiE '<link[^>]+rel="stylesheet"' "$f" \
      && grep -qiE '<link[^>]+rel="stylesheet"[^>]+href="https?://' "$f" \
      && bad="${bad} external-stylesheet"
    # An inline <script> is allowed only for ld+json. -F, not a regex: `\+` in a
    # basic regular expression means "one or more d", not a literal plus, which
    # made this flag the very page it was written to allow.
    if grep -qiE '<script' "$f" && grep -iE '<script' "$f" | grep -qvF 'application/ld+json'; then
      bad="${bad} inline-script"
    fi
    [ -z "$bad" ] && ok "$(basename "$f"): inert" || bad "$(basename "$f"):${bad}"
  done
else
  ok "no published pages"
fi

# ── 5. publishing jobs sit behind the approval environment ───────────────────
#
# `environment:` alone is NOT the check. The approval and the publish
# credentials live in different environments on purpose — the reviewer sits on
# release-approval, the Docker Hub token sits on release, which carries no
# reviewer so that seven publishing jobs do not mean seven prompts. Treating
# any environment as "gated" would therefore pass a job that publishes with
# nobody approving anything. What has to hold is that every publishing job is,
# or descends from, a job in APPROVAL_ENV.
head_ "Rule 4/5 — publishing jobs sit behind the approval environment"
APPROVAL_ENV="${APPROVAL_ENV:-release-approval}"
for f in "$WF"/*.y*ml; do
  awk -v F="$(basename "$f")" -v APPROVAL="$APPROVAL_ENV" '
    # A comment block at job indentation introduces the job BELOW it, not the
    # one above. Buffering those and handing them to the next job is what stops
    # a comment mentioning another job being read as part of this one — which
    # made one job look gated and another look like it published.
    /^jobs:/ {injobs=1; next}
    injobs && /^  #/ { pend = pend $0 "\n"; next }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      if (job != "") flush()
      job=$1; sub(/:$/,"",job); body=pend; pend=""; next
    }
    injobs { if (pend != "") { body = body pend; pend = "" } body = body $0 "\n" }

    function flush() { bodies[job] = body; order[++n] = job }
    END {
      if (job != "") flush()
      # Only the approval environment counts as an approver.
      for (j in bodies)
        if (bodies[j] ~ ("environment:[[:space:]]*" APPROVAL "[[:space:]]*$") ||
            bodies[j] ~ ("environment:[[:space:]]*" APPROVAL "[^A-Za-z0-9_-]")) approver[j] = 1

      # Reachability, not just direct needs. A publishing job four hops below
      # the approval is still governed by it, and checking one hop would have
      # forced every job to declare the environment — the seven-prompt problem
      # this split exists to solve.
      for (j in bodies) {
        b = bodies[j]
        if (match(b, /needs:[^\n]*/)) needs[j] = substr(b, RSTART, RLENGTH)
        else needs[j] = ""
      }
      for (pass = 1; pass <= n; pass++) {
        changed = 0
        for (j in bodies) {
          if (j in covered || j in approver) continue
          for (k in bodies) {
            if (!(k in approver) && !(k in covered)) continue
            if (index(needs[j], k)) { covered[j] = 1; changed = 1; break }
          }
        }
        if (!changed) break
      }

      for (i = 1; i <= n; i++) {
        j = order[i]; b = bodies[j]
        pub = (b ~ /push:[[:space:]]*true/) || (b ~ /helm push/) \
              || (b ~ /gh release create/) || (b ~ /imagetools create/)
        if (!pub) continue
        # A job may opt out with a marker naming its reason. Only for work that
        # publishes nothing anyone would pull.
        if (b ~ /no-release-gate:/) { printf "  ok    %s:%s exempt, see marker\n", F, j; continue }
        if (j in approver) { printf "  ok    %s:%s is the approval job\n", F, j; continue }
        if (j in covered)  { printf "  ok    %s:%s behind %s\n", F, j, APPROVAL; continue }
        printf "  FAIL  %s:%s publishes without %s upstream\n", F, j, APPROVAL
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
    # Any expansion, not a list of contexts. Naming contexts is how this
    # missed ${{ needs.*.result }} in the status jobs, which zizmor caught
    # and this did not.
    inrun && /\$\{\{/ {
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
# Anchored to the start of the line so a *comment* mentioning either string
# is not counted as one. An off-by-one here reads as a checkout missing the
# setting, which is the one finding in this file that must never be noise.
n_co=$(grep -rhE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*actions/checkout@' "$WF" 2>/dev/null | wc -l | tr -d ' ')
n_pc=$(grep -rhE '^[[:space:]]*persist-credentials:[[:space:]]*false' "$WF" 2>/dev/null | wc -l | tr -d ' ')
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

# ── 10. a cancelled or failed release is reverted ────────────────────────────
# Something must run when a release stops part-way after its first push, and
# undo it. That used to be a set of cleanup_* jobs; it is now a `rollback` job
# calling the withdraw workflow, because the Docker Hub version tag — the only
# write that cannot be undone — is created last and in one step, so everything
# a stopped release can have written is reversible.
#
# Checked as a property: some cleanup_* or rollback job runs with always(), so
# it still runs when the workflow is cancelled, and its condition takes a
# cancelled push into account.
head_ "Rule 6 — a cancelled or failed release is reverted"
for f in "$WF"/release.y*ml; do
  [ -e "$f" ] || continue
  hit=$(awk '
    /^  (rollback|cleanup_[A-Za-z0-9_]+):[[:space:]]*$/ { injob=1; body=""; next }
    injob && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { injob=0 }
    injob { body = body $0 "\n" }
    injob && /^    (uses|steps):/ {
      if (body ~ /always\(\)/ && body ~ /cancelled/) { print "yes"; exit }
    }
  ' "$f")
  if [ "$hit" = "yes" ]; then
    ok "$(basename "$f"): a rollback runs on cancellation and failure"
  else
    bad "$(basename "$f"): nothing reverts a release cancelled or failed after its first push"
  fi
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

# ── 12. Docker Hub credentials only inside environment-gated jobs ────────────
# Only credentials are gated. A repository variable holding the Docker Hub
# repository name is not one, so this matches secrets.DOCKERHUB* specifically.
#
# Two environments are allowed, and they are not interchangeable:
#   release            — the registry token, which can push and delete tags.
#   dockerhub-metadata — the account password, which the Hub web API demands
#                        for the description and which can do anything the
#                        account can. It is deliberately NOT in `release`, so
#                        no publishing job can read it.
head_ "Rule 4 — Docker Hub credentials only in environment-gated jobs"
for f in "$WF"/*.y*ml; do
  grep -qE 'secrets\.DOCKERHUB' "$f" || continue
  awk -v F="$(basename "$f")" '
    /^jobs:/ {injobs=1; next}
    injobs && /^  #/ { pend = pend $0 "\n"; next }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { if (job!="") flush(); job=$1; sub(/:$/,"",job); body=pend; pend=""; next }
    injobs { if (pend != "") { body = body pend; pend = "" } body = body $0 "\n" }
    END {if (job!="") flush()}
    function flush() {
      if (body !~ /secrets\.DOCKERHUB/) return
      # A job that calls a local reusable workflow cannot declare an
      # environment — the callee does. Passing the username on is fine; passing
      # a write-capable credential is not, and the callee could not use it
      # anyway, because an environment secret always beats a passed one.
      if (body ~ /uses:[[:space:]]*\.\/\.github\/workflows\//) {
        if (body ~ /secrets\.DOCKERHUB_(PASSWORD|RELEASE_TOKEN):/) {
          printf "  FAIL  %s:%s passes a write-capable Docker Hub credential into a called workflow\n", F, job
        } else {
          printf "  ok    %s:%s calls a reusable workflow; the environment is declared there\n", F, job
        }
        return
      }
      gated = (body ~ /environment:[[:space:]]*(release|dockerhub-metadata)/)
      if (!gated) {
        printf "  FAIL  %s:%s uses Docker Hub credentials outside a gated environment\n", F, job
        return
      }
      # The account password is strictly narrower than the rest: only the
      # metadata environment may hold it.
      if (body ~ /secrets\.DOCKERHUB_PASSWORD/ && body !~ /environment:[[:space:]]*dockerhub-metadata/) {
        printf "  FAIL  %s:%s reads DOCKERHUB_PASSWORD outside environment: dockerhub-metadata\n", F, job
        return
      }
      printf "  ok    %s:%s gated\n", F, job
    }
  ' "$f"
done > /tmp/_dh.txt
[ -s /tmp/_dh.txt ] && cat /tmp/_dh.txt || echo "  ok    no Docker Hub usage found"
grep -q FAIL /tmp/_dh.txt && FAIL=1; rm -f /tmp/_dh.txt

# ── 12b. every non-GITHUB_TOKEN secret sits behind an environment ────────────
# A workflow_dispatch can be started from any ref by anyone with write access,
# so a repository secret used by an ungated job is readable by whatever code
# that branch happens to contain. An environment with a branch policy is the
# only thing that stops it.
#
# FREEMYIP_TOKEN and CERTBOT_EMAIL are the deliberate exceptions: they have to
# be reachable from pull request jobs, and neither can publish anything — the
# token writes one TXT record, the address registers with Let's Encrypt staging.
head_ "Secrets other than GITHUB_TOKEN are environment-gated"
for f in "$WF"/*.y*ml; do
  grep -qE 'secrets\.[A-Z_]+' "$f" || continue
  awk -v F="$(basename "$f")" '
    /^jobs:/ {injobs=1; next}
    injobs && /^  #/ { pend = pend $0 "\n"; next }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { if (job!="") flush(); job=$1; sub(/:$/,"",job); body=pend; pend=""; next }
    injobs { if (pend != "") { body = body pend; pend = "" } body = body $0 "\n" }
    END {if (job!="") flush()}
    function flush(  tmp) {
      tmp = body
      gsub(/secrets\.(GITHUB_TOKEN|FREEMYIP_TOKEN|CERTBOT_EMAIL|DOCKERHUB_USERNAME)/, "", tmp)
      if (tmp !~ /secrets\.[A-Z_]+/) return
      if (body ~ /uses:[[:space:]]*\.\/\.github\/workflows\//) return
      if (body ~ /environment:[[:space:]]*[a-z-]+/) printf "  ok    %s:%s gated\n", F, job
      else                                          printf "  FAIL  %s:%s reads a privileged secret without an environment\n", F, job
    }
  ' "$f"
done > /tmp/_sec.txt
[ -s /tmp/_sec.txt ] && cat /tmp/_sec.txt || echo "  ok    no privileged secrets outside GITHUB_TOKEN"
grep -q FAIL /tmp/_sec.txt && FAIL=1; rm -f /tmp/_sec.txt

# ── 12b. credential environments are reachable only through the approval ─────
#
# `release` carries no reviewer of its own — the reviewer sits
# on release-approval, so one decision covers a whole release instead of one
# prompt per job. That makes the environment check above necessary but not
# sufficient: any job on main that declares `environment: release` receives the
# Docker Hub publish token, approved or not. What has to hold is that every such
# job is the approval job or descends from it through `needs`.
#
# dockerhub-metadata is deliberately not listed: its job refreshes the Hub page
# on its own when the page source changes on main, by the user's decision to
# keep one approval per release.
head_ "Credential environments are reachable only through the approval"
CRED_ENVS="${CRED_ENVS:-release}"
for f in "$WF"/*.y*ml; do
  awk -v F="$(basename "$f")" -v APPROVAL="${APPROVAL_ENV:-release-approval}" -v CRED="$CRED_ENVS" '
    BEGIN { n = split(CRED, c, " "); for (i = 1; i <= n; i++) cred[c[i]] = 1 }
    /^jobs:/ {injobs=1; next}
    injobs && /^  #/ { next }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job=$1; sub(/:$/,"",job); order[++m]=job; next }
    injobs && job != "" && /^    needs:/ { needs[job] = $0 }
    injobs && job != "" && /^    environment:/ { e=$2; env[job]=e; if (e == APPROVAL) approver[job]=1 }
    END {
      for (pass = 1; pass <= m; pass++) {
        changed = 0
        for (i = 1; i <= m; i++) {
          j = order[i]
          if (j in covered || j in approver) continue
          for (k in approver) if (index(needs[j], k)) { covered[j]=1; changed=1 }
          for (k in covered)  if (!(j in covered) && index(needs[j], k)) { covered[j]=1; changed=1 }
        }
        if (!changed) break
      }
      for (i = 1; i <= m; i++) {
        j = order[i]
        if (!(env[j] in cred)) continue
        if (j in covered) printf "  ok    %s:%s (%s) behind %s\n", F, j, env[j], APPROVAL
        else              printf "  FAIL  %s:%s reads the %s environment without passing %s\n", F, j, env[j], APPROVAL
      }
    }
  ' "$f"
done > /tmp/_cred.txt
[ -s /tmp/_cred.txt ] && cat /tmp/_cred.txt || echo "  ok    no job uses a credential environment"
grep -q FAIL /tmp/_cred.txt && FAIL=1; rm -f /tmp/_cred.txt

# ── 12c. package write access is reachable only through the approval ─────────
#
# A run's GITHUB_TOKEN with packages: write can publish to this repository's
# packages — and, because GitHub gives the publishing repository the admin role
# on them, delete their versions. That is how the release publishes and how
# rollback and withdraw remove versions without any personal token. It is not
# an environment secret, so the rule above cannot see it: this one holds every
# job asking for packages: write to the same standard — the approval job, or
# downstream of it through `needs`.
head_ "Package write access is reachable only through the approval"
for f in "$WF"/*.y*ml; do
  awk -v F="$(basename "$f")" -v APPROVAL="${APPROVAL_ENV:-release-approval}" '
    /^jobs:/ {injobs=1; next}
    injobs && /^  #/ { next }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job=$1; sub(/:$/,"",job); order[++m]=job; inperm=0; next }
    injobs && job != "" && /^    needs:/ { needs[job] = $0 }
    injobs && job != "" && /^    environment:/ { if ($2 == APPROVAL) approver[job]=1 }
    injobs && job != "" && /^    permissions:/ { inperm=1; next }
    injobs && job != "" && inperm && /^    [a-z]/ { inperm=0 }
    injobs && job != "" && inperm && /^      packages:[[:space:]]*write/ { pw[job]=1 }
    END {
      for (pass = 1; pass <= m; pass++) {
        changed = 0
        for (i = 1; i <= m; i++) {
          j = order[i]
          if (j in covered || j in approver) continue
          for (k in approver) if (index(needs[j], k)) { covered[j]=1; changed=1 }
          for (k in covered)  if (!(j in covered) && index(needs[j], k)) { covered[j]=1; changed=1 }
        }
        if (!changed) break
      }
      for (i = 1; i <= m; i++) {
        j = order[i]
        if (!(j in pw)) continue
        if (j in covered || j in approver) printf "  ok    %s:%s packages: write behind %s\n", F, j, APPROVAL
        else printf "  FAIL  %s:%s asks for packages: write without passing %s\n", F, j, APPROVAL
      }
    }
  ' "$f"
done > /tmp/_pkg.txt
[ -s /tmp/_pkg.txt ] && cat /tmp/_pkg.txt || echo "  ok    no job asks for packages: write"
grep -q FAIL /tmp/_pkg.txt && FAIL=1; rm -f /tmp/_pkg.txt

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
