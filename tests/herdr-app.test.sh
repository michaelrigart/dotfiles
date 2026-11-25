#!/bin/zsh
# Tests for bin/checkout-spaces, bin/retire, wt-app and open-space (--no-focus), and for what
# `chezmoi add` leaves alone in the app's folder, on dot_config/herdr-app as chezmoi renders it. Run:
# ./tests/herdr-app.test.sh
#
# herdr-app, hc, fzf, claude, wt-rm, ps and lsof are stubs (tests/fixtures/herdr-app/stubs) first on PATH and
# linked into the scratch HOME's .local/bin, the first folder of the PATH open-space and
# close-own-tab pin; every call lands in one log, so the order of calls is what is asserted. The repositories are real, in a
# scratch folder, and so is dot_config/zsh/functions (linked into a scratch HOME): retire's own
# checks run for real, and checkout-spaces runs for real against the stubs. The real wt-rm is never
# run, and no stub touches the app.
emulate -L zsh
setopt no_unset pipe_fail

here=${0:A:h}
SRC=${0:A:h:h}
# The installed Herdr app's own mods, which the patch-mod checks read; taken before any
# newworld points HERDR_APP_HOME at a scratch folder.
shipped=${HERDR_APP_HOME:-$HOME/.config/herdr-app}/mods
for f in dot_config/herdr-app/bin/executable_{checkout-spaces,claude-app,close-own-tab,edit-scrollback,folder-gone,open-space,patch-mod,respaces,retire,session-written,wt-app} \
         dot_config/herdr-app/{claude-settings,programs}.json.tmpl dot_config/zsh/functions; do
  [[ -f $SRC/$f ]] || { print -u2 -- "missing $f"; exit 2 }
done
source $here/fixtures/herdr-app/render.zsh
PATH_BASE=$PATH
# wt-app reaches dev and wt, which pick the front end from these: a run from a Herdr pane or an
# app terminal must not decide it, so each case that needs one sets it.
unset HC_SCOPE HC_TERMINAL_SOCKET HERDR_ENV HERDR_PANE_ID
root=$(mktemp -d "${TMPDIR:-/tmp}/herdr-app-tests.XXXXXX") || exit 1
root=${root:A}  # the app reports resolved paths
trap 'rm -rf "$root"' EXIT
herdr_app_render $root/r || { print -u2 -- "INCONCLUSIVE: chezmoi could not render dot_config/herdr-app"; exit 2 }
bin=$root/r/home/.config/herdr-app/bin

typeset -i passed=0 total=0
exec 9>&1  # check reports here, so a check called with its output redirected still counts for run.sh
check() { # <description> <command...>: passes when the command succeeds
  local what=$1; shift
  (( ++total ))
  if "$@"; then (( ++passed )); print -u9 -- "  PASS: $what"; else print -u9 -- "  FAIL: $what"; fi
}
# line number of the first log line matching a pattern, 0 when none
at() { local n; n=$(grep -n -m1 -- "$1" "$LOG" | cut -d: -f1); print -r -- ${n:-0} }
did() { grep -q -- "$1" "$LOG" }
not_did() { ! did "$1" }
differs() { ! cmp -s "$@" }
before() { local a b; a=$(at "$1"); b=$(at "$2"); (( a > 0 && b > a )) }

# --- one scratch world per case ------------------------------------------------------------
# $main is a repository with one linked worktree $wt on branch feat, made as wt makes it.
newworld() {
  PATH=$PATH_BASE  # a case that shadowed programs on PATH must not reach the next world's setup
  world=$root/$1; mkdir -p $world/home/.config $world/app $world/state $world/repos/fresh
  ln -s $SRC/dot_config/zsh $world/home/.config/zsh
  # The TUI's pane command, as open-space and xreview read it.
  mkdir -p $world/home/.config/herdr
  print -r -- 'codex --sandbox read-only --ask-for-approval never' > $world/home/.config/herdr/codex-pane-command
  export HOME=$world/home HERDR_APP_HOME=$world/app STUB_DIR=$world/state LOG=$world/state/log
  export STUB_LOG=$LOG STUB_LS=$world/state/ls.json
  export RETIRE_WT_RM=$here/fixtures/herdr-app/stubs/wt-rm STUB_CHECKOUT_SPACES=$bin/checkout-spaces HC_TERMINAL_ID=t9 DEV_OPEN_SPACE=$bin/open-space HC_SCOPE=space
  # open-space and close-own-tab pin their PATH, whose first folder is $HOME/.local/bin: the
  # trusted stubs are there, whatever the caller's PATH holds.
  mkdir -p $world/home/.local/bin
  local s; for s in herdr-app hc fzf claude wt-rm ps lsof; do ln -s $here/fixtures/herdr-app/stubs/$s $world/home/.local/bin/$s; done
  unset STUB_WTRM_RC STUB_WTRM_WARN STUB_DOWN STUB_LS_DOWN STUB_WTRM_CLOSE CODEX_HOME XDG_CONFIG_HOME
  : > $LOG; : > $STUB_DIR/closed
  main=$world/repos/proj; wt=$world/repos/proj-feat
  local g=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false)
  $g init -q --template= -b main $main
  $g -C $main commit -q --allow-empty -m init
  $g -C $main worktree add -q -b feat $wt
  $g -C $main worktree lock --reason "wt-managed; remove with command wt-rm" $wt
  ls_json
  export PATH=$here/fixtures/herdr-app/stubs:$PATH_BASE
}
# ls_json [agent_status] — the app: the worktree's space (a Claude and a Codex), the main
# checkout's space with this terminal (t9), and a space for the terminals open-space makes.
ls_json() {
  local agent=${1:-idle}
  jq -n --arg wt $wt --arg main $main --arg st $agent '{spaces: [
    {id: "sp-wt", name: "proj-feat", folder: $wt, machine: null, active: false, tabs: [
      {id: "tb-a", name: "agents", terminals: [
        {terminal: "t1", pane: "p1", status: $st, app: "claude-code", sub_agents: []},
        {terminal: "t2", pane: "p2", status: "idle", app: "codex", sub_agents: []}]}]},
    {id: "sp-main", name: "proj", folder: $main, machine: null, active: true, tabs: [
      {id: "tb-r", name: "retire", terminals: [
        {terminal: "t9", pane: "p9", status: null, app: null, sub_agents: []}]}]},
    {id: "sp-x", name: "x", folder: "/nowhere", machine: null, active: false, tabs: [
      {id: "tb-x", name: "x", terminals: [
        {terminal: "tNEW1", pane: "pN1", status: null, app: null, sub_agents: []},
        {terminal: "tNEW2", pane: "pN2", status: null, app: null, sub_agents: []}]}]}]}' > $STUB_LS
}
# records <claude-id> <codex-id> — what resume keeps for the worktree's two agents
records() {
  jq -n --arg c $1 --arg x $2 '{"resume.sessions": {
    t1: {app: "claude", id: $c, cwd: "/", fresh: "'"'"'claude'"'"' '"'"'--fresh'"'"'", cmd: "'"'"'claude'"'"' '"'"'--resume'"'"' '"'"'\($c)'"'"'"},
    t2: {app: "codex", id: $x, cwd: "/", fresh: "'"'"'codex'"'"' '"'"'--fresh'"'"'", cmd: "'"'"'codex'"'"' '"'"'resume'"'"' '"'"'\($x)'"'"'"}}}' > $HERDR_APP_HOME/shared.json
}
# add_space <id> <folder> <terminal> <status> — one more space in the app, with one agent
add_space() {
  jq --arg id $1 --arg f $2 --arg t $3 --arg st $4 '.spaces += [{id: $id, name: $id, folder: $f, machine: null, active: false, tabs: [
    {id: ("tb-" + $id), name: "agents", terminals: [{terminal: $t, pane: ("p" + $t), status: $st, app: "claude-code", sub_agents: []}]}]}]' $STUB_LS > $STUB_LS.new
  mv $STUB_LS.new $STUB_LS
}
# launched_in <terminal> <folder> — `hc ls`'s folder for it: where it was STARTED
launched_in() { jq -n --arg t $1 --arg c $2 '{terminals: [{address: $t, cwd: $c}]}' > $STUB_DIR/hc-ls.json }
# now_in <terminal> <folder> — `hc get`'s foreground folder: where it is NOW
now_in() { print -r -- $2 > $STUB_DIR/cwd-$1 }
retire() { "$bin/retire" "$@" </dev/null }
cs() { "$bin/checkout-spaces" "$@" </dev/null }


# --- retire: refusals change nothing -------------------------------------------------------
newworld main
retire $main >/dev/null 2>&1; rc=$?
check "refuses the main checkout" test $rc -ne 0
check "main checkout: nothing closed, nothing removed" not_did 'space.close\|wt-rm'

newworld notrepo; mkdir $world/plain
retire $world/plain >/dev/null 2>&1; rc=$?
check "refuses a folder that is not a repository" test $rc -ne 0
check "not a repository: nothing closed, nothing removed" not_did 'space.close\|wt-rm'

newworld elsewhere; mv $wt $world/repos/moved; git -C $main worktree repair $world/repos/moved 2>/dev/null
retire $world/repos/moved >/dev/null 2>&1; rc=$?
check "refuses a worktree wt would not have made there" test $rc -ne 0
check "misplaced: nothing closed, nothing removed" not_did 'space.close\|wt-rm'

newworld detached; git -C $wt checkout -q --detach
retire $wt >/dev/null 2>&1; rc=$?
check "refuses a detached HEAD" test $rc -ne 0
check "detached: nothing closed, nothing removed" not_did 'space.close\|wt-rm'


# --- checkout-spaces: refusals change nothing ----------------------------------------------
for busy in working blocked; do
  newworld busy-$busy; ls_json $busy
  cs close $wt >$world/out 2>&1; rc=$?
  check "refuses while an agent is $busy" test $rc -ne 0
  check "$busy agent: nothing closed" not_did 'space.close'
done

newworld inside; jq '.spaces[0].tabs[0].terminals += [{terminal: "t9", pane: "p9", status: null, app: null, sub_agents: []}]' $STUB_LS > $STUB_LS.new; mv $STUB_LS.new $STUB_LS
cs close $wt >/dev/null 2>&1; rc=$?
check "refuses when run from inside the space being closed" test $rc -ne 0
check "inside: nothing closed" not_did 'space.close'

newworld subagent; ls_json
# The app's listing names a sub-agent by address only; its status is the core's to give.
jq '.spaces[0].tabs[0].terminals[0].sub_agents = ["t1s"]' $STUB_LS > $STUB_LS.new; mv $STUB_LS.new $STUB_LS
jq -n '{terminals: [{address: "t1s", agent: "claude-code", status: "working", cwd: "/x"}]}' > $STUB_DIR/hc-ls.json
cs check $wt >/dev/null 2>&1; rc=$?
check "refuses while a sub-agent is working" test $rc -ne 0
check "sub-agent: nothing closed" not_did 'space.close'

# A second space in a folder under the checkout is part of it.
newworld subspace; add_space sp-sub $wt/sub tS working
cs check $wt >/dev/null 2>&1; rc=$?
check "refuses while an agent in a subfolder space is working" test $rc -ne 0
check "subfolder space: nothing closed" not_did 'space.close'
newworld subspace-idle; add_space sp-sub $wt/sub tS idle; add_space sp-sibling $wt-other tO working
cs close $wt >/dev/null 2>&1; rc=$?
check "an idle subfolder space is closed with the checkout" did 'space.close {"id":"sp-sub","confirmed":true}'
check "a folder that only shares the prefix is left alone" not_did 'sp-sibling'
check "the checkout's own space closes before the subfolder's" before 'space.close {"id":"sp-wt"' 'space.close {"id":"sp-sub"'
# the caller (HC_TERMINAL_ID=t9) is read once for its own check; every hc call runs without it
check "hc runs without the caller's identity" test "$(grep -c '^hc ' $LOG)" -gt 0 -a "$(grep '^hc ' $LOG | grep -cv ' id=unset scope=unset$')" -eq 0

# Only the checkout's own spaces close. Another space's terminal counts by where it is now.
newworld wandered-out; add_space sp-away $main tA idle; launched_in tA $wt; now_in tA $main
cs close $wt >/dev/null 2>&1; rc=$?
check "a shell launched in the worktree that has cd'd out passes" test $rc -eq 0
check "...and its space is left open" not_did 'sp-away'
check "...while the worktree's own space closes" did 'space.close {"id":"sp-wt","confirmed":true}'

newworld wandered-in; add_space sp-away $main tA idle; launched_in tA $main; now_in tA $wt/src
cs check $wt >$world/out 2>&1; rc=$?
check "refuses a shell launched elsewhere that has cd'd in" test $rc -ne 0
check "the refusal names the terminal" grep -q 'tA' $world/out
check "a foreign space with a terminal inside is not closed" not_did 'sp-away'
check "foreign terminal inside: nothing closed" not_did 'space.close'
jq '.spaces |= map(select(.id != "sp-wt"))' $STUB_LS > $STUB_LS.new; mv $STUB_LS.new $STUB_LS
cs check $wt >/dev/null 2>&1; rc=$?
check "...and refuses when the checkout has no space of its own" test $rc -eq 1

newworld unaskable; print x > $STUB_DIR/fail-t2
cs check $wt >$world/out 2>&1; rc=$?
check "refuses when a terminal of the set cannot be asked about" test $rc -ne 0
check "unaskable: nothing closed" not_did 'space.close'
check "unaskable: the terminal is named" grep -q 't2' $world/out
newworld unaskable-foreign; print x > $STUB_DIR/fail-tNEW1
cs check $wt >$world/out 2>&1; rc=$?
check "another space's terminal that cannot be asked about refuses" test $rc -eq 1
check "...and is named" grep -q 'tNEW1' $world/out
newworld nofolder; print '{"state":"live"}' > $STUB_DIR/get-tNEW1.json
cs check $wt >$world/out 2>&1; rc=$?
check "another space's terminal that answers without a folder refuses" test $rc -eq 1
check "...and is named" grep -q 'tNEW1.*gave no folder' $world/out
# A terminal that answers without a folder is judged by its foreground group: ps gives the group
# in its root's terminal, lsof each member's folder. The caller's own terminal is the one seen
# (wt-rm runs the helper from it, and hc often cannot name that foreground).
newworld group; print '{"state":"live","pid":4242}' > $STUB_DIR/get-t9.json; print 777 > $STUB_DIR/tpgid-4242
print -l "$UID 777" "0 1" "-2 1" > $STUB_DIR/uid-pgid
print -l / $main > $STUB_DIR/lsof-777
cs check $wt >$world/out 2>&1; rc=$?
check "a terminal without a folder passes when its foreground group is outside the checkout" test $rc -eq 0
print -l / $wt/src > $STUB_DIR/lsof-777
cs check $wt >$world/out 2>&1; rc=$?
check "...refuses when one process of that group is inside" test $rc -eq 1
check "...and names the terminal and the folder" grep -qF -- "t9 (proj / retire) is in $wt/src" $world/out
# lsof cannot read another user's process, so a listing that looks clean proves nothing then.
print -l / $main > $STUB_DIR/lsof-777; print "0 777" >> $STUB_DIR/uid-pgid
cs check $wt >$world/out 2>&1; rc=$?
check "...and refuses when another user's process is in the group, whatever lsof listed" test $rc -eq 1
print -l "$UID 777" "0 1" "-2 1" > $STUB_DIR/uid-pgid
rm $STUB_DIR/lsof-777
cs check $wt >$world/out 2>&1; rc=$?
check "...and refuses when the group cannot be read" test $rc -eq 1
# lsof escapes bytes outside printable ASCII, so such a checkout path cannot be matched against its answer.
newworld group-café; print '{"state":"live","pid":4242}' > $STUB_DIR/get-t9.json; print 777 > $STUB_DIR/tpgid-4242
print -l "$UID 777" "0 1" "-2 1" > $STUB_DIR/uid-pgid
print -l / $main > $STUB_DIR/lsof-777
cs check $wt >$world/out 2>&1; rc=$?
check "a checkout path lsof would escape refuses the group read" test $rc -eq 1
# A terminal of the set whose answer shows nothing about its foreground is not vouched for.
newworld empty-answer; print '{}' > $STUB_DIR/get-t2.json
cs check $wt >$world/out 2>&1; rc=$?
check "a terminal of the set that answers {} refuses" test $rc -eq 1
check "...and is named" grep -q 't2.*gave no foreground' $world/out
newworld finished; print '{"state":"finished"}' > $STUB_DIR/get-t2.json
cs check $wt >/dev/null 2>&1; rc=$?
check "a finished terminal, which answers without a foreground, passes" test $rc -eq 0
# Another local space that is not in the shape the traversals rely on is not read around.
newworld malformed-listing; jq '.spaces[2].tabs = null' $STUB_LS > $STUB_LS.new; mv $STUB_LS.new $STUB_LS
cs check $wt >$world/out 2>&1; rc=$?
check "a listing with another local space whose tabs is null refuses" test $rc -eq 1
check "...and says the answer was not in the expected shape" grep -q 'expected shape' $world/out

# Unsaved buffers die with the terminal.
for editor in nvim vim; do
  newworld editor-$editor; print $editor > $STUB_DIR/fg-t2
  cs check $wt >$world/out 2>&1; rc=$?
  check "refuses while $editor is open" test $rc -ne 0
  check "$editor: nothing closed" not_did 'space.close'
  check "$editor: says where it is" grep -q 't2' $world/out
done

# No app: the stub link gone, and a copy of the helper whose pinned PATH lacks /opt/homebrew/bin,
# where Michael's machine has the live herdr-app. The copy is run only once it names no
# /opt/homebrew at all: if the pin line has changed shape, the case fails without running it.
newworld noapp; rm $HOME/.local/bin/herdr-app
sed 's#:/opt/homebrew/bin$##' $bin/checkout-spaces > $world/cs-noapp; chmod +x $world/cs-noapp
if grep -q /opt/homebrew $world/cs-noapp || ! differs $bin/checkout-spaces $world/cs-noapp; then
  check "no app: the test copy drops /opt/homebrew/bin from the pin (not run)" false
else
  check "no app: check passes" $world/cs-noapp check $wt
  check "no app: list is the empty set" test "$($world/cs-noapp list $wt)" = '{"spaces":[],"terminals":[],"records":[]}'
fi

newworld down; export STUB_LS_DOWN=1
cs check $wt >$world/out 2>&1; rc=$?
check "an unreachable app refuses" test $rc -eq 1
check "...and says to open the window" grep -q 'open its window' $world/out
newworld noobject; print '{"error":"no window"}' > $STUB_DIR/ls-raw
cs check $wt >/dev/null 2>&1; rc=$?
check "a listing without spaces refuses" test $rc -eq 1

newworld subagent-unknown
jq '.spaces[0].tabs[0].terminals[0].sub_agents = ["t1s"]' $STUB_LS > $STUB_LS.new; mv $STUB_LS.new $STUB_LS
for how in missing malformed failing; do
  case $how in
    failing) : > $STUB_DIR/hc-ls-fail ;;
    malformed) print '{"terminals":["t1s"]}' > $STUB_DIR/hc-ls.json ;;
    *) print '{"terminals":[]}' > $STUB_DIR/hc-ls.json ;;
  esac
  cs check $wt >/dev/null 2>&1; rc=$?
  check "a sub-agent whose status hc ls does not give refuses ($how)" test $rc -eq 1
done
rm $STUB_DIR/hc-ls-fail; jq -n '{terminals: [{address: "t1s", agent: "claude-code", status: "idle", cwd: "/x"}]}' > $STUB_DIR/hc-ls.json
cs check $wt >/dev/null 2>&1; rc=$?
check "a sub-agent that hc ls lists as idle passes" test $rc -eq 0
check "hc ls runs without the caller's identity too" test "$(grep -c '^hc ls ' $LOG)" -gt 0 -a "$(grep '^hc ' $LOG | grep -cv ' id=unset scope=unset$')" -eq 0

newworld badrecords; print 'not json' > $HERDR_APP_HOME/shared.json
cs close $wt >$world/out 2>$world/err; rc=$?
check "unreadable records still close" test $rc -eq 0
check "...and name the agents without a record" grep -q 't1' $world/err

newworld onerecord; records cid-claude cid-codex; jq 'del(.["resume.sessions"].t2)' $HERDR_APP_HOME/shared.json > $world/sh.new; mv $world/sh.new $HERDR_APP_HOME/shared.json
cs close $wt >$world/out 2>$world/err; rc=$?
check "a readable file lacking an agent's record still closes" test $rc -eq 0
check "...and the warning names only the agent without one" grep -q 'no resume record for codex (t2);' $world/err

newworld stuck; : > $STUB_DIR/stuck-sp-wt
cs close $wt >/dev/null 2>&1; rc=$?
check "a space that survives the close refuses" test $rc -eq 1

newworld closefail; add_space sp-sub $wt/sub tS idle; add_space sp-sub2 $wt/sub2 tS2 idle
: > $STUB_DIR/closefail-sp-sub
cs close $wt >$world/out 2>&1; rc=$?
check "a failed close stops and names" test $rc -eq 1
check "...the space it closed" grep -q 'sp-wt' $world/out
check "...and the one that failed" grep -q 'sp-sub' $world/out
check "...and closes nothing after it" not_did 'space.close {"id":"sp-sub2"'

newworld gone; rm -rf $wt
check "a gone checkout's space closes" cs close $wt
check "...the space made there" did 'space.close {"id":"sp-wt","confirmed":true}'

newworld symlink; ln -s $wt $world/link
jq --arg l $world/link '.spaces[0].folder = $l' $STUB_LS > $STUB_LS.new; mv $STUB_LS.new $STUB_LS
cs close $wt >/dev/null 2>&1
check "symlinked space folder is own" did 'space.close {"id":"sp-wt","confirmed":true}'

newworld shadow; mkdir $world/shadow
for p in herdr-app hc jq; do print -r -- "#!/bin/sh
: > $world/shadow-ran" > $world/shadow/$p; chmod +x $world/shadow/$p; done
PATH=$world/shadow:$PATH cs close $wt >/dev/null 2>&1
check "the helper ignores a caller PATH" test ! -e $world/shadow-ran

# --- retire: success -----------------------------------------------------------------------
newworld ok; export STUB_WTRM_CLOSE=$wt
records cid-claude cid-codex
retire $wt >/dev/null 2>&1; rc=$?
check "success exits 0" test $rc -eq 0
check "closes the space with confirmation" did 'space.close {"id":"sp-wt","confirmed":true}'
check "wt-rm runs in the main checkout with the branch" did "wt-rm cwd=${main:A} args=feat\$"
check "retire closes no space itself before wt-rm" before 'wt-rm ' 'space.close'
check "success closes its own tab" did 'tab.close {"id":"tb-r","confirmed":true}'
check "the own tab closes after wt-rm" before 'wt-rm ' 'tab.close'
check "success does not reopen" not_did 'space.new'

# wt-rm can succeed and still warn (branch kept, files recreated): the tab stays for Enter.
newworld warned; export STUB_WTRM_CLOSE=$wt STUB_WTRM_WARN=1
retire $wt >$world/out 2>&1; rc=$?
check "a warned success exits 0" test $rc -eq 0
check "a warned success keeps its warning on screen" grep -q "not fully merged" $world/out
check "a warned success keeps the tab" not_did 'tab.close'
print | "$bin/retire" $wt >/dev/null 2>&1
check "Enter closes the tab after a warned success" did 'tab.close {"id":"tb-r","confirmed":true}'

# --- retire: failure -----------------------------------------------------------------------
newworld fail; export STUB_WTRM_CLOSE=$wt STUB_WTRM_RC=3
retire $wt >$world/out 2>&1; rc=$?
check "failure exits non-zero" test $rc -ne 0
check "failure keeps wt-rm's output" grep -q STUB-WT-RM-OUTPUT $world/out
check "failure keeps the tab" not_did 'tab.close'
check "failure without Enter does not reopen" not_did 'space.new'
check "retire closes no space itself before wt-rm" before 'wt-rm ' 'space.close'

# Enter reopens, agents resumed from the records read before the close.
newworld reopen; export STUB_WTRM_CLOSE=$wt STUB_WTRM_RC=3
records cid-claude cid-codex
mkdir -p $HOME/.claude/projects/p; : > $HOME/.claude/projects/p/cid-claude.jsonl
export CODEX_HOME=$world/codex; mkdir -p $CODEX_HOME/sessions/2026
: > $CODEX_HOME/sessions/2026/rollout-cid-codex.jsonl
print | "$bin/retire" $wt >$world/out 2>&1; rc=$?
check "reopen: keeps wt-rm's exit status" test $rc -eq 3
check "reopen: a written Claude session is resumed" did 'space.new.*--resume'"'"' '"'"'cid-claude'
check "reopen: a written Codex session is resumed" did "pane.split.*resume.*cid-codex"
check "reopen: the reopened space is made after wt-rm" before 'wt-rm ' 'space.new'

# Every agent's resume command is printed before the close, not just the two reopened.
newworld allcmds; export STUB_WTRM_RC=3
jq '.spaces[0].tabs[0].terminals += [{terminal: "t3", pane: "p3", status: "idle", app: "claude-code", sub_agents: []}]' $STUB_LS > $STUB_LS.new; mv $STUB_LS.new $STUB_LS
records cid-claude cid-codex
jq '."resume.sessions".t3 = {app: "claude", id: "cid-third", cwd: "/x", fresh: "x", cmd: "claude --resume cid-third"}' $HERDR_APP_HOME/shared.json > $HERDR_APP_HOME/s.new; mv $HERDR_APP_HOME/s.new $HERDR_APP_HOME/shared.json
cs close $wt >$world/out 2>&1
check "every agent's resume command is printed" test "$(grep -c -e cid-claude -e cid-codex -e cid-third $world/out)" -eq 3

# A session never written has nothing to resume: that agent starts fresh.
newworld fresh; export STUB_WTRM_CLOSE=$wt STUB_WTRM_RC=3
records cid-claude cid-codex
export CODEX_HOME=$world/codex; mkdir -p $CODEX_HOME/sessions
print | "$bin/retire" $wt >$world/out 2>&1
check "reopen: an unwritten Claude session starts fresh" did "space.new.*--fresh"
check "reopen: an unwritten Claude session is not resumed" not_did "space.new.*--resume"
check "reopen: an unwritten Codex session starts fresh" did "pane.split.*codex.*--fresh"

# The records of a second space, or a subfolder space listed first, never displace the worktree's own.
newworld ownrecords; export STUB_WTRM_CLOSE=$wt STUB_WTRM_RC=3
add_space sp-sub $wt/sub tS idle; add_space sp-away $main tA idle
jq '.spaces |= sort_by(.id != "sp-sub")' $STUB_LS > $STUB_LS.new; mv $STUB_LS.new $STUB_LS
records cid-claude cid-codex
jq '."resume.sessions".tS = {app: "claude", id: "cid-sub", cwd: "/x", fresh: "'"'"'claude'"'"' '"'"'--sub'"'"'", cmd: "sub-cmd"} | ."resume.sessions".tA = {app: "claude", id: "cid-away", cwd: "/x", fresh: "'"'"'claude'"'"' '"'"'--away'"'"'", cmd: "away-cmd"}' $HERDR_APP_HOME/shared.json > $HERDR_APP_HOME/s.new; mv $HERDR_APP_HOME/s.new $HERDR_APP_HOME/shared.json
mkdir -p $HOME/.claude/projects/p; : > $HOME/.claude/projects/p/cid-claude.jsonl
print | "$bin/retire" $wt >$world/out 2>&1
check "reopen takes the worktree's own record, not a subfolder space's" did "space.new.*cid-claude"
check "reopen never takes another space's record" not_did "space.new.*\(sub\|away\)"

# No records at all: open-space's defaults.
newworld norecords; export STUB_WTRM_CLOSE=$wt STUB_WTRM_RC=3
print | "$bin/retire" $wt >$world/out 2>&1
check "reopen without records starts plain claude" did 'space.new.*"argv":\["claude"\]'

newworld listdown; export STUB_LS_DOWN=1
retire $wt >/dev/null 2>&1; rc=$?
check "an unreachable app refuses retire" test $rc -ne 0
check "...before wt-rm runs" not_did 'wt-rm '

newworld refusedearly; export STUB_WTRM_RC=1
print | "$bin/retire" $wt >$world/out 2>&1
check "a wt-rm that closed nothing offers no reopen" not_did 'space.new'
grep -q 'Enter reopens' $world/out; check "...and does not ask" test $? -ne 0

# --- wt-app and open-space --no-focus ------------------------------------------------------
# sp-main is active, so it is what focus must come back to.
newworld focus
mkdir -p $world/hooks
( cd $main && "$bin/wt-app" --no-focus newbranch ) >$world/out 2>&1; rc=$?
check "wt-app --no-focus succeeds" test $rc -eq 0
check "wt-app --no-focus makes the space for the new checkout" did 'space.new.*"folder":"'$world'/repos/proj-newbranch"'
check "wt-app --no-focus made the checkout through wt" test -e $world/repos/proj-newbranch/.git
check "wt-app --no-focus gives focus back to the active space" did 'space.select {"id":"sp-main"}'
check "the focus comes back after the space is made" before 'space.new' 'space.select {"id":"sp-main"}'
check "the focus is the last thing that moves" test "$(grep '^herdr-app do' $LOG | tail -1)" = 'herdr-app do space.select {"id":"sp-main"}'

# run_held <stdin line, or "" for none> <command...> — the command with that line on stdin and
# its output in $world/out, stdin then held open until the command says "Press Enter to close"
# and a moment has passed. Its status comes back, and $world/held exists if it was still running
# when stdin was released: a hold is a blocking read, so a command that does not hold is gone by
# then.
run_held() {
  local line=$1; shift
  rm -f $world/released $world/held; : > $world/out
  ( [[ -z $line ]] || print -r -- "$line"; for i in {1..100}; do grep -q 'Press Enter to close' $world/out && break; sleep 0.1; done
    sleep 0.5; : > $world/released; print ) |
    ( "$@" >$world/out 2>&1; rc=$?; [[ -e $world/released ]] && : > $world/held; exit $rc )
}

# --prompt asks for the branch on stdin. It ends when wt does: a popup closes with it, and a tab
# (the key outside the michael layout) is closed by wt-app itself.
newworld prompt
( cd $main && print newbranch | "$bin/wt-app" --prompt ) >$world/out 2>&1; rc=$?
check "wt-app --prompt succeeds" test $rc -eq 0
check "wt-app --prompt makes the space for the entered branch" did 'space.new.*proj-newbranch'
check "wt-app --prompt closes its own tab" did 'tab.close {"id":"tb-r","confirmed":true}'
check "the tab closes after the space is made" before 'space.new' 'tab.close'
check "wt-app --prompt does not hold the popup open" test -z "$(grep 'Press Enter to close.' $world/out)"

# When wt fails the popup is held open, with the message on screen: a folder where the checkout
# would go that is not a worktree makes wt refuse. The tab stays too, if there is one.
newworld prompt-fails; mkdir $world/repos/proj-junk
( cd $main && run_held junk "$bin/wt-app" --prompt ); rc=$?
check "wt-app --prompt exits non-zero when wt fails" test $rc -ne 0
check "...makes no space" not_did 'space.new'
check "...says to press Enter" grep -q 'Press Enter to close.' $world/out
check "...and was still waiting for it when released" test -e $world/held
check "...and keeps its tab" not_did 'tab.close'

# --prompt is wt-prompt, which has no --no-focus.
newworld prompt-nofocus
( cd $main && "$bin/wt-app" --prompt --no-focus </dev/null ) >$world/out 2>&1; rc=$?
check "wt-app --prompt --no-focus is refused" test $rc -ne 0
check "...with the usage line" grep -q '^usage: wt-app' $world/out
check "...and makes no space" not_did 'space.new'

# --- edit-scrollback ------------------------------------------------------------------------
# The terminal's text goes to Neovim in a temp file, cursor on the last line, and the file goes
# when Neovim does. The screen's trailing blank lines are not part of it.
newworld scrollback
mkdir -p $world/nvim-bin $world/tmp
cat > $world/nvim-bin/nvim <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$STUB_DIR/nvim-args"
cp "$3" "$STUB_DIR/nvim-saw"
echo "$3" > "$STUB_DIR/nvim-file"
exit ${STUB_NVIM_RC:-0}
EOF
chmod +x $world/nvim-bin/nvim
printf 'one\ntwo\n\n\n' > $STUB_DIR/read-t5
PATH=$world/nvim-bin:$PATH TMPDIR=$world/tmp "$bin/edit-scrollback" t5 >$world/out 2>&1; rc=$?
check "edit-scrollback succeeds" test $rc -eq 0
check "edit-scrollback reads the terminal's history" did 'hc read t5 --lines'
check "nvim opens at the last line of a file" test "$(sed -n 1p $STUB_DIR/nvim-args)" = +
check "nvim gets the terminal's text, without the trailing blank lines" test "$(<$STUB_DIR/nvim-saw)" = $'one\ntwo'
check "the temp file is gone afterwards" test ! -e "$(<$STUB_DIR/nvim-file)"
# A failing Neovim holds the popup open, as a failing read does, instead of closing it unread.
run_held "" env STUB_NVIM_RC=3 PATH=$world/nvim-bin:$PATH TMPDIR=$world/tmp "$bin/edit-scrollback" t5; rc=$?
check "edit-scrollback reports a failing nvim" test $rc -eq 1 -a "$(grep -c 'nvim exited 3' $world/out)" -eq 1
check "...and holds the popup open until it is read" test -e $world/held

newworld nofocus-off
( cd $main && "$bin/wt-app" other ) >$world/out 2>&1; rc=$?
check "wt-app without the flag succeeds" test $rc -eq 0
check "wt-app without the flag leaves focus to the new space" not_did 'space.select'

newworld existing
"$bin/open-space" --no-focus $wt >/dev/null 2>&1; rc=$?
check "--no-focus on a folder with a space succeeds" test $rc -eq 0
check "--no-focus does not select the existing space" not_did 'space.select {"id":"sp-wt"}'

newworld existing-focus
"$bin/open-space" $wt >/dev/null 2>&1
check "without the flag an existing space is selected" did 'space.select {"id":"sp-wt"}'

# --- the Codex pane outlives Ctrl+C ----------------------------------------------------------
# A second Ctrl+C to quit Codex can land after Codex has left raw mode, so the signal kills it;
# an interactive shell then drops the rest of its command line, `exec` included, and the pane
# closes. Run the split's own wrapper on a pty around a program killed that way: it must still
# reach the shell it hands over to ($0, here a stand-in that only says so).
# interrupted <pane.split json> <what the wrapper gets after $0...>
interrupted() {
  local -a sh; sh=("${(@f)$(jq -r '.argv[0,1,2]' <<<"$1")}")
  ZDOTDIR=$world/zdot script -q /dev/null "${sh[@]}" $world/after "${@[2,-1]}" </dev/null 2>&1
}
codex_split() { sed -n 's/^herdr-app do pane.split \(.*"argv".*\)$/\1/p' $LOG | head -1 }
ctrlc_world() {
  newworld $1; mkdir -p $world/zdot $world/repos/fresh; : > $world/zdot/.zshrc
  printf '#!/bin/sh\necho SHELL-REACHED\n' > $world/after; chmod +x $world/after
}
typeset -i skipped=0
if script -q /dev/null true </dev/null >/dev/null 2>&1; then
  ctrlc_world ctrlc
  "$bin/open-space" --no-focus $world/repos/fresh >/dev/null 2>&1
  check "the Codex pane survives a Ctrl+C that kills Codex" \
    grep -q SHELL-REACHED <(interrupted "$(codex_split)" 'sh -c "kill -INT \$\$"')
  ctrlc_world ctrlc-cmd
  "$bin/open-space" --no-focus --codex-cmd 'codex resume x' $world/repos/fresh >/dev/null 2>&1
  check "a resumed Codex pane survives a Ctrl+C that kills Codex" \
    grep -q SHELL-REACHED <(interrupted "$(codex_split)" 'sh -c "kill -INT \$\$"')
else
  skipped+=2; print -u2 -- "SKIP: no pseudo-terminal here (sandboxed?), the 2 Ctrl+C cases did not run"
fi

# --- the agents' commands --------------------------------------------------------------------
# Codex runs the TUI's pane command, read from the file the way xreview reads it: the first line
# that is neither a comment nor empty. Nothing of it is kept in open-space.
newworld panecmd
cat > $HOME/.config/herdr/codex-pane-command <<'EOF'
# a comment

  # an indented comment
codex --sandbox workspace-write --model x
codex --second line
EOF
"$bin/open-space" --no-focus $world/repos/fresh >/dev/null 2>&1; rc=$?
check "the pane command is read from the file" test $rc -eq 0
check "the Codex split runs the file's first command line" test "$(jq -r '.argv[4]' <<<"$(codex_split)")" = 'codex --sandbox workspace-write --model x'
check "no Codex split carries --no-daemon" not_did 'no-daemon'
newworld panecmd-xdg; mkdir -p $world/xdg/herdr; print -r -- 'codex --from-xdg' > $world/xdg/herdr/codex-pane-command
XDG_CONFIG_HOME=$world/xdg "$bin/open-space" --no-focus $world/repos/fresh >/dev/null 2>&1
check "the file is looked for under XDG_CONFIG_HOME, as xreview does" test "$(jq -r '.argv[4]' <<<"$(codex_split)")" = 'codex --from-xdg'

# A file that is missing, empty or only comments is no command: refused before the app is asked
# anything, so nothing is half-built.
newworld panecmd-missing; rm $HOME/.config/herdr/codex-pane-command
"$bin/open-space" --no-focus $world/repos/fresh >$world/out 2>&1; rc=$?
check "a missing pane command file is refused" test $rc -ne 0
check "...naming the file" grep -q "$HOME/.config/herdr/codex-pane-command" $world/out
check "...nothing half-built: no tab made either" not_did 'tab.new'
check "...and makes no space" not_did 'space.new'
newworld panecmd-empty; : > $HOME/.config/herdr/codex-pane-command
"$bin/open-space" --no-focus $world/repos/fresh >/dev/null 2>&1; rc=$?
check "an empty pane command file is refused" test $rc -ne 0
check "...and makes no space" not_did 'space.new'
newworld panecmd-comments; printf '# only\n\n# comments\n' > $HOME/.config/herdr/codex-pane-command
"$bin/open-space" --no-focus $world/repos/fresh >/dev/null 2>&1; rc=$?
check "a pane command file of comments is refused" test $rc -ne 0
check "...and makes no space" not_did 'space.new'
# Focusing a space that exists needs no pane command: only making one does.
newworld panecmd-existing; rm $HOME/.config/herdr/codex-pane-command
"$bin/open-space" $wt >/dev/null 2>&1; rc=$?
check "an existing space is focused without the pane command file" test $rc -eq 0
check "...it is selected" did 'space.select {"id":"sp-wt"}'
check "...and nothing is made" not_did 'space.new'
# --pick closes its own tab when it is done, but not on a refusal, which must stay readable.
newworld panecmd-pick; git init -q $world/repos/fresh
( cd $world/repos/fresh && "$bin/open-space" --pick ) >$world/out 2>&1; rc=$?
check "--pick with the pane command file there makes the space" test $rc -eq 0 -a "$(grep -c 'space.new' $LOG)" -eq 1
check "--pick closes its own tab when it has made the space" did 'tab.close {"id":"tb-r","confirmed":true}'
newworld panecmd-pick-missing; git init -q $world/repos/fresh; rm $HOME/.config/herdr/codex-pane-command
( cd $world/repos/fresh && "$bin/open-space" --pick ) >$world/out 2>&1; rc=$?
check "--pick without the pane command file is refused" test $rc -ne 0
check "...naming the file" grep -q "$HOME/.config/herdr/codex-pane-command" $world/out
check "...makes no space" not_did 'space.new'
check "...and leaves its tab open, with the refusal on screen" not_did 'tab.close'
newworld panecmd-pick-existing; rm $HOME/.config/herdr/codex-pane-command
( cd $main && "$bin/open-space" --pick ) >$world/out 2>&1; rc=$?
check "--pick of an existing space needs no pane command file" test $rc -eq 0
check "...and closes its own tab" did 'tab.close {"id":"tb-r","confirmed":true}'

# --codex-cmd names the command itself, so the file is not needed then.
newworld panecmd-given; rm $HOME/.config/herdr/codex-pane-command
"$bin/open-space" --no-focus --codex-cmd 'codex resume x' $world/repos/fresh >/dev/null 2>&1; rc=$?
check "--codex-cmd does not need the pane command file" test $rc -eq 0
check "...and runs that command" test "$(jq -r '.argv[4]' <<<"$(codex_split)")" = 'codex resume x'

# Claude starts as plain claude. claude-app stays only for sessions recorded with its path, and
# passes everything on untouched. claude is a stub on PATH.
newworld claude-app
"$bin/open-space" --no-focus $world/repos/fresh >/dev/null 2>&1
check "the Claude tab starts plain claude" did 'space.new.*"argv":\["claude"\]'
check "...and no tab starts claude-app" not_did '"argv":\["[^"]*claude-app'
: > $LOG; "$bin/claude-app" --x y >/dev/null 2>&1; rc=$?
check "claude-app runs claude" test $rc -eq 0
check "claude-app passes its arguments and adds none" test "$(<$STUB_DIR/claude-argv)" = $'--x\ny'
: > $LOG; "$bin/claude-app" >/dev/null 2>&1
check "claude-app without arguments starts bare claude" test -z "$(<$STUB_DIR/claude-argv)" -a "$(grep -c '^claude-args' $LOG)" -eq 1
# The settings file stays as it was, for the sessions that recorded it; programs.json no longer
# overrides how the app's own menus start Claude.
check "the settings still exclude xreview-app and wt-app by their full paths, with arguments" \
  jq -e --arg c "${bin:h}/bin/xreview-app *" --arg w "${bin:h}/bin/wt-app *" '. == {sandbox: {excludedCommands: [$c, $w]}}' ${bin:h}/claude-settings.json >/dev/null
check "programs.json has no claude override" \
  jq -e '.programs | has("claude") | not' ${bin:h}/programs.json >/dev/null
check "AGENTS.local.md, the notes the app has agents read, reaches the app's folder" test -s ${bin:h}/AGENTS.local.md
check "keys.json binds Cmd+Alt+1…9 to agent.select 1…9" \
  jq -e '[range(1; 10) as $i | .global["cmd-alt-\($i)"] == "agent.select:\($i)"] | all' ${bin:h}/keys.json >/dev/null
check "keys.json binds Ctrl+Cmd+arrows to pane.resize that way" \
  jq -e '[("left", "right", "up", "down") as $d | .global["ctrl-cmd-\($d)"] == "pane.resize:\($d)"] | all' ${bin:h}/keys.json >/dev/null
# A key written twice in one object keeps one of its bindings at most, and jq never says so.
check "keys.json names no key twice in one object" /usr/bin/python3 -I -c '
import json, sys
def once(pairs):
    keys = [k for k, _ in pairs]
    if len(set(keys)) != len(keys): sys.exit(1)
    return dict(pairs)
json.load(open(sys.argv[1]), object_pairs_hook=once)' ${bin:h}/keys.json

# --- the pinned PATH -------------------------------------------------------------------------
# open-space and close-own-tab run unsandboxed after the caller's PATH has served a repository's
# hooks, so a folder first on that PATH (a mise _.path the sandbox can write) must reach neither
# herdr-app nor jq: the trusted stubs are in $HOME/.local/bin, the shadows only touch a marker.
shadowed_world() {
  newworld $1; mkdir -p $world/evil
  local c; for c in herdr-app jq git fzf; do
    printf '#!/bin/sh\ntouch %s/marker\nexit 1\n' $world >| $world/evil/$c; chmod +x $world/evil/$c
  done
  export PATH=$world/evil:$PATH_BASE
}
shadowed_world pinned-open
"$bin/open-space" --no-focus $world/repos/fresh >/dev/null 2>&1; rc=$?
check "open-space succeeds with herdr-app and jq shadowed on the caller's PATH" test $rc -eq 0
check "...and made the space through the trusted herdr-app" did 'space.new'
check "...and split the Codex pane" did 'pane.split'
check "...and never ran a shadow" test ! -e $world/marker
shadowed_world pinned-pick; PATH=$PATH_BASE git init -q $world/repos/fresh
( cd $world/repos/fresh && "$bin/open-space" --pick ) >/dev/null 2>&1; rc=$?
check "open-space --pick succeeds with herdr-app, jq, git and fzf shadowed on the caller's PATH" test $rc -eq 0
check "...made the space and closed its own tab" test "$(grep -c 'space.new' $LOG)" -eq 1 -a "$(grep -c 'tab.close' $LOG)" -eq 1
check "...and never ran a shadow" test ! -e $world/marker
shadowed_world pinned-close
"$bin/close-own-tab" >/dev/null 2>&1; rc=$?
check "close-own-tab succeeds with herdr-app and jq shadowed on the caller's PATH" test $rc -eq 0
check "...and closed the tab through the trusted herdr-app" did 'tab.close {"id":"tb-r","confirmed":true}'
check "...and never ran a shadow" test ! -e $world/marker

# --- the helpers -----------------------------------------------------------------------------
newworld helpers
check "session-written: a Claude transcript on disk" test "$(mkdir -p $HOME/.claude/projects/p && : > $HOME/.claude/projects/p/sid.jsonl && $bin/session-written claude sid; print $?)" = 0
check "session-written: no Claude transcript" test "$($bin/session-written claude other; print $?)" = 1
export CODEX_HOME=$world/codex; mkdir -p $CODEX_HOME/sessions/d; : > $CODEX_HOME/sessions/d/rollout-xid.jsonl
check "session-written: a Codex transcript on disk" test "$($bin/session-written codex xid; print $?)" = 0
check "session-written: no Codex transcript" test "$($bin/session-written codex nope; print $?)" = 1
check "session-written: an unknown agent has none" test "$($bin/session-written pi sid; print $?)" = 1

mkdir -p $world/fg/locked/inner; chmod 000 $world/fg/locked
$bin/folder-gone $world/fg/absent; rc_absent=$?
$bin/folder-gone $world/fg; rc_there=$?
$bin/folder-gone $world/fg/locked/inner; rc_unknown=$?
chmod 755 $world/fg/locked
check "folder-gone: an absent folder is gone" test $rc_absent -eq 0
check "folder-gone: a present folder is not" test $rc_there -eq 1
check "folder-gone: an unreadable parent is unknown, not gone" test $rc_unknown -eq 2

# --- respaces ------------------------------------------------------------------------------
# The edits, against copies of the shipped mods' main.js (Herdr's own, read-only here). They need
# the installed app's mods; on a machine without them the 21 checks are skipped, not failed.
if [[ -f $shipped/menu/main.js && -f $shipped/spaces/main.js ]]; then
for mod in menu spaces; do
  newworld patch-$mod; d=$world/$mod; mkdir -p $d; cp $shipped/$mod/main.js $d/main.js
  $bin/patch-mod $mod $d >/dev/null 2>&1; rc=$?
  check "patch-mod $mod applies to the shipped mod" test $rc -eq 0
  check "patch-mod $mod changed it" differs $shipped/$mod/main.js $d/main.js
done
anchor='} from "herdr";'
newworld patch-missing; d=$world/spaces; mkdir -p $d; grep -v -F "$anchor" $shipped/spaces/main.js > $d/main.js
$bin/patch-mod spaces $d >$world/out 2>&1; rc=$?
check "patch-mod stops when an anchor is missing" test $rc -ne 0
check "a missing anchor leaves the clone unpatched" cmp -s $d/main.js <(grep -v -F "$anchor" $shipped/spaces/main.js)
check "a missing anchor is reported as matching 0 times" grep -q 'matches 0 times' $world/out
newworld patch-twice; d=$world/spaces; mkdir -p $d; { cat $shipped/spaces/main.js; print -r -- "$anchor"; } > $d/main.js
$bin/patch-mod spaces $d >$world/out 2>&1; rc=$?
check "patch-mod stops when an anchor matches twice" test $rc -ne 0
check "a duplicated anchor leaves the clone unpatched" cmp -s $d/main.js <({ cat $shipped/spaces/main.js; print -r -- "$anchor"; })
check "a duplicated anchor is reported as matching 2 times" grep -q 'matches 2 times' $world/out
# rows.tail copies the mod's gitTail; a change of one character there must stop respaces.
newworld patch-gittail; d=$world/spaces; mkdir -p $d
sed 's/\.min_w(where ? SIDE_MIN : 0)/.min_w(where ? SIDE_MIN : 1)/' $shipped/spaces/main.js > $d/main.js
check "the gitTail case differs from the shipped mod by that one line" test "$(diff $shipped/spaces/main.js $d/main.js | grep -c '^>')" -eq 1
cp $d/main.js $world/changed.js
$bin/patch-mod spaces $d >$world/out 2>&1; rc=$?
check "patch-mod stops when Herdr's gitTail changed" test $rc -ne 0
check "a changed gitTail leaves the clone unpatched" cmp -s $d/main.js $world/changed.js
check "a changed gitTail is reported as a digest mismatch, naming rows.tail and the new digest" grep -q 'gitTail changed.*sha256 [0-9a-f]\{64\}.*rows\.tail.*set GITTAIL_SHA256' $world/out
# The method must also be found exactly once for its digest to mean anything.
sig='  gitTail(g, tree, name, t) {'
newworld patch-nogittail; d=$world/spaces; mkdir -p $d; grep -v -F "$sig" $shipped/spaces/main.js > $d/main.js
$bin/patch-mod spaces $d >$world/out 2>&1; rc=$?
check "patch-mod stops when gitTail is missing" test $rc -ne 0
check "a missing gitTail leaves the clone unpatched" cmp -s $d/main.js <(grep -v -F "$sig" $shipped/spaces/main.js)
check "a missing gitTail is reported as found 0 times, naming rows.tail" grep -q 'gitTail: its signature line is found 0 times.*rows\.tail' $world/out
newworld patch-twogittail; d=$world/spaces; mkdir -p $d
{ cat $shipped/spaces/main.js; awk -v s="$sig" '$0 == s { on = 1 } on { print } on && $0 == "  }" { exit }' $shipped/spaces/main.js; } > $d/main.js
cp $d/main.js $world/twice.js
check "the two-gitTail case holds the signature twice" test "$(grep -c -F "$sig" $d/main.js)" -eq 2
$bin/patch-mod spaces $d >$world/out 2>&1; rc=$?
check "patch-mod stops when gitTail is present twice" test $rc -ne 0
check "a duplicated gitTail leaves the clone unpatched" cmp -s $d/main.js $world/twice.js
check "a duplicated gitTail is reported as found 2 times, naming rows.tail" grep -q 'gitTail: its signature line is found 2 times.*rows\.tail' $world/out
else
  skipped+=21; print -u2 -- "SKIP: no installed Herdr app mods in $shipped; the 21 patch-mod checks did not run"
fi

# --- rows.js, phases.js and the usage mod: what the spaces pane draws, what waits while hidden ----
# Run headless under JavaScriptCore (the runtime herdr-app-resume uses): the modules' imports are
# pointed at fixtures/herdr-app/rows-stubs.js in a scratch copy, so the sources stay as they ship.
# Each test prints PASS/FAIL lines, counted here.
jsc=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
for f in $SRC/dot_config/herdr-app/patches/{phases,rows}.js $SRC/dot_config/herdr-app/mods/usage/main.js \
         $here/fixtures/herdr-app/{rows.test,hidden.test,rows-stubs}.js; do
  [[ -f $f ]] || { print -u2 -- "missing ${f#$SRC/}"; exit 2 }
done
if [[ -x $jsc ]]; then
  d=$root/rows-js; mkdir -p $d
  stubbed() { sed -e 's|from "gpui-kit"|from "./rows-stubs.js"|' -e 's|from "gpui-base"|from "./rows-stubs.js"|' -e 's|from "herdr"|from "./rows-stubs.js"|' $1 }
  stubbed $SRC/dot_config/herdr-app/patches/phases.js > $d/phases.js
  stubbed $SRC/dot_config/herdr-app/patches/rows.js > $d/rows.js
  stubbed $SRC/dot_config/herdr-app/mods/usage/main.js > $d/usage.js
  cp $here/fixtures/herdr-app/{rows.test,hidden.test,rows-stubs}.js $d/
  check "rows.js, phases.js and the usage mod import only what the stubs stand in for" \
    test -z "$(grep -h '^import .* from "[^.]' $d/phases.js $d/rows.js $d/usage.js)"
  for t in rows hidden; do
    js_out=$($jsc -m $d/$t.test.js 2>&1); js_rc=$?
    print -r -- $js_out
    js_pass=$(print -r -- $js_out | grep -c '^  PASS:'); js_fail=$(print -r -- $js_out | grep -c '^  FAIL:')
    (( passed += js_pass, total += js_pass + js_fail ))
    check "the $t test ran cleanly (jsc exit $js_rc, $((js_pass + js_fail)) assertions)" test $js_rc -eq 0 -a $((js_pass + js_fail)) -gt 0
  done
else
  skipped+=3; print -u2 -- "SKIP: no jsc here; the rows, phases and usage checks did not run"
fi

# With the window closed nothing may be moved: the old clone would be gone and the new one
# never made.
newworld respaces-down; mkdir -p $HERDR_APP_HOME/mods/michael-spaces; : > $HERDR_APP_HOME/mods/michael-spaces/marker
export STUB_DOWN=1
"$bin/respaces" >/dev/null 2>&1; rc=$?
check "respaces stops when the app is not reachable" test $rc -ne 0
check "respaces leaves the old clone in place" test -e $HERDR_APP_HOME/mods/michael-spaces/marker
check "respaces makes no clone when the app is not reachable" not_did 'mod.clone'

# A second run races the first on mv and mod.clone: it must stop before moving anything. The
# lock is held by this subshell's own open file, which respaces' child cannot inherit.
newworld respaces-locked; mkdir -p $HERDR_APP_HOME/mods/michael-spaces; : > $HERDR_APP_HOME/mods/michael-spaces/marker
touch $HERDR_APP_HOME/.respaces.lock
( zmodload zsh/system && zsystem flock -t 0 $HERDR_APP_HOME/.respaces.lock && "$bin/respaces" >/dev/null 2>&1 ); rc=$?
check "respaces stops when another run holds the lock" test $rc -ne 0
check "respaces leaves the old clone in place when locked" test -e $HERDR_APP_HOME/mods/michael-spaces/marker
check "respaces makes no clone when locked" not_did 'mod.clone'

# --- the allowlist: what chezmoi add leaves alone --------------------------------------------
# The app writes its own state beside the files the repository manages, and its shipped mods sit
# in mods/. `chezmoi add` of any of them must add nothing to the source, and of the whole folder
# only a script that is new. Each case has a source made the way the render's is, and a home
# holding what the app writes. No templated target is in it (keys.json, ...): `chezmoi add` of
# one stops at a prompt about removing the template attribute. Every add reads /dev/null, so an
# unexpected prompt fails instead of waiting.
allow_world() { # <name>: sets $a (the case's folder) and $app (the app's folder in its home)
  a=$root/allow-$1; app=$a/home/.config/herdr-app
  herdr_app_source $a || return
  mkdir -p $app/data/x $app/layouts/.state $app/mods/{michael-spaces,spaces,nav} $app/bin || return
  print '{}' > $app/view.json; print '{}' > $app/shared.json; print '{}' > $app/data/x/s.json
  print '{}' > $app/layouts/.state/michael.json
  print '// clone' > $app/mods/michael-spaces/main.js; print '// shipped' > $app/mods/spaces/main.js
  print '// types' > $app/mods/nav/gpui-kit.d.ts; print '{}' > $app/mods/nav/jsconfig.json
  print -r -- $'#!/bin/sh\nexit 0' > $app/bin/new-script; chmod 755 $app/bin/new-script
  # The managed files that sit beside the ignored ones, as they are deployed. Without them a
  # folder holding only ignored files (layouts/, mods/nav) gets a .keep in the source.
  cp $SRC/dot_config/herdr-app/layouts/michael.json $app/layouts/michael.json || return
  cp $SRC/dot_config/herdr-app/mods/nav/mod.json $app/mods/nav/mod.json
}
source_files() { find $a/src -type f | sort }
chezmoi_add() { herdr_app_chezmoi $a add "$1" </dev/null >$a/out 2>&1 }
for p in view.json shared.json data layouts/.state mods/michael-spaces mods/spaces mods/nav/gpui-kit.d.ts mods/nav/jsconfig.json; do
  allow_world ${p//\//_} || { print -u2 -- "INCONCLUSIVE: no scratch source for the allowlist cases"; exit 2 }
  before=$(source_files); chezmoi_add $app/$p
  check "chezmoi add of $p adds nothing" test "$(source_files)" = "$before"
done
allow_world tree || { print -u2 -- "INCONCLUSIVE: no scratch source for the allowlist cases"; exit 2 }
before=$(source_files); chezmoi_add $app
check "chezmoi add of the whole tree adds no runtime or shipped file, only the new script" \
  test "$(source_files | grep -vxF -f <(print -r -- $before))" = $a/src/dot_config/herdr-app/bin/executable_new-script

print -- "$passed/$total passed"
(( skipped == 0 )) || print -- "$skipped skipped"
(( passed == total ))
