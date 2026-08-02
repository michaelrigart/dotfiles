#!/usr/bin/env bash
# Mocked test for reconcile-agents.sh: stubs claude/codex on PATH with crafted JSON and
# asserts the review-fix behaviour — exact field matching, explicit JSON-schema validation
# (empty stdout / {} / [{}] rejected), disabled/failed-install handling, and Codex source
# normalization + reconciliation. Run: bash .scripts/test-reconcile-agents.sh
set -u
RECON="$(cd "$(dirname "$0")" && pwd)/reconcile-agents.sh"
BIN=$(mktemp -d); CFG=$(mktemp -d); CLD=$(mktemp -d)
mkdir -p "$CFG/agents" "$CLD/plugins"
trap 'rm -rf "$BIN" "$CFG" "$CLD"' EXIT   # clean temp dirs even on interrupt
pass=0; fail=0; OUT=""; RC=0

# Claude state is read from files, not the CLI: `claude plugin list` no longer exists and
# `marketplace list` lost --json. Scenarios below still AUTHOR the legacy CLI shapes
# (readable, and unchanged from when this suite was written); run() materializes them into
# the real on-disk layout under $CLD. Anything that does not convert is written through
# verbatim so the malformed/wrong-shape scenarios still reach the schema guard.
# The `type == "array"` guards are load-bearing. jq's map() on {} yields [] rather than
# failing, so without them the {} rejection scenario would be converted into a valid
# "nothing installed" state and the reconciler would reinstall every declared plugin —
# silently deleting the very case section F exists to pin.
materialize_claude_state() {
  local conv
  if conv=$(printf '%s' "$MOCK_CL_MKT" | jq -ce 'if type == "array" then (map({key: .repo, value: {source: {source: "github", repo: .repo}}}) | from_entries) else error("not-legacy") end' 2>/dev/null); then
    printf '%s' "$conv" > "$CLD/plugins/known_marketplaces.json"
  else
    printf '%s' "$MOCK_CL_MKT" > "$CLD/plugins/known_marketplaces.json"
  fi
  if conv=$(printf '%s' "$MOCK_CL_PLUGINS" | jq -ce 'if type == "array" then {version: 2, plugins: (map({key: .id, value: [{scope: .scope}]}) | from_entries)} else error("not-legacy") end' 2>/dev/null); then
    printf '%s' "$conv" > "$CLD/plugins/installed_plugins.json"
    printf '%s' "$MOCK_CL_PLUGINS" | jq -c '{enabledPlugins: (map({key: .id, value: .enabled}) | from_entries)}' > "$CLD/settings.json"
  else
    printf '%s' "$MOCK_CL_PLUGINS" > "$CLD/plugins/installed_plugins.json"
    printf '{}' > "$CLD/settings.json"
  fi
}

# install/add still go through the CLI — those subcommands exist and are asserted live below.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "plugin install"*)         exit "$MOCK_CL_INSTALL_RC" ;;
  "plugin marketplace add"*) exit 0 ;;
  *) exit 0 ;;
esac
STUB
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "plugin marketplace list --json") printf '%s' "$MOCK_CX_MKT" ;;
  "plugin list --json")             printf '%s' "$MOCK_CX_PLUGINS" ;;
  "plugin marketplace add"*)        exit 0 ;;
  "plugin add"*)                    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/claude" "$BIN/codex"

reset_mocks() {  # sane valid-empty defaults; scenarios override specific ones
  export MOCK_CL_MKT='[]' MOCK_CL_PLUGINS='[]' MOCK_CL_INSTALL_RC=0
  export MOCK_CX_MKT='{"marketplaces":[]}' MOCK_CX_PLUGINS='{"installed":[]}'
}
run() {  # run <manifest> (\n allowed) ; sets $OUT and $RC
  printf '%b\n' "$1" > "$CFG/agents/plugins.conf"
  materialize_claude_state
  OUT=$(PATH="$BIN:$PATH" XDG_CONFIG_HOME="$CFG" CLAUDE_CONFIG_DIR="$CLD" /bin/bash "$RECON" 2>&1); RC=$?
}
_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; printf '%s\n' "$OUT" | sed 's/^/    | /'; fail=$((fail + 1)); }
has()   { case "$OUT" in *"$1"*) _pass "$2" ;; *) _fail "$2" ;; esac; }
hasnt() { case "$OUT" in *"$1"*) _fail "$2" ;; *) _pass "$2" ;; esac; }
rc_is() { if [ "$RC" -eq "$1" ]; then _pass "$2"; else _fail "$2"; fi; }

echo "A. substring collision — declared code-review, installed only xcode-review"
reset_mocks; export MOCK_CL_PLUGINS='[{"id":"xcode-review@m","scope":"user","enabled":true}]'
run "claude_plugin code-review@m"
has "install: code-review@m" "code-review treated as MISSING (would install), not falsely present"
has "drift"                  "xcode-review reported as drift"

echo "B. malformed JSON from plugin list"
reset_mocks; export MOCK_CL_PLUGINS='not json {{{'
run "claude_plugin foo@m"
has   "claude plugin list: unexpected JSON shape" "block skipped on malformed JSON"
hasnt "install: foo@m"                            "no spurious install attempted"
rc_is 1                                           "exit status 1"

echo "C. schema drift — valid JSON, wrong top-level shape"
reset_mocks; export MOCK_CL_PLUGINS='{"unexpected":"shape"}'
run "claude_plugin foo@m"
has   "unexpected JSON shape" "block skipped on schema drift"
rc_is 1                       "exit status 1"

echo "D. disabled plugin left as-is, not reinstalled"
reset_mocks; export MOCK_CL_PLUGINS='[{"id":"foo@m","scope":"user","enabled":false}]'
run "claude_plugin foo@m"
has   "disabled (left as-is): foo@m" "disabled reported"
hasnt "install: foo@m"               "not reinstalled"

echo "E. failed install sets status=1"
reset_mocks; export MOCK_CL_INSTALL_RC=1
run "claude_plugin foo@m"
has   "failed to install claude plugin: foo@m" "failure surfaced"
rc_is 1                                        "exit status 1"

echo "F. schema gap — empty stdout / {} / [{}] rejected (jq exit status alone misses these)"
reject_case() {  # reject_case <name> <json>
  reset_mocks; export MOCK_CL_PLUGINS="$2"
  run "claude_plugin foo@m"
  has   "unexpected JSON shape" "$1: block skipped"
  hasnt "install: foo@m"        "$1: no spurious install"
  rc_is 1                       "$1: exit 1"
}
reject_case "empty-stdout"          ''
reject_case "empty-object"          '{}'
reject_case "array-of-empty-object" '[{}]'

echo "G. codex marketplace — normalized exact match on the git source"
reset_mocks; export MOCK_CX_MKT='{"marketplaces":[{"name":"agent-skills","marketplaceSource":{"source":"https://github.com/addyosmani/agent-skills.git"}}]}'
run "codex_marketplace addyosmani/agent-skills"
has "codex marketplace present: addyosmani/agent-skills" "exact git source matches (present, no add)"

echo "G2. codex marketplace — a fork must NOT satisfy the declaration"
reset_mocks; export MOCK_CX_MKT='{"marketplaces":[{"name":"fork","marketplaceSource":{"source":"https://github.com/addyosmani/agent-skills-fork.git"}}]}'
run "codex_marketplace addyosmani/agent-skills"
has "codex marketplace add: addyosmani/agent-skills" "fork does not match → add attempted"

echo "H. codex plugin present + schema-drift rejection"
reset_mocks; export MOCK_CX_PLUGINS='{"installed":[{"pluginId":"agent-skills@agent-skills","enabled":true,"marketplaceName":"agent-skills"}]}'
run "codex_plugin agent-skills@agent-skills"
has "codex plugin present: agent-skills@agent-skills" "codex plugin present"
reset_mocks; export MOCK_CX_PLUGINS='{"installed":[{}]}'
run "codex_plugin foo@bar"
has   "codex plugin list: unexpected JSON shape" "codex [{}]-in-installed rejected"
rc_is 1                                          "codex schema drift exit 1"

echo "I. LIVE contract — the real state files and the real CLI surface"
# Everything above this line is mocked, so it agrees with itself no matter what Claude Code
# actually does. That is how `claude plugin list --json` stayed green in this suite long
# after the subcommand was removed, while the reconciler silently reconciled nothing.
# These assertions read the real files and the real `claude --help` output, so a schema or
# CLI change goes RED here. Absent tooling SKIPS loudly rather than passing.
_skip() { echo "  SKIP: $1"; }
LIVE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LIVE_INST="$LIVE_HOME/plugins/installed_plugins.json"
LIVE_MKT="$LIVE_HOME/plugins/known_marketplaces.json"

if [ -r "$LIVE_INST" ]; then
  ver=$(jq -r '.version // empty' "$LIVE_INST" 2>/dev/null)
  if [ "$ver" = "2" ]; then _pass "installed_plugins.json is schema version 2 (reader is pinned to it)"
  else _fail "installed_plugins.json schema version is '$ver', reader expects 2"; fi
  if jq -e '(.plugins | type) == "object"' "$LIVE_INST" >/dev/null 2>&1; then
    _pass "installed_plugins.json .plugins is an object keyed by plugin id"
  else _fail "installed_plugins.json .plugins is not an object"; fi
  if jq -e '[.plugins[][] | select(has("scope"))] | length > 0' "$LIVE_INST" >/dev/null 2>&1; then
    _pass "install records carry .scope (user-scope projection depends on it)"
  else _fail "install records have no .scope field"; fi
else
  _skip "installed_plugins.json absent — live schema unverified"
fi

if [ -r "$LIVE_MKT" ]; then
  if jq -e 'type == "object" and (to_entries | length > 0) and all(.[]; has("source"))' "$LIVE_MKT" >/dev/null 2>&1; then
    _pass "known_marketplaces.json is an object whose entries carry .source"
  else _fail "known_marketplaces.json shape changed"; fi
  if jq -e '[.[] | select((.source.repo? // "") != "")] | length > 0' "$LIVE_MKT" >/dev/null 2>&1; then
    _pass "at least one marketplace exposes .source.repo (the projection field)"
  else _fail "no marketplace exposes .source.repo"; fi
else
  _skip "known_marketplaces.json absent — live schema unverified"
fi

# The reconciler still SHELLS OUT for the mutating half. These are the only two CLI
# surfaces it depends on; `plugin list` is deliberately not among them any more.
if command -v claude >/dev/null 2>&1; then
  cl_help=$(claude plugin --help 2>&1)
  case "$cl_help" in
    *install*) _pass "claude plugin install still exists (used to add missing plugins)" ;;
    *)         _fail "claude plugin install is gone — reconciler cannot install" ;;
  esac
  case "$cl_help" in
    *marketplace*) _pass "claude plugin marketplace still exists" ;;
    *)             _fail "claude plugin marketplace is gone" ;;
  esac
  case "$(claude plugin marketplace --help 2>&1)" in
    *add*) _pass "claude plugin marketplace add still exists (used to add marketplaces)" ;;
    *)     _fail "claude plugin marketplace add is gone — reconciler cannot add marketplaces" ;;
  esac
else
  _skip "claude not on PATH — live CLI surface unverified"
fi

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
