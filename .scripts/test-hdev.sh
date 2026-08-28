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
case "$*" in
  "status server"|"status")
    printf '%s\n' "${MOCK_STATUS:-server:
  status: not running}" ;;
  "workspace list")
    [ "${MOCK_SERVER_UP:-1}" = "0" ] && {
      printf '%s' '{"error":{"code":"server_not_running","message":"no herdr server"}}'
      exit 1; }
    printf '%s' "${MOCK_WS_LIST:-{\"result\":{\"workspaces\":[]}}}" ;;
  "pane list"*)    printf '%s' "${MOCK_PANE_LIST:-{\"result\":{\"panes\":[]}}}" ;;
  "tab list"*)     printf '%s' "${MOCK_TAB_LIST:-{\"result\":{\"tabs\":[]}}}" ;;
  "workspace create"*)
    exit_rc="${MOCK_WS_CREATE_RC:-0}"; [ "$exit_rc" != 0 ] && exit "$exit_rc"
    printf '%s' '{"result":{"workspace":{"workspace_id":"w7"},"tab":{"tab_id":"w7:t4"},"root_pane":{"pane_id":"w7:p3"}}}' ;;
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
  export MOCK_WS_CREATE_RC=0
  export MOCK_TAB_SEQ_FILE="$(mktemp "${TMPROOT%/}/tabseq.XXXXXX")"; print -n 0 > "$MOCK_TAB_SEQ_FILE"
  unset MOCK_TAB_CREATE_FAIL_AT MOCK_STATUS
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
mock_topology() {
  local cwd="$1" label="$2"; shift 2
  local i=1 pn=1 tabs="" panes="" spec name n k
  for spec in "$@"; do
    name="${spec%%:*}"; n="${spec##*:}"
    [[ -n "$tabs" ]] && tabs+=","
    tabs+="{\"tab_id\":\"w7:t$i\",\"label\":\"$name\"}"
    k=1
    while (( k <= n )); do
      [[ -n "$panes" ]] && panes+=","
      panes+="{\"pane_id\":\"w7:p$pn\",\"tab_id\":\"w7:t$i\",\"workspace_id\":\"w7\",\"cwd\":\"$cwd\"}"
      # The direction the baseline expects for this label, so a healthy fixture is
      # healthy without every test restating its geometry.
      case "$name" in
        runtime) print -r -- "w7:p$pn down"  >> "$MOCK_LAYOUT_FILE" ;;
        *)       print -r -- "w7:p$pn right" >> "$MOCK_LAYOUT_FILE" ;;
      esac
      (( pn++ )); (( k++ ))
    done
    (( i++ ))
  done
  export MOCK_TAB_LIST="{\"result\":{\"tabs\":[$tabs]}}"
  export MOCK_PANE_LIST="{\"result\":{\"panes\":[$panes]}}"
  export MOCK_WS_LIST="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"label\":\"$label\"}]}}"
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

finish
