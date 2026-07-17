#!/usr/bin/env bash
# Mocked test for reconcile-agents.sh: stubs `claude`/`codex` on PATH with crafted JSON
# and asserts the review-fix behaviour (exact matching, JSON/schema validation) plus
# disabled-plugin and failed-install handling. Run: bash .scripts/test-reconcile-agents.sh
set -u
RECON="$(cd "$(dirname "$0")" && pwd)/reconcile-agents.sh"
BIN=$(mktemp -d); CFG=$(mktemp -d); mkdir -p "$CFG/agents"
pass=0; fail=0; OUT=""; RC=0

# --- stub CLIs: behaviour driven by env vars set per-scenario -----------------
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "plugin marketplace list --json") printf '%s' "${MOCK_CL_MKT:-[]}" ;;
  "plugin list --json")             printf '%s' "${MOCK_CL_PLUGINS:-[]}" ;;
  "plugin install"*)                echo "install $*" >&2; exit "${MOCK_CL_INSTALL_RC:-0}" ;;
  "plugin marketplace add"*)        exit 0 ;;
  *) exit 0 ;;
esac
STUB
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "plugin marketplace list --json") printf '%s' '{"marketplaces":[]}' ;;
  "plugin list --json")             printf '%s' '{"installed":[]}' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/claude" "$BIN/codex"

run() {  # run <manifest-line> ; sets $OUT and $RC
  printf '%s\n' "$1" > "$CFG/agents/plugins.conf"
  OUT=$(PATH="$BIN:$PATH" XDG_CONFIG_HOME="$CFG" /bin/bash "$RECON" 2>&1); RC=$?
}
_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; printf '%s\n' "$OUT" | sed 's/^/    | /'; fail=$((fail + 1)); }
has()   { case "$OUT" in *"$1"*) _pass "$2" ;; *) _fail "$2" ;; esac; }
hasnt() { case "$OUT" in *"$1"*) _fail "$2" ;; *) _pass "$2" ;; esac; }
rc_is() { if [ "$RC" -eq "$1" ]; then _pass "$2"; else _fail "$2"; fi; }

echo "A. substring collision — declared code-review, installed only xcode-review (finding 2)"
export MOCK_CL_MKT='[]'
export MOCK_CL_PLUGINS='[{"id":"xcode-review@m","scope":"user","enabled":true}]'
run "claude_plugin code-review@m"
has "install: code-review@m" "code-review treated as MISSING (would install), not falsely present"
has "drift"                  "xcode-review reported as drift"

echo "B. malformed JSON from plugin list (finding 1)"
export MOCK_CL_PLUGINS='not json {{{'
run "claude_plugin foo@m"
has   "claude plugin list: unexpected JSON shape" "block skipped on malformed JSON"
hasnt "install: foo@m"                            "no spurious install attempted"
rc_is 1                                           "exit status 1"

echo "C. schema drift — valid JSON, wrong shape (finding 1)"
export MOCK_CL_PLUGINS='{"unexpected":"shape"}'
run "claude_plugin foo@m"
has   "unexpected JSON shape" "block skipped on schema drift"
rc_is 1                       "exit status 1"

echo "D. disabled plugin left as-is, not reinstalled"
export MOCK_CL_PLUGINS='[{"id":"foo@m","scope":"user","enabled":false}]'
run "claude_plugin foo@m"
has   "disabled (left as-is): foo@m" "disabled reported"
hasnt "install: foo@m"               "not reinstalled"

echo "E. failed install sets status=1"
export MOCK_CL_PLUGINS='[]'; export MOCK_CL_INSTALL_RC=1
run "claude_plugin foo@m"
has   "failed to install claude plugin: foo@m" "failure surfaced"
rc_is 1                                        "exit status 1"
unset MOCK_CL_INSTALL_RC

echo; echo "RESULT: $pass passed, $fail failed"
rm -rf "$BIN" "$CFG"
[ "$fail" -eq 0 ]
