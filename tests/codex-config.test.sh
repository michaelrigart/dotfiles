#!/usr/bin/env bash
# Feeds fixtures through dot_codex/modify_private_config.toml and asserts the emitted
# config. Unlike the Claude settings script this one is a chezmoi *template*, not a
# plain filter, so it is exercised with `chezmoi execute-template --init` and the
# fixture piped in as stdin.
#
# The split this pins: Codex writes this file at runtime (model, effort, plugins,
# marketplaces, project trust), so anything the template does NOT enforce must survive
# untouched, and anything it DOES enforce must win over whatever is on disk.
#
# Run: ./tests/codex-config.test.sh   (sandboxed is fine)

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$SRC/dot_codex/modify_private_config.toml"
HOOKS_TPL="$SRC/dot_codex/modify_private_hooks.json"
[ -f "$TPL" ] || { echo "missing template: $TPL" >&2; exit 1; }
[ -f "$HOOKS_TPL" ] || { echo "missing template: $HOOKS_TPL" >&2; exit 1; }
command -v chezmoi >/dev/null 2>&1 || { echo "chezmoi not on PATH" >&2; exit 1; }

pass=0; fail=0; OUT=""

_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; printf '    | got: %s\n' "$2"; fail=$((fail + 1)); }

# --with-stdin is what populates .chezmoi.stdin, the live file the modify_ template parses.
emit() { OUT=$(printf '%s' "$1" | chezmoi execute-template --with-stdin --file "$TPL" 2>&1); }

# has <regex> <label> — the emitted TOML must contain it
has() {
  if printf '%s' "$OUT" | grep -Eq "$1"; then _pass "$2"
  else _fail "$2" "$(printf '%s' "$OUT" | head -c 200)"; fi
}
hasnt() {
  if printf '%s' "$OUT" | grep -Eq "$1"; then _fail "$2" "$(printf '%s' "$OUT" | grep -E "$1" | head -2)"
  else _pass "$2"; fi
}

emit_hooks() {
  OUT=$(printf '%s' "$1" | chezmoi --config /dev/null --config-format toml \
    --source "$SRC" --destination "$HOME" execute-template --with-stdin --file "$HOOKS_TPL" 2>&1)
}

echo "A. enforced feature flags win over whatever is on disk"
# memories was added by Codex itself; it must be pinned by us, not left to the tool.
emit '[features]
js_repl = true
memories = false
prevent_idle_sleep = false
'
hasnt '^\s*js_repl'                 "js_repl deleted even when the live file sets it"
has '^\s*memories = true'           "memories forced on even when the live file says false"
has '^\s*prevent_idle_sleep = true' "prevent_idle_sleep forced on"
has '^\s*hooks = true'              "agent hooks forced on for the Herdr integration"

echo "A2. the shared app-server daemon stays off"
# Hooks run inside the daemon, which keeps the environment of whichever pane spawned
# it, so every Herdr session report lands on that one pane. See the template comment.
emit '[features]
daemon_auto_start = true
'
has '^\s*daemon_auto_start = false' "daemon_auto_start forced off even when the live file says true"
emit ''
has '^\s*daemon_auto_start = false' "daemon_auto_start emitted even when absent from the input"

echo "A2b. the in-TUI update prompt stays off (spec 2026-10-01 §4.1)"
emit 'check_for_update_on_startup = true
'
has '^\s*check_for_update_on_startup = false' "the update prompt is forced off over a live 'true'"
emit ''
has '^\s*check_for_update_on_startup = false' "and pinned off on an empty live file"

echo "A3. every TUI puts its thread id first in its title"
# The pane-map hook and xreview join a pane to its thread through the title. Codex
# truncates long titles, so thread-id must be FIRST or it is the part that gets cut.
emit 'tui.terminal_title = ["current-dir"]'
has '^\s*terminal_title = \["thread-id", "thread-title", "current-dir"\]' "terminal_title pinned with thread-id first"

echo "B. js_repl is deleted, not pinned"
# It was pinned off while Codex shipped it as a live flag (0.149.1). Codex 0.159 removed
# the flag. The template carries every key it does not name, so the old pin has to be
# DELETED from the live file; merely no longer setting it would keep it forever.
emit '[features]
js_repl = false
'
hasnt '^\s*js_repl' "a leftover js_repl pin is deleted from the live file"
emit ''
hasnt '^\s*js_repl' "js_repl is never emitted"

echo "C. model preferences are seeded, not enforced"
# /model, /effort and fast-mode changes must persist across an apply.
emit 'model = "gpt-5.9-custom"
model_reasoning_effort = "low"
service_tier = "flex"
plan_mode_reasoning_effort = "low"
'
has 'model = "gpt-5.9-custom"'      "runtime model kept"
has 'model_reasoning_effort = "low"' "runtime effort kept"
has 'service_tier = "flex"'          "runtime service_tier kept"
has 'plan_mode_reasoning_effort = "low"' "runtime plan-mode effort kept"

emit ''
has 'model = "gpt-5.6-sol"'          "model seeded when absent"
has 'service_tier = "fast"'          "service_tier seeded when absent"

echo "D. Codex-written state survives untouched"
# These are written by the tool at runtime and must never be reverted by an apply:
# plugin enablement, marketplace revisions, per-project trust, and the hook trust
# hashes that gate third-party session_start hooks.
emit '[plugins."agent-skills@agent-skills"]
enabled = true

[marketplaces.agent-skills]
source = "https://github.com/addyosmani/agent-skills.git"
source_type = "git"

[projects."/Users/michael/Code/Netronix/curato"]
trust_level = "trusted"

[hooks.state."agent-skills@agent-skills:hooks/hooks.json:session_start:0:0"]
trusted_hash = "sha256:deadbeef"
'
has 'agent-skills@agent-skills'      "plugin enablement carried through"
has 'addyosmani/agent-skills'        "marketplace source carried through"
has 'trust_level = "trusted"'        "per-project trust carried through"
has 'sha256:deadbeef'                "hook trusted_hash carried through"

echo "E. enforced UI settings"
emit 'tui.theme = "gruvbox"'
has 'theme = "tokyo-night"'          "theme forced to tokyo-night"
has 'open_transcript = "ctrl-t"'     "transcript keybinding enforced"
has 'interrupt_turn = "f12"'         "interrupt keybinding enforced"
has 'notification_condition = "unfocused"' "notification condition enforced"

echo "F. notify path is derived from \$HOME, never hardcoded"
emit ''
has "$HOME/.codex/computer-use"      "notify hook points at this machine's home"
hasnt '/Users/[a-z]+/\.codex/computer-use.*/Users/' "no doubled or foreign home path"

echo "G. output is valid TOML"
emit ''
if printf '%s' "$OUT" | python3 -c 'import sys,tomllib; tomllib.loads(sys.stdin.read())' 2>/dev/null; then
  _pass "emitted config parses as TOML"
else
  _fail "emitted config parses as TOML" "$(printf '%s' "$OUT" | head -c 200)"
fi

echo "H. hooks.json renders the observed Herdr registration"
MAPCMD="/usr/bin/python3 '$HOME/.codex/herdr-codex-pane-map.py'"
emit_hooks '{}'
if printf '%s' "$OUT" | jq -e --arg cmd "bash '$HOME/.codex/herdr-agent-state.sh' session" --arg map "$MAPCMD" '
  (keys == ["hooks"])
  and (.hooks | keys == ["SessionStart"])
  and (.hooks.SessionStart | length == 2)
  and (.hooks.SessionStart[0] | keys == ["hooks"])
  and (.hooks.SessionStart[1] | keys == ["hooks"])
  and (.hooks.SessionStart[0].hooks == [{type: "command", command: $cmd, timeout: 10}])
  and (.hooks.SessionStart[1].hooks == [{type: "command", command: $map, timeout: 10}])
' >/dev/null 2>&1; then
  _pass "fresh hooks.json has herdr's entry, then the pane-map entry"
else
  _fail "fresh hooks.json has herdr's entry, then the pane-map entry" "$(printf '%s' "$OUT" | head -c 300)"
fi

echo "I. hooks.json preserves unrelated state and stays idempotent"
fixture='{"other":42,"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/bin/true"}]},{"hooks":[{"type":"command","command":"bash '\''/old/.codex/herdr-agent-state.sh'\'' session","timeout":5}]},{"hooks":[{"type":"command","command":"python3 '\''/old/.codex/herdr-codex-pane-map.py'\''"}]},{"hooks":[{"type":"command","command":"/bin/keep-me"},{"type":"command","command":"bash '\''/old/.codex/herdr-agent-state.sh'\'' session","timeout":5}]}],"Stop":[{"hooks":[{"type":"command","command":"/bin/false"}]}]}}'
emit_hooks "$fixture"
first="$OUT"
if printf '%s' "$first" | jq -e --arg cmd "bash '$HOME/.codex/herdr-agent-state.sh' session" --arg map "$MAPCMD" '
  .other == 42
  and (.hooks.Stop[0].hooks[0].command == "/bin/false")
  and ([.hooks.SessionStart[] | select(any(.hooks[]?; .command == "/bin/true"))] | length == 1)
  and ([.hooks.SessionStart[]?.hooks[]? | select((.command // "") | contains("herdr-agent-state.sh"))] == [{type: "command", command: $cmd, timeout: 10}])
  and ([.hooks.SessionStart[]?.hooks[]? | select((.command // "") | contains("herdr-codex-pane-map.py"))] == [{type: "command", command: $map, timeout: 10}])
  and ( ([.hooks.SessionStart[] | any(.hooks[]?; (.command // "") | contains("herdr-agent-state.sh"))] | index(true))
        < ([.hooks.SessionStart[] | any(.hooks[]?; (.command // "") | contains("herdr-codex-pane-map.py"))] | index(true)) )
  and ([.hooks.SessionStart[] | select(any(.hooks[]?; .command == "/bin/keep-me")) | .hooks]
       == [[{type: "command", command: "/bin/keep-me"}]])
' >/dev/null 2>&1; then
  _pass "unrelated hooks survive, each stale entry is replaced exactly once, herdr before the pane-map"
else
  _fail "unrelated hooks survive, each stale entry is replaced exactly once, herdr before the pane-map" "$(printf '%s' "$first" | head -c 300)"
fi

emit_hooks "$first"
second="$OUT"
if jq -en --argjson first "$first" --argjson second "$second" '$first == $second' >/dev/null; then
  _pass "re-rendering hooks.json is semantically idempotent"
else
  _fail "re-rendering hooks.json is semantically idempotent" "second render differs"
fi

if printf '{broken' | chezmoi --config /dev/null --config-format toml \
    --source "$SRC" --destination "$HOME" execute-template --with-stdin --file "$HOOKS_TPL" \
    >/dev/null 2>&1; then
  _fail "invalid hooks.json is rejected" "template accepted malformed JSON"
else
  _pass "invalid hooks.json is rejected"
fi

echo "J. every Codex integration target is managed by chezmoi"
managed=$(chezmoi --source "$SRC" managed 2>/dev/null)
for target in .codex/config.toml .codex/herdr-agent-state.sh .codex/hooks.json .codex/herdr-codex-pane-map.py; do
  case "$managed" in
    *"$target"*) _pass "$target is chezmoi-managed" ;;
    *) _fail "$target is chezmoi-managed" "not in \`chezmoi managed\`" ;;
  esac
done

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
