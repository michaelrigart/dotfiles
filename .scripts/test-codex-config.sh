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
# Run: bash .scripts/test-codex-config.sh   (bash, sandboxed is fine)

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$SRC/dot_codex/modify_private_config.toml"
[ -f "$TPL" ] || { echo "missing template: $TPL" >&2; exit 1; }
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

echo "A. enforced feature flags win over whatever is on disk"
# The live file had js_repl removed and memories added by Codex itself; both must be
# pinned by us, not left to the tool.
emit '[features]
js_repl = true
memories = false
prevent_idle_sleep = false
'
has '^\s*js_repl = false'           "js_repl forced off even when the live file says true"
has '^\s*memories = true'           "memories forced on even when the live file says false"
has '^\s*prevent_idle_sleep = true' "prevent_idle_sleep forced on"

echo "B. js_repl is pinned, not dropped"
# Regression guard. An earlier revision unset the key on the grounds that it was
# obsolete; codex 0.149.1 still ships it, so unsetting it silently removed the guard
# and let an upstream default flip enable a JS REPL. Absent must never be acceptable.
emit ''
has '^\s*js_repl = false' "js_repl emitted even when absent from the input"

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

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
