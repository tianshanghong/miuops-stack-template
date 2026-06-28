#!/usr/bin/env bash
#
# Structure-lint oracle for the miuops fleet template.
#
# Asserts that this repo carries the agreed fleet skeleton and ZERO deploy
# machinery: the caller deploy.yml pins an immutable tag and forwards secrets,
# the .sops.yaml rule targets only fleet/secrets/{json,env}, .gitignore commits
# the encrypted secrets while blocking decrypted scratch, the example stack sits
# at the two-level <server>/<stack>/ path and passes the miuops policy-check, and
# the old machinery (sync-template.yml, inline rsync/compose deploy, top-level
# stacks/) is gone.
#
# Every assertion is designed to FAIL if the property it guards is broken; run
# with MUTATE=<name> to prove a given assertion can fail (see --list-mutations).
#
# Usage:
#   tests/template_structure_test.sh                 # run the full oracle
#   tests/template_structure_test.sh --list-mutations
#   MUTATE=<name> tests/template_structure_test.sh   # apply a mutation in a
#                                                    # throwaway copy, expect red

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY=".github/workflows/deploy.yml"
CI=".github/workflows/ci.yml"
SOPS=".sops.yaml"
GITIGNORE=".gitignore"
EXAMPLE_STACK="fleet/stacks/server-01/whoami/docker-compose.yml"

pass=0
fail=0
ok()   { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# assert "<description>" <command...>  — passes when the command succeeds.
assert() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# --- optional mutation harness (proves assertions can fail) -------------------
MUTATIONS="caller_tag caller_secrets caller_machinery sops_regex \
gitignore_allow gitignore_block stack_policy stack_depth sync_gone \
old_stacks_gone example_present readme_known_hosts \
group_vars_example readme_deployed_vars readme_observability group_vars_token_bridge"

if [ "${1:-}" = "--list-mutations" ]; then
  echo "Available mutations (run as MUTATE=<name>):"
  for m in $MUTATIONS; do echo "  - $m"; done
  exit 0
fi

if [ -n "${MUTATE:-}" ]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  # Copy the tracked tree into a throwaway dir, mutate it there, lint that.
  cp -R "$REPO_ROOT/." "$work/"
  rm -rf "$work/.git"
  case "$MUTATE" in
    caller_tag)       sed -i.bak 's#deploy\.yml@v[0-9][^ ]*#deploy.yml@main#' "$work/$DEPLOY" ;;
    caller_secrets)   sed -i.bak '/secrets: inherit/d' "$work/$DEPLOY" ;;
    caller_machinery) printf '      - uses: appleboy/ssh-action@v1\n        run: rsync stacks/\n' >> "$work/$DEPLOY" ;;
    sops_regex)       sed -i.bak 's#\^fleet/secrets/.*#^fleet/.*#' "$work/$SOPS" ;;
    gitignore_allow)  sed -i.bak '/!fleet\/secrets\/\*\.json/d;/!fleet\/secrets\/\*\.env/d' "$work/$GITIGNORE" ;;
    gitignore_block)  sed -i.bak '/^\*\.dec$/d;/^\*\.plain$/d' "$work/$GITIGNORE" ;;
    readme_known_hosts) sed -i.bak '/SSH_KNOWN_HOSTS/d' "$work/README.md" ;;
    stack_policy)     printf '    privileged: true\n    ports: ["0.0.0.0:80:80"]\n' >> "$work/$EXAMPLE_STACK" ;;
    stack_depth)      mkdir -p "$work/fleet/stacks/server-01" && cp "$work/$EXAMPLE_STACK" "$work/fleet/stacks/server-01/docker-compose.yml" ;;
    sync_gone)        printf 'name: Sync template\n' > "$work/.github/workflows/sync-template.yml" ;;
    old_stacks_gone)  mkdir -p "$work/stacks" && touch "$work/stacks/.gitkeep" ;;
    example_present)  rm -f "$work/$EXAMPLE_STACK" ;;
    group_vars_example)   rm -f "$work/fleet/group_vars/all.yml.example" ;;
    readme_deployed_vars) sed -i.bak '/\.vars\.json/d' "$work/README.md" ;;
    readme_observability) sed -i.bak '/[Oo]bservability/d' "$work/README.md" ;;
    group_vars_token_bridge) printf 'export GRAFANA_CLOUD_TOKEN=glc_x\n' >> "$work/fleet/group_vars/all.yml.example" ;;
    *) echo "unknown mutation: $MUTATE (see --list-mutations)" >&2; exit 2 ;;
  esac
  echo "## Running oracle against MUTATED copy (MUTATE=$MUTATE) — expect FAIL"
  REPO_ROOT="$work"
fi

cd "$REPO_ROOT" || { echo "cannot cd to $REPO_ROOT" >&2; exit 2; }
echo "# template_structure_test — repo: $REPO_ROOT"

# --- 1. caller deploy.yml pins an immutable tag (not a mutable ref) -----------
assert "deploy.yml uses the miuops reusable workflow pinned to a vN.N.N tag" \
  grep -Eq 'uses: *tianshanghong/miuops/\.github/workflows/deploy\.yml@v[0-9]+\.[0-9]+\.[0-9]+' "$DEPLOY"
if grep -Eq 'deploy\.yml@(main|master|HEAD)' "$DEPLOY" 2>/dev/null; then
  bad "deploy.yml must NOT pin a mutable ref (@main/@master/@HEAD)"
else
  ok  "deploy.yml does not pin a mutable ref (@main/@master/@HEAD)"
fi

# --- 2. caller forwards secrets and is machinery-free ------------------------
assert "deploy.yml forwards 'secrets: inherit'" \
  grep -q 'secrets: inherit' "$DEPLOY"
if grep -Eiq 'rsync|ssh-action|ssh_private_key|appleboy|burnett01|docker compose' "$DEPLOY" 2>/dev/null; then
  bad "deploy.yml must not contain inline deploy machinery (rsync/ssh-action/compose)"
else
  ok  "deploy.yml contains no inline deploy machinery"
fi

# --- 3. .sops.yaml rule targets ONLY fleet/secrets/{json,env} ----------------
assert ".sops.yaml has the '^fleet/secrets/' path_regex" \
  grep -Eq 'path_regex:[[:space:]]*\^fleet/secrets/.*\\\.\(json\|env\)\$' "$SOPS"
# Behavioural check: the rule's regex must match the two secret kinds and reject
# the plaintext config paths. Extract the regex from .sops.yaml and test it.
sops_regex_matches() {
  python3 - "$SOPS" <<'PY'
import re, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
rules = doc["creation_rules"]
pats = [re.compile(r["path_regex"]) for r in rules if "path_regex" in r]
must_match = ["fleet/secrets/abc.json", "fleet/secrets/server-01.env"]
must_not   = ["fleet/host_vars/server-01.yml", "fleet/inventory.ini",
              "fleet/stacks/server-01/whoami/docker-compose.yml"]
def any_match(p): return any(rx.search(p) for rx in pats)
ok = all(any_match(p) for p in must_match) and not any(any_match(p) for p in must_not)
sys.exit(0 if ok else 1)
PY
}
assert ".sops.yaml regex matches secrets json/env but NOT plaintext config" \
  sops_regex_matches

# --- 4. .gitignore commits encrypted secrets, blocks decrypted scratch -------
assert ".gitignore allows committing encrypted fleet/secrets/*.json" \
  grep -Fq '!fleet/secrets/*.json' "$GITIGNORE"
assert ".gitignore allows committing encrypted fleet/secrets/*.env" \
  grep -Fq '!fleet/secrets/*.env' "$GITIGNORE"
assert ".gitignore blocks decrypted *.dec scratch anywhere (un-anchored, not just fleet/secrets/)" \
  grep -qE '^[*][.]dec$' "$GITIGNORE"
assert ".gitignore blocks decrypted scratch *.plain" \
  grep -Fq '*.plain' "$GITIGNORE"
assert "README documents the SSH_KNOWN_HOSTS per-server secret (host-key pinning)" \
  grep -Fq 'SSH_KNOWN_HOSTS' README.md

# --- 5. example stack exists at the two-level <server>/<stack>/ path ---------
assert "example stack exists at $EXAMPLE_STACK" \
  test -f "$EXAMPLE_STACK"
# the two-star glob must expand to at least one file at <server>/<stack>/ depth
shopt -s nullglob
two_level=(fleet/stacks/*/*/docker-compose.yml)
if [ ${#two_level[@]} -ge 1 ]; then
  ok  "two-level glob fleet/stacks/*/*/docker-compose.yml is non-empty"
else
  bad "two-level glob fleet/stacks/*/*/docker-compose.yml is non-empty"
fi
shopt -u nullglob
# no compose one level too shallow (would be silently skipped by the glob)
assert "no stack mis-placed one level too shallow (fleet/stacks/server-01/docker-compose.yml)" \
  test ! -e fleet/stacks/server-01/docker-compose.yml

# --- 6. example stack PASSES the miuops policy-check -------------------------
# Prefer the canonical check fetched from miuops/main (fail-closed); fall back to
# a local checkout so the oracle is runnable offline. Skip only if neither is
# reachable — and say so loudly.
POLICY_LOCAL="/Users/wwang/src/miuops/tests/stack_policy_check.py"
policy_script=""
fetched="$(mktemp)"
if curl -fsSL -o "$fetched" \
     https://raw.githubusercontent.com/tianshanghong/miuops/main/tests/stack_policy_check.py 2>/dev/null \
     && [ -s "$fetched" ]; then
  policy_script="$fetched"
  echo "# policy-check: using script fetched from miuops/main"
elif [ -f "$POLICY_LOCAL" ]; then
  policy_script="$POLICY_LOCAL"
  echo "# policy-check: using local $POLICY_LOCAL"
fi
if [ -n "$policy_script" ]; then
  shopt -s nullglob
  files=(fleet/stacks/*/*/docker-compose.yml fleet/stacks/*/*/compose.yml fleet/stacks/*/*/compose.yaml)
  shopt -u nullglob
  if [ ${#files[@]} -eq 0 ]; then
    bad "policy-check found no stacks to lint"
  elif python3 "$policy_script" "${files[@]}" >/dev/null 2>&1; then
    ok  "example stack(s) PASS the miuops policy-check"
  else
    bad "example stack(s) FAIL the miuops policy-check"
  fi
else
  echo "WARN - policy-check script unavailable (no network, no local checkout); skipping"
fi
rm -f "$fetched"

# --- 7. obsolete machinery is GONE -------------------------------------------
assert "sync-template.yml is removed" \
  test ! -e .github/workflows/sync-template.yml
assert "old top-level stacks/ dir is removed" \
  test ! -e stacks
# no tool/CLI machinery shipped in the template
assert "no roles/ dir shipped in the template" \
  test ! -e roles
assert "no playbook.yml shipped in the template" \
  test ! -e playbook.yml

# --- 8. round-trip shape for secrets -----------------------------------------
assert "fleet/secrets/ exists (so sops -e -i has a home)" \
  test -d fleet/secrets
assert ".env.example exists as the cleartext source for fleet/secrets/<server>.env" \
  test -f .env.example

# --- 9. ci.yml policy-check glob points at the two-level depth ---------------
assert "ci.yml policy-check glob is fleet/stacks/*/*/docker-compose.yml" \
  grep -Fq 'fleet/stacks/*/*/docker-compose.yml' "$CI"
if grep -Eq 'files=\(stacks/\*/' "$CI" 2>/dev/null; then
  bad "ci.yml still uses the old single-level stacks/*/ glob"
else
  ok  "ci.yml does not use the old single-level stacks/*/ glob"
fi

# --- 10. ships the new deployed-secret + config model scaffolding -------------
# group_vars/all.yml is where fleet-wide CONFIG (the Grafana Cloud obs endpoints)
# lives; the deployed SECRETS (the Grafana token, a server's AWS backup creds) are
# SOPS-encrypted JSON vars files the converge decrypts. The template must teach this
# so a new adopter lands on the current model, not the pre-SOPS env bridge.
assert "fleet/group_vars/all.yml.example exists (fleet-wide config home for obs endpoints)" \
  test -f fleet/group_vars/all.yml.example
assert "README documents the fleet-wide deployed secret all.vars.json (the Grafana token)" \
  grep -Fq 'all.vars.json' README.md
assert "README documents the per-server <server>.vars.json deployed secret (AWS backup creds)" \
  grep -Fq '<server>.vars.json' README.md
assert "README covers observability (on by default, shipping to Grafana Cloud)" \
  grep -Eiq 'observability' README.md
# Meaning-level pin (not just substring): the obs token example must send the token to
# all.vars.json AND must NOT carry a stale `export GRAFANA_CLOUD_TOKEN` env bridge -- the
# exact drift you'd get by copying the tool repo's (still-stale) all.yml.example.
assert "all.yml.example sends the obs token to all.vars.json, not a stale env export" \
  bash -c "grep -Fq 'all.vars.json' fleet/group_vars/all.yml.example && ! grep -Eqi 'export GRAFANA_CLOUD_TOKEN' fleet/group_vars/all.yml.example"

# --- summary ------------------------------------------------------------------
echo
echo "# ---- ${pass} passed, ${fail} failed ----"
[ "$fail" -eq 0 ]
