#!/usr/bin/env bash
# Tests for the weekly research schedule (spec 2026-11-21-weekly-research): the LaunchAgent
# template and the .chezmoiignore rule that deploys it only on the machine named research_host
# in .chezmoidata/machines.toml. The wrapper it starts is tests/weekly-research.test.sh's.
# Nothing is applied or loaded; chezmoi only renders and lists from a scratch source.
#
#   ./tests/weekly-research-schedule.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$SRC/Library/LaunchAgents/be.netronix.weekly-research.plist.tmpl"
IGNORE="$SRC/.chezmoiignore"
DATA="$SRC/.chezmoidata/machines.toml"
for f in "$PLIST" "$IGNORE" "$DATA"; do
  [ -f "$f" ] || { echo "missing subject under test: $f" >&2; exit 2; }
done
command -v chezmoi >/dev/null 2>&1 || { echo "INCONCLUSIVE: chezmoi is not on PATH; install it (brew install chezmoi)" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }
has() { if grep -qF -- "$3" "$2"; then _pass "$1"; else _fail "$1" "missing: $3"; fi; }

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/weekly-research-schedule.XXXXXX")" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

echo "A. the LaunchAgent"
rendered="$ROOT/agent.plist"
# The decoy data home keeps a user's own chezmoi data out of the render, as the Codex plist case does.
mkdir -p "$ROOT/decoy/chezmoi/.chezmoidata"; echo '= not toml' > "$ROOT/decoy/chezmoi/.chezmoidata/broken.toml"
XDG_DATA_HOME="$ROOT/decoy" chezmoi execute-template --source "$SRC" --file "$PLIST" > "$rendered" 2>"$ROOT/tpl.err" \
  || _fail "the plist template renders" "$(head -c 200 "$ROOT/tpl.err")"
if plutil -lint "$rendered" >/dev/null 2>&1; then _pass "the rendered plist is valid"; else _fail "the rendered plist is valid" "$(plutil -lint "$rendered" 2>&1)"; fi
x() { plutil -extract "$1" raw -o - "$rendered" 2>&1; }
is "the label" "$(x Label)" "be.netronix.weekly-research"
is "it starts weekly-research from ~/.local/bin" "$(x ProgramArguments.0)" "$HOME/.local/bin/weekly-research"
is "and passes it no arguments" "$(x ProgramArguments)" 1
is "on Mondays" "$(x StartCalendarInterval.Weekday)" 1
is "at 07" "$(x StartCalendarInterval.Hour)" 7
is "at :30" "$(x StartCalendarInterval.Minute)" 30
if plutil -extract RunAtLoad raw -o - "$rendered" >/dev/null 2>&1; then _fail "it does not run at load" "RunAtLoad is set"; else _pass "it does not run at load"; fi
is "standard output goes nowhere" "$(x StandardOutPath)" /dev/null
is "and so does standard error" "$(x StandardErrorPath)" /dev/null
has "the header names the spec" "$PLIST" "docs/superpowers/specs/2026-11-21-weekly-research-design.md"
has "and the bootstrap command" "$PLIST" "launchctl bootstrap gui/\$(id -u)"
has "and the kickstart command" "$PLIST" "launchctl kickstart gui/\$(id -u)/be.netronix.weekly-research"
has "and the bootout command" "$PLIST" "launchctl bootout gui/\$(id -u)/be.netronix.weekly-research"

echo "B. the plist deploys only on the research host"
TARGET="Library/LaunchAgents/be.netronix.weekly-research.plist"
HOST="$(hostname -s)"
# scratch <name> <research_host>: a source holding only the ignore file, the data and the plist
scratch() {
  local d="$ROOT/$1"
  mkdir -p "$d/.chezmoidata" "$d/Library/LaunchAgents"
  cp "$IGNORE" "$d/.chezmoiignore"
  grep -v '^research_host' "$DATA" > "$d/.chezmoidata/machines.toml"
  printf 'research_host = "%s"\n' "$2" >> "$d/.chezmoidata/machines.toml"
  cp "$PLIST" "$d/Library/LaunchAgents/be.netronix.weekly-research.plist.tmpl"
  XDG_DATA_HOME="$ROOT/decoy" chezmoi --source "$d" ignored 2>&1
}
other="$(scratch other "not-$HOST")"
case "$(printf '%s\n' "$other" | grep -Fx -- "$TARGET")" in "$TARGET") _pass "another research_host ignores the plist" ;; *) _fail "another research_host ignores the plist" "$other" ;; esac
mine="$(scratch mine "$HOST")"
case "$(printf '%s\n' "$mine" | grep -Fx -- "$TARGET")" in "") _pass "this machine as research_host deploys the plist" ;; *) _fail "this machine as research_host deploys the plist" "$mine" ;; esac
is "and the plist is not ignored by anything else in the scratch source" "$(printf '%s\n' "$mine" | grep -c 'weekly-research')" 0
research_host="$(grep -E '^research_host *=' "$DATA" | head -1)"
is "machines.toml names the research host" "$research_host" 'research_host = "fenrir"'

printf '\n%d/%d passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
