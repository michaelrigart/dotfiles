#!/usr/bin/env bash
# Tests dot_config/herdr/config.toml — the palette, chrome and row layout.
#
# Herdr paints with tokens it does not document, and an unknown key makes it reject the
# whole file, so two things are pinned: `herdr config check` accepts the file (and is shown
# to reject a broken copy, so a green check means something), and the exact lines this
# config relies on are present. There is no TOML parser in /usr/bin/python3's stdlib, so
# the cases read sections with awk.
#
# Run: ./tests/herdr-config.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$ROOT/dot_config/herdr/config.toml"

pass=0; fail=0
_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; fail=$((fail + 1)); }
check() { if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 (got '$1', want '$2')"; fi; }

if [ ! -r "$CONF" ]; then
  echo "FATAL: $CONF not found — every assertion below would pass vacuously."
  exit 2
fi
if ! command -v herdr >/dev/null 2>&1; then
  echo "FATAL: herdr is not on PATH; cannot run 'herdr config check'."
  exit 2
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/herdr-config.XXXXXX")"; trap 'rm -rf "$T"' EXIT

# section <table> — the lines of one table, header excluded, up to the next table header.
section() {
  awk -v h="[$1]" '
    /^\[/ { on = ($0 == h); next }
    on && $0 !~ /^[[:space:]]*#/ { print }
  ' "$CONF"
}
flat() { tr '\n' ' ' | tr -s ' '; }

# in_order <string> <needle>… — succeeds when every needle appears, each after the last.
in_order() {
  local s="$1" rest; shift
  for n in "$@"; do
    rest="${s#*"$n"}"
    [ "$rest" = "$s" ] && return 1
    s="$rest"
  done
  return 0
}

echo "config check"
out="$(HERDR_CONFIG_PATH="$CONF" herdr config check 2>&1)"; rc=$?
check "$rc" "0" "herdr config check exits 0"
case "$out" in *"config: ok"*) _pass "herdr config check prints config: ok";;
  *) _fail "herdr config check prints config: ok (got: $out)";; esac

cp "$CONF" "$T/broken.toml"
printf '\n[ui]\nno_such_key_here = 1\n' >> "$T/broken.toml"
HERDR_CONFIG_PATH="$T/broken.toml" herdr config check >/dev/null 2>&1; rc=$?
check "$rc" "1" "a copy with an unknown [ui] key fails the check"

echo "[theme.custom]"
THEME="$(section theme.custom)"
for kv in 'accent=#7aa2f7' 'panel_bg=reset' 'sidebar_bg=#16161e' 'active_row_bg=#292e42' \
  'selection_bg=#283457' 'surface0=#292e42' 'surface1=#3b4261' 'surface_dim=#3b4261' \
  'overlay0=#565f89' 'overlay1=#737aa2' 'text=#c0caf5' 'subtext0=#a9b1d6' 'mauve=#bb9af7' \
  'green=#9ece6a' 'yellow=#e0af68' 'red=#f7768e' 'blue=#7aa2f7' 'teal=#73daca' 'peach=#ff9e64'; do
  k="${kv%%=*}"; v="${kv#*=}"
  check "$(printf '%s\n' "$THEME" | grep -cE "^$k = \"")" "1" "$k is set once"
  got="$(printf '%s\n' "$THEME" | sed -n "s/^$k = \"\(.*\)\".*/\1/p")"
  check "$got" "$v" "$k = $v"
done

echo "[ui]"
UI="$(section ui)"
check "$(printf '%s\n' "$UI" | grep -c '^show_agent_labels_on_pane_borders = true$')" "1" "pane borders carry the agent label"
check "$(printf '%s\n' "$UI" | grep -c '^window_title = "{workspace} · {tab}"$')" "1" "window title names workspace and tab"
check "$(printf '%s\n' "$UI" | grep -c '^tab_bar_right_separator = "  │  "$')" "1" "tab bar right separator"
TBR="$(printf '%s\n' "$UI" | flat)"
if in_order "$TBR" 'tab_bar_right = [' '~/.config/herdr/usage.sh' '{ type = "zoom" }' '{ type = "datetime", format = "%H:%M" }'; then
  _pass "tab_bar_right lists usage command, zoom, datetime in order"
else _fail "tab_bar_right lists usage command, zoom, datetime in order (got: $TBR)"; fi
if in_order "$TBR" 'type = "command"' 'interval_seconds = 60' 'timeout_seconds = 5'; then
  _pass "the usage entry is a command with a 60 s interval and 5 s timeout"
else _fail "the usage entry is a command with a 60 s interval and 5 s timeout (got: $TBR)"; fi

echo "agent rows"
AGENTS="$(section ui.sidebar.agents | flat)"
if in_order "$AGENTS" 'token = "agent"' 'token = "$spin"' '"state_text"'; then
  _pass "agents rows: \$spin follows agent, state_text follows \$spin"
else _fail "agents rows: \$spin follows agent, state_text follows \$spin (got: $AGENTS)"; fi
CODEX="$(section ui.sidebar.agents.rows_by_agent | flat)"
if in_order "$CODEX" 'token = "agent"' 'token = "$spin"' '"state_text"'; then
  _pass "codex override: \$spin follows agent, state_text follows \$spin"
else _fail "codex override: \$spin follows agent, state_text follows \$spin (got: $CODEX)"; fi
case "$AGENTS" in *terminal_title_stripped*) _pass "agents rows keep the dim title row";;
  *) _fail "agents rows keep the dim title row";; esac
case "$CODEX" in *terminal_title_stripped*) _fail "codex override keeps only row 1";;
  *) _pass "codex override keeps only row 1";; esac

echo "space rows"
SPACES="$(section ui.sidebar.spaces | flat)"
if in_order "$SPACES" '$active' '$review' '$merged' '$ci_ok' '$ci_fail' '$ci_run' 'token = "branch"'; then
  _pass "row 2: \$ci_* follow the phase tokens and precede branch"
else _fail "row 2: \$ci_* follow the phase tokens and precede branch (got: $SPACES)"; fi

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
