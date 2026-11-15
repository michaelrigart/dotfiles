#!/bin/zsh
# Tests for bin/xreview-app and the `herdr` of xreview-shim/, as chezmoi renders them from
# dot_config/herdr-app. Run: ./tests/herdr-app-xreview.test.sh
#
# hc, herdr-app and ps are stubs (tests/fixtures/herdr-app/stubs) first on PATH; every call lands in one log. The
# contract tests run xreview's own jq filters, copied from ~/.local/bin/xreview with their line
# numbers, over what the shim prints and assert what xreview would conclude from it. xreview
# itself is never run, and neither is the real hc, herdr-app or herdr.
emulate -L zsh
setopt no_unset pipe_fail

here=${0:A:h}
SRC=${0:A:h:h}
for f in dot_config/herdr-app/bin/executable_xreview-app dot_config/herdr-app/xreview-shim/executable_herdr; do
  [[ -f $SRC/$f ]] || { print -u2 -- "missing $f"; exit 2 }
done
source $here/fixtures/herdr-app/render.zsh
PATH_BASE=$PATH
root=$(mktemp -d "${TMPDIR:-/tmp}/xreview-app-tests.XXXXXX") || exit 1
root=${root:A}
trap 'rm -rf "$root"' EXIT
herdr_app_render $root/r || { print -u2 -- "INCONCLUSIVE: chezmoi could not render dot_config/herdr-app"; exit 2 }
bin=$root/r/home/.config/herdr-app/bin
shim=$root/r/home/.config/herdr-app/xreview-shim/herdr

typeset -i passed=0 total=0
exec 9>&1  # check reports here, so a check called with its output redirected still counts for run.sh
check() { # <description> <command...>: passes when the command succeeds
  local what=$1; shift
  (( ++total ))
  if "$@"; then (( ++passed )); print -u9 -- "  PASS: $what"; else print -u9 -- "  FAIL: $what"; fi
}
did() { grep -q -- "$1" "$LOG" }
not_did() { ! did "$1" }
same() { [[ $1 == $2 ]] }
not() { ! "$@" }

# --- one scratch world per case ------------------------------------------------------------
# Spaces: main (Codex t1, Claude t2), main again on a remote machine (Codex t5), wt (Codex t3
# working, a bare shell t4), other (Codex t6).
main=/work/repo wt=/work/repo-feat other=/work/other
newworld() {
  world=$root/$1; mkdir -p $world/state
  export STUB_DIR=$world/state LOG=$world/state/log
  export STUB_LOG=$LOG STUB_LS=$world/state/ls.json
  unset STUB_LS_DOWN PINNED_PATH XREVIEW_APP_XREVIEW
  : > $LOG; : > $STUB_DIR/closed
  jq -n --arg main $main --arg wt $wt --arg other $other '
    def t($id; $app; $st): {terminal: $id, pane: ("p" + $id), status: $st, app: $app, name: null, sub_agents: []};
    def sp($id; $f; $m; $ts): {id: $id, name: $id, folder: $f, machine: $m, active: false,
      tabs: [{id: ("tb-" + $id), name: "agents", terminals: $ts}]};
    {spaces: [
      sp("sp-main"; $main; null; [t("t1"; "codex"; "idle"), t("t2"; "claude-code"; "idle")]),
      sp("sp-remote"; $main; "box"; [t("t5"; "codex"; "idle")]),
      sp("sp-wt"; $wt; null; [t("t3"; "codex"; "working"), t("t4"; null; null)]),
      sp("sp-other"; $other; null; [t("t6"; "codex"; "idle")])]}' > $STUB_LS
  export PATH=$here/fixtures/herdr-app/stubs:$PATH_BASE
}
# core <terminal> <title> <state> <shell-pid> <fg-pid> <fg-name> — what `hc get` says; the
# foreground's argv is [/bin/<name>, --flag]
core() {
  jq -n --arg t $1 --arg title "$2" --arg st $3 --argjson sh $4 --argjson fg $5 --arg n $6 '{
    address: $t, pid: $sh, state: "live", cwd: "/work/repo", title: $title,
    status: (if $st == "none" then null else {app: "codex", state: $st} end),
    foreground: {pid: $fg, name: $n, argv: [("/bin/" + $n), "--flag"], cwd: "/work/repo/sub"}}' > $STUB_DIR/get-$1.json
}
# a Codex TUI in the foreground of t1: shell 1000, Codex 2000, itself the leader of its group
codex_up() { core t1 "${1:-}" ${2:-idle} 1000 2000 codex; print 2000 > $STUB_DIR/pgid-2000 }
shell_up() { core t1 "" none 1000 1000 zsh }
runshim() { $shim "$@" >$world/out 2>$world/err </dev/null; rc=$? }

# --- xreview's own reading of the shim's output --------------------------------------------
# Each body is xreview's, line numbers in ~/.local/bin/xreview as of this suite.
x_find_pane() { # <root>; find_pane, 183-186: the ids of the Codex panes in the root
  local snap; snap="$($shim pane list 2>/dev/null || true)"
  [[ -n $snap ]] || return 1
  print -r -- $snap | jq -r --arg cwd "$1" \
    '.result.panes[]? | select(.agent == "codex" and ((.cwd | type) == "string") and (.cwd == $cwd or (.cwd | startswith($cwd + "/.claude/worktrees/")))) | .pane_id'
}
x_pane_obj() { # <pane>; pane_obj, 223-225: the pane object, or exit 1 when the read failed
  local out rc=0
  out="$($shim pane get "$1" 2>/dev/null)" || rc=$?
  [[ $rc -eq 0 && -n $out ]] || return 1
  print -r -- $out | jq -ce '.result.pane | objects' 2>/dev/null || return 1
}
x_title_id() { # <pane>; pane_title_id, 206/215 and title_id_from, 47: the thread id prefix of the title
  local raw
  raw="$($shim pane get "$1" 2>/dev/null | jq -r ".result.pane | (.terminal_title_stripped // .terminal_title) // empty" 2>/dev/null || true)"
  print -r -- $raw | sed -nE 's/^[[:space:]]*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{5,12}).*/\1/p'
}
x_status() { # <pane>; pane_guard, 352: the status it reads
  x_pane_obj "$1" | jq -r '.agent_status // empty' 2>/dev/null
}
x_busy() { case "$(x_status "$1")" in working|blocked) return 0 ;; esac; return 1 }  # pane_guard, 353-355
x_gone() { # <pane>; pane_gone, 250-253
  local err
  err="$($shim pane get "$1" 2>&1 >/dev/null)" || true
  case "$err" in *'"pane_not_found"'*) return 0 ;; esac
  return 1
}
x_proc() { # <pane>; pane_proc, 264-270: the process info, or exit 1
  local out
  out="$($shim pane process-info --pane "$1" 2>/dev/null)" || return 1
  print -r -- $out | jq -e '.result.process_info
    | (.shell_pid | type == "number")
      and (.foreground_processes | type == "array"
           and all(type == "object" and (.name | type == "string")
                   and (.argv | type == "array" and length > 0)))' >/dev/null 2>&1 || return 1
  print -r -- $out | jq -c '.result.process_info'
}
x_codex() { # <proc-json>; proc_codex, 274-278: the foreground Codex process
  print -r -- "$1" | jq -c '.foreground_process_group_id as $g
    | [.foreground_processes[]? | select(.name == "codex" or .argv0 == "codex")]
    | (map(select(.pid == $g)) + .) | .[0] // empty' 2>/dev/null
}
x_freed() { print -r -- "$1" | jq -e '.foreground_process_group_id == .shell_pid' >/dev/null 2>&1 }  # proc_freed, 281
x_is_free() { # <pane>; pane_is_free, 502-505: the shell is back in the foreground
  local proc
  if proc="$(x_proc "$1")"; then x_freed "$proc"; return; fi
  return 1
}
x_screen() { $shim pane read "$1" --source visible --lines 12 --format text 2>/dev/null }  # pane_screen, 389
x_lock() { print -rn -- "$1" | tr -c 'A-Za-z0-9._-' '_' }  # lock_pane, the file's name

# refuses <args...>: the shim fails loudly, prints nothing, calls nothing
refuses() {
  : > $LOG
  runshim "$@"
  [[ $rc -ne 0 && -s $world/err && ! -s $world/out ]] && ! grep -q pane_not_found $world/err \
    && ! grep -q '^\(hc\|herdr-app\|ps\) ' $LOG
}

# --- find_pane: which panes are Codex panes of a checkout ----------------------------------
newworld find
check "the Codex pane of a checkout is found" same "$(x_find_pane $main)" app:t1
check "a worktree's own Codex pane is found, busy or not" same "$(x_find_pane $wt)" app:t3
check "a checkout with no Codex pane finds none" same "$(x_find_pane /work/nowhere)" ""
check "only local Codex terminals are listed" same "$($shim pane list | jq -c '[.result.panes[].pane_id]')" '["app:t1","app:t3","app:t6"]'
# t2 (Claude) shares t1's folder and t5 (Codex, on another machine) shares its folder too.
check "a Claude terminal or a remote Codex in the folder is not a candidate" test "$(x_find_pane $main | grep -c .)" -eq 1
check "a harness worktree's Codex pane is the main checkout's, as for the TUI" same \
  "$(jq '.spaces[0].folder = "/work/repo/.claude/worktrees/x"' $STUB_LS > $STUB_LS.new && mv $STUB_LS.new $STUB_LS; x_find_pane /work/repo)" app:t1
check "the pane id is not a TUI pane id" test "$($shim pane list | jq -r '.result.panes[].pane_id' | grep -vc '^app:t[0-9]*$')" -eq 0
check "the lock file of an app pane has a name of its own" same "$(x_lock app:t1)" app_t1
check "...which no TUI pane's lock can have" test "$(x_lock app:t1)" != "$(x_lock wV:p2)"
export STUB_LS_DOWN=1
check "the app being closed is no Codex pane list" not x_find_pane $main
unset STUB_LS_DOWN

# --- get: found, busy or free, and not found -----------------------------------------------
newworld get
fake_title="01234567-89ab-cdef-0123-45678... | Review | ~/x"
codex_up "$fake_title"
check "the pane's object is read" x_pane_obj app:t1 >/dev/null
check "the thread id prefix is the one at the start of the title" same "$(x_title_id app:t1)" 01234567-89ab-cdef-0123-45678
check "a pane without a title has no thread id" same "$(core t1 "" idle 1000 2000 codex; x_title_id app:t1)" ""
check "an idle pane is not busy" not x_busy app:t1
check "...and says idle" same "$(x_status app:t1)" idle
for st in working blocked; do
  codex_up "" $st
  check "a $st pane is busy" x_busy app:t1
done
for st in done error; do
  codex_up "" $st
  check "a $st pane is not busy" not x_busy app:t1
done
shell_up
check "a pane whose Codex has quit reads unknown, not busy" same "$(x_status app:t1)" unknown
jq '.spaces[0].tabs[0].terminals[0] |= (.app = null | .status = null)' $STUB_LS > $STUB_LS.new && mv $STUB_LS.new $STUB_LS
check "...and is no longer an agent's" same "$($shim pane get app:t1 | jq -c '.result.pane.agent')" null
core t1 $'x\aA\tB' idle 1000 2000 codex
check "the stripped title has no control characters" same "$($shim pane get app:t1 | jq -r '.result.pane.terminal_title_stripped')" xAB
check "the raw title keeps them" same "$($shim pane get app:t1 | jq -r '.result.pane.terminal_title | length')" 5
check "the pane reports the folder of its space" same "$($shim pane get app:t1 | jq -r '.result.pane.cwd')" $main
# Codex leads its title with a spinner glyph while it works; xreview's own regex and its title_id_from
# must still find the thread id in what the shim calls stripped.
spun=01234567-89ab-cdef-0123-45678
for lead in "◐ " "⠋ " "  ⠙ " $'\a◐\t'; do
  core t1 "$lead$spun... | Review | ~/x" idle 1000 2000 codex
  check "a title led by '${lead//[[:cntrl:]]/?}' gives xreview the thread id" same "$(x_title_id app:t1)" $spun
  check "...the raw title keeping its lead" same "$($shim pane get app:t1 | jq -r '.result.pane.terminal_title')" "$lead$spun... | Review | ~/x"
done
core t1 "◐ 01234567-89ab-cdef-0123-45678... | ◐ Review ☃" idle 1000 2000 codex
check "only the lead is stripped: later glyphs stay" same "$($shim pane get app:t1 | jq -r '.result.pane.terminal_title_stripped')" "01234567-89ab-cdef-0123-45678... | ◐ Review ☃"
core t1 "◐ ⠋" idle 1000 2000 codex
check "a title of nothing but glyphs strips to nothing" same "$($shim pane get app:t1 | jq -c '.result.pane.terminal_title_stripped')" '""'
core t1 "" idle 1000 2000 codex; jq '.title = null' $STUB_DIR/get-t1.json > $STUB_DIR/new && mv $STUB_DIR/new $STUB_DIR/get-t1.json
check "a terminal whose title is null can be read" x_pane_obj app:t1 >/dev/null
check "...with an empty title, as the TUI has" same "$($shim pane get app:t1 | jq -c '.result.pane | [.terminal_title, .terminal_title_stripped]')" '["",""]'
check "...and no thread id" same "$(x_title_id app:t1)" ""
core t4 "" none 4000 4000 zsh
check "a terminal with no agent can be read: a Codex pane that was just quit is one" same "$($shim pane get app:t4 | jq -r '.result.pane.pane_id')" app:t4

: > $LOG
for id in app:t999 app:t2 app:t5 wV:p2 app: app:t1x\; "app:t1 " ""; do
  check "'$id' is not found" x_gone "$id"
  check "'$id' reads nothing" not x_pane_obj "$id"
done
check "an id that is not in scope never reaches the core" not_did '^hc get'
codex_up; : > $STUB_DIR/gone-t1
check "a terminal the core does not have is not found" x_gone app:t1
rm $STUB_DIR/gone-t1
jq '.state = "exited"' $STUB_DIR/get-t1.json > $STUB_DIR/new && mv $STUB_DIR/new $STUB_DIR/get-t1.json
check "a finished terminal is not found" x_gone app:t1
codex_up; : > $STUB_DIR/fail-t1
check "a core that cannot answer is a failed read" not x_pane_obj app:t1
check "...never a closed pane" not x_gone app:t1
rm $STUB_DIR/fail-t1
for garbage in 'not json {' '' '[1,2]' '{}' '{"state": 3}'; do
  codex_up; print -r -- "$garbage" > $STUB_DIR/get-t1.json
  check "a core answer that is not a terminal ($garbage) is a failed read" not x_pane_obj app:t1
  check "...never a closed pane" not x_gone app:t1
done
codex_up
export STUB_LS_DOWN=1
check "an app that cannot answer is a failed read" not x_pane_obj app:t1
check "...never a closed pane, either" not x_gone app:t1
unset STUB_LS_DOWN
# An app that is starting or restarting answers with no spaces at all.
cp $STUB_LS $STUB_LS.full; print -r -- '{"spaces": []}' > $STUB_LS; : > $LOG
check "an app with no spaces yet is a failed read" not x_pane_obj app:t1
check "...never a closed pane, either" not x_gone app:t1
check "...for process-info too" not x_proc app:t1
for call in "send-keys app:t1 ctrl+c" "run app:t1 x" "read app:t1 --source visible --lines 3 --format text"; do
  runshim pane ${=call}
  check "...'${call%% *}' fails as a failed read, not as a closed pane" test $rc -eq 1 -a -s $world/err -a ! -s $world/out
  check "...'${call%% *}' says nothing of a pane not found" not grep -q pane_not_found $world/err
done
check "...sending nothing" not_did '^hc \(keys\|send\|read\)'
check "...though a pane list with no spaces is simply empty" same "$($shim pane list | jq -c '.result.panes')" '[]'
mv $STUB_LS.full $STUB_LS

# --- process-info: the foreground, and "freed" ---------------------------------------------
newworld proc
codex_up
proc=$(x_proc app:t1); check "the process is described as xreview needs" test -n "$proc"
check "the shell is the core's own terminal pid" same "$(jq .shell_pid <<<$proc)" 1000
check "Codex is the foreground process xreview sees" same "$(x_codex $proc | jq -c '[.pid, .name, .argv0, .argv, .cmdline]')" '[2000,"codex","codex",["/bin/codex","--flag"],"/bin/codex --flag"]'
check "a Codex in the foreground is not a freed pane" not x_freed $proc
check "...so the ladder sees it is not free" not x_is_free app:t1
check "the group of a foreground process that is not the shell is asked of ps" did '^ps -o pgid= -p 2000$'
check "the foreground group is a number" same "$(jq '.foreground_process_group_id | type' <<<$proc)" '"number"'

check "argv0 is the program's name, not its path" same "$(jq -r '.foreground_processes[0].argv0' <<<$proc)" codex
: > $LOG; shell_up
proc=$(x_proc app:t1)
check "a shell in the foreground is freed" x_freed $proc
check "...and the ladder sees it is free" x_is_free app:t1
check "the shell's own group is not asked of ps" not_did '^ps -o pgid='
check "no Codex process is left to guard" same "$(x_codex $proc)" ""

# A terminal whose root process is Codex itself has no shell to be freed to.
for root in codex /opt/homebrew/bin/codex node tmux zshell zsh-wrapper; do
  core t1 "" idle 2000 2000 codex; print -r -- $root > $STUB_DIR/comm-2000; : > $LOG
  check "a terminal rooted in '$root' is a failed read" not x_proc app:t1
  check "...never a closed pane" not x_gone app:t1
  check "...so the ladder sees it is not free" not x_is_free app:t1
  check "...and nothing is sent to it" not_did '^hc-args'
done
# What ps says now counts, not what hc's foreground says (an `exec codex` in a shell)
core t1 "" idle 2000 2000 zsh; print codex > $STUB_DIR/comm-2000
check "the root's current name wins over the name hc gives" not x_proc app:t1
core t1 "" idle 2000 2000 codex; print zsh > $STUB_DIR/comm-2000
: > $LOG
check "a shell root that hc names something else is a failed read" not x_proc app:t1
check "...never a closed pane" not x_gone app:t1
check "...so the ladder sees it is not free" not x_is_free app:t1
check "...and nothing is sent to it" not_did '^hc-args'
rm $STUB_DIR/comm-2000
# A shell root without job control runs Codex in its own group: ps gives the shell's pid for it
core t1 "" idle 1000 2000 codex; print 1000 > $STUB_DIR/pgid-2000; : > $LOG
check "a foreground in the group of its shell is a failed read" not x_proc app:t1
check "...never a closed pane" not x_gone app:t1
check "...so the ladder sees it is not free" not x_is_free app:t1
check "...and nothing is sent to it" not_did '^hc-args'
rm $STUB_DIR/pgid-2000
# a terminal rooted in a shell with Codex in the foreground, whichever way ps spells the shell
for root in zsh -zsh /bin/zsh -bash /opt/homebrew/bin/fish sh dash ksh; do
  codex_up; print -r -- $root > $STUB_DIR/comm-1000
  check "a Codex under '$root' is the foreground of a shell terminal" x_proc app:t1 >/dev/null
  check "...not freed" not x_is_free app:t1
  check "...with the Codex process there to guard" same "$(x_codex "$(x_proc app:t1)" | jq .pid)" 2000
done
rm $STUB_DIR/comm-1000
codex_up; : > $STUB_DIR/commfail-1000
check "a root that ps cannot name is a failed read" not x_proc app:t1
check "...never a closed pane" not x_gone app:t1
rm $STUB_DIR/commfail-1000
shell_up; print codex > $STUB_DIR/comm-1000
check "even a Codex that is the root and the foreground itself is no freed pane" not x_is_free app:t1
rm $STUB_DIR/comm-1000

# a Codex that is not the leader of its group: the group is what ps says
core t1 "" idle 1000 2001 codex; print 2000 > $STUB_DIR/pgid-2001
proc=$(x_proc app:t1)
check "a foreground process that is not the group leader gets the group ps gives" same "$(jq .foreground_process_group_id <<<$proc)" 2000
check "...asking ps about that process" did '^ps -o pgid= -p 2001$'
check "...and its own pid is still the process's" same "$(x_codex $proc | jq .pid)" 2001
rm $STUB_DIR/pgid-2001
check "a group that ps cannot give is a failed read" not x_proc app:t1
check "...never a closed pane" not x_gone app:t1
core t1 "" idle 1000 2000 codex; jq '.foreground.argv = []' $STUB_DIR/get-t1.json > $STUB_DIR/new && mv $STUB_DIR/new $STUB_DIR/get-t1.json
check "a foreground with no argv fails xreview's own check, as it would for the TUI" not x_proc app:t1
core t1 "" idle 1000 2000 codex; jq 'del(.foreground)' $STUB_DIR/get-t1.json > $STUB_DIR/new && mv $STUB_DIR/new $STUB_DIR/get-t1.json
check "a terminal with no foreground is a failed read" not x_proc app:t1
for id in app:t999 app:t2 app:t5 wV:p2; do
  check "process-info of '$id' is not found" x_gone "$id"
  check "process-info of '$id' reads nothing" not x_proc "$id"
done
: > $STUB_DIR/gone-t1
check "pane_is_free on a closed pane is not free" not x_is_free app:t1
rm $STUB_DIR/gone-t1

# --- keys, run and read go to the terminal of the id ---------------------------------------
newworld io
check "ctrl+c goes to the terminal's keys" test "$($shim pane send-keys app:t1 ctrl+c; grep '^hc-args' $LOG)" = 'hc-args [keys] [t1] [ctrl+c]'
: > $LOG; $shim pane send-keys app:t3 ctrl+c
check "...of whichever terminal it names" did '^hc-args \[keys\] \[t3\] \[ctrl+c\]$'
check "...and only that one" test "$(grep -c '^hc ' $LOG)" -eq 1
: > $LOG; $shim pane send-keys app:t4 ctrl+c
check "a terminal with no agent gets it as well" did '^hc-args \[keys\] \[t4\] \[ctrl+c\]$'

: > $LOG; $shim pane run app:t1 "codex -C /work/repo resume 0123"
check "run sends its text whole to the terminal" did '^hc-args \[send\] \[t1\] \[codex -C /work/repo resume 0123\]$'
: > $LOG; $shim pane run app:t3 "codex"
check "...whichever terminal it names" did '^hc-args \[send\] \[t3\] \[codex\]$'

for i in {1..30}; do print "line $i"; done > $STUB_DIR/read-t1
print three > $STUB_DIR/read-t3
check "read gives the bottom of the screen" same "$(x_screen app:t1 | tr '\n' ,)" "line 19,line 20,line 21,line 22,line 23,line 24,line 25,line 26,line 27,line 28,line 29,line 30,"
check "...as many lines as asked for" same "$($shim pane read app:t1 --source visible --lines 2 --format text | tr '\n' ,)" "line 29,line 30,"
check "...from the terminal it names" same "$(x_screen app:t3)" three
check "...a short screen whole" test "$(x_screen app:t3 | grep -c .)" -eq 1

: > $LOG
for id in app:t999 app:t2 app:t5 wV:p2 'app:t1;x'; do
  $shim pane send-keys $id ctrl+c 2>/dev/null; r1=$?
  $shim pane run $id x 2>/dev/null; r2=$?
  $shim pane read $id --source visible --lines 12 --format text 2>/dev/null; r3=$?
  check "keys, run and read refuse '$id'" test "$r1$r2$r3" = 111
done
check "...and send nothing anywhere" not_did '^hc \(keys\|send\|read\)'

# --- the session report is a successful no-op ----------------------------------------------
: > $LOG
runshim pane report-agent-session app:t1 --source herdr:codex --agent codex --agent-session-id 0123 --seq 1700000000000000000
check "report-agent-session succeeds" test $rc -eq 0
check "...and says nothing" test ! -s $world/out -a ! -s $world/err
check "...and touches nothing" test ! -s $LOG

# --- anything else fails loudly and does nothing -------------------------------------------
newworld unsupported
refusal() { check "refused: herdr $*" refuses "$@" }
refusal
refusal --version
refusal pane
refusal pane list --json
refusal pane list app:t1
refusal pane get
refusal pane get app:t1 --json
refusal pane process-info app:t1
refusal pane process-info --pane
refusal pane process-info --pane app:t1 extra
refusal pane send-keys app:t1
refusal pane send-keys app:t1 ctrl+d
refusal pane send-keys app:t1 enter
refusal pane send-keys app:t1 ctrl+c ctrl+c
refusal pane run app:t1
refusal pane run app:t1 a b
refusal pane read app:t1
refusal pane read app:t1 --lines 12
refusal pane read app:t1 --source all --lines 12 --format text
refusal pane read app:t1 --source visible --lines 12 --format json
refusal pane read app:t1 --source visible --lines x --format text
refusal pane read app:t1 --source visible --lines 0 --format text
refusal pane read app:t1 --source visible --lines 12 --format text extra
refusal pane read app:t1 --format text --lines 12 --source visible
refusal pane split app:t1
refusal pane close app:t1
refusal pane focus app:t1
refusal pane report-agent-session app:t1
refusal pane report-agent-session app:t1 --source herdr:claude --agent codex --agent-session-id 0123 --seq 1
refusal pane report-agent-session wV:p2 --source herdr:codex --agent codex --agent-session-id 0123 --seq 1
refusal workspace list
refusal tab list
refusal server stop

# --- the shim's replies have the TUI's structure -------------------------------------------
# tests/fixtures/herdr-app/tui-shapes.json: the keys and types of the real replies. Every key the shim
# gives is the TUI's, of the same type; process info and the error are the TUI's whole.
newworld shapes
shapes=$here/fixtures/herdr-app/tui-shapes.json
codex_up "$fake_title"
ty='def types: with_entries(.value |= type) | to_entries | sort_by(.key) | from_entries;'
# subset_of <shim json> <fixture key>: each non-null value of the shim has the type the TUI's has
subset_of() { jq -e --slurpfile f $shapes --arg k $2 '. as $o | $f[0][$k] as $t
  | to_entries | all(.value == null or ($t[.key] == (.value | type)))' <<<$1 >/dev/null }
runshim pane get app:t1; got_pane=$(jq -c .result.pane $world/out)
check "get: the envelope is the TUI's" same "$(jq -c '[(.id | type), (.result | keys)]' $world/out)" "$(jq -c '[.envelope.id, .envelope.result]' $shapes)"
check "get: its keys are the TUI's, with the TUI's types" subset_of $got_pane get_pane
runshim pane list; got_pane=$(jq -c '.result.panes[0]' $world/out)
check "list: its keys are the TUI's, with the TUI's types" subset_of $got_pane list_pane
runshim pane process-info --pane app:t1
check "process-info: the keys are the TUI's, no more and no fewer" same "$(jq -c "$ty "'.result.process_info | types | keys' $world/out)" "$(jq -c '.process_info | keys' $shapes)"
check "process-info: its types are the TUI's" same "$(jq -c "$ty "'.result.process_info | types' $world/out)" "$(jq -c '.process_info' $shapes)"
check "process-info: a process's keys and types are the TUI's" same "$(jq -c "$ty "'.result.process_info.foreground_processes[0] | types' $world/out)" "$(jq -c '.process' $shapes)"
runshim pane get app:t999
check "not found: the error is the TUI's, on stderr" same "$(jq -c '[keys, (.error | keys), .error.code]' $world/err)" "$(jq -c '[.not_found.top, .not_found.error, .not_found.code]' $shapes)"
check "not found: nothing on stdout" test ! -s $world/out

# --- xreview-app ---------------------------------------------------------------------------
# A stand-in for xreview that resets its PATH as the real one does (its line 24), then says
# which herdr it would run, with what arguments, and what PATH it was left with.
newworld xreview-app
cat > $world/xreview <<'EOS'
#!/bin/bash
PATH=${PINNED_PATH:-$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH
command -v herdr
echo "$PATH"
printf '[%s]\n' "$@"
exit 7
EOS
chmod +x $world/xreview
export XREVIEW_APP_XREVIEW=$world/xreview
shimdir=${shim:h}
"$bin/xreview-app" dispatch "two words" --flag >$world/out 2>$world/err; rc=$?
check "xreview-app is executable" test -x $bin/xreview-app
check "the shim is executable" test -x $shim
check "xreview-app passes xreview's exit status on" test $rc -eq 7
check "xreview finds the shim as its herdr, not the TUI's" same "$(sed -n 1p $world/out)" $shim
check "...with the shim folder first on the PATH it was left with" test "$(sed -n 2p $world/out | cut -d: -f1)" = $shimdir
check "xreview gets its arguments as they were" same "$(sed -n '3,$p' $world/out | tr '\n' ' ')" "[dispatch] [two words] [--flag] "
check "the folder is put in front of a PINNED_PATH that was set" same "$(PINNED_PATH=/custom:/usr/bin "$bin/xreview-app" 2>/dev/null | sed -n 2p)" "$shimdir:/custom:/usr/bin"
check "the folder is put in front of the PATH xreview would have used" same "$(sed -n 2p $world/out)" "$shimdir:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
# xreview-app runs outside the sandbox with the caller's PATH. With tools planted in a folder first
# on that PATH, none may run, and xreview must start with the PATH it is going to set.
mkdir -p $world/planted $world/marks
for tool in grep sed cat awk head tr jq; do
  printf '#!/bin/sh\necho planted >> %s/%s\nexit 1\n' $world/marks $tool > $world/planted/$tool
  chmod +x $world/planted/$tool
done
cat > $world/xreview-env <<'EOS'
#!/bin/bash
echo "PINNED_PATH=$PINNED_PATH"
echo "PATH=$PATH"
PATH=${PINNED_PATH:-$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH
EOS
chmod +x $world/xreview-env
marks() { local -a m; m=($world/marks/*(N:t)); print -r -- $m }
PATH=$world/planted:$PATH XREVIEW_APP_XREVIEW=$world/xreview-env "$bin/xreview-app" >$world/out 2>$world/err; rc=$?
check "planted tools first on the caller's PATH: xreview runs" test $rc -eq 0
check "...none of them runs" same "$(marks)" ""
want=$shimdir:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
check "...xreview gets the PINNED_PATH it will set" same "$(sed -n 1p $world/out)" "PINNED_PATH=$want"
check "...and the same as its PATH" same "$(sed -n 2p $world/out)" "PATH=$want"
PATH=$world/planted:$PATH PINNED_PATH=/custom:/usr/bin XREVIEW_APP_XREVIEW=$world/xreview-env "$bin/xreview-app" >$world/out 2>$world/err; rc=$?
check "an inherited PINNED_PATH is honoured with planted tools too" same "$(tr '\n' ' ' < $world/out)" "PINNED_PATH=$shimdir:/custom:/usr/bin PATH=$shimdir:/custom:/usr/bin "
check "...and none of them runs" same "$(marks)" ""

XREVIEW_APP_XREVIEW=$world/absent "$bin/xreview-app" >$world/out 2>$world/err; rc=$?
check "a missing xreview is an error" test $rc -ne 0

# The PATH xreview would have used is read from the xreview that runs, not kept as a copy: a
# stand-in with another default gets that one, $HOME expanded and nothing else.
xreview_with() { # <the PATH line> -> a stand-in whose only job is to say what it ran with
  printf '#!/bin/bash\n%s\necho "$PATH"\n' "$1" > $world/xreview-other; chmod +x $world/xreview-other
}
xreview_with 'PATH=${PINNED_PATH:-$HOME/mybin:/opt/other:/usr/bin}; export PATH'
check "the default PATH is the one in xreview's own line" same \
  "$(XREVIEW_APP_XREVIEW=$world/xreview-other "$bin/xreview-app" 2>/dev/null)" "$shimdir:$HOME/mybin:/opt/other:/usr/bin"
check "a PINNED_PATH that was set still wins over it" same \
  "$(PINNED_PATH=/custom XREVIEW_APP_XREVIEW=$world/xreview-other "$bin/xreview-app" 2>/dev/null)" "$shimdir:/custom"
# A line that is not found exactly once, or has another variable in it, stops everything: xreview
# is not run.
for changed in 'PATH=$HOME/.local/bin:/usr/bin; export PATH' \
               'PATH=${PINNED_PATH:-$HOME/bin:$SOMETHING_ELSE}; export PATH' \
               'PATH=${PINNED_PATH:-}; export PATH' \
               'PATH=${PINNED_PATH:-/usr/bin}; export PATH
PATH=${PINNED_PATH:-/bin}; export PATH' \
               'echo nothing'; do
  xreview_with "$changed"
  XREVIEW_APP_XREVIEW=$world/xreview-other "$bin/xreview-app" >$world/out 2>$world/err; rc=$?
  check "a changed PATH line is refused: ${changed//$'\n'/ ; }" test $rc -ne 0
  check "...saying so" grep -q "xreview's PATH line changed; update xreview-app" $world/err
  check "...without running xreview" test ! -s $world/out
done

print -- "$passed/$total passed"
(( passed == total ))
