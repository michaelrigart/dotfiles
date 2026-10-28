#!/usr/bin/env bash
# Tests for the functions reload hook in dot_zshrc: an interactive shell re-reads
# ~/.config/zsh/functions when its mtime changes (spec 2026-10-28, section 1).
#
# Each case starts a fresh `env -i /bin/zsh -f` that sources the SOURCE dot_zshrc with every
# file it sources stubbed in a temp HOME (whose name holds a space), then a functions
# fixture. The script asserts the registration, removes it, and calls the hook directly:
# zsh 5.9 runs preexec hooks before each line of a non-interactive script too, which would
# reload between the test's own lines. mtimes are set with `touch -t`, never by waiting.
#
# Split from zshrc.test.sh, which needs a pty, so this one runs sandboxed.
#
#   ./tests/zshrc-reload.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ZSHRC="$SRC/dot_zshrc"
FUNCS="$SRC/dot_config/zsh/functions"
[ -f "$ZSHRC" ] || { echo "missing script under test: $ZSHRC" >&2; exit 2; }
[ -f "$FUNCS" ] || { echo "missing functions file: $FUNCS" >&2; exit 2; }
[ -x /bin/zsh ] || { echo "no /bin/zsh" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/zshrcreload.XXXXXX")"
trap 'chmod -R u+rw "$T" 2>/dev/null; rm -rf "$T"' EXIT
HOMEDIR="$T/ho me"
FN="$HOMEDIR/.config/zsh/functions"
mkdir -p "$HOMEDIR/.config/zsh" "$T/omz" "$T/brew/share/zsh-syntax-highlighting"
for f in zshenv config aliases; do : > "$HOMEDIR/.config/zsh/$f"; done
: > "$T/omz/oh-my-zsh.sh"
: > "$T/brew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

RELOADED='zsh: reloaded ~/.config/zsh/functions'
FAILED='zsh: cannot reload ~/.config/zsh/functions; keeping the old functions'
V1='f() { print v1 }'

# The prelude: source dot_zshrc against the fixture, record the registration, remove it, and
# define the helpers the case bodies use. `call` runs the hook in this shell, stdout and
# stderr to files; `show` prints what the last call wrote and what `f` now prints.
cat > "$T/prelude.zsh" <<'ZSH'
autoload -Uz add-zsh-hook
FN=$HOME/.config/zsh/functions
T1=202601010100.00; T2=202601010200.00; T3=202601010300.00
source $DOTZSHRC
REG_PRE=${preexec_functions[(r)_zshrc_reload_functions]}
REG_PRECMD=${precmd_functions[(r)_zshrc_reload_functions]}
STAT_KIND=$(whence -w stat)
add-zsh-hook -d preexec _zshrc_reload_functions
put() { print -r -- "f() { print $1 }" > $FN; touch -t $2 $FN }
call() { _zshrc_reload_functions >$TT/out 2>$TT/err; CALL_OUT=$(<$TT/out); CALL_ERR=$(<$TT/err) }
show() { print -r -- "out=[$CALL_OUT] err=[$CALL_ERR] f=[$(f)]" }
ZSH

# run <fixture text> <case body> -> the case's stdout (the script's own stderr is dropped)
run() {
  chmod 644 "$FN" 2>/dev/null; rm -f "$FN" "$FN.away"
  printf '%s\n' "$1" > "$FN"; touch -t 202601010000.00 "$FN"
  { cat "$T/prelude.zsh"; printf '%s\n' "$2"; } > "$T/case.zsh"
  env -i HOME="$HOMEDIR" ZSH="$T/omz" HOMEBREW_PREFIX="$T/brew" PATH=/usr/bin:/bin \
    DOTZSHRC="$ZSHRC" TT="$T" /bin/zsh -f "$T/case.zsh" 2>"$T/case.err"
  local rc=$?
  cat "$T/case.err" >> "$T/all.err"
  return $rc
}
# line_n <n> <text>: line n of text
line_n() { printf '%s\n' "$2" | sed -n "${1}p"; }
want() { printf 'out=[%s] err=[%s] f=[%s]' "$1" "$2" "$3"; }

# Z1: registered in preexec, not precmd; `stat` stays a command
out="$(run "$V1" 'print -r -- "pre=[$REG_PRE] precmd=[$REG_PRECMD] stat=[$STAT_KIND]"')"
is "Z1 the hook is in preexec_functions" "$(line_n 1 "$out" | sed -n 's/^\(pre=\[[^]]*\]\).*/\1/p')" 'pre=[_zshrc_reload_functions]'
is "Z1 and not in precmd_functions" "$(line_n 1 "$out" | sed -n 's/.*\(precmd=\[[^]]*\]\).*/\1/p')" 'precmd=[]'
is "Z1 stat is no builtin" "$(line_n 1 "$out" | sed -n 's/.*\(stat=\[[^]]*\]\)$/\1/p')" 'stat=[stat: command]'

# Z2: unchanged file, nothing printed and nothing re-sourced
out="$(run $'(( ++LOADS ))\n'"$V1" 'L0=$LOADS; call; print -r -- "out=[$CALL_OUT] err=[$CALL_ERR] loads=$L0,$LOADS"')"
is "Z2 an unchanged file is silent and not re-sourced" "$out" 'out=[] err=[] loads=1,1'

# Z3: new body, later mtime
out="$(run "$V1" 'put v2 $T1; call; show')"
is "Z3 a changed file loads the new function, stderr is the reload line" "$out" "$(want '' "$RELOADED" v2)"

# Z4: an earlier mtime than the recorded one reloads too
out="$(run "$V1" 'put v2 201912312359.00; call; show')"
is "Z4 an earlier mtime reloads" "$out" "$(want '' "$RELOADED" v2)"

# Z5: unclosed brace keeps the old function; a second call is silent; a fix reloads
out="$(run "$V1" "print -r -- 'f() { print BAD' > \$FN; touch -t \$T1 \$FN; call; show; call; show; put v3 \$T2; call; show")"
is "Z5 a syntax error keeps the old f with one failure line" "$(line_n 1 "$out")" "$(want '' "$FAILED" v1)"
is "Z5 a second call is silent" "$(line_n 2 "$out")" "$(want '' '' v1)"
is "Z5 a fixed file with a new mtime reloads" "$(line_n 3 "$out")" "$(want '' "$RELOADED" v3)"

# Z6: unreadable file with a new mtime; chmod alone does not retry
out="$(run "$V1" 'put v2 $T1; chmod 000 $FN; call; show; chmod 644 $FN; call; show')"
is "Z6 mode 000 keeps the old f with one failure line" "$(line_n 1 "$out")" "$(want '' "$FAILED" v1)"
is "Z6 chmod alone, mtime unchanged, reloads nothing" "$(line_n 2 "$out")" "$(want '' '' v1)"

# Z7: file moved away, then back with a new mtime
out="$(run "$V1" "mv \$FN \$FN.away; call; show; call; show
print -r -- 'f() { print v2 }' > \$FN.away; touch -t \$T1 \$FN.away; mv \$FN.away \$FN; call; show")"
is "Z7 a missing file keeps the old f with one failure line" "$(line_n 1 "$out")" "$(want '' "$FAILED" v1)"
is "Z7 a second call is silent" "$(line_n 2 "$out")" "$(want '' '' v1)"
is "Z7 moved back with a new mtime reloads" "$(line_n 3 "$out")" "$(want '' "$RELOADED" v2)"

# Z8: an alias that clashes with a later definition fails in the live shell, so f stays
out="$(run "$V1" "alias ll='ls -l'
print -r -- 'f() { print v2 }
ll() { print ll }' > \$FN; touch -t \$T1 \$FN; call; show
unalias ll; touch -t \$T2 \$FN; call; show")"
is "Z8 an alias clash keeps the old f with one failure line" "$(line_n 1 "$out")" "$(want '' "$FAILED" v1)"
is "Z8 after unalias and a new mtime it reloads" "$(line_n 2 "$out")" "$(want '' "$RELOADED" v2)"

# Z9: the file is replaced between the stat and the read. zstat is shadowed by a function
# that calls the builtin and then, once, renames a newer version over the file.
out="$(run "$V1" "put v2 \$T1
SWAP=1
zstat() { builtin zstat \"\$@\"; local rc=\$?
  if (( SWAP )); then SWAP=0; print -r -- 'f() { print v3 }' > \$TT/swap; touch -t \$T2 \$TT/swap; mv \$TT/swap \$FN; fi
  return \$rc }
call; show; call; show; call; show")"
is "Z9 the newer text is loaded and the reload line printed" "$(line_n 1 "$out")" "$(want '' "$RELOADED" v3)"
is "Z9 the next call reloads it once more" "$(line_n 2 "$out")" "$(want '' "$RELOADED" v3)"
is "Z9 the call after is silent" "$(line_n 3 "$out")" "$(want '' '' v3)"

# Z10: a function absent from the new file stays defined
out="$(run $'f() { print v1 }\ng() { print gv }' 'put v2 $T1; call; show; print -r -- "g=[$(g)]"')"
is "Z10 the new f is loaded" "$(line_n 1 "$out")" "$(want '' "$RELOADED" v2)"
is "Z10 a function the new file lacks stays defined" "$(line_n 2 "$out")" 'g=[gv]'

# Z12: nothing a case script did wrote to its stderr, which would be a startup error or
# warning from the new block in dot_zshrc (the hook's own stderr is captured by `call`)
is "Z12 no case script wrote to stderr" "$(cat "$T/all.err" 2>/dev/null)" ''

# Z11: the real functions file holds the invariants the reload relies on: only function
# definitions and comments at top level, and no function reading where it was loaded from.
# The line check below is a cheap first pin. The trace check is the one that decides: sourcing
# the file under xtrace in a clean shell traces every command the file runs at top level and
# none of its function definitions, comments or blank lines, so a trace line naming the file
# means some statement runs at load time (a typeset, an assignment, any command, however it
# is indented). It sees only what runs when the file is sourced in that clean shell; it does
# not prove what a function body does when called.
bad="$(grep -nEv '^(#.*|[[:space:]].*|\}|[A-Za-z_][A-Za-z0-9_.:-]*\(\) \{)?$' "$FUNCS")"
is "Z11 every top-level line is a comment, blank, } or name() {" "$bad" ''
reads="$(grep -nF -e '$0' -e funcsourcetrace -e functions_source -e '%x' -e '%N' -e LINENO "$FUNCS")"
is "Z11 no function reads where it was loaded from" "$reads" ''
# The probe sources a byte-identical copy at a path the suite controls ($T/probe-functions):
# xtrace quotes an argument holding a space or other shell-special character ('/a b/functions'),
# while %N in PS4 does not, so the real path could not be matched against the trace verbatim.
cp "$FUNCS" "$T/probe-functions"
cat > "$T/invariant.zsh" <<'ZSH'
exec 2>$TT/trace
PS4='+TRACE:%N:%i> '
setopt xtrace
source $TT/probe-functions >$TT/inv.out
print -r -- $? >$TT/source.rc
unsetopt xtrace
ZSH
rm -f "$T/trace" "$T/inv.out" "$T/source.rc"
inv_msg="$(env -i HOME="$HOMEDIR" PATH=/usr/bin:/bin TT="$T" /bin/zsh -f "$T/invariant.zsh" 2>&1)"
inv_rc=$?
# Positive control: the probe must have traced its own `source` line (line 4 of the probe
# script), or the checks below would compare empty strings and pass without looking at anything.
is "Z11 the probe script ran to its end and wrote nothing before its trace started" "$inv_rc:$inv_msg" '0:'
is "Z11 the probe traced its own source line (positive control)" \
   "$(grep -F "+TRACE:$T/invariant.zsh:4> source " "$T/trace" 2>/dev/null | grep -c 'probe-functions')" 1
is "Z11 the source of the functions file itself returned status 0" "$(cat "$T/source.rc" 2>/dev/null)" 0
is "Z11 sourcing it at top level runs no statement (no trace line names it)" "$(grep -nF "+TRACE:$T/probe-functions:" "$T/trace")" ''
is "Z11 sourcing it writes no stdout" "$(cat "$T/inv.out")" ''
is "Z11 sourcing it writes no stderr but the trace" "$(grep -v '^+TRACE:' "$T/trace")" ''

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
