#!/usr/bin/env bash
# Mocked test for reconcile-agents.sh: stubs claude/codex on PATH with crafted JSON and
# asserts the review-fix behaviour — exact field matching, explicit JSON-schema validation
# (empty stdout / {} / [{}] rejected), disabled/failed-install handling, and Codex source
# normalization + reconciliation. Run: bash .scripts/test-reconcile-agents.sh
set -u
RECON="$(cd "$(dirname "$0")" && pwd)/reconcile-agents.sh"
BIN=$(mktemp -d); CFG=$(mktemp -d); mkdir -p "$CFG/agents"
trap 'rm -rf "$BIN" "$CFG"' EXIT   # clean temp dirs even on interrupt
pass=0; fail=0; OUT=""; RC=0

cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "plugin marketplace list --json") printf '%s' "$MOCK_CL_MKT" ;;
  "plugin list --json")             printf '%s' "$MOCK_CL_PLUGINS" ;;
  "plugin install"*)                exit "$MOCK_CL_INSTALL_RC" ;;
  "plugin marketplace add"*)        exit 0 ;;
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
  OUT=$(PATH="$BIN:$PATH" XDG_CONFIG_HOME="$CFG" /bin/bash "$RECON" 2>&1); RC=$?
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

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
