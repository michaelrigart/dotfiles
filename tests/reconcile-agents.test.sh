#!/usr/bin/env bash
# Mocked test for reconcile-agents.sh: stubs claude/codex on PATH with crafted JSON and
# asserts the review-fix behaviour — exact field matching, explicit JSON-schema validation
# (empty stdout / {} / [{}] rejected), disabled/failed-install handling, and Codex source
# normalization + reconciliation. Run: ./tests/reconcile-agents.test.sh
# test-requires: unsandboxed  # writes a temp XDG config dir; sandboxed it reports ~18 false failures
set -u
RECON="$(cd "$(dirname "$0")/.." && pwd)/.scripts/reconcile-agents.sh"
[ -f "$RECON" ] || { echo "missing script under test: $RECON" >&2; exit 2; }
BIN=$(mktemp -d); CFG=$(mktemp -d); CALLS="$BIN/calls.log"
mkdir -p "$CFG/agents"
trap 'rm -rf "$BIN" "$CFG"' EXIT   # clean temp dirs even on interrupt
pass=0; fail=0; OUT=""; RC=0

# Both CLIs are stubbed on PATH. The claude stub serves `plugin list --json` and
# `plugin marketplace list --json` from MOCK_CL_PLUGINS / MOCK_CL_MKT (exit codes from
# MOCK_CL_PLUGINS_RC / MOCK_CL_MKT_RC) and appends every add/install call to $CALLS, so
# "no installs" is asserted on what was actually invoked, not just on log text.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "plugin marketplace list --json") printf '%s' "$MOCK_CL_MKT"; exit "$MOCK_CL_MKT_RC" ;;
  "plugin list --json")             printf '%s' "$MOCK_CL_PLUGINS"; exit "$MOCK_CL_PLUGINS_RC" ;;
  "plugin install"*)                echo "$*" >> "$CALLS"; exit "$MOCK_CL_INSTALL_RC" ;;
  "plugin marketplace add"*)        echo "$*" >> "$CALLS"; exit 0 ;;
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
  export MOCK_CL_MKT_RC=0 MOCK_CL_PLUGINS_RC=0
  export MOCK_CX_MKT='{"marketplaces":[]}' MOCK_CX_PLUGINS='{"installed":[]}'
}
run() {  # run <manifest> (\n allowed) ; sets $OUT and $RC; resets the call log
  printf '%b\n' "$1" > "$CFG/agents/plugins.conf"
  : > "$CALLS"
  OUT=$(CALLS="$CALLS" PATH="$BIN:$PATH" XDG_CONFIG_HOME="$CFG" /bin/bash "$RECON" 2>&1); RC=$?
}
_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; printf '%s\n' "$OUT" | sed 's/^/    | /'; fail=$((fail + 1)); }
# Live assertions (section I) do not run the reconciler, so $OUT holds unrelated output
# from the last mocked scenario — dumping it there misdirects whoever is debugging.
_fail_live() { echo "  FAIL: $1"; fail=$((fail + 1)); }
has()   { case "$OUT" in *"$1"*) _pass "$2" ;; *) _fail "$2" ;; esac; }
hasnt() { case "$OUT" in *"$1"*) _fail "$2" ;; *) _pass "$2" ;; esac; }
# called/not_called look at the add/install calls the claude stub recorded
called()     { if grep -qF -- "$1" "$CALLS"; then _pass "$2"; else _fail "$2"; fi; }
not_called() { if grep -qF -- "$1" "$CALLS"; then _fail "$2"; else _pass "$2"; fi; }
rc_is() { if [ "$RC" -eq "$1" ]; then _pass "$2"; else _fail "$2"; fi; }

echo "A. substring collision — declared code-review, installed only xcode-review"
reset_mocks; export MOCK_CL_PLUGINS='[{"id":"xcode-review@m","scope":"user","enabled":true}]'
run "claude_plugin code-review@m"
has "install: code-review@m" "code-review treated as MISSING (would install), not falsely present"
has "drift"                  "xcode-review reported as drift"
called "plugin install code-review@m --scope user" "install reached the CLI"

echo "B. malformed JSON from plugin list"
reset_mocks; export MOCK_CL_PLUGINS='not json {{{'
run "claude_plugin foo@m"
has   "claude plugin list: unexpected JSON shape" "block skipped on malformed JSON"
hasnt "install: foo@m"                            "no spurious install attempted"
not_called "plugin install"                       "no install call reached the CLI"
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
not_called "plugin install"          "no install call reached the CLI"

echo "E. failed install sets status=1"
reset_mocks; export MOCK_CL_INSTALL_RC=1
run "claude_plugin foo@m"
has   "failed to install claude plugin: foo@m" "failure surfaced"
rc_is 1                                        "exit status 1"
called "plugin install foo@m --scope user"     "install was attempted at user scope"

echo "F. schema gap — empty stdout / {} / [{}] rejected (jq exit status alone misses these)"
reject_case() {  # reject_case <name> <json>
  reset_mocks; export MOCK_CL_PLUGINS="$2"
  run "claude_plugin foo@m"
  has   "unexpected JSON shape" "$1: block skipped"
  hasnt "install: foo@m"        "$1: no spurious install"
  not_called "plugin install"   "$1: no install call reached the CLI"
  rc_is 1                       "$1: exit 1"
}
reject_case "empty-stdout"          ''
reject_case "empty-object"          '{}'
reject_case "array-of-empty-object" '[{}]'
reject_case "scope-null"            '[{"id":"foo@m","scope":null,"enabled":false}]'
reject_case "enabled-string"        '[{"id":"foo@m","scope":"user","enabled":"yes"}]'
reject_case "non-object-element"    '["foo@m"]'

echo "F1. marketplace .repo must be a string when present; null counts as absent"
reset_mocks; export MOCK_CL_MKT='[{"name":"m","source":"github","repo":42}]'
run "claude_marketplace owner/repo"
has   "claude marketplace list: unexpected JSON shape" "repo:42 rejected"
not_called "marketplace add"                           "repo:42: nothing added"
rc_is 1                                                "repo:42: exit 1"
reset_mocks; export MOCK_CL_MKT='[{"name":"m","source":"git","repo":null}]'
run "# nothing declared"
hasnt "unexpected JSON shape"        "repo:null tolerated"
not_called "marketplace add"         "repo:null with nothing declared: nothing added"
rc_is 0                              "repo:null: exit 0"
run "claude_marketplace owner/repo"
called "marketplace add owner/repo"  "repo:null counts as absent: a declared marketplace is still added"

echo "F2. a failing or garbage CLI response is never read as none installed"
reset_mocks; export MOCK_CL_PLUGINS='[]' MOCK_CL_PLUGINS_RC=1
run "claude_plugin foo@m"
has   "claude plugin list failed" "plugin list exit 1 surfaced (even with a valid-looking body)"
not_called "plugin install"       "plugin list exit 1: nothing installed"
rc_is 1                           "plugin list exit 1: exit status 1"
reset_mocks; export MOCK_CL_MKT='<html>oops</html>'
run "claude_marketplace owner/repo"
has   "claude marketplace list: unexpected JSON shape" "garbage marketplace list rejected"
not_called "marketplace add"                           "garbage marketplace list: nothing added"
rc_is 1                                                "garbage marketplace list: exit status 1"
reset_mocks; export MOCK_CL_MKT='[]' MOCK_CL_MKT_RC=1
run "claude_marketplace owner/repo"
has   "claude plugin marketplace list failed" "marketplace list exit 1 surfaced"
not_called "marketplace add"                  "marketplace list exit 1: nothing added"
rc_is 1                                       "marketplace list exit 1: exit status 1"
reset_mocks; export MOCK_CL_MKT='{"name":"x"}'
run "claude_marketplace owner/repo"
has   "claude marketplace list: unexpected JSON shape" "marketplace object (not array) rejected"
not_called "marketplace add"                           "marketplace object: nothing added"

echo "F3. marketplaces — present ones are not re-added, missing ones are, non-GitHub entries tolerated"
reset_mocks; export MOCK_CL_MKT='[{"name":"a","source":"github","repo":"owner/have"},{"name":"b","source":"git","url":"https://example.com/x.git"}]'
run "claude_marketplace owner/have\nclaude_marketplace owner/missing"
has   "marketplace present: owner/have"  "installed marketplace reported present"
not_called "marketplace add owner/have"  "present marketplace not re-added"
called "marketplace add owner/missing"   "missing marketplace added"
rc_is 0                                  "entry without .repo does not fail the run"

echo "F4. marketplaces are added before plugins are installed"
reset_mocks
run "claude_marketplace owner/repo\nclaude_plugin foo@mkt"
if [ "$(sed -n 1p "$CALLS")" = "plugin marketplace add owner/repo" ] && [ "$(sed -n 2p "$CALLS")" = "plugin install foo@mkt --scope user" ]; then
  _pass "marketplace add precedes plugin install"
else _fail "marketplace add precedes plugin install"; fi

echo "F5. present plugin is not reinstalled; missing one is"
reset_mocks; export MOCK_CL_PLUGINS='[{"id":"have@m","version":"1","scope":"user","enabled":true,"projectEnabled":false}]'
run "claude_plugin have@m\nclaude_plugin missing@m"
has   "plugin present: have@m"          "installed plugin reported present"
not_called "plugin install have@m"      "present plugin not reinstalled"
called "plugin install missing@m"       "missing plugin installed"
rc_is 0                                 "exit status 0"

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

echo "I. LIVE contract — the real CLI surface"
# Everything above this line is mocked, so it agrees with itself no matter what Claude Code
# actually does. That is how `claude plugin list --json` stayed green in this suite long
# after the subcommand was removed, while the reconciler silently reconciled nothing.
# These assertions call the real `claude` (read-only list/help commands), so a CLI or
# schema change goes RED here. Absent tooling SKIPS loudly rather than passing.
_skip() { echo "  SKIP: $1"; }
if command -v claude >/dev/null 2>&1; then
  if live=$(claude plugin list --json 2>/dev/null) \
     && printf '%s' "$live" | jq -e 'type == "array" and all(.[]; has("id") and has("scope") and has("enabled"))' >/dev/null 2>&1; then
    _pass "claude plugin list --json is an array of {id, scope, enabled} (the reconciler's schema)"
  else _fail_live "claude plugin list --json failed or changed shape"; fi
  if live=$(claude plugin marketplace list --json 2>/dev/null) \
     && printf '%s' "$live" | jq -e 'type == "array" and all(.[]; type == "object" and has("name"))' >/dev/null 2>&1; then
    _pass "claude plugin marketplace list --json is an array of named objects (the reconciler's schema)"
  else _fail_live "claude plugin marketplace list --json failed or changed shape"; fi
  cl_help=$(claude plugin --help 2>&1)
  case "$cl_help" in
    *install*) _pass "claude plugin install still exists (used to add missing plugins)" ;;
    *)         _fail_live "claude plugin install is gone — reconciler cannot install" ;;
  esac
  case "$cl_help" in
    *marketplace*) _pass "claude plugin marketplace still exists" ;;
    *)             _fail_live "claude plugin marketplace is gone" ;;
  esac
  case "$(claude plugin marketplace --help 2>&1)" in
    *add*) _pass "claude plugin marketplace add still exists (used to add marketplaces)" ;;
    *)     _fail_live "claude plugin marketplace add is gone — reconciler cannot add marketplaces" ;;
  esac
else
  _skip "claude not on PATH — live CLI surface unverified"
fi

echo "J. fresh machine — an empty [] from both queries means nothing installed"
reset_mocks
run "claude_marketplace owner/repo\nclaude_plugin foo@mkt"
has   "marketplace add: owner/repo" "a declared marketplace is added on a fresh machine"
has   "install: foo@mkt"            "a declared plugin is installed on a fresh machine"
called "plugin marketplace add owner/repo"   "marketplace add reached the CLI"
called "plugin install foo@mkt --scope user" "plugin install reached the CLI"
rc_is 0                             "a fresh machine reconciles cleanly"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
