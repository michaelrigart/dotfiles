#!/usr/bin/env zsh
# Mocked test for dev/layout.sh — Herdr's shell surface.
#
#   A  dev            repo resolution cascade
#   B  dev            the linked-worktree guard
#   C  layout.sh       bootstrap: server probe and readiness
#   D  layout.sh       identity: lock-before-scan, path matching, ambiguity
#   E  layout.sh       existing workspaces: focus, add missing tabs
#   F  layout.sh       malformed responses; empty responses and the error envelope
#   G  layout.sh       build: construction sequence, explicit IDs, trap
#   J  tab-goto.sh     label resolution
#   N  layout.sh       --make-tab: the lazy editor tab
#
# herdr is stubbed on PATH and every invocation is logged, so tests can assert on
# ordering and — for malformed workspaces — on the ABSENCE of mutation. Git is NOT
# stubbed: real repos are used, because git's own answers about worktrees are part of
# what is under test.
#
# Run: ./tests/dev.test.sh
set -u
# zsh sets BG_NICE by default, so backgrounding the D10 and N13 lock holders tries to renice it
# and prints "nice(5) failed" wherever setpriority is denied. Same reason layout.sh
# sets it: environment-dependent noise that obscures real failures.
setopt no_bg_nice

ROOT="$(cd "${0:h}/.." && pwd)"
FUNCS="$ROOT/dot_config/zsh/functions"
LAYOUT="$ROOT/dot_config/herdr/executable_layout.sh"
TABGOTO="$ROOT/dot_config/herdr/executable_tab-goto.sh"
CONFIG="$ROOT/dot_config/herdr/config.toml"
SMART_SPLITS="$ROOT/dot_config/nvim/lua/plugins/smart-splits.lua"
[[ -r "$FUNCS" ]] || { print -ru2 -- "cannot read $FUNCS"; exit 1 }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

pass=0 fail=0 OUT="" RC=0
_pass() { print -r -- "  PASS: $1"; pass=$((pass + 1)) }
_fail() { print -r -- "  FAIL: $1"; print -r -- "$OUT" | sed 's/^/    | /'; fail=$((fail + 1)) }
has()      { [[ "$OUT" == *"$1"* ]] && _pass "$2" || _fail "$2" }
hasnt()    { [[ "$OUT" == *"$1"* ]] && _fail "$2" || _pass "$2" }
rc_is()    { [[ "$RC" == "$1" ]] && _pass "$2" || _fail "$2 (rc=$RC)" }
eq()       { [[ "$1" == "$2" ]] && _pass "$3" || _fail "$3 ('$1' != '$2')" }
logged()   { [[ "$(<$HLOG)" == *"$1"* ]] && _pass "$2" || _fail "$2" }
unlogged() { [[ "$(<$HLOG)" == *"$1"* ]] && _fail "$2" || _pass "$2" }
# Count exact-match invocation lines — presence alone cannot catch a duplicate.
# grep -c prints "0" *and* exits 1 on no match, so `|| print 0` would emit two zeroes
# and every count comparison would silently compare against "0\n0".
count_logged() { grep -Fxc -- "$1" "$HLOG" 2>/dev/null | head -1 }

TMPROOT="${TMPDIR:-/tmp}"
mkd() { mktemp -d "${TMPROOT%/}/dev-test.XXXXXX" }
STUBS=$(mkd)
# layout.sh derives its lock path from XDG_STATE_HOME, which zshenv exports to the
# REAL ~/.local/state — so without this every run littered the user's state directory
# with lock files named after long-gone fixture temp dirs, and a test that tried to
# contend the lock silently locked a different file.
XDGSTATE=$(mkd)
export XDG_STATE_HOME="$XDGSTATE"
trap 'rm -rf "$STUBS" "$XDGSTATE" "${ROOTTMP:-}"' EXIT

# --- herdr stub -------------------------------------------------------------
# Returns JSON from MOCK_* variables so tests control what the server "contains".
# Deliberately returns NON-sequential ids (w7, w7:t4, w7:p3) so any code that
# predicts w1/w1:p1 instead of parsing fails loudly.
cat > "$STUBS/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HLOG"
# Defaults are plain assignments, NOT ${VAR:-{...}}: a brace inside a :- default ends
# the expansion early in bash and the remaining "}}" leaks into stdout, appending two
# stray braces to otherwise-valid JSON. jq still extracts the right value while
# printing a parse error, so it corrupts quietly.
: "${MOCK_WS_LIST:=}"; : "${MOCK_PANE_LIST:=}"; : "${MOCK_TAB_LIST:=}"
[ -z "$MOCK_WS_LIST" ]   && MOCK_WS_LIST='{"result":{"workspaces":[]}}'
[ -z "$MOCK_PANE_LIST" ] && MOCK_PANE_LIST='{"result":{"panes":[]}}'
[ -z "$MOCK_TAB_LIST" ]  && MOCK_TAB_LIST='{"result":{"tabs":[]}}'
DEF_WS_CREATE='{"result":{"workspace":{"workspace_id":"w7"},"tab":{"tab_id":"w7:t4"},"root_pane":{"pane_id":"w7:p3"}}}'
# Forcing a genuinely empty response needs its own knob: setting MOCK_*_LIST=""
# hits the defaults above and yields valid JSON instead, so the empty-response path
# could not be reached from a fixture at all.
if [ -n "${MOCK_EMPTY_FOR:-}" ]; then
  case "$*" in "$MOCK_EMPTY_FOR"*) exit 0 ;; esac
fi
case "$*" in
  "status server"|"status")
    printf '%s\n' "${MOCK_STATUS:-server:
  status: not running}" ;;
  "server")
    # Starting the server makes subsequent probes succeed, so the bootstrap is tested
    # as the state transition it actually is rather than as two frozen states.
    # MOCK_SERVER_NEVER_READY models a server that starts but never answers, which is
    # what the timeout path needs.
    [ -z "${MOCK_SERVER_NEVER_READY:-}" ] && : > "$MOCK_SERVER_STARTED_FILE"
    exit 0 ;;
  "workspace list")
    if [ "${MOCK_SERVER_UP:-1}" = "0" ] && \
       { [ -z "${MOCK_SERVER_STARTED_FILE:-}" ] || [ ! -e "$MOCK_SERVER_STARTED_FILE" ]; }; then
      printf '%s' '{"error":{"code":"server_not_running","message":"no herdr server"}}'
      exit 1
    fi
    printf '%s' "$MOCK_WS_LIST" ;;
  "pane list"*)    printf '%s' "$MOCK_PANE_LIST" ;;
  "tab list"*)
    # Stateful when MOCK_TAB_STATE_FILE is set: `tab create` appends there and this
    # merges it in, so one process can observe what another just created. A static list
    # makes every concurrency fixture unfalsifiable — both racers see absence forever.
    if [ -n "${MOCK_TAB_STATE_FILE:-}" ] && [ -s "$MOCK_TAB_STATE_FILE" ]; then
      extra=$(tr -d '\n' < "$MOCK_TAB_STATE_FILE" | sed 's/,$//')
      printf '%s' "$MOCK_TAB_LIST" | sed "s/\"tabs\":\[/\"tabs\":[$extra,/; s/,\]}}\$/]}}/"
    else
      printf '%s' "$MOCK_TAB_LIST"
    fi ;;
  "workspace focus"*) exit "${MOCK_FOCUS_RC:-0}" ;;
  "tab focus"*)
    # Exit status AND payload: this CLI returns an error envelope with status 0 (see
    # F1d), so a focus that only checks $? cannot be told from one that works.
    [ -n "${MOCK_TAB_FOCUS_JSON:-}" ] && printf '%s' "$MOCK_TAB_FOCUS_JSON"
    exit "${MOCK_TAB_FOCUS_RC:-0}" ;;
  "pane run"*)        exit "${MOCK_PANE_RUN_RC:-0}" ;;
  "workspace create"*)
    exit_rc="${MOCK_WS_CREATE_RC:-0}"; [ "$exit_rc" != 0 ] && exit "$exit_rc"
    printf '%s' "${MOCK_WS_CREATE_JSON:-$DEF_WS_CREATE}" ;;
  "worktree open"*)
    printf '%s' "$MOCK_WORKTREE_OPEN_JSON" ;;
  "tab create"*)
    # The counter lives in a FILE, not a variable: the stub is a separate process per
    # call, so an exported variable could never advance and every tab would come back
    # with identical ids — a fixture that hides exactly the id-reuse bug it should catch.
    n=$(( $(cat "$MOCK_TAB_SEQ_FILE" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$MOCK_TAB_SEQ_FILE"
    if [ -n "${MOCK_TAB_CREATE_FAIL_AT:-}" ] && [ "$n" = "$MOCK_TAB_CREATE_FAIL_AT" ]; then
      printf '%s' '{"error":{"code":"internal","message":"boom"}}' >&2; exit 1
    fi
    # The tab id is what --make-tab hands back to be focused, so a response without
    # one has to be reachable from a fixture.
    if [ -n "${MOCK_TAB_CREATE_NO_TAB_ID:-}" ]; then
      printf '%s' "{\"result\":{\"tab\":{},\"root_pane\":{\"pane_id\":\"w7:p$((n+3))\"}}}"
      exit 0
    fi
    # The other half of the same window: a usable tab id, no usable pane id. The tab
    # exists on the server either way, so both shapes have to be reachable.
    if [ -n "${MOCK_TAB_CREATE_NO_PANE_ID:-}" ]; then
      printf '%s' "{\"result\":{\"tab\":{\"tab_id\":\"w7:t$((n+4))\"},\"root_pane\":{}}}"
      exit 0
    fi
    if [ -n "${MOCK_TAB_STATE_FILE:-}" ]; then
      lbl=""; prev=""
      for a in "$@"; do [ "$prev" = "--label" ] && lbl="$a"; prev="$a"; done
      printf '{"tab_id":"w7:t%s","label":"%s"},' "$((n+4))" "$lbl" >> "$MOCK_TAB_STATE_FILE"
    fi
    printf '%s' "{\"result\":{\"tab\":{\"tab_id\":\"w7:t$((n+4))\"},\"root_pane\":{\"pane_id\":\"w7:p$((n+3))\"}}}" ;;
  "pane split"*)   printf '%s' '{"result":{"pane":{"pane_id":"w7:p9"}}}' ;;
  "pane layout"*)
    # Direction is per-pane, looked up in a map file the fixture writes: "<pane> <dir>"
    # per line. A map beats an env var because the stub is a separate process and the
    # answer differs per tab — agents is split right, runtime down.
    # Walk argv for --pane. NOT "${*##*--pane }": on $* bash applies the pattern to
    # each positional parameter rather than the joined string, so the id never
    # extracted, every lookup missed, and the direction check silently always passed.
    pid=""; prev=""
    for a in "$@"; do [ "$prev" = "--pane" ] && pid="$a"; prev="$a"; done
    # LAST match wins: mock_topology writes the healthy defaults, then a test appends
    # mock_split_dir to override one pane. First-match-wins would ignore the override
    # and quietly turn the wrong-direction test into one that can never detect it.
    dir=$(awk -v p="$pid" '$1==p {d=$2} END {print d}' "${MOCK_LAYOUT_FILE:-/dev/null}" 2>/dev/null)
    # Mirrors the real envelope: the snapshot sits under .result.layout, not
    # .result. Getting this wrong is invisible to a mocked suite — it just validates
    # whatever shape the stub invents.
    printf '{"result":{"layout":{"splits":[{"direction":"%s"}]}}}' "${dir:-right}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUBS/herdr"
export PATH="$STUBS:$PATH"

mock_reset() {
  export HLOG="$(mktemp "${TMPROOT%/}/hlog.XXXXXX")"
  export MOCK_SERVER_UP=1 MOCK_WS_LIST='{"result":{"workspaces":[]}}'
  export MOCK_PANE_LIST='{"result":{"panes":[]}}'
  export MOCK_TAB_LIST='{"result":{"tabs":[]}}'
  export MOCK_LAYOUT_FILE="$(mktemp "${TMPROOT%/}/layout.XXXXXX")"
  export MOCK_WS_CREATE_RC=0 MOCK_FOCUS_RC=0 MOCK_TAB_FOCUS_RC=0
  # Created here rather than in each test: building the path inside an eval'd setup
  # string needs three levels of quoting, and getting it wrong leaves the variable
  # empty, the marker unwritten, and the failure looking like a broken timeout.
  export MOCK_SERVER_STARTED_FILE="$(mktemp "${TMPROOT%/}/started.XXXXXX")"
  rm -f "$MOCK_SERVER_STARTED_FILE"
  unset MOCK_SERVER_NEVER_READY MOCK_EMPTY_FOR MOCK_WS_CREATE_JSON MOCK_WS_ID \
        MOCK_WORKTREE_OPEN_JSON
  export MOCK_TAB_SEQ_FILE="$(mktemp "${TMPROOT%/}/tabseq.XXXXXX")"; print -n 0 > "$MOCK_TAB_SEQ_FILE"
  unset MOCK_TAB_CREATE_FAIL_AT MOCK_STATUS MOCK_TAB_CREATE_NO_TAB_ID \
        MOCK_PANE_RUN_RC MOCK_TAB_FOCUS_JSON MOCK_TAB_STATE_FILE \
        MOCK_TAB_CREATE_NO_PANE_ID
  # The HL_* knobs are exported by individual tests and would otherwise leak into
  # every later one — HL_READY_TRIES=2 from a timeout test silently shortening an
  # unrelated bootstrap, for instance, which is how C4 first failed.
  unset HL_READY_TRIES HL_TRACE_LOCK HL_LOCK_DELAY HL_SCAN_DELAY
}

# Shape helpers. Keep them tiny and literal — a clever fixture builder is one more
# thing that can be wrong in a way the tests cannot see.
mock_workspace() {  # <id> <label>
  export MOCK_WS_LIST="{\"result\":{\"workspaces\":[{\"workspace_id\":\"$1\",\"label\":\"$2\"}]}}"
}
mock_panes() {      # <cwd>  — one pane in workspace w7, that cwd
  export MOCK_PANE_LIST="{\"result\":{\"panes\":[{\"pane_id\":\"w7:p3\",\"tab_id\":\"w7:t4\",\"workspace_id\":\"w7\",\"cwd\":\"$1\"}]}}"
}
mock_tabs() {       # <label>...  — tabs w7:t1.. with the given labels, no panes
  local i=1 out="" ; for l in "$@"; do
    [[ -n "$out" ]] && out+=","
    out+="{\"tab_id\":\"w7:t$i\",\"label\":\"$l\"}"; i=$((i+1))
  done
  export MOCK_TAB_LIST="{\"result\":{\"tabs\":[$out]}}"
}

# mock_topology <cwd> <label> <tab:panecount>...
# Tabs, panes and the workspace label in ONE call. Setting them separately is how the
# fixtures drifted: a workspace with every managed tab and zero panes is not healthy,
# it is malformed, and separate helpers made correct code look broken.
# The workspace id is parameterised (MOCK_WS_ID, default w7) so a fixture's
# pre-existing workspace can be told apart from one the code creates — the stub's
# `workspace create` also answers w7, which made "the other workspace is not focused"
# unfalsifiable once build started focusing its own result.
mock_topology() {
  local cwd="$1" label="$2"; shift 2
  local w="${MOCK_WS_ID:-w7}"
  local i=1 pn=1 tabs="" panes="" spec name n k
  for spec in "$@"; do
    name="${spec%%:*}"; n="${spec##*:}"
    [[ -n "$tabs" ]] && tabs+=","
    # ${w}, braced: zsh reads a bare "$w:t" as the :t (tail) history modifier, so this
    # quietly emitted "w72" where the server returns "w7:t2". Pane ids escaped it only
    # because :p is not a modifier. Nothing asserted on a tab id from here until
    # --make-tab started printing one back, which is how it survived this long.
    tabs+="{\"tab_id\":\"${w}:t$i\",\"label\":\"$name\"}"
    k=1
    while (( k <= n )); do
      [[ -n "$panes" ]] && panes+=","
      panes+="{\"pane_id\":\"${w}:p$pn\",\"tab_id\":\"${w}:t$i\",\"workspace_id\":\"$w\",\"cwd\":\"$cwd\"}"
      # The direction the baseline expects for this label, so a healthy fixture is
      # healthy without every test restating its geometry.
      case "$name" in
        runtime) print -r -- "$w:p$pn down"  >> "$MOCK_LAYOUT_FILE" ;;
        *)       print -r -- "$w:p$pn right" >> "$MOCK_LAYOUT_FILE" ;;
      esac
      (( pn++ )); (( k++ ))
    done
    (( i++ ))
  done
  export MOCK_TAB_LIST="{\"result\":{\"tabs\":[$tabs]}}"
  export MOCK_PANE_LIST="{\"result\":{\"panes\":[$panes]}}"
  export MOCK_WS_LIST="{\"result\":{\"workspaces\":[{\"workspace_id\":\"$w\",\"label\":\"$label\"}]}}"
}

# mock_split_dir <pane_id> <right|down> — override one pane's split direction, so a
# test can make exactly one managed tab wrong and leave the rest healthy.
mock_split_dir() { print -r -- "$1 $2" >> "$MOCK_LAYOUT_FILE" }

# The complete, healthy baseline — the shape every "good workspace" test starts from.
# The editor tab is LAZY: alt+e creates it on demand, so a healthy space carries only
# the eager tabs. FULL_EDITOR is the same space after alt+e has been pressed once —
# also healthy, which is the whole point of the split.
FULL=(agents:2 runtime:2)
FULL_EDITOR=(agents:2 editor:1 runtime:2)

mkrepo() {  # <path> — a real git repo
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" commit -q --allow-empty -m init
  print -r -- "${1:A}"
}

print -r -- "=== dev test suite ==="
mock_reset

# --- summary ----------------------------------------------------------------
# Defined NOW, not in the last task. Without it Tasks 3-7 exit 0 while assertions
# fail, and each of those tasks commits green on a suite that never gated anything.
# Every later task inserts its section ABOVE this block.
finish() {
  print -r -- ""
  print -r -- "=== $pass passed, $fail failed ==="
  (( fail == 0 ))
}
# --- A: resolution ----------------------------------------------------------
print -r -- "-- A: dev resolution"
ROOTTMP=$(mkd); CODE="$ROOTTMP/Code"
R1=$(mkrepo "$CODE/Netronix/curato")
R2=$(mkrepo "$CODE/ViuMore/curato")     # same basename, different org
mkdir -p "$ROOTTMP/notrepo"

# Stub layout.sh: record every argument it was handed, do nothing else.
LSTUB="$STUBS/layout.sh"
cat > "$LSTUB" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$LAYOUT_ARG"
S
chmod +x "$LSTUB"

# fzf declines (exit 1), so an ambiguous name must resolve to nothing.
# Declines by default; MOCK_FZF_SELECT makes it choose, so both the cancel and the
# select path are covered. Cancellation alone would let an implementation that always
# bails after fzf pass every assertion.
cat > "$STUBS/fzf" <<'S'
#!/usr/bin/env bash
printf '%s\n' "fzf-invoked" >> "$FZFLOG"
[ -n "${MOCK_FZF_SELECT:-}" ] && { printf '%s\n' "$MOCK_FZF_SELECT"; exit 0; }
exit 1
S
chmod +x "$STUBS/fzf"

run_dev() {
  mock_reset
  export LAYOUT_ARG="$(mktemp "${TMPROOT%/}/larg.XXXXXX")"
  export FZFLOG="$(mktemp "${TMPROOT%/}/fzflog.XXXXXX")"
  OUT="$(HOME="$ROOTTMP" DEV_LAYOUT="$LSTUB" zsh -c "
    source '$FUNCS'; dev $1" 2>&1)"; RC=$?
}

run_dev "'$R1'"
eq "$(<$LAYOUT_ARG)" "$R1" "A1 explicit path resolves to that repo"

run_dev "Netronix/curato"
eq "$(<$LAYOUT_ARG)" "$R1" "A2 path relative to ~/Code resolves"

run_dev "'$ROOTTMP/notrepo'"
rc_is 1 "A3 a non-repo directory fails"
has "not inside a git repo" "A3 says why"
eq "$(<$LAYOUT_ARG)" "" "A3 layout.sh is never invoked"

# Ambiguity must reach the picker, never silently pick one.
run_dev "curato"
eq "$(<$LAYOUT_ARG)" "" "A4 an ambiguous basename resolves to nothing"
[[ -s "$FZFLOG" ]] && _pass "A4 the picker is consulted" || _fail "A4 the picker was never invoked"

# The other half: when the picker DOES choose, that choice must be honoured.
MOCK_FZF_SELECT="ViuMore/curato" run_dev "curato"
eq "$(<$LAYOUT_ARG)" "$R2" "A5 a picker selection resolves to the chosen repo"

# --- B: linked worktrees route through Herdr's native worktree mode ---------
print -r -- "-- B: linked worktree routing"
WT="$CODE/Netronix/curato-feature"
git -C "$R1" worktree add -q -b feature "$WT" 2>/dev/null
WT="${WT:A}"

run_dev "'$WT'"
rc_is 0 "B1 a linked worktree is accepted"
eq "$(<$LAYOUT_ARG)" "--worktree $R1 ${WT:A}" \
  "B1 the checkout is opened through the primary repo's Herdr worktree group"

mkdir -p "$WT/src/deep"
run_dev "'$WT/src/deep'"
rc_is 0 "B2 a directory inside a linked worktree is accepted"
eq "$(<$LAYOUT_ARG)" "--worktree $R1 ${WT:A}" \
  "B2 subdirectories still resolve to the worktree root"

run_dev "'$R1'"
eq "$(<$LAYOUT_ARG)" "$R1" "B2 the primary checkout is still allowed"

# --- C: bootstrap -----------------------------------------------------------
print -r -- "-- C: bootstrap"

# HOME must be the fixture root: hl_label derives the label from $HOME/Code, so
# without it every expected label in this suite would be wrong.
run_layout() {  # <mock-setup> <layout.sh args...>
  mock_reset
  eval "$1"
  shift
  OUT="$(HOME="$ROOTTMP" DEV_NO_ATTACH=1 zsh "$LAYOUT" "$@" 2>&1)"; RC=$?
}

# Inside herdr: never starts a server. Each absence assertion is paired with a
# presence one — "nothing was logged" passes trivially when nothing ran at all, so on
# its own it could never detect a layout.sh that failed to launch.
run_layout "export HERDR_ENV=1" "$R1"
rc_is 0 "C1 inside herdr, layout.sh runs"
unlogged "server" "C1 inside herdr, no server is started"

# Outside herdr with a server already up: also must not start one.
run_layout "unset HERDR_ENV; export MOCK_SERVER_UP=1" "$R1"
rc_is 0 "C2 with a server up, layout.sh runs"
eq "$(count_logged 'server')" "0" "C2 an existing server is not restarted"

# Outside herdr with no server: probes, fails cleanly rather than hanging.
run_layout "unset HERDR_ENV; export MOCK_SERVER_UP=0 MOCK_SERVER_NEVER_READY=1 HL_READY_TRIES=2" "$R1"
logged "workspace list" "C3 readiness is probed with a real failing call"
rc_is 1 "C3 an unreachable server fails rather than hanging"
has "did not become ready" "C3 reports the timeout"

# C4: the start itself. C3 only covers probing and the timeout — deleting the
# `herdr server` line entirely would leave every other assertion green.
run_layout "unset HERDR_ENV; export MOCK_SERVER_UP=0
  mock_topology '$R1' 'Netronix/curato' $FULL" "$R1"
rc_is 0 "C4 a down server is started and the run completes"
eq "$(count_logged 'server')" "1" "C4 the server is started exactly once"

# --- D: identity ------------------------------------------------------------
print -r -- "-- D: identity"

# A workspace whose panes sit at this repo → found.
run_layout "export HERDR_ENV=1; mock_topology '$R1' 'Netronix/curato' $FULL" "$R1"
logged "workspace focus w7" "D1 a path match is focused"
unlogged "workspace create" "D1 nothing is created"

# Same basename, different org: must NOT match.
run_layout "export HERDR_ENV=1; export MOCK_WS_ID=w5
  mock_topology '$R1' 'Netronix/curato' $FULL" "$R2"
logged "workspace create" "D2 a different repo with the same basename builds its own"
unlogged "workspace focus w5" "D2 the other repo's workspace is not focused"

# Label says curato, panes say elsewhere → not a match; build our own.
run_layout "export HERDR_ENV=1; mock_topology '/somewhere/else' 'Netronix/curato' $FULL" "$R1"
logged "workspace create" "D3 a label match with a mismatched path is not focused"

# The lock is taken before any scan.
run_layout "export HERDR_ENV=1; export HL_TRACE_LOCK=1; mock_topology '$R1' 'Netronix/curato' $FULL" "$R1"
has "LOCK-ACQUIRED" "D4 the lock is acquired"
has "SCAN" "D4 the scan happens"
[[ "$OUT" == *"LOCK-ACQUIRED"*"SCAN"* ]] \
  && _pass "D4 lock precedes scan" || _fail "D4 scan happened before the lock"

# Two candidate workspaces: take the first in Herdr's order, warn, never refuse.
run_layout "export HERDR_ENV=1
  export MOCK_PANE_LIST='{\"result\":{\"panes\":[
    {\"pane_id\":\"w7:p1\",\"tab_id\":\"w7:t1\",\"workspace_id\":\"w7\",\"cwd\":\"$R1\"},
    {\"pane_id\":\"w8:p1\",\"tab_id\":\"w8:t1\",\"workspace_id\":\"w8\",\"cwd\":\"$R1\"}]}}'
  export MOCK_WS_LIST='{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\"},{\"workspace_id\":\"w8\"}]}}'" "$R1"
rc_is 0 "D5 two candidate workspaces still focus"
logged "workspace focus w7" "D5 the first candidate is focused"
has "using w7" "D5 the ambiguity is reported"
unlogged "workspace create" "D5 nothing is created"

# D6/D7: a failing herdr call must not be reported as success. Before explicit
# propagation both of these exited 0 and went on to attach.
run_layout "export HERDR_ENV=1; export MOCK_FOCUS_RC=1
  mock_topology '$R1' 'Netronix/curato' $FULL" "$R1"
rc_is 1 "D6 a failed focus fails the run"

run_layout "export HERDR_ENV=1; export MOCK_WS_CREATE_RC=1; mock_panes '/nowhere'" "$R1"
rc_is 1 "D7 a failed create fails the run"

# Provenance wins over a pane that merely cd'd to the repo root.
run_layout "export HERDR_ENV=1
  export MOCK_WS_LIST='{\"result\":{\"workspaces\":[
    {\"workspace_id\":\"w5\",\"label\":\"x\",\"worktree\":{\"checkout_path\":\"$R1\",\"is_linked_worktree\":false}},
    {\"workspace_id\":\"w7\",\"label\":\"y\"}]}}'
  export MOCK_PANE_LIST='{\"result\":{\"panes\":[{\"pane_id\":\"w7:p1\",\"tab_id\":\"w7:t1\",\"workspace_id\":\"w7\",\"cwd\":\"$R1\"}]}}'
  export MOCK_TAB_LIST='{\"result\":{\"tabs\":[{\"tab_id\":\"w5:t1\",\"label\":\"agents\"},{\"tab_id\":\"w5:t2\",\"label\":\"runtime\"}]}}'" "$R1"
logged "workspace focus w5" "D8 the workspace whose provenance is the repo is focused"
unlogged "workspace focus w7" "D8 a pane cwd does not outrank provenance"

# A workspace with provenance for ANOTHER checkout is never adopted through a cd'd pane.
run_layout "export HERDR_ENV=1
  export MOCK_WS_LIST='{\"result\":{\"workspaces\":[
    {\"workspace_id\":\"w5\",\"label\":\"other\",\"worktree\":{\"checkout_path\":\"$R2\",\"is_linked_worktree\":false}}]}}'
  export MOCK_PANE_LIST='{\"result\":{\"panes\":[{\"pane_id\":\"w5:p1\",\"tab_id\":\"w5:t1\",\"workspace_id\":\"w5\",\"cwd\":\"$R1\"}]}}'" "$R1"
logged "workspace create" "D9 another checkout's workspace is not adopted; a new one is built"
unlogged "workspace focus w5" "D9 the other checkout's workspace is not focused"

# D10: a lock held by another process times out loudly and builds nothing. Two dev runs
# racing past a stuck lock is how duplicate workspaces get made.
D10_LOCKDIR="$XDG_STATE_HOME/herdr-layout"
mkdir -p "$D10_LOCKDIR"
D10_KEY="${R1//\//-}"; D10_KEY="${D10_KEY#-}"
D10_LOCK="$D10_LOCKDIR/$D10_KEY.lock"
: >> "$D10_LOCK"
zsh -c "zmodload -F zsh/system b:zsystem; zsystem flock '$D10_LOCK'; sleep 8" &
D10_HOLDER=$!
sleep 0.7
run_layout "export HERDR_ENV=1 HL_LOCK_TIMEOUT=1; mock_panes '/nowhere'" "$R1"
kill $D10_HOLDER 2>/dev/null; wait $D10_HOLDER 2>/dev/null
unset HL_LOCK_TIMEOUT
rc_is 1 "D10 a held lock fails the run"
has "held the lock" "D10 says why"
unlogged "workspace create" "D10 nothing is created"
unlogged "workspace focus" "D10 nothing is focused"

# --- E: existing workspaces: focus, add missing tabs -----------------------
print -r -- "-- E: an existing workspace is never refused"
L="Netronix/curato"
# Bug 2: a manual split, a changed direction, a duplicate label or a renamed space
# must never stop dev from focusing it.
for setup_case in \
  "mock_topology '$R1' '$L' agents:3 runtime:2|E1 a manual split in agents" \
  "mock_topology '$R1' '$L' $FULL; mock_split_dir w7:p1 down|E2 an agents tab split the other way" \
  "mock_topology '$R1' '$L' agents:2 agents:2 runtime:2|E3 a duplicated managed label" \
  "mock_topology '$R1' '$L' agents:2 editor:2 runtime:2|E4 a split editor tab" \
  "mock_topology '$R1' 'my own name' $FULL|E5 a workspace the user renamed" \
  "mock_topology '$R1' '$L' $FULL notes:1 error:1|E6 extra unmanaged tabs, one labelled error"
do
  run_layout "export HERDR_ENV=1; ${setup_case%%|*}" "$R1"
  rc_is 0 "${setup_case#*|} still focuses"
  logged "workspace focus w7" "${setup_case#*|}: the workspace is focused"
  unlogged "tab create" "${setup_case#*|}: nothing is created"
  unlogged "workspace rename" "${setup_case#*|}: nothing is renamed"
  unlogged "tab close" "${setup_case#*|}: nothing is closed"
done

# Missing eager tabs are added; the lazy editor tab is not.
run_layout "export HERDR_ENV=1; mock_topology '$R1' '$L' agents:2 editor:1" "$R1"
logged "tab create --workspace w7 --label runtime" "E7 a missing runtime tab is added"
unlogged "--label agents" "E7 the existing agents tab is not recreated"
unlogged "--label editor" "E7 the existing editor tab is not recreated"
logged "workspace focus w7" "E7 the workspace is focused after the add"

run_layout "export HERDR_ENV=1; mock_topology '$R1' '$L' runtime:2" "$R1"
logged "tab create --workspace w7 --label agents" "E8 a missing agents tab is added"
logged "pane run w7:p4 claude" "E8 claude starts in the new agents tab"
unlogged "--label editor" "E8 no editor tab is added"

# --- F0: malformed responses are not actionable state -----------------------
print -r -- "-- F0: invalid JSON at the boundary"

# Invalid pane JSON. Before the boundary check this returned rc=0 with no workspace
# id — indistinguishable from "no workspace exists" — so main went on to build a
# duplicate for a repo that already had one.
run_layout "export HERDR_ENV=1; export MOCK_PANE_LIST='{\"result\":{\"panes\":[' " "$R1"
rc_is 1 "F0a invalid pane JSON fails the run"
has "invalid JSON" "F0a gives one controlled diagnostic"
hasnt "parse error" "F0a does not leak raw jq noise"
unlogged "workspace create" "F0a nothing is created"
unlogged "workspace focus"  "F0a nothing is focused"

# Invalid tab JSON must stop the run before anything is created: an unparsable tab list
# is not "no tabs".
run_layout "export HERDR_ENV=1
  mock_topology '$R1' 'Netronix/curato' $FULL
  export MOCK_TAB_LIST='{\"result\":{\"tabs\":[' " "$R1"
rc_is 1 "F0b invalid tab JSON fails the run"
has "invalid JSON" "F0b gives one controlled diagnostic"
unlogged "tab create"       "F0b nothing is created"
unlogged "workspace rename" "F0b nothing is renamed"
unlogged "pane split"       "F0b nothing is split"
unlogged "workspace focus"  "F0b nothing is focused"

# --- F1: empty responses and the error envelope -----------------------------
print -r -- "-- F1: empty responses and envelope detection"

# jq exits 0 on empty input, so an empty pane list previously read as "no workspace
# exists" with rc=0 and went on to build a duplicate.
run_layout "export HERDR_ENV=1; export MOCK_EMPTY_FOR='pane list'" "$R1"
rc_is 1 "F1a an empty pane response fails the run"
has "empty response" "F1a says what was wrong"
unlogged "workspace create" "F1a nothing is created"
unlogged "workspace focus"  "F1a nothing is focused"

# Same for tabs: an empty tab response is not "no tabs", so nothing may be created.
run_layout "export HERDR_ENV=1
  mock_topology '$R1' 'Netronix/curato' $FULL
  export MOCK_EMPTY_FOR='tab list'" "$R1"
rc_is 1 "F1b an empty tab response fails the run"
unlogged "tab create"       "F1b nothing is created"
unlogged "workspace rename" "F1b nothing is renamed"

# The converse: a genuine error envelope returned with exit status 0 must be caught.
run_layout "export HERDR_ENV=1
  export MOCK_PANE_LIST='{\"error\":{\"code\":\"internal\",\"message\":\"boom\"}}'" "$R1"
rc_is 1 "F1d an error envelope with exit 0 is rejected"
unlogged "workspace create" "F1d nothing is created"

# --- G: build ---------------------------------------------------------------
print -r -- "-- G: build"
run_layout "export HERDR_ENV=1; mock_panes '/nowhere'" "$R1"
rc_is 0 "G1 a clean build succeeds"
logged "workspace create --cwd $R1 --label Netronix/curato --no-focus" \
  "G1 created under its final label, unfocused, with an explicit cwd"

# Ids come from the responses, never guessed. The stub deliberately returns w7:p3,
# not w1:p1, so any predicted id fails here.
logged "pane split --pane w7:p3 --direction right" "G2 the agents pane splits by parsed id"
logged "pane run w7:p3 claude" "G2 claude runs in the parsed root pane"
logged "pane run w7:p9 codex --sandbox read-only --ask-for-approval never"  "G2 codex runs read-only in the split's parsed id"

logged "tab create --workspace w7 --label runtime" "G3 tabs are created with --workspace"
unlogged "--workspace-id"    "G3 the non-existent --workspace-id flag is never used"
unlogged "--target-pane-id"  "G3 the non-existent --target-pane-id flag is never used"

# The runtime split must target that tab's OWN root pane. tab create does not focus,
# so an untargeted split could land on the agents tab instead. runtime is now the
# first tab the build creates, so it takes the first sequenced root pane.
logged "pane split --pane w7:p4 --direction down" "G4 the runtime split targets its own parsed root pane"

# The editor tab is lazy. Building it here is what the whole change removes: a space
# opens without nvim, and alt+e creates the tab the first time it is wanted.
unlogged "--label editor" "G4 no editor tab is created at build time"
unlogged "nvim"           "G4 nvim is never launched at build time"

# The git tab is gone: lazygit is an alt+g popup now, not a managed tab that layout.sh
# would keep re-adding.
unlogged "--label git" "G4 no git tab is created"
unlogged "lazygit"     "G4 lazygit is never launched into a pane"

logged "workspace focus w7" "G5 focused once complete"
logged "tab focus w7:t4" "G5 the agents tab is focused, as dev.kdl pinned it"
[[ "$(<$HLOG)" == *"workspace focus w7"*"tab focus w7:t4"* ]] \
  && _pass "G5 focus precedes the agents-tab focus" \
  || _fail "G5 focus ordering is wrong"

# Trap: fail on the runtime tab create, so the workspace is genuinely half-built —
# the agents tab and its two panes exist, nothing else does.
run_layout "export HERDR_ENV=1; mock_panes '/nowhere'; export MOCK_TAB_CREATE_FAIL_AT=1" "$R1"
rc_is 1 "G6 a failed build fails loudly"
logged "workspace close w7" "G6 the trap closes the partial workspace"
logged "tab create --workspace w7 --label runtime" "G6 it reached the runtime tab create"
unlogged "workspace rename" "G6 a build never renames"

# hl_api_json proves a payload parses — not that mandatory ids are present.
run_layout "export HERDR_ENV=1; mock_panes '/nowhere'
  export MOCK_WS_CREATE_JSON='{\"result\":{\"workspace\":{},\"tab\":{},\"root_pane\":{}}}'" "$R1"
rc_is 1 "G7 a create response missing ids fails"
has "missing" "G7 says what was missing"
unlogged "pane split" "G7 no follow-up command is issued with a null id"
unlogged "pane run"   "G7 nothing is run"
unlogged "workspace close" "G7 with no workspace id there is nothing to close"

# G7b: a VALID workspace id but a missing tab id. The workspace exists, so failing
# here without closing it leaves exactly the orphan the trap exists to remove — the
# window that opened when the trap was armed only after all three ids parsed.
run_layout "export HERDR_ENV=1; mock_panes '/nowhere'
  export MOCK_WS_CREATE_JSON='{\"result\":{\"workspace\":{\"workspace_id\":\"w7\"},\"tab\":{},\"root_pane\":{}}}'" "$R1"
rc_is 1 "G7b a missing tab id fails the build"
logged "workspace close w7" "G7b the created workspace is still closed"
unlogged "pane split" "G7b nothing is split"

# G7c: ids must be strings. `jq -er` alone returns 7 and {} with exit 0.
run_layout "export HERDR_ENV=1; mock_panes '/nowhere'
  export MOCK_WS_CREATE_JSON='{\"result\":{\"workspace\":{\"workspace_id\":7},\"tab\":{\"tab_id\":\"w7:t4\"},\"root_pane\":{\"pane_id\":\"w7:p3\"}}}'" "$R1"
rc_is 1 "G7c a non-string workspace id is rejected"
unlogged "tab rename" "G7c nothing proceeds on a numeric id"

# --- J: tab jumps resolve by label ------------------------------------------
print -r -- "-- J: tab-goto"

goto() {  # <mock-setup> <label>
  mock_reset; eval "$1"
  OUT="$(HERDR_ACTIVE_WORKSPACE_ID=w7 zsh "$TABGOTO" "$2" 2>&1)"; RC=$?
}

goto "mock_tabs agents editor runtime" runtime
rc_is 0 "J1 a known label resolves"
logged "tab focus w7:t3" "J1 focuses the tab carrying that label"

# Order-independence: a re-added tab is appended, and herdr 0.8.2 has no `tab move`, so a
# workspace can hold its managed tabs in any order. An index would land on the wrong one.
goto "mock_tabs runtime agents editor" runtime
rc_is 0 "J2 resolves in a reordered workspace"
logged "tab focus w7:t1" "J2 follows the label, not the position"

goto "mock_tabs agents editor" runtime
rc_is 1 "J3 a missing label fails"
has "no tab labelled" "J3 says why"
unlogged "tab focus" "J3 no tab is focused"

goto "mock_tabs agents agents" agents
rc_is 1 "J4 an ambiguous label fails rather than picking one"
has "refusing to guess" "J4 says why"
unlogged "tab focus" "J4 no tab is focused"

# No injected context: say so rather than falling back to the globally-focused
# workspace, which is racy under a shared session view.
mock_reset; mock_tabs agents editor runtime
OUT="$(env -u HERDR_ACTIVE_WORKSPACE_ID -u HERDR_WORKSPACE_ID zsh "$TABGOTO" agents 2>&1)"; RC=$?
rc_is 1 "J5 no active workspace in the environment fails"
has "no active workspace" "J5 says why"
unlogged "tab focus" "J5 no tab is focused"

# Empty, malformed and error responses must not become a jump — each asserted
# separately, since one check passing does not exercise the others.
goto "export MOCK_EMPTY_FOR='tab list'" agents
rc_is 1 "J6a an empty tab response fails"
has "empty response" "J6a says why"
unlogged "tab focus" "J6a no tab is focused"

goto "export MOCK_TAB_LIST='{\"result\":{\"tabs\":['" agents
rc_is 1 "J6b invalid JSON fails"
has "invalid JSON" "J6b says why"
unlogged "tab focus" "J6b no tab is focused"

goto "export MOCK_TAB_LIST='{\"error\":{\"code\":\"internal\"}}'" agents
rc_is 1 "J6c an error envelope fails"
has "error envelope" "J6c says why"
unlogged "tab focus" "J6c no tab is focused"

# Ids must be non-empty strings. `jq -r` renders a missing/numeric/object id as
# "null"/"7"/"{}" and would hand that straight to `tab focus`.
goto "export MOCK_TAB_LIST='{\"result\":{\"tabs\":[{\"label\":\"agents\"}]}}'" agents
rc_is 1 "J7a a missing tab id fails"
has "malformed id" "J7a says why"
unlogged "tab focus" "J7a no tab is focused"

goto "export MOCK_TAB_LIST='{\"result\":{\"tabs\":[{\"tab_id\":7,\"label\":\"agents\"}]}}'" agents
rc_is 1 "J7b a numeric tab id fails"
unlogged "tab focus" "J7b no tab is focused"

goto "export MOCK_TAB_LIST='{\"result\":{\"tabs\":[{\"tab_id\":{},\"label\":\"agents\"}]}}'" agents
rc_is 1 "J7c an object tab id fails"
unlogged "tab focus" "J7c no tab is focused"

# type = "shell" commands run detached, so stderr never reaches the TUI. A failed jump
# must therefore be visible as a notification, or it is indistinguishable from a
# keybinding that does nothing at all.
goto "mock_tabs agents editor" runtime
logged "notification show" "J8 a failed jump is surfaced as a notification"

# J9: the tab exists at list time and is gone by focus time — the real race, since
# nothing holds a lock between the two calls. Detached execution makes an unhandled
# failure here indistinguishable from a key that does nothing.
goto "mock_tabs agents editor runtime; export MOCK_TAB_FOCUS_RC=1" runtime
rc_is 1 "J9 a focus that fails after a successful list fails the jump"
has "could not focus" "J9 the diagnostic names the focus failure"
logged "tab focus w7:t3" "J9 the focus was genuinely attempted"
logged "notification show" "J9 the failure is surfaced as a notification"

# --create: the lazy tab's jump has to be able to make what it jumps to. It does NOT
# re-list afterwards — layout.sh hands back the id it just created, so there is no
# window between the create and the focus for another client to change the tab set.
# tab-goto EXECUTES layout.sh, the way dev does. The chezmoi source file carries no
# exec bit — the `executable_` prefix adds it at apply time — so DEV_LAYOUT points at a
# shim that runs the real script rather than at the unexecutable source. Pointing it
# straight at $LAYOUT fails with "permission denied" and says nothing about the code.
LAYOUT_EXEC="$STUBS/layout-exec.sh"
cat > "$LAYOUT_EXEC" <<EXEC
#!/bin/sh
exec zsh "$LAYOUT" "\$@"
EXEC
chmod +x "$LAYOUT_EXEC"

gotoc() {  # <mock-setup> <tab-goto args...>
  mock_reset; eval "$1"; shift
  OUT="$(HOME="$ROOTTMP" HERDR_ACTIVE_WORKSPACE_ID=w7 DEV_LAYOUT="$LAYOUT_EXEC" \
    zsh "$TABGOTO" "$@" 2>&1)"; RC=$?
}

gotoc "mock_topology '$R1' 'Netronix/curato' $FULL" --create editor
rc_is 0 "J10 --create succeeds when the label is absent"
logged "tab create --workspace w7 --label editor" "J10 the missing editor tab is created"
logged "pane run w7:p4 nvim ." "J10 nvim is launched in the new tab's own pane"
logged "tab focus w7:t5" "J10 the newly created tab is focused by its returned id"

gotoc "mock_topology '$R1' 'Netronix/curato' $FULL_EDITOR" --create editor
rc_is 0 "J11 --create succeeds when the label is present"
unlogged "tab create" "J11 an existing editor tab is never duplicated"
unlogged "nvim"       "J11 a second nvim is never launched over a live session"
logged "tab focus w7:t2" "J11 the existing tab is focused"

# Only the lazy label may be conjured. Without this, a typo in config.toml would
# silently start populating tabs layout.sh does not manage.
gotoc "mock_topology '$R1' 'Netronix/curato' $FULL" --create notes
rc_is 1 "J12 --create refuses a label layout.sh does not manage"
# The reason matters: without it this passes on "no tab labelled --create", which is
# what it did before --create existed at all.
has "not a managed tab" "J12 the refusal comes from layout.sh, not from a misparse"
unlogged "tab create" "J12 no unmanaged tab is created"
logged "notification show" "J12 the refusal is surfaced as a notification"

gotoc "mock_topology '$R1' 'Netronix/curato' $FULL" --create
rc_is 1 "J13 --create with no label fails"
has "usage" "J13 says how to call it"

# J15/J16: `tab focus` answers with an error envelope at exit status 0 — the same
# shape layout.sh's F1d pins. Checking only $? turns a failed jump into a silent
# success, which under detached execution is a key that does nothing and says nothing.
gotoc "mock_topology '$R1' 'Netronix/curato' $FULL
  export MOCK_TAB_FOCUS_JSON='{\"error\":{\"code\":\"internal\",\"message\":\"focus failed\"}}'" \
  --create editor
rc_is 1 "J15 a created tab whose focus returns an error envelope fails"
logged "notification show" "J15 the failure is surfaced as a notification"

gotoc "mock_tabs agents editor runtime
  export MOCK_TAB_FOCUS_JSON='{\"error\":{\"code\":\"internal\",\"message\":\"focus failed\"}}'" \
  editor
rc_is 1 "J16 an ordinary jump whose focus returns an error envelope fails too"
logged "notification show" "J16 the failure is surfaced as a notification"

# Without the flag the behaviour is unchanged: re-adding a missing eager tab is dev's job
# (layout.sh), and a jump that silently built one would hide the real fault.
gotoc "mock_topology '$R1' 'Netronix/curato' agents:2" runtime
rc_is 1 "J14 a bare jump still refuses to create the tab it cannot find"
unlogged "tab create" "J14 nothing is created without --create"

# --- L: Herdr-native worktree open/reopen -----------------------------------
print -r -- "-- L: native worktree workspaces"

worktree_fixture() { # <already-open:true|false> <linked:true|false> [reported-path]
  local already="$1" linked="$2" reported="${3:-$WT}"
  export MOCK_WORKTREE_OPEN_JSON="{\"result\":{\"type\":\"worktree_opened\",\"already_open\":$already,\"workspace\":{\"workspace_id\":\"w7\",\"label\":\"Netronix/curato-feature\",\"worktree\":{\"checkout_path\":\"$reported\",\"is_linked_worktree\":$linked}},\"tab\":{\"tab_id\":\"w7:t4\",\"label\":\"1\"},\"root_pane\":{\"pane_id\":\"w7:p3\",\"tab_id\":\"w7:t4\",\"workspace_id\":\"w7\",\"cwd\":\"$reported\"},\"worktree\":{\"path\":\"$reported\",\"is_linked_worktree\":$linked,\"branch\":\"feature\"}}}"
}

blank_worktree_topology() {
  export MOCK_TAB_LIST='{"result":{"tabs":[{"tab_id":"w7:t4","label":"1"}]}}'
  export MOCK_PANE_LIST="{\"result\":{\"panes\":[{\"pane_id\":\"w7:p3\",\"tab_id\":\"w7:t4\",\"workspace_id\":\"w7\",\"cwd\":\"$WT\"}]}}"
  export MOCK_WS_LIST="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"label\":\"Netronix/curato-feature\",\"worktree\":{\"checkout_path\":\"$WT\",\"is_linked_worktree\":true}}]}}"
}

run_worktree_layout() {
  OUT="$(HOME="$ROOTTMP" HERDR_ENV=1 DEV_NO_ATTACH=1 zsh "$LAYOUT" \
    --worktree "$R1" "$WT" 2>&1)"; RC=$?
}

mock_reset
worktree_fixture false true
blank_worktree_topology
run_worktree_layout
rc_is 0 "L1 a newly-opened native worktree workspace is adopted"
# The label is the slug, the part of the directory name that is NOT the project. A
# linked checkout is a sibling named "<primary>-<slug>", so its path leads with
# everything it shares with the primary and only reaches the distinguishing part at the
# end — where a 40-column rail has already truncated it. Labelling it by the project
# instead makes every worktree of one project read identically, which is the same
# failure from the other direction. Only the slug says which checkout this is, and the
# grouping already marks it as a sub-space, so the label carries no marker of its own.
logged "worktree open --cwd $R1 --path $WT --label feature --no-focus" \
  "L1 a linked checkout is labelled by its slug, not its project"

# hl_label directly, because the slug form has three outcomes and only one of them is
# reachable through a successful open. The other two are the fallbacks the label
# contract promises: a cosmetic name must never be worth failing a workspace open, so
# anything it cannot derive confidently has to degrade to the old path-derived form
# rather than abort or invent a slug.
hl_label_of() { HOME="$ROOTTMP" zsh -c "source '$LAYOUT' --source-only; hl_label '$1'" 2>&1 }

eq "$(hl_label_of "$WT")" "feature" \
  "L1b a sibling linked checkout yields the slug"

# Not a sibling: same primary, different parent directory. Basenames alone still look
# conventional — curato-elsewhere against curato — so a check that compares only those
# reports "elsewhere" for a checkout that is not part of the sibling layout at all, and
# would collide with a real Code/Netronix/curato-elsewhere if one existed.
git -C "$R1" worktree add -q -b elsewhere "$CODE/Elsewhere/curato-elsewhere" 2>/dev/null
eq "$(hl_label_of "$CODE/Elsewhere/curato-elsewhere")" "Elsewhere/curato-elsewhere" \
  "L1c a non-sibling linked checkout falls back to the path-derived label"

# A .git file git cannot resolve: the marker says linked, the lookup says nothing. The
# label must come out of the fallback rather than empty.
mkdir -p "$CODE/Netronix/curato-broken"
print -r -- "gitdir: /nowhere/that/exists" > "$CODE/Netronix/curato-broken/.git"
eq "$(hl_label_of "$CODE/Netronix/curato-broken")" "Netronix/curato-broken" \
  "L1d an unresolvable .git file falls back to the path-derived label"

# Herdr truncates the far end of a label, so two siblings whose slugs share a prefix
# longer than the rail render as one string — distinct workspaces, one visible name.
# The slug is shortened here instead, keeping the tail, because that is where a branch
# carries its identity: -design against -rollout. Doing it here is the only version that
# stays derivable from the path; shortening against whatever siblings exist would make a
# name depend on the order they were created in.
hl_shorten_of() { HOME="$ROOTTMP" zsh -c "source '$LAYOUT' --source-only; hl_shorten '$1' '${2:-34}'" 2>&1 }

eq "$(hl_shorten_of small-improvements)" "small-improvements" \
  "L1e a slug inside the budget is left alone"
eq "$(hl_shorten_of feature-minimize-lod-detection-registration)" \
  "feature-min…detection-registration" \
  "L1f an over-budget slug keeps its head and its tail"
eq "$(hl_shorten_of feature-lod-alert-scoped-coverage)" "feature-lod-alert-scoped-coverage" \
  "L1g a slug that fits the budget whole is never abbreviated"

# The collision itself: these two differ only after character 41.
D="feature-lod-alert-scoped-coverage-totals-design"
R="feature-lod-alert-scoped-coverage-totals-rollout"
eq "$(hl_shorten_of $D)" "feature-lod…coverage-totals-design" "L1h the design sibling keeps its tail"
eq "$(hl_shorten_of $R)" "feature-lo…coverage-totals-rollout" "L1i the rollout sibling keeps its tail"
[[ "$(hl_shorten_of $D)" != "$(hl_shorten_of $R)" ]] \
  && _pass "L1j two siblings sharing a 41-character prefix stay distinguishable" \
  || _fail "L1j two siblings sharing a 41-character prefix stay distinguishable"

# End to end: a real linked checkout whose slug is over budget.
git -C "$R1" worktree add -q -b "$D" "$CODE/Netronix/curato-$D" 2>/dev/null
eq "$(hl_label_of "$CODE/Netronix/curato-$D")" "feature-lod…coverage-totals-design" \
  "L1k a long-slugged checkout is labelled with the shortened slug"

# The budget hl_label passes, pinned. This slug is the one that renders differently at
# 30 than at 32, so the rail width and the slug budget cannot drift apart silently —
# they are one decision, and a narrower rail that kept the old budget would hand the
# tail back to Herdr's truncation.
M="feature-minimize-lod-detection-registration"
git -C "$R1" worktree add -q -b "$M" "$CODE/Netronix/curato-$M" 2>/dev/null
eq "$(hl_label_of "$CODE/Netronix/curato-$M")" "feature-min…detection-registration" \
  "L1l hl_label shortens to the budget the rail is sized for"

# The budget counts characters, and how many characters a string has is a question the
# caller's locale answers: under LC_ALL=C zsh measures and slices bytes, so the same
# slug comes back a different length, cut mid-codepoint into invalid UTF-8. A label
# has to be a function of its argument and nothing else.
ACC="ééééééééééééééééééééééééééééééééééééééé"
eq "$(HOME="$ROOTTMP" LC_ALL=C zsh -c "source '$LAYOUT' --source-only; hl_shorten '$ACC' 34")" \
   "$(HOME="$ROOTTMP" LC_ALL=en_US.UTF-8 zsh -c "source '$LAYOUT' --source-only; hl_shorten '$ACC' 34")" \
  "L1m the same slug shortens identically whatever locale the caller is in"

# The nudge to a word boundary must never cost a character the tail was going to show.
# These two differ inside the retained tail, at the character right before a hyphen that
# sits within SLACK of the tail's start — so a nudge that trims the tail forward past
# that hyphen throws the difference away and both slugs render as one label. The tail
# grows to a boundary; it never shrinks to one.
X="$(printf 'a%.0s' {1..30})x12345-abcdefghij"
Y="$(printf 'a%.0s' {1..30})y12345-abcdefghij"
[[ "$(hl_shorten_of $X)" != "$(hl_shorten_of $Y)" ]] \
  && _pass "L1n a difference inside the retained tail survives the word-boundary nudge" \
  || _fail "L1n a difference inside the retained tail survives the word-boundary nudge"

# The same, in the head. Head and tail are both retained text: whichever end a pair
# differs at, the difference has to reach the label. Only the middle is discarded, and
# that is the one collision this accepts.
HX="feature-abcdef-xzzzzzzzzzzzzzzzzzshared-final-tail"
HY="feature-abcdef-yzzzzzzzzzzzzzzzzzshared-final-tail"
[[ "$(hl_shorten_of $HX)" != "$(hl_shorten_of $HY)" ]] \
  && _pass "L1o a difference inside the retained head survives too" \
  || _fail "L1o a difference inside the retained head survives too"

# Growing the tail to a boundary must not grow it past the budget. A budget too small to
# hold a head, an ellipsis and a tail is still a budget, and the answer has to fit it.
eq "$(hl_shorten_of a-bbbbbbbbb 5)" "a-…bb" "L1p a boundary is never grown past the budget"

# A budget too small for an ellipsis is still governed by the same contract: keep the
# tail, because that is the end that identifies. Keeping the head there would make the
# degenerate case the one place the function contradicts itself.
eq "$(hl_shorten_of $D 0)" "" "L1r0 a budget of zero yields nothing, not everything"
eq "$(hl_shorten_of $D 2)" "gn" "L1r a budget below three keeps the tail, not the head"
[[ "$(hl_shorten_of $D 2)" != "$(hl_shorten_of $R 2)" ]] \
  && _pass "L1s tail-distinguished slugs stay distinct even at budget two" \
  || _fail "L1s tail-distinguished slugs stay distinct even at budget two"
eq "${#$(hl_shorten_of feature-lod-alert-scoped-coverage-totals-design 34)}" "34" \
  "L1q a shortened slug uses the budget it was given, and no more"
logged "tab rename w7:t4 agents" "L1 the native root tab becomes agents"
logged "pane split --pane w7:p3 --direction right --cwd $WT --no-focus" \
  "L1 the native root pane is reused for the agents split"
eq "$(count_logged "tab create --workspace w7 --label runtime --cwd $WT --no-focus")" 1 \
  "L1 runtime is created exactly once"
# Adoption builds the same eager baseline as an ordinary space — a worktree is not a
# reason to open nvim any more than a primary checkout is.
unlogged "--label editor" "L1 adoption creates no editor tab either"
unlogged "tab create --workspace w7 --label agents" \
  "L1 no redundant agents tab is appended"

mock_reset
worktree_fixture true true
mock_topology "$WT" "Netronix/curato-feature" $FULL
# Preserve native provenance; mock_topology intentionally supplies only the fields
# ordinary workspace tests need.
export MOCK_WS_LIST="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"label\":\"Netronix/curato-feature\",\"worktree\":{\"checkout_path\":\"$WT\",\"is_linked_worktree\":true}}]}}"
run_worktree_layout
rc_is 0 "L2 reopening a complete worktree workspace succeeds"
logged "workspace focus w7" "L2 the existing worktree workspace is focused"
unlogged "tab create" "L2 reopening does not duplicate tabs"
unlogged "workspace create" "L2 reopening does not create an ordinary workspace"

mock_reset
worktree_fixture false true "$R1"
blank_worktree_topology
run_worktree_layout
rc_is 1 "L3 a response pointing at a different checkout is refused"
has "different checkout" "L3 says why"
unlogged "tab rename" "L3 nothing is mutated on mismatched provenance"

mock_reset
worktree_fixture false false
blank_worktree_topology
run_worktree_layout
rc_is 1 "L4 non-linked provenance is refused in worktree mode"
has "not a linked worktree" "L4 says why"
unlogged "tab rename" "L4 nothing is mutated without linked provenance"

mock_reset
worktree_fixture false true
blank_worktree_topology
# The runtime tab is the only one adoption creates, so it is the only one that can
# fail partway.
export MOCK_TAB_CREATE_FAIL_AT=1
run_worktree_layout
rc_is 1 "L5 a failed adoption fails the run"
logged "workspace close w7" "L5 the partial workspace is closed but the checkout survives"

# Reopening never refuses: a manual split in the worktree's agents tab still focuses.
mock_reset
worktree_fixture true true
mock_topology "$WT" "curato-feature" agents:3 runtime:2
export MOCK_WS_LIST="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"label\":\"curato-feature\",\"worktree\":{\"checkout_path\":\"$WT\",\"is_linked_worktree\":true}}]}}"
run_worktree_layout
rc_is 0 "L6 a reopened worktree with a manual split still focuses"
logged "workspace focus w7" "L6 it is focused"
unlogged "tab create" "L6 nothing is created"

# Reopening adds a missing eager tab.
mock_reset
worktree_fixture true true
mock_topology "$WT" "curato-feature" agents:2
export MOCK_WS_LIST="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"label\":\"curato-feature\",\"worktree\":{\"checkout_path\":\"$WT\",\"is_linked_worktree\":true}}]}}"
run_worktree_layout
rc_is 0 "L7 a reopened worktree missing runtime succeeds"
logged "tab create --workspace w7 --label runtime" "L7 the missing runtime tab is added"
unlogged "tab rename" "L7 an existing workspace's tabs are never renamed"

# --- M: seamless Neovim/Herdr navigation ----------------------------------
print -r -- "-- M: smart-splits Herdr navigation"

# Direct focus_pane bindings consume Ctrl-h/j/k/l before Neovim sees them. The
# smart-splits Herdr plugin is the required dispatcher: it forwards into Neovim when
# appropriate, then Neovim's Herdr backend crosses the pane edge through the CLI.
for spec in 'ctrl+h:left' 'ctrl+j:down' 'ctrl+k:up' 'ctrl+l:right'; do
  key="${spec%%:*}"; action="${spec#*:}"
  OUT="$(awk -v key="$key" -v cmd="smart-splits.nvim.$action" '
    BEGIN { RS="\\[\\[keys.command\\]\\]" }
    index($0, "key = \"" key "\"") && index($0, "command = \"" cmd "\"") { print; found=1 }
    END { if (!found) exit 1 }
  ' "$CONFIG" 2>&1)"; RC=$?
  rc_is 0 "$key is routed through smart-splits.nvim.$action"
  has 'type = "plugin_action"' "$key uses a Herdr plugin action, not a detached shell"
done
OUT="$(<"$CONFIG")"
hasnt 'focus_pane_left = "ctrl+h"' "no direct Ctrl-h binding bypasses Neovim"
hasnt 'focus_pane_down = "ctrl+j"' "no direct Ctrl-j binding bypasses Neovim"
hasnt 'focus_pane_up = "ctrl+k"' "no direct Ctrl-k binding bypasses Neovim"
hasnt 'focus_pane_right = "ctrl+l"' "no direct Ctrl-l binding bypasses Neovim"

OUT="$(<"$SMART_SPLITS")"
has 'lazy = false' "smart-splits loads early enough to establish multiplexer integration"
for key in h j k l; do
  has "<C-$key>" "Neovim keeps the Ctrl-$key smart-splits mapping"
done

# The built-in worktree creator cannot run .worktreeinclude/.worktreehook or apply
# the Git ownership lock. Replace its default shortcut with a popup that calls the
# safe wt flow while retaining Herdr's native open/grouping after creation.
OUT="$(awk '
  BEGIN { RS="\\[\\[keys.command\\]\\]" }
  index($0, "key = \"prefix+shift+g\"") && index($0, "-ic wt-prompt") { print; found=1 }
  END { if (!found) exit 1 }
' "$CONFIG" 2>&1)"; RC=$?
rc_is 0 "prefix+shift+g opens the safe wt prompt"
has 'type = "popup"' "the safe worktree prompt is session-modal"
# lazygit reaches for a popup, not a managed tab. The tab-goto binding must be gone
# with it: tab-goto.sh refuses a label it cannot find, so a stale alt+g would fire a
# notification every time instead of doing nothing visible.
OUT="$(awk '
  BEGIN { RS="\\[\\[keys.command\\]\\]" }
  index($0, "key = \"alt+g\"") && index($0, "lazygit") { print; found=1 }
  END { if (!found) exit 1 }
' "$CONFIG" 2>&1)"; RC=$?
rc_is 0 "alt+g opens lazygit"
has 'type = "popup"' "lazygit is a session-modal popup, not a managed tab"
OUT="$(<"$CONFIG")"
hasnt 'tab-goto.sh git' "no jump binding survives for the removed git tab"
hasnt 'description = "tab: git"' "the git tab jump is gone from the keymap"
has 'new_worktree = ""' "Herdr's unprepared built-in worktree shortcut is disabled"
has 'close_workspace = "alt+q"' "Alt-q closes the current project workspace"
has 'edit_scrollback = "alt+s"' "Alt-s keeps the long-standing scrollback mnemonic"
has 'confirm_close = true' "workspace close keeps Herdr's confirmation guard explicit"

# alt+e is the only way the editor tab ever comes into existence now, so the binding
# must carry --create. A stale bare jump would fire a notification on every press in a
# space that has not had nvim opened yet — which is every new space.
OUT="$(awk '
  BEGIN { RS="\\[\\[keys.command\\]\\]" }
  index($0, "key = \"alt+e\"") && index($0, "tab-goto.sh --create editor") { print; found=1 }
  END { if (!found) exit 1 }
' "$CONFIG" 2>&1)"; RC=$?
rc_is 0 "alt+e creates the editor tab on demand"
has 'type = "shell"' "the editor jump stays a detached shell command"
OUT="$(<"$CONFIG")"
hasnt 'tab-goto.sh --create agents'  "the eager agents jump does not create"
hasnt 'tab-goto.sh --create runtime' "the eager runtime jump does not create"

# --- N: layout.sh --make-tab ------------------------------------------------
print -r -- "-- N: layout.sh --make-tab"

mk() {  # <mock-setup> <layout.sh args...>
  mock_reset; eval "$1"; shift
  OUT="$(HOME="$ROOTTMP" HERDR_ACTIVE_WORKSPACE_ID=w7 zsh "$LAYOUT" "$@" 2>&1)"; RC=$?
}

mk "mock_topology '$R1' 'Netronix/curato' $FULL" --make-tab editor
rc_is 0 "N1 a missing managed tab is created"
logged "tab create --workspace w7 --label editor --cwd $R1 --no-focus" \
  "N1 created unfocused, in the resolved repo root"
logged "pane run w7:p4 nvim ." "N1 nvim runs in the new tab's parsed root pane"
eq "$OUT" "w7:t5" "N1 the new tab id is printed for the caller to focus"
unlogged "tab focus" "N1 focusing is the caller's job, not this mode's"
unlogged "workspace rename" "N1 a lazy tab does not touch the space's label"

# Idempotent under the lock. tab-goto checks, then calls here — two fast alt+e presses
# would otherwise both see the tab missing and the space would end up malformed.
mk "mock_topology '$R1' 'Netronix/curato' $FULL_EDITOR" --make-tab editor
rc_is 0 "N2 an existing tab is not an error"
unlogged "tab create" "N2 the existing tab is not duplicated"
unlogged "nvim"       "N2 no second nvim is launched"
eq "$OUT" "w7:t2" "N2 the existing tab's id is printed"

mk "mock_topology '$R1' 'Netronix/curato' $FULL" --make-tab notes
rc_is 1 "N3 an unmanaged label is refused"
has "not a managed tab" "N3 says why"
unlogged "tab create" "N3 nothing is created"

mk "mock_topology '$ROOTTMP/notrepo' 'notrepo' $FULL" --make-tab editor
rc_is 1 "N4 a non-repo workspace is refused"
has "not inside a git repository" "N4 says why"
unlogged "tab create" "N4 nothing is created"

mk "export HL_TRACE_LOCK=1; mock_topology '$R1' 'Netronix/curato' $FULL" --make-tab editor
has "LOCK-ACQUIRED" "N5 --make-tab takes the same per-repo lock"

mock_reset; mock_topology "$R1" "Netronix/curato" $FULL
OUT="$(HOME="$ROOTTMP" env -u HERDR_ACTIVE_WORKSPACE_ID -u HERDR_WORKSPACE_ID \
  zsh "$LAYOUT" --make-tab editor 2>&1)"; RC=$?
rc_is 1 "N6 without a workspace in context it refuses to run"
has "no active workspace" "N6 says what is missing"

# A linked checkout without provenance still gets its tab: its repo is the pane's toplevel.
mk "mock_topology '$WT' 'curato-feature' $FULL" --make-tab editor
rc_is 0 "N7 a linked checkout without provenance gets its editor tab"
logged "tab create --workspace w7 --label editor --cwd $WT --no-focus" \
  "N7 created in the pane's own checkout"

mk "mock_topology '$WT' 'curato-feature' $FULL
  export MOCK_WS_LIST='{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"label\":\"curato-feature\",\"worktree\":{\"checkout_path\":\"$WT\",\"is_linked_worktree\":true}}]}}'" \
  --make-tab editor
rc_is 0 "N7b a native worktree workspace gets its editor tab"
logged "tab create --workspace w7 --label editor --cwd $WT --no-focus" \
  "N7b created in the worktree checkout, not the primary"

# Provenance outranks the first pane's cwd.
mk "mock_topology '$R1' 'curato-feature' $FULL
  export MOCK_WS_LIST='{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"label\":\"curato-feature\",\"worktree\":{\"checkout_path\":\"$WT\",\"is_linked_worktree\":true}}]}}'" \
  --make-tab editor
logged "tab create --workspace w7 --label editor --cwd $WT --no-focus" \
  "N7c the workspace's provenance decides the repo, not where its first pane stands"

# Without provenance the toplevel, not a subdirectory, is the repo.
mkdir -p "$WT/src/deep"
mk "mock_topology '$WT/src/deep' 'curato-feature' $FULL" --make-tab editor
rc_is 0 "N7d a pane in a subdirectory still resolves"
logged "tab create --workspace w7 --label editor --cwd $WT --no-focus" \
  "N7d the checkout's toplevel, not the subdirectory"

mk "mock_topology '$R1' 'Netronix/curato' $FULL" --make-tab
rc_is 1 "N8 --make-tab with no label fails"
has "usage" "N8 says how to call it"

# N9: --make-tab is always invoked by something that reports for it — tab-goto captures
# its stderr and raises the notification. Notifying here too means every failed alt+e
# shows two toasts, the second one saying strictly more than the first.
mk "mock_topology '$ROOTTMP/notrepo' 'notrepo' $FULL" --make-tab editor
rc_is 1 "N9 a refused --make-tab still fails"
has "not inside a git repository" "N9 the reason is on stderr for the caller to relay"
unlogged "notification show" "N9 --make-tab does not raise its own toast"

# N11: `tab create` succeeding and `pane run` failing leaves a tab with the right
# label and the right pane count — so the workspace looks complete, dev leaves it alone,
# and every later alt+e focuses an empty shell labelled "editor" forever. During a build
# the workspace trap covers this; --make-tab has no trap, so it must clean up itself.
mk "mock_topology '$R1' 'Netronix/curato' $FULL; export MOCK_PANE_RUN_RC=1" --make-tab editor
rc_is 1 "N11 a tab whose command fails to launch fails the call"
logged "tab create --workspace w7 --label editor" "N11 the tab was genuinely created first"
logged "tab close w7:t5" "N11 the half-built tab is closed rather than left behind"

# N11b: the same window, entered through a validation failure instead of a command
# failure. `tab create` answered, so the tab EXISTS on the server; whether the response
# also carried a usable pane id changes nothing about that. Parsing the pane id before
# the tab id meant this path returned without an id to clean up with.
mk "mock_topology '$R1' 'Netronix/curato' $FULL; export MOCK_TAB_CREATE_NO_PANE_ID=1" \
  --make-tab editor
rc_is 1 "N11b a create response with no root pane id fails"
has "missing" "N11b says what was missing"
logged "tab close w7:t5" "N11b the tab that was created is still closed"
unlogged "pane run" "N11b nothing is run in a pane that could not be identified"

# N12: the real race, on the schedule that breaks it — B waits BEFORE taking the lock,
# so it arrives with a stale observation after A has created and released. Both
# processes see one shared tab list, so a re-check that moved above the lock would let
# both create. N5's marker alone cannot catch that.
mock_reset
export MOCK_TAB_STATE_FILE="$(mktemp "${TMPROOT%/}/tabstate.XXXXXX")"; : > "$MOCK_TAB_STATE_FILE"
mock_topology "$R1" "Netronix/curato" $FULL
( HOME="$ROOTTMP" HERDR_ACTIVE_WORKSPACE_ID=w7 HL_LOCK_DELAY=2 \
    zsh "$LAYOUT" --make-tab editor >"${TMPROOT%/}/mkB.out" 2>&1 ) &
RACE_B=$!
sleep 0.2
A_OUT="$(HOME="$ROOTTMP" HERDR_ACTIVE_WORKSPACE_ID=w7 zsh "$LAYOUT" --make-tab editor 2>&1)"
a_rc=$?
b_rc=0; wait $RACE_B 2>/dev/null || b_rc=$?
B_OUT="$(<"${TMPROOT%/}/mkB.out")"
eq "$(count_logged "tab create --workspace w7 --label editor --cwd $R1 --no-focus")" "1" \
  "N12 two overlapping presses create exactly one editor tab"
[[ "$a_rc" == 0 && "$b_rc" == 0 ]] \
  && _pass "N12 both racers succeed" || _fail "N12 racer rc=$a_rc/$b_rc"
eq "$B_OUT" "$A_OUT" "N12 both racers return the same tab id"
unset MOCK_TAB_STATE_FILE

# N13: N12 asserts the OUTCOME of two overlapping presses, but it cannot prove the
# ordering that produces it — whether the mutant loses depends on which process wins a
# 0.2s head start, so it is evidence, not a guard. This one is deterministic. A real
# flock held by another process is a hard barrier: the contender cannot pass hl_lock,
# and the editor tab appears WHILE it is stuck there. If the re-check sits above the
# lock, the contender reads the tab list before blocking — at which point the tab does
# not exist — and creates a second one. Verified against that mutant.
mock_reset
export MOCK_TAB_STATE_FILE="$(mktemp "${TMPROOT%/}/tabstate2.XXXXXX")"; : > "$MOCK_TAB_STATE_FILE"
mock_topology "$R1" "Netronix/curato" $FULL
N13_LOCKDIR="$XDG_STATE_HOME/herdr-layout"; mkdir -p "$N13_LOCKDIR"
N13_KEY="${R1//\//-}"; N13_KEY="${N13_KEY#-}"
N13_LOCK="$N13_LOCKDIR/$N13_KEY.lock"; : >> "$N13_LOCK"
zsh -c "zmodload -F zsh/system b:zsystem; zsystem flock '$N13_LOCK'; sleep 30" &
N13_HOLDER=$!
sleep 0.7
N13_OUTF="$(mktemp "${TMPROOT%/}/n13.XXXXXX")"
N13_TRACE="$(mktemp "${TMPROOT%/}/n13trace.XXXXXX")"
# A generous lock timeout: the handshake below may spend seconds waiting, and a
# contender that gave up while we watched for it would look like a passing test.
( HOME="$ROOTTMP" HERDR_ACTIVE_WORKSPACE_ID=w7 HL_TRACE_LOCK=1 HL_LOCK_TIMEOUT=60 \
    zsh "$LAYOUT" --make-tab editor >"$N13_OUTF" 2>"$N13_TRACE" ) &
N13_C=$!
# The handshake. Wait until the contender SAYS it is at the lock, rather than assuming
# it got there within some sleep — on a slower machine the fixture would otherwise
# insert the tab and release before the contender looked at anything, and an
# ensure-before-lock mutant would then find w7:t9, create nothing, and pass.
n13_i=0
while (( n13_i < 150 )); do
  [[ "$(<$N13_TRACE)" == *LOCK-WAIT* ]] && break
  sleep 0.1; (( n13_i++ ))
done
[[ "$(<$N13_TRACE)" == *LOCK-WAIT* ]] \
  && _pass "N13 the contender reached the lock and blocked there" \
  || _fail "N13 the contender never reached the lock — the rest proves nothing"
# What the lock holder "did" while it held the lock.
print -n '{"tab_id":"w7:t9","label":"editor"},' >> "$MOCK_TAB_STATE_FILE"
kill $N13_HOLDER 2>/dev/null; wait $N13_HOLDER 2>/dev/null
n13_rc=0; wait $N13_C 2>/dev/null || n13_rc=$?
N13_OUT="$(<"$N13_OUTF")"
RC=$n13_rc; rc_is 0 "N13 the contender succeeds once the lock is released"
eq "$(count_logged "tab create --workspace w7 --label editor --cwd $R1 --no-focus")" "0" \
  "N13 a contender blocked on the lock never creates a tab it could not have seen"
eq "$N13_OUT" "w7:t9" "N13 it adopts the tab that appeared while it waited"
unset MOCK_TAB_STATE_FILE

# N10: the tab id is now load-bearing — it is what the caller focuses — so a create
# response without one must fail rather than hand "null" to `tab focus`.
mk "mock_topology '$R1' 'Netronix/curato' $FULL; export MOCK_TAB_CREATE_NO_TAB_ID=1" \
  --make-tab editor
rc_is 1 "N10 a tab create response with no tab id fails"
has "missing" "N10 says what was missing"
unlogged "tab focus" "N10 nothing is focused on a null id"

# The same response is fatal to a build, which has relied on that field since the id
# started being returned.
run_layout "export HERDR_ENV=1; mock_panes '/nowhere'; export MOCK_TAB_CREATE_NO_TAB_ID=1" "$R1"
rc_is 1 "N10b a build stops on a tab create response with no tab id"
logged "workspace close w7" "N10b the trap closes the partial workspace"

finish
