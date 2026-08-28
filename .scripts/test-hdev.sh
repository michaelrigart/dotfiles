#!/usr/bin/env zsh
# Mocked test for hdev/layout.sh — the Herdr trial's shell surface.
#
#   A  hdev            repo resolution cascade
#   B  hdev            the linked-worktree guard
#   C  layout.sh       bootstrap: server probe and readiness
#   D  layout.sh       identity: lock-before-scan, path matching, ambiguity
#   E  layout.sh       classification: complete / provisional / malformed
#   F  layout.sh       build: construction sequence, explicit IDs, trap
#   G  layout.sh       repair: missing tabs, the rename window
#   H  tab-goto.sh     label resolution
#
# herdr is stubbed on PATH and every invocation is logged, so tests can assert on
# ordering and — for malformed workspaces — on the ABSENCE of mutation. Git is NOT
# stubbed: real repos are used, because git's own answers about worktrees are part of
# what is under test.
#
# Run: zsh .scripts/test-hdev.sh
set -u

ROOT="$(cd "${0:h}/.." && pwd)"
FUNCS="$ROOT/dot_config/zsh/functions"
LAYOUT="$ROOT/dot_config/herdr/executable_layout.sh"
TABGOTO="$ROOT/dot_config/herdr/executable_tab-goto.sh"
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
mkd() { mktemp -d "${TMPROOT%/}/hdev-test.XXXXXX" }
STUBS=$(mkd)
trap 'rm -rf "$STUBS" "${ROOTTMP:-}"' EXIT

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
  "tab list"*)     printf '%s' "$MOCK_TAB_LIST" ;;
  "workspace focus"*) exit "${MOCK_FOCUS_RC:-0}" ;;
  "tab focus"*)       exit "${MOCK_TAB_FOCUS_RC:-0}" ;;
  "workspace create"*)
    exit_rc="${MOCK_WS_CREATE_RC:-0}"; [ "$exit_rc" != 0 ] && exit "$exit_rc"
    printf '%s' "${MOCK_WS_CREATE_JSON:-$DEF_WS_CREATE}" ;;
  "tab create"*)
    # The counter lives in a FILE, not a variable: the stub is a separate process per
    # call, so an exported variable could never advance and every tab would come back
    # with identical ids — a fixture that hides exactly the id-reuse bug it should catch.
    n=$(( $(cat "$MOCK_TAB_SEQ_FILE" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$MOCK_TAB_SEQ_FILE"
    if [ -n "${MOCK_TAB_CREATE_FAIL_AT:-}" ] && [ "$n" = "$MOCK_TAB_CREATE_FAIL_AT" ]; then
      printf '%s' '{"error":{"code":"internal","message":"boom"}}' >&2; exit 1
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
    printf '{"result":{"splits":[{"direction":"%s"}]}}' "${dir:-right}" ;;
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
  unset MOCK_SERVER_NEVER_READY MOCK_EMPTY_FOR MOCK_WS_CREATE_JSON MOCK_WS_ID
  export MOCK_TAB_SEQ_FILE="$(mktemp "${TMPROOT%/}/tabseq.XXXXXX")"; print -n 0 > "$MOCK_TAB_SEQ_FILE"
  unset MOCK_TAB_CREATE_FAIL_AT MOCK_STATUS
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
# fixtures drifted: a workspace with four tabs and zero panes is not "four good tabs",
# it is malformed, and separate helpers made a correct classifier look broken.
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
    tabs+="{\"tab_id\":\"$w:t$i\",\"label\":\"$name\"}"
    k=1
    while (( k <= n )); do
      [[ -n "$panes" ]] && panes+=","
      panes+="{\"pane_id\":\"$w:p$pn\",\"tab_id\":\"$w:t$i\",\"workspace_id\":\"$w\",\"cwd\":\"$cwd\"}"
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
FULL=(agents:2 editor:1 runtime:2 git:1)

mkrepo() {  # <path> — a real git repo
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" commit -q --allow-empty -m init
  print -r -- "${1:A}"
}

print -r -- "=== hdev test suite ==="
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
print -r -- "-- A: hdev resolution"
ROOTTMP=$(mkd); CODE="$ROOTTMP/Code"
R1=$(mkrepo "$CODE/Netronix/curato")
R2=$(mkrepo "$CODE/ViuMore/curato")     # same basename, different org
mkdir -p "$ROOTTMP/notrepo"

# Stub layout.sh: record the path it was handed, do nothing else.
LSTUB="$STUBS/layout.sh"
cat > "$LSTUB" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$LAYOUT_ARG"
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

run_hdev() {
  mock_reset
  export LAYOUT_ARG="$(mktemp "${TMPROOT%/}/larg.XXXXXX")"
  export FZFLOG="$(mktemp "${TMPROOT%/}/fzflog.XXXXXX")"
  OUT="$(HOME="$ROOTTMP" HDEV_LAYOUT="$LSTUB" zsh -c "
    source '$FUNCS'; hdev $1" 2>&1)"; RC=$?
}

run_hdev "'$R1'"
eq "$(<$LAYOUT_ARG)" "$R1" "A1 explicit path resolves to that repo"

run_hdev "Netronix/curato"
eq "$(<$LAYOUT_ARG)" "$R1" "A2 path relative to ~/Code resolves"

run_hdev "'$ROOTTMP/notrepo'"
rc_is 1 "A3 a non-repo directory fails"
has "not inside a git repo" "A3 says why"
eq "$(<$LAYOUT_ARG)" "" "A3 layout.sh is never invoked"

# Ambiguity must reach the picker, never silently pick one.
run_hdev "curato"
eq "$(<$LAYOUT_ARG)" "" "A4 an ambiguous basename resolves to nothing"
[[ -s "$FZFLOG" ]] && _pass "A4 the picker is consulted" || _fail "A4 the picker was never invoked"

# The other half: when the picker DOES choose, that choice must be honoured.
MOCK_FZF_SELECT="ViuMore/curato" run_hdev "curato"
eq "$(<$LAYOUT_ARG)" "$R2" "A5 a picker selection resolves to the chosen repo"

# --- B: the linked-worktree guard -------------------------------------------
print -r -- "-- B: linked-worktree guard"
WT="$CODE/Netronix/curato-feature"
git -C "$R1" worktree add -q -b feature "$WT" 2>/dev/null

run_hdev "'$WT'"
rc_is 1 "B1 a linked worktree is refused"
has "linked worktree" "B1 names the reason"
has "Use: dev " "B1 points at dev"
eq "$(<$LAYOUT_ARG)" "" "B1 layout.sh is never invoked"

run_hdev "'$R1'"
eq "$(<$LAYOUT_ARG)" "$R1" "B2 the primary checkout is still allowed"

# --- C: bootstrap -----------------------------------------------------------
print -r -- "-- C: bootstrap"

# HOME must be the fixture root: hl_label derives the label from $HOME/Code, so
# without it every expected label in this suite would be wrong.
run_layout() {  # <mock-setup> <layout.sh args...>
  mock_reset
  eval "$1"
  shift
  OUT="$(HOME="$ROOTTMP" HDEV_NO_ATTACH=1 zsh "$LAYOUT" "$@" 2>&1)"; RC=$?
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

# Panes for one repo spanning two workspaces is ambiguous — refuse, never guess.
run_layout "export HERDR_ENV=1
  export MOCK_PANE_LIST='{\"result\":{\"panes\":[
    {\"pane_id\":\"w7:p1\",\"tab_id\":\"w7:t1\",\"workspace_id\":\"w7\",\"cwd\":\"$R1\"},
    {\"pane_id\":\"w8:p1\",\"tab_id\":\"w8:t1\",\"workspace_id\":\"w8\",\"cwd\":\"$R1\"}]}}'" "$R1"
rc_is 1 "D5 panes spanning two workspaces fails"
has "refusing to guess" "D5 says why"
unlogged "workspace create" "D5 nothing is created"
unlogged "workspace focus" "D5 nothing is focused"

# D6/D7: a failing herdr call must not be reported as success. Before explicit
# propagation both of these exited 0 and went on to attach.
run_layout "export HERDR_ENV=1; export MOCK_FOCUS_RC=1
  mock_topology '$R1' 'Netronix/curato' $FULL" "$R1"
rc_is 1 "D6 a failed focus fails the run"

run_layout "export HERDR_ENV=1; export MOCK_WS_CREATE_RC=1; mock_panes '/nowhere'" "$R1"
rc_is 1 "D7 a failed create fails the run"

# --- E: the managed baseline ------------------------------------------------
print -r -- "-- E: the managed baseline"
L="Netronix/curato"

cls() {  # <mock-setup> → OUT is the classification
  mock_reset; eval "$1"
  OUT="$(HOME="$ROOTTMP" zsh -c "source '$LAYOUT' --source-only; hl_classify w7 '$L'" 2>&1)"; RC=$?
}

cls "mock_topology '$R1' '$L' $FULL"
eq "$OUT" "complete" "E1 the full baseline = complete"

cls "mock_topology '$R1' '$L' $FULL notes:1 scratch:1"
eq "$OUT" "complete" "E2 extra unmanaged tabs do not demote it"

cls "mock_topology '$R1' '$L' agents:2 editor:1 git:1"
eq "$OUT" "provisional" "E3 a missing managed tab = provisional"

# The rename window: correct topology, non-final label.
cls "mock_topology '$R1' '$L (building)' $FULL"
eq "$OUT" "provisional" "E4 correct topology under a (building) label = provisional"

cls "mock_topology '$R1' '$L' agents:2 agents:2 editor:1 runtime:2 git:1"
has "malformed" "E5 a duplicated managed label = malformed"

cls "mock_topology '$R1' '$L' agents:1 editor:1 runtime:2 git:1"
has "malformed" "E5b a managed tab with the wrong pane count = malformed"

# Two panes stacked and two side by side both count 2. Only direction separates them,
# and a fresh-build live gate would never see a split changed after the fact.
cls "mock_topology '$R1' '$L' $FULL; mock_split_dir w7:p1 down"
has "malformed" "E5c an agents tab split the wrong way = malformed"

# Malformed must not mutate anything.
run_layout "export HERDR_ENV=1; mock_topology '$R1' '$L' agents:2 agents:2 editor:1 runtime:2 git:1" "$R1"
rc_is 1 "E6 malformed fails"
unlogged "tab create"       "E6 no tab is created"
unlogged "tab close"        "E6 no tab is closed"
unlogged "pane split"       "E6 no pane is split"
unlogged "workspace rename" "E6 nothing is renamed"

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

# Invalid tab JSON reaches the classifier, which previously returned "provisional"
# with rc=0 and let repair mutate the workspace.
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

# Same for tabs, which previously classified as provisional and let repair mutate.
run_layout "export HERDR_ENV=1
  mock_topology '$R1' 'Netronix/curato' $FULL
  export MOCK_EMPTY_FOR='tab list'" "$R1"
rc_is 1 "F1b an empty tab response fails the run"
unlogged "tab create"       "F1b nothing is created"
unlogged "workspace rename" "F1b nothing is renamed"

# A tab the user labelled "error" is data, not an API failure. Substring matching on
# '"error"' rejected the whole response; the envelope check looks at the top level.
cls "mock_topology '$R1' '$L' $FULL error:1"
eq "$OUT" "complete" "F1c an unmanaged tab labelled 'error' stays complete"

# The converse: a genuine error envelope returned with exit status 0 must be caught.
run_layout "export HERDR_ENV=1
  export MOCK_PANE_LIST='{\"error\":{\"code\":\"internal\",\"message\":\"boom\"}}'" "$R1"
rc_is 1 "F1d an error envelope with exit 0 is rejected"
unlogged "workspace create" "F1d nothing is created"

# --- G: build ---------------------------------------------------------------
print -r -- "-- G: build"
run_layout "export HERDR_ENV=1; mock_panes '/nowhere'" "$R1"
rc_is 0 "G1 a clean build succeeds"
logged "workspace create --cwd $R1 --label Netronix/curato (building) --no-focus" \
  "G1 created under the provisional label, unfocused, with an explicit cwd"

# Ids come from the responses, never guessed. The stub deliberately returns w7:p3,
# not w1:p1, so any predicted id fails here.
logged "pane split --pane w7:p3 --direction right" "G2 the agents pane splits by parsed id"
logged "pane run w7:p3 claude" "G2 claude runs in the parsed root pane"
logged "pane run w7:p9 codex"  "G2 codex runs in the split's parsed id"

logged "tab create --workspace w7 --label editor" "G3 tabs are created with --workspace"
unlogged "--workspace-id"    "G3 the non-existent --workspace-id flag is never used"
unlogged "--target-pane-id"  "G3 the non-existent --target-pane-id flag is never used"

# The runtime split must target that tab's OWN root pane. tab create does not focus,
# so an untargeted split could land on the agents tab instead.
logged "pane split --pane w7:p5 --direction down" "G4 the runtime split targets its own parsed root pane"
logged "pane run w7:p4 nvim ."   "G4 editor runs in its own tab"
logged "pane run w7:p6 lazygit"  "G4 git runs in its own tab"

logged "workspace rename w7 Netronix/curato" "G5 renamed to the final label"
logged "workspace focus w7" "G5 focused once complete"
logged "tab focus w7:t4" "G5 the agents tab is focused, as dev.kdl pinned it"
[[ "$(<$HLOG)" == *"workspace rename w7"*"workspace focus w7"*"tab focus w7:t4"* ]] \
  && _pass "G5 rename precedes focus, and the tab focus comes last" \
  || _fail "G5 rename/focus ordering is wrong"

# Trap: fail on the THIRD tab create, so the workspace is genuinely half-built.
run_layout "export HERDR_ENV=1; mock_panes '/nowhere'; export MOCK_TAB_CREATE_FAIL_AT=3" "$R1"
rc_is 1 "G6 a failed build fails loudly"
logged "workspace close w7" "G6 the trap closes the partial workspace"
logged "tab create --workspace w7 --label git" "G6 it reached the third tab create (git)"
unlogged "workspace rename" "G6 a failed build is never renamed to the final label"

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

# --- H: repair --------------------------------------------------------------
print -r -- "-- H: repair"
run_layout "export HERDR_ENV=1; mock_topology '$R1' 'Netronix/curato' agents:2 editor:1" "$R1"
logged "tab create --workspace w7 --label runtime" "H1 the missing runtime tab is created"
logged "tab create --workspace w7 --label git"     "H1 the missing git tab is created"
unlogged "--label agents" "H1 the existing agents tab is not recreated"
unlogged "--label editor" "H1 the existing editor tab is not recreated"
unlogged "workspace create" "H1 no duplicate workspace"

# The rename window: everything present, only the label wrong. Rename ALONE.
run_layout "export HERDR_ENV=1; mock_topology '$R1' 'Netronix/curato (building)' $FULL" "$R1"
rc_is 0 "H2 the rename window is repaired"
eq "$(count_logged 'tab create --workspace w7 --label agents')" "0" "H2 no tab is created"
unlogged "pane split" "H2 nothing is split"
logged "workspace rename w7 Netronix/curato" "H2 renamed to the final label"

# Extra tabs survive repair untouched.
run_layout "export HERDR_ENV=1; mock_topology '$R1' 'Netronix/curato' agents:2 editor:1 notes:1" "$R1"
unlogged "tab close" "H3 the user's own tab is never closed"
unlogged "--label notes" "H3 the user's own tab is never recreated"

# --- J: tab jumps resolve by label ------------------------------------------
print -r -- "-- J: tab-goto"

goto() {  # <mock-setup> <label>
  mock_reset; eval "$1"
  OUT="$(HERDR_ACTIVE_WORKSPACE_ID=w7 zsh "$TABGOTO" "$2" 2>&1)"; RC=$?
}

goto "mock_tabs agents editor runtime git" runtime
rc_is 0 "J1 a known label resolves"
logged "tab focus w7:t3" "J1 focuses the tab carrying that label"

# Order-independence: repair appends, and herdr 0.8.2 has no `tab move`, so a repaired
# workspace can hold its managed tabs in any order. An index would land on the wrong one.
goto "mock_tabs git agents editor runtime" git
rc_is 0 "J2 resolves in a reordered workspace"
logged "tab focus w7:t1" "J2 follows the label, not the position"

goto "mock_tabs agents editor" git
rc_is 1 "J3 a missing label fails"
has "no tab labelled" "J3 says why"
unlogged "tab focus" "J3 no tab is focused"

goto "mock_tabs agents agents" agents
rc_is 1 "J4 an ambiguous label fails rather than picking one"
has "refusing to guess" "J4 says why"
unlogged "tab focus" "J4 no tab is focused"

# No injected context: say so rather than falling back to the globally-focused
# workspace, which is racy under a shared session view.
mock_reset; mock_tabs agents editor runtime git
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
goto "mock_tabs agents editor" git
logged "notification show" "J8 a failed jump is surfaced as a notification"

# J9: the tab exists at list time and is gone by focus time — the real race, since
# nothing holds a lock between the two calls. Detached execution makes an unhandled
# failure here indistinguishable from a key that does nothing.
goto "mock_tabs agents editor runtime git; export MOCK_TAB_FOCUS_RC=1" runtime
rc_is 1 "J9 a focus that fails after a successful list fails the jump"
has "could not focus" "J9 the diagnostic names the focus failure"
logged "tab focus w7:t3" "J9 the focus was genuinely attempted"
logged "notification show" "J9 the failure is surfaced as a notification"

finish
