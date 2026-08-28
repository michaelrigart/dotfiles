# Herdr Trial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Herdr beside Zellij as a reversible trial — a four-tab project workspace built by one script, reachable from a shell (`hdev`) and from inside Herdr (a plugin action), with Zellij and the `dev`/`wt`/`wt-rm` lifecycle untouched.

**Architecture:** `layout.sh` owns the topology and is the only thing that talks to the Herdr CLI. `hdev` (zsh) resolves a repo and delegates; a plugin action calls the same script in `--current` mode to repair a workspace in place. Identity is the canonical repo path, read from pane `cwd`; correctness comes from a lock taken before any scan and a "managed baseline" classification that tolerates the user's own tabs and refuses to guess about malformed ones.

**Tech Stack:** zsh, herdr 0.8.2 CLI + JSON socket API, `jq`, chezmoi (source-first, `modify_` scripts for merge-preserving JSON/TOML), Homebrew.

**Spec:** `docs/superpowers/specs/2026-08-27-herdr-trial-design.md`

**Status:** In progress

## Global Constraints

- **Branch:** `feat/herdr-trial`. Commit per task. **Never add agent attribution** to commit messages — no `Co-authored-by`, no "Generated with", no session links.
- **chezmoi is source-first.** Never edit a deployed file in `$HOME`. Edit `~/.local/share/chezmoi/...` then `chezmoi apply <target>`. `chezmoi apply` needs an **unsandboxed** shell: `Brewfile.tmpl` reads `scutil --get ComputerName`, which returns a generic `"MacBook Pro"` under the sandbox and fails the machine guard.
- **herdr version floor: 0.8.2.** Exact CLI forms, verified — no others exist:
  - `herdr workspace create [--cwd PATH] [--label TEXT] [--focus|--no-focus]`
  - `herdr tab create [--workspace <workspace_id>] [--cwd PATH] [--label TEXT] [--focus|--no-focus]`
  - `herdr tab list [--workspace <workspace_id>]`, `tab focus <tab_id>`, `tab rename <tab_id> <label>`
  - `herdr pane split [PANE_ID] | --pane <ID> --direction <right|down> [--cwd PATH] [--no-focus]`
  - `herdr pane run <PANE_ID> <COMMAND>...`, `herdr pane list [--workspace <id>]`
  - **`--workspace-id` and `--target-pane-id` do not exist.** Using them fails.
  - There is **no** `tab move` and **no** pane-clear method.
- **IDs are parsed from JSON, never predicted.** `workspace create` → `.result.workspace.workspace_id`, `.result.tab.tab_id`, `.result.root_pane.pane_id`. `tab create` → `.result.tab.tab_id`, `.result.root_pane.pane_id`. `pane split` → `.result.pane.pane_id`.
- **Managed labels:** exactly `agents`, `editor`, `runtime`, `git`. Geometry: `agents` = 2 panes (split right), `runtime` = 2 panes (split down), `editor` and `git` = 1 pane.
- **Unmanaged tabs are never created, closed, renamed or counted.**
- **Malformed workspaces fail without mutation** — no `create`, `close`, `split` or `rename` may be issued.
- **Lock before scan**, always. Released on every exit path.
- **Tab jumps resolve by unique label, never by index.**
- **Construction passes `--cwd <repo>` explicitly and runs `--no-focus`** until complete.
- Tests pin exact values. A test that cannot go red is not coverage.

---

### Task 0: Branch and preflight

Everything after this touches deployed config. Do it from a branch, not `main`.

**Files:** none.

- [ ] **Step 1: Confirm a clean tree and branch**

```bash
cd ~/.local/share/chezmoi
git status --short          # must be empty
git checkout -b feat/herdr-trial
```

Expected: empty status, then `feat/herdr-trial`. **If the tree is dirty, stop** — an
unrelated in-flight change must not be swept into this work.

- [ ] **Step 2: Confirm the binary matches the plan's assumptions**

```bash
herdr --version                                  # expect 0.8.2 or later
herdr tab create -h  | grep -q -- --workspace  && echo "tab --workspace OK"
herdr pane split -h  | grep -q -- --pane       && echo "pane --pane OK"
herdr tab 2>&1       | grep -q "tab move"      && echo "WARNING: tab move now exists"
```

Expected: both `OK` lines; no warning. A newer herdr that renamed a flag invalidates
the construction sequence — stop and report rather than adapting silently.

---

### Task 1: Herdr config, and falsifying the Alt keybindings

The spec names Alt-key viability as the most likely thing to fail. Do it first: everything else is wasted if `alt+a` never arrives.

**Files:**
- Create: `dot_config/herdr/config.toml`

**Interfaces:**
- Consumes: nothing.
- Produces: `~/.config/herdr/config.toml` with `[keys]` bindings that later tasks' `[[keys.command]]` entries extend.

- [ ] **Step 1: Write the config**

Create `dot_config/herdr/config.toml`. Only deliberate divergences from `herdr --default-config` — everything omitted stays on the shipped default so an upstream change stays visible.

```toml
# Herdr configuration — managed by chezmoi
# (source: dot_config/herdr/config.toml → ~/.config/herdr/config.toml)
#
# Only deliberate divergences from `herdr --default-config` live here. Anything
# omitted follows the shipped default, so an upstream default change surfaces as a
# behaviour change rather than being silently pinned.
#
# Keybinding model mirrors the Zellij setup it runs beside:
#   Ctrl-h/j/k/l  → move between panes
#   Alt + <key>   → tabs, zoom, panes, detach
# Alt rather than digits because digits need Shift on AZERTY. Ghostty is configured
# `macos-option-as-alt = left`, so this works from the LEFT Option key only.

# First run otherwise shows onboarding and may write back to this file, which chezmoi
# owns — the write would surface as drift and be reverted on the next apply.
onboarding = false

[theme]
name = "tokyo-night"

[session]
# The single setting the Claude/Codex integrations exist to serve. It is the shipped
# default but arrives commented out; pinning it keeps the dependency legible.
resume_agents_on_restore = true

[keys]
# Kept as an escape hatch. Unlike Zellij's stock Ctrl leaders, herdr's prefix does not
# shadow shell readline or Neovim keys, so nothing needs clearing.
prefix = "ctrl+b"

zoom = "alt+z"
split_vertical = "alt+n"
new_tab = "alt+t"
detach = "alt+w"
toggle_sidebar = "alt+b"

focus_pane_left = "ctrl+h"
focus_pane_down = "ctrl+j"
focus_pane_up = "ctrl+k"
focus_pane_right = "ctrl+l"

# The on-demand `bin/rails console` slot. Session-modal, so it does not disturb the
# tab layout — better than Zellij's floating layer, where Alt-n added *floating* panes
# while the layer was visible.
[[keys.command]]
key = "alt+p"
type = "popup"
command = "exec \"${SHELL:-sh}\""
description = "scratch shell"
width = "80%"
height = "80%"
```

Note there is deliberately **no `alt+k`**: herdr 0.8.2 has no clear method, and the only implementation would inject control sequences into whatever occupies the pane.

- [ ] **Step 2: Apply it**

```bash
chezmoi apply ~/.config/herdr/config.toml
```

Run **unsandboxed**. Expected: file appears at `~/.config/herdr/config.toml`.

- [ ] **Step 3: Validate the config**

Use `herdr config check`. **Not** `herdr status client` — that reports nothing about
config validity: a file containing `not_a_real_action = "alt+q"` produces byte-identical
output to a good one, so checking there is a step that cannot fail.

```bash
herdr config check
```

Expected: `config: ok`.

Note `config check` **exits 0 either way** — the same exit-status trap as
`herdr status server`. The string is the signal. Confirm the check can go red before
trusting it green:

```bash
printf '[keys]\nnot_a_real_action = "alt+q"\n' > "$TMPDIR/bad.toml"
HERDR_CONFIG_PATH="$TMPDIR/bad.toml" herdr config check
```

Expected: `config: issues found` / `unknown config key keys.not_a_real_action`.

- [ ] **Step 4: Falsify the Alt bindings by hand**

```bash
herdr
```

Order matters. Each step must produce a **visible** change, or the check is vacuous —
`alt+z` in a single-pane tab, for instance, can look identical zoomed and not. Use the
**left** Option key throughout:

1. `alt+n` — a second pane appears.
2. `alt+z` twice — that pane visibly zooms, then restores.
3. `alt+t` — a new tab appears.
4. `alt+b` twice — the sidebar hides, then returns.
5. `alt+p` — the popup opens; exit it.
6. Confirm the Tokyo Night palette matches Ghostty.
7. `alt+w` — detaches back to the shell. Last, because it ends the session view.

**If any binding does nothing, stop before Task 3.** The fallback is `[keys.indexed]`
with `ctrl` (`ctrl+1..9`), which loses the AZERTY property that motivated the scheme —
a decision for the user, not a silent substitution.

**If Alt does not arrive**, stop and report before continuing. The fallback is `[keys.indexed]` with `ctrl` (`ctrl+1..9`), which loses the AZERTY property — that is a decision for the user, not a silent substitution.

- [ ] **Step 5: Verify the theme**

Confirm the TUI renders in Tokyo Night, matching Ghostty. Then detach with `alt+w`.

- [ ] **Step 6: Commit**

```bash
git add dot_config/herdr/config.toml
git commit -m "Add the herdr config: Tokyo Night, Alt keybindings"
```

---

### Task 2: Test harness and the `herdr` stub

Everything downstream is tested through this. Build it once, properly.

**Files:**
- Create: `.scripts/test-hdev.sh`

**Interfaces:**
- Produces: helpers `_pass`/`_fail`/`has`/`hasnt`/`rc_is`/`eq`/`logged`/`unlogged`, a `herdr` stub on `PATH` logging every invocation to `$HLOG`, and `mock_reset`/`mock_workspace`/`mock_panes`/`mock_tabs` for shaping stub responses. Later tasks add sections to this file.

- [ ] **Step 1: Write the harness**

Mirrors `.scripts/test-wt-functions.sh`: real git repos, stubbed multiplexer, assertions on a logged invocation trail so *ordering* and *absence* are both testable.

```zsh
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
  "workspace list")
    [ "${MOCK_SERVER_UP:-1}" = "0" ] && {
      printf '%s' '{"error":{"code":"server_not_running","message":"no herdr server"}}'
      exit 1; }
    printf '%s' "$MOCK_WS_LIST" ;;
  "pane list"*)    printf '%s' "$MOCK_PANE_LIST" ;;
  "tab list"*)     printf '%s' "$MOCK_TAB_LIST" ;;
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
finish
```

Later tasks insert their sections immediately **above** the `finish` call — never after it.

- [ ] **Step 2: Run it**

```bash
zsh .scripts/test-hdev.sh
```

Expected: prints the header, exits 0, no tests yet. **Must be run with `zsh`, not `bash`** — the harness uses zsh-only syntax (`${0:h}`, `${1:A}`).

- [ ] **Step 3: Commit**

```bash
git add .scripts/test-hdev.sh
git commit -m "Add the hdev test harness and herdr stub"
```

---

### Task 3: `hdev` — resolution and the linked-worktree guard

The guard is the safety-critical half. `wt-rm` stops Zellij sessions before removing a worktree because a live process holding the directory open is what leaves husks; it cannot see Herdr. Confining Herdr to primary checkouts is what keeps that invariant true.

**Files:**
- Modify: `dot_config/zsh/functions` (append `hdev`; **do not touch `dev`, `wt`, `wt-rm`**)
- Modify: `.scripts/test-hdev.sh` (sections A, B)

**Interfaces:**
- Consumes: `_wt_git` (existing, clears `GIT_DIR`/`GIT_WORK_TREE` routing).
- Produces: `hdev [target]` → resolves a repo, refuses linked worktrees, then `exec`s `~/.config/herdr/layout.sh <canonical-repo-path>`.

- [ ] **Step 1: Write the failing tests**

Append to `.scripts/test-hdev.sh`:

```zsh
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

run_hdev() {
  mock_reset
  export LAYOUT_ARG="$(mktemp "${TMPROOT%/}/larg.XXXXXX")"
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

# Ambiguity must reach the picker, never silently pick one. fzf is stubbed to decline
# (exit 1), so a correct hdev resolves nothing and invokes nothing.
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

export FZFLOG="$(mktemp "${TMPROOT%/}/fzflog.XXXXXX")"
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

# `has "dev"` would be vacuous here: the failure output during the red phase is
# "command not found: hdev", which contains "dev". Match the guidance line itself.
run_hdev "'$WT'"
rc_is 1 "B1 a linked worktree is refused"
has "linked worktree" "B1 names the reason"
has "Use: dev " "B1 points at dev"
eq "$(<$LAYOUT_ARG)" "" "B1 layout.sh is never invoked"

run_hdev "'$R1'"
eq "$(<$LAYOUT_ARG)" "$R1" "B2 the primary checkout is still allowed"
```

- [ ] **Step 2: Run to verify they fail**

```bash
zsh .scripts/test-hdev.sh
```

Expected: FAIL on A1 — `hdev: command not found`.

- [ ] **Step 3: Implement `hdev`**

Append to `dot_config/zsh/functions`, after `dev`. `dev` itself is not modified.

```zsh
# hdev — open (or return to) a project in its Herdr workspace. The Herdr-side
# counterpart to `dev`, running beside it during the trial; `dev` is unchanged.
#   hdev                   pick from all repos under ~/Code (fzf)
#   hdev curato            by name: exact basename → case-insensitive substring → fzf
#   hdev Netronix/curato   path relative to ~/Code
#   hdev .                 the git repo containing the current directory
#
# Resolution only. Everything about Herdr lives in layout.sh, which is also what the
# `dev.layout.apply` plugin action calls — one topology definition, two entry points.
hdev() {
  emulate -L zsh
  setopt local_options null_glob extended_glob

  local code="$HOME/Code" repo arg="$1"
  local -a repos=( "$code"/*/.git(N:h) "$code"/*/*/.git(N:h) )

  if [[ "$arg" == "." || ( -n "$arg" && -d "$arg" ) ]]; then
    repo="$(_wt_git -C "${arg:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
      || { print -ru2 -- "hdev: '${arg:-$PWD}' is not inside a git repo."; return 1 }
  elif [[ -n "$arg" && -e "$code/$arg/.git" ]]; then
    repo="$code/$arg"
  else
    local -a hits
    if [[ -z "$arg" ]]; then
      hits=( $repos )
    else
      hits=( ${(M)repos:#*/$arg} )                      # exact basename
      (( ${#hits} )) || hits=( ${(M)repos:#(#i)*$arg*} ) # case-insensitive substring
    fi
    if (( ${#hits} == 1 )); then
      repo="${hits[1]}"
    else
      local -a pool; (( ${#hits} )) && pool=( $hits ) || pool=( $repos )
      local sel
      sel="$(print -rl -- ${pool[@]#$code/} | fzf --prompt='hdev > ' ${arg:+--query=$arg})" || return 0
      [[ -n "$sel" ]] || return 0
      repo="$code/$sel"
    fi
  fi

  repo="${repo:A}"
  [[ -n "$repo" && -e "$repo/.git" ]] || { print -ru2 -- "hdev: no git repo resolved."; return 1 }

  # Refuse linked worktrees. wt-rm's teardown stops the *Zellij* session before
  # removing a checkout — "a live process holding the directory open is what leaves
  # an empty tmp/ husk behind" — and it cannot see Herdr. A Herdr workspace on a wt
  # worktree would survive that shutdown and write into a deleted directory. Keeping
  # the trial on primary checkouts means no teardown lifecycle competes with it.
  #
  # A primary checkout has .git as a directory; a linked worktree has it as a file
  # pointing elsewhere, and its common dir sits outside the checkout.
  if [[ -f "$repo/.git" ]]; then
    print -ru2 -- "hdev: $repo is a linked worktree — refusing."
    print -ru2 -- "    Herdr is not wired into wt-rm's teardown, so a workspace here could"
    print -ru2 -- "    outlive the checkout. Use: dev $repo"
    return 1
  fi

  "${HDEV_LAYOUT:-$HOME/.config/herdr/layout.sh}" "$repo"
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
zsh .scripts/test-hdev.sh
```

Expected: sections A and B all PASS.

- [ ] **Step 5: Commit**

```bash
git add dot_config/zsh/functions .scripts/test-hdev.sh
git commit -m "Add hdev: repo resolution and the linked-worktree guard"
```

---

### Task 4: `layout.sh` — bootstrap and readiness

**Files:**
- Create: `dot_config/herdr/executable_layout.sh`
- Modify: `.scripts/test-hdev.sh` (section C)

**Interfaces:**
- Consumes: `hdev` passes a canonical repo path as `$1`.
- Produces: `layout.sh <repo>` / `layout.sh --current`. Internal functions later tasks extend: `hl_server_ready`, `hl_ensure_server`, `hl_api` (runs `herdr` and returns JSON on stdout, non-zero on error).

- [ ] **Step 1: Write the failing tests**

```zsh
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

# Inside herdr: never starts a server, never attaches a client.
run_layout "export HERDR_ENV=1" "$R1"
unlogged "server" "C1 inside herdr, no server is started"

# Outside herdr with a server already up: also must not start a second one.
run_layout "unset HERDR_ENV; export MOCK_SERVER_UP=1" "$R1"
eq "$(count_logged 'server')" "0" "C2 an existing server is not restarted"

# Outside herdr with no server: probes, then starts exactly one.
run_layout "unset HERDR_ENV; export MOCK_SERVER_UP=0 HDEV_NO_ATTACH=1 HL_READY_TRIES=2" "$R1"
logged "workspace list" "C3 readiness is probed with a real failing call"
rc_is 1 "C3 unreachable server fails rather than hanging"
has "did not become ready" "C3 reports the timeout"
```

- [ ] **Step 2: Run to verify they fail**

Expected: FAIL — `layout.sh` does not exist.

- [ ] **Step 3: Implement the bootstrap half**

Create `dot_config/herdr/executable_layout.sh`:

```zsh
#!/usr/bin/env zsh
# layout.sh — build, focus or repair a project's Herdr workspace.
# Managed by chezmoi (source: dot_config/herdr/executable_layout.sh).
#
#   layout.sh <repo-path>   build-or-focus, called by hdev from a shell
#   layout.sh --current     repair in place, called by the dev.layout.apply plugin
#
# The single definition of what a project workspace looks like. Both entry points go
# through it, so there is no second copy to drift.
emulate -L zsh
# no_bg_nice: zsh sets BG_NICE by default, so `cmd &` renices the job. That renice
# fails outright where setpriority is denied (a sandbox, some CI), taking the
# backgrounded server with it — and even where it succeeds, quietly deprioritising the
# Herdr server every agent runs inside is not what anyone wants.
#
# NOT err_return: it does not fire for a command whose status is already being tested,
# which is exactly the shape used below, so failure propagation is explicit instead.
setopt local_options no_unset pipe_fail no_bg_nice

MANAGED_TABS=(agents editor runtime git)
BUILDING_SUFFIX=" (building)"

die() { print -ru2 -- "layout.sh: $*"; exit 1 }

# hl_api — run a herdr CLI call, return its JSON on stdout. Non-zero on failure, with
# the server's message. Every call goes through here so failures are uniform: the old
# Zellij shape returned 0 from every step while the layout silently failed, and exit
# status was no guard.
hl_api() {
  local out rc
  out="$(command herdr "$@" 2>&1)"; rc=$?
  if (( rc != 0 )) || [[ "$out" == *'"error"'* ]]; then
    print -ru2 -- "layout.sh: herdr $* failed: $out"
    return 1
  fi
  print -r -- "$out"
}

# hl_server_ready — is a server actually answering? `herdr status server` exits 0 even
# while reporting "not running", so exit status is not a readiness signal and there is
# no CLI `ping`. The probe is therefore a real call that fails when the server is down.
hl_server_ready() {
  local out
  out="$(command herdr workspace list 2>&1)" || return 1
  [[ "$out" == *server_not_running* ]] && return 1
  return 0
}

hl_ensure_server() {
  hl_server_ready && return 0
  # `herdr server` runs in the foreground: background and detach it explicitly. A
  # second hdev racing this must neither fail nor start a second server, so the
  # start is fire-and-forget and readiness is what we actually wait on.
  (command herdr server >/dev/null 2>&1 &) || true
  local tries="${HL_READY_TRIES:-40}" i=1
  while (( i <= tries )); do
    hl_server_ready && return 0
    sleep 0.25
    (( i++ ))
  done
  die "the herdr server did not become ready after $(( tries / 4 ))s"
}

main() {
  local mode repo
  if [[ "${1:-}" == "--current" ]]; then
    mode=current
  else
    mode=path
    repo="${1:?usage: layout.sh <repo-path> | --current}"
    [[ -d "$repo" ]] || die "no such directory: $repo"
    repo="${repo:A}"
  fi

  if [[ -z "${HERDR_ENV:-}" ]]; then
    hl_ensure_server
  fi

  # Workspace handling arrives in Tasks 5-8.

  hl_attach
}

# hl_attach — from a shell, the point of hdev is to end up *inside* Herdr. Build or
# focus first, then hand the terminal over. Inside Herdr there is nothing to attach to,
# and HDEV_NO_ATTACH lets tests and scripted runs stop short of a blocking TUI.
hl_attach() {
  [[ -n "${HERDR_ENV:-}" ]] && return 0
  [[ -n "${HDEV_NO_ATTACH:-}" ]] && return 0
  exec command herdr
}

main "$@"
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
zsh .scripts/test-hdev.sh
```

Expected: section C passes.

- [ ] **Step 5: Commit**

```bash
git add dot_config/herdr/executable_layout.sh .scripts/test-hdev.sh
git commit -m "Add layout.sh bootstrap: headless server start and readiness probe"
```

---

### Task 5: Identity — lock before scan, path matching, loud ambiguity

**Files:**
- Modify: `dot_config/herdr/executable_layout.sh`
- Modify: `.scripts/test-hdev.sh` (section D)

**Interfaces:**
- Produces: `hl_lock <canonical-path>`, `hl_find_workspace <canonical-path>` → prints a `workspace_id` or nothing; exits non-zero on ambiguity.

- [ ] **Step 1: Write the failing tests**

```zsh
# --- D: identity ------------------------------------------------------------
print -r -- "-- D: identity"

# A workspace whose panes sit at this repo → found.
run_layout "export HERDR_ENV=1; mock_topology '$R1' 'Netronix/curato' \$FULL" "$R1"
logged "workspace focus w7" "D1 a path match is focused"
unlogged "workspace create" "D1 nothing is created"

# Same basename, different org: must NOT match.
run_layout "export HERDR_ENV=1; mock_topology '$R1' 'Netronix/curato' \$FULL" "$R2"
logged "workspace create" "D2 a different repo with the same basename builds its own"
unlogged "workspace focus w7" "D2 the other workspace is not focused"

# Label says curato, panes say elsewhere → refuse rather than trust the label.
run_layout "export HERDR_ENV=1; mock_topology '/somewhere/else' 'Netronix/curato' \$FULL" "$R1"
logged "workspace create" "D3 a label match with a mismatched path is not focused"

# The lock is taken before any scan.
run_layout "export HERDR_ENV=1; export HL_TRACE_LOCK=1; mock_topology '$R1' 'Netronix/curato' \$FULL" "$R1"
has "LOCK-ACQUIRED" "D4 the lock is acquired"
[[ "$OUT" == *"LOCK-ACQUIRED"*"SCAN"* ]] \
  && _pass "D4 lock precedes scan" || _fail "D4 scan happened before the lock"
```

- [ ] **Step 2: Run to verify they fail**

Expected: FAIL — nothing is focused or created yet.

- [ ] **Step 3: Implement**

Add to `layout.sh` above `main`:

```zsh
# hl_lock — serialise per canonical repo path. Acquired BEFORE any scan, and the scan
# repeated underneath it: classifying first and locking second permits a delayed
# duplicate, where B scans empty, waits while A builds and releases, then acts on its
# stale observation and creates a second workspace for the same repo.
#
# `zsystem flock`, matching _wt_lock in zsh/functions — NOT a mkdir sentinel. The
# reason is stated there: an fcntl record lock is released by the kernel when the
# process dies, "the backstop for every path an explicit unlock cannot reach." A
# mkdir lock has no such backstop, so one SIGKILL would wedge that repository until
# someone removed the directory by hand.
#
# zsystem opens but does not create the lock file, so it must exist first.
hl_lock() {
  local key="${1//\//-}" dir="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-layout"
  mkdir -p "$dir"
  HL_LOCKFILE="$dir/${key#-}.lock"
  : >>"$HL_LOCKFILE"
  zmodload -F zsh/system b:zsystem 2>/dev/null

  [[ -n "${HL_LOCK_DELAY:-}" ]] && sleep "$HL_LOCK_DELAY"

  if ! zsystem flock -t 10 "$HL_LOCKFILE" 2>/dev/null; then
    die "another layout.sh has held the lock for $1 for over 10s"
  fi
  [[ -n "${HL_TRACE_LOCK:-}" ]] && print -ru2 -- "LOCK-ACQUIRED"
}

# hl_find_workspace — the workspace whose panes live at this path, if any.
# Identity is the canonical path, not the label: WorkspaceInfo carries no cwd, but
# PaneInfo carries `cwd`, and labels are mutable and non-unique.
hl_find_workspace() {
  local repo="$1" ws panes ids
  # stderr, not stdout: this function's stdout IS its return value (ws="$(...)"), so a
  # trace line printed there would be captured into the workspace id and corrupt it.
  [[ -n "${HL_TRACE_LOCK:-}" ]] && print -ru2 -- "SCAN"
  panes="$(hl_api pane list)" || return 1
  ids=( ${(f)"$(print -r -- "$panes" | jq -r --arg d "$repo" \
        '.result.panes[] | select(.cwd == $d) | .workspace_id' | sort -u)"} )
  ids=( ${ids:#} )
  (( ${#ids} == 0 )) && return 0
  (( ${#ids} > 1 )) && die "panes for $repo span workspaces: ${ids[*]} — refusing to guess"
  print -r -- "${ids[1]}"
}
```

And extend `main` after `hl_ensure_server`:

```zsh
  if [[ "$mode" == path ]]; then
    hl_lock "$repo"
    local ws; ws="$(hl_find_workspace "$repo")" || exit 1
    if [[ -n "$ws" ]]; then
      hl_reconcile "$ws" "$repo"
    else
      hl_build "$repo"
    fi
  fi
```

- [ ] **Step 4: Add temporary stubs so the file runs**

```zsh
hl_reconcile() { hl_api workspace focus "$1" >/dev/null }
hl_build()     { hl_api workspace create --cwd "$1" --label "x" --no-focus >/dev/null }
```

These are replaced in Tasks 6-7. They exist so section D can go green now.

- [ ] **Step 5: Run tests to verify they pass**

Expected: section D passes.

- [ ] **Step 6: Commit**

```bash
git add dot_config/herdr/executable_layout.sh .scripts/test-hdev.sh
git commit -m "Add path-based workspace identity with lock-before-scan"
```

---

### Task 6: Classification — the managed baseline

**Files:**
- Modify: `dot_config/herdr/executable_layout.sh`
- Modify: `.scripts/test-hdev.sh` (section E)

**Interfaces:**
- Produces: `hl_classify <workspace_id> <final-label>` → prints `complete`, `provisional`, or `malformed:<reason>`.

- [ ] **Step 1: Write the failing tests**

```zsh
# --- E: classification ------------------------------------------------------
print -r -- "-- E: the managed baseline"
L="Netronix/curato"

cls() {  # <mock-setup> → OUT is the classification
  mock_reset; eval "$1"
  OUT="$(HOME="$ROOTTMP" zsh -c "source '$LAYOUT' --source-only; hl_classify w7 '$L'" 2>&1)"; RC=$?
}

cls "mock_topology '$R1' '$L' \$FULL"
eq "$OUT" "complete" "E1 the full baseline = complete"

cls "mock_topology '$R1' '$L' \$FULL notes:1 scratch:1"
eq "$OUT" "complete" "E2 extra unmanaged tabs do not demote it"

cls "mock_topology '$R1' '$L' agents:2 editor:1 git:1"
eq "$OUT" "provisional" "E3 a missing managed tab = provisional"

# The rename window: correct topology, non-final label. Complete in every respect
# except the one that marks it finished.
cls "mock_topology '$R1' '$L (building)' \$FULL"
eq "$OUT" "provisional" "E4 correct topology under a (building) label = provisional"

cls "mock_topology '$R1' '$L' agents:2 agents:2 editor:1 runtime:2 git:1"
has "malformed" "E5 a duplicated managed label = malformed"

# Geometry, not just names: a single-pane agents tab is malformed, and this is the
# case a name-only check certified as healthy.
cls "mock_topology '$R1' '$L' agents:1 editor:1 runtime:2 git:1"
has "malformed" "E5b a managed tab with the wrong pane count = malformed"

# Two panes stacked and two side by side both count 2. Only direction separates them,
# and a fresh-build live gate would never see a split changed after the fact.
cls "mock_topology '$R1' '$L' \$FULL; mock_split_dir w7:p1 down"
has "malformed" "E5c an agents tab split the wrong way = malformed"

# Malformed must not mutate anything.
run_layout "export HERDR_ENV=1; mock_topology '$R1' '$L' agents:2 agents:2 editor:1 runtime:2 git:1" "$R1"
rc_is 1 "E6 malformed fails"
unlogged "tab create"   "E6 no tab is created"
unlogged "tab close"    "E6 no tab is closed"
unlogged "pane split"   "E6 no pane is split"
unlogged "workspace rename" "E6 nothing is renamed"
```

- [ ] **Step 2: Run to verify they fail**

Expected: FAIL — `hl_classify` undefined.

- [ ] **Step 3: Implement**

Add a source-only guard at the very bottom of `layout.sh`, replacing the bare `main "$@"`:

```zsh
# Allow the test suite to source the helpers without running anything.
if [[ "${1:-}" == "--source-only" ]]; then
  return 0 2>/dev/null || exit 0
fi
main "$@"
```

And add `hl_classify`:

```zsh
# hl_classify — complete / provisional / malformed, over the MANAGED baseline only.
#
# Counting all tabs is wrong in both directions: alt+t exists, so a user's fifth tab
# is ordinary use and must not demote a healthy workspace; and a dead build can carry
# all four names while missing a split, which a name-only check would certify.
#
# Malformed never triggers repair. Fixing a duplicated label means choosing which one
# to destroy, and nothing here knows enough to choose safely.
hl_classify() {
  local ws="$1" final="$2" tabs labels count label tab_id panes n
  tabs="$(hl_api tab list --workspace "$ws")" || return 1

  for label in $MANAGED_TABS; do
    count=$(print -r -- "$tabs" | jq -r --arg l "$label" \
              '[.result.tabs[] | select(.label == $l)] | length')
    (( count > 1 )) && { print -r -- "malformed: $count tabs labelled '$label'"; return 0 }
  done

  local missing=0
  for label in $MANAGED_TABS; do
    tab_id=$(print -r -- "$tabs" | jq -r --arg l "$label" \
              '.result.tabs[] | select(.label == $l) | .tab_id' | head -1)
    if [[ -z "$tab_id" ]]; then missing=1; continue; fi

    # Geometry: agents and runtime hold two panes, editor and git one.
    panes="$(hl_api pane list --workspace "$ws")" || return 1
    n=$(print -r -- "$panes" | jq -r --arg t "$tab_id" \
          '[.result.panes[] | select(.tab_id == $t)] | length')
    local want=1
    [[ "$label" == agents || "$label" == runtime ]] && want=2
    # Zero panes is malformed, not "not yet checked". An earlier draft exempted 0 to
    # keep a thin fixture green — precisely the escape hatch that makes a test unable
    # to go red.
    if [[ "$n" != "$want" ]]; then
      print -r -- "malformed: tab '$label' has $n panes, expected $want"; return 0
    fi

    # Direction, not just count: two panes side by side and two stacked both count 2.
    # PaneLayoutSnapshot exposes .splits[].direction, so this is checkable here — and
    # it has to be, because a live gate that only ever inspects a fresh build cannot
    # see a workspace whose split was changed afterwards. That drift is exactly what
    # classification exists to catch.
    local want_dir="" first_pane dir
    [[ "$label" == agents ]]  && want_dir=right
    [[ "$label" == runtime ]] && want_dir=down
    if [[ -n "$want_dir" ]]; then
      first_pane=$(print -r -- "$panes" | jq -r --arg t "$tab_id" \
                    '[.result.panes[] | select(.tab_id == $t)][0].pane_id')
      dir=$(hl_api pane layout --pane "$first_pane" \
            | jq -r '[.result.splits[].direction] | unique | join(",")')
      if [[ "$dir" != "$want_dir" ]]; then
        print -r -- "malformed: tab '$label' is split '$dir', expected '$want_dir'"; return 0
      fi
    fi
  done

  local current
  current=$(hl_api workspace list | jq -r --arg w "$ws" \
              '.result.workspaces[] | select(.workspace_id == $w) | .label')

  # The label matters independently of the tabs. A build killed after the last
  # `tab create` but before the rename leaves correct topology under a (building)
  # label — provisional, repaired by renaming alone.
  if (( missing )) || [[ "$current" != "$final" ]]; then
    print -r -- "provisional"
  else
    print -r -- "complete"
  fi
}
```

- [ ] **Step 4: Wire it into `hl_reconcile`**

Replace the temporary stub:

```zsh
hl_reconcile() {
  local ws="$1" repo="$2" verdict
  verdict="$(hl_classify "$ws" "$(hl_label "$repo")")" || exit 1
  case "$verdict" in
    complete)     hl_api workspace focus "$ws" >/dev/null ;;
    provisional)  hl_repair "$ws" "$repo" ;;
    malformed:*)  die "$ws is ${verdict#malformed: } — fix it by hand, or close it" ;;
  esac
}

# hl_label — the display label. Deterministic from the path so it is stable, but
# purely cosmetic: identity is the canonical path, checked via pane cwd.
hl_label() {
  # BOTH sides resolved. hdev hands over "${repo:A}", so on macOS a repo under /tmp
  # arrives as /private/tmp/... while $HOME is still /tmp/... — the prefix never
  # matches and the label silently degrades to the full absolute path. The same
  # applies to any ~/Code behind a symlink, which _wt_assert_worktree already warns
  # about: "git reports real paths, and ~/Code may sit behind a symlink."
  local repo="${1:A}" home="${HOME:A}"
  case "$repo" in
    "$home/Code/"*) print -r -- "${repo#$home/Code/}" ;;
    "$home/"*)      print -r -- "${repo#$home/}" ;;
    *)              print -r -- "$repo" ;;
  esac
}
```

- [ ] **Step 5: Run tests to verify they pass**

Expected: section E passes, including all four no-mutation assertions in E6.

- [ ] **Step 6: Commit**

```bash
git add dot_config/herdr/executable_layout.sh .scripts/test-hdev.sh
git commit -m "Classify workspaces against a managed baseline"
```

---

### Task 7: Build and repair

**Files:**
- Modify: `dot_config/herdr/executable_layout.sh`
- Modify: `.scripts/test-hdev.sh` (sections F, G)

**Interfaces:**
- Produces: `hl_build <repo>`, `hl_repair <workspace_id> <repo>`, `hl_make_tab <ws> <label> <repo>`.

- [ ] **Step 1: Write the failing tests**

```zsh
# --- F: build ---------------------------------------------------------------
print -r -- "-- F: build"
run_layout "export HERDR_ENV=1; mock_panes '/nowhere'" "$R1"
rc_is 0 "F1 a clean build succeeds"
logged "workspace create --cwd $R1 --label Netronix/curato (building) --no-focus" \
  "F1 created under the provisional label, unfocused, with an explicit cwd"
logged "pane split --pane w7:p3 --direction right" "F2 the agents pane splits by parsed id"
logged "pane run w7:p3 claude" "F2 claude runs in the parsed pane id, not a guessed one"
logged "pane run w7:p9 codex"  "F2 codex runs in the split's parsed id"
logged "tab create --workspace w7 --label editor"  "F3 tabs are created with --workspace"
unlogged "--workspace-id" "F3 the non-existent --workspace-id flag is never used"
unlogged "--target-pane-id" "F3 the non-existent --target-pane-id flag is never used"
logged "workspace rename w7 Netronix/curato" "F4 renamed to the final label last"
logged "workspace focus w7" "F4 focused only once complete"

# The runtime split must target that tab's own root pane.
[[ "$(<$HLOG)" == *"pane split --pane w7:p6 --direction down"* ]] \
  && _pass "F5 the runtime split targets its own parsed root pane" \
  || _fail "F5 the runtime split had no or the wrong target"

# Trap: a mid-build failure closes what it created. Fail on the THIRD tab create, so
# the workspace is genuinely half-built — failing on the first would also pass a trap
# that only handled the trivial case.
run_layout "export HERDR_ENV=1; mock_panes '/nowhere'; export MOCK_TAB_CREATE_FAIL_AT=3" "$R1"
rc_is 1 "F6 a failed build fails loudly"
logged "workspace close w7" "F6 the trap closes the partial workspace"
logged "tab create --workspace w7 --label editor" "F6 it got as far as the third tab"

# --- G: repair --------------------------------------------------------------
print -r -- "-- G: repair"
run_layout "export HERDR_ENV=1; mock_topology '$R1' 'Netronix/curato' agents:2 editor:1" "$R1"
logged "tab create --workspace w7 --label runtime" "G1 the missing runtime tab is created"
logged "tab create --workspace w7 --label git"     "G1 the missing git tab is created"
unlogged "--label agents" "G1 the existing agents tab is not recreated"
unlogged "--label editor" "G1 the existing editor tab is not recreated"
unlogged "workspace create" "G1 no duplicate workspace"

# The rename window: everything present, only the label wrong. Rename ALONE.
run_layout "export HERDR_ENV=1; mock_topology '$R1' 'Netronix/curato (building)' \$FULL" "$R1"
rc_is 0 "G2 the rename window is repaired"
eq "$(count_logged 'tab create --workspace w7 --label agents')" "0" "G2 no tab is created"
logged "workspace rename w7 Netronix/curato" "G2 renamed to the final label"

# Extra tabs survive repair untouched.
run_layout "export HERDR_ENV=1; mock_topology '$R1' 'Netronix/curato' agents:2 editor:1 notes:1" "$R1"
unlogged "tab close" "G3 the user's own tab is never closed"
unlogged "--label notes" "G3 the user's own tab is never recreated"
```

- [ ] **Step 2: Run to verify they fail**

Expected: FAIL — the stub `hl_build` only creates a workspace.

- [ ] **Step 3: Implement**

Replace the temporary `hl_build` stub:

```zsh
# hl_make_tab — create one managed tab and populate it. Returns its root pane id.
# Every id is parsed from the response: public ids are opaque, closed ids are not
# reused, and order must not be inferred.
hl_make_tab() {
  local ws="$1" label="$2" repo="$3" out pane
  out="$(hl_api tab create --workspace "$ws" --label "$label" --cwd "$repo" --no-focus)" || return 1
  pane="$(print -r -- "$out" | jq -r '.result.root_pane.pane_id')"
  [[ -n "$pane" && "$pane" != null ]] || die "tab create '$label' returned no root pane"

  case "$label" in
    editor)  hl_api pane run "$pane" "nvim ." >/dev/null ;;
    git)     hl_api pane run "$pane" "lazygit" >/dev/null ;;
    runtime) hl_api pane split --pane "$pane" --direction down --cwd "$repo" --no-focus >/dev/null ;;
    agents)
      local right
      right="$(hl_api pane split --pane "$pane" --direction right --cwd "$repo" --no-focus \
               | jq -r '.result.pane.pane_id')"
      [[ -n "$right" && "$right" != null ]] || die "the agents split returned no pane"
      # pane run, not agent start: agent start blocks until the agent is detected
      # ready (30s default), serialising every build behind two boot sequences, and
      # it changes exit semantics. A shell pane leaves a live prompt on quit, exactly
      # as dev.kdl's `claude; exec zsh` did.
      hl_api pane run "$pane" "claude" >/dev/null
      hl_api pane run "$right" "codex" >/dev/null ;;
  esac
  print -r -- "$pane"
}

hl_build() {
  local repo="$1" label out ws
  label="$(hl_label "$repo")"
  out="$(hl_api workspace create --cwd "$repo" --label "$label$BUILDING_SUFFIX" --no-focus)" || exit 1
  ws="$(print -r -- "$out" | jq -r '.result.workspace.workspace_id')"
  local t1 p1
  t1="$(print -r -- "$out" | jq -r '.result.tab.tab_id')"
  p1="$(print -r -- "$out" | jq -r '.result.root_pane.pane_id')"

  # Close what we created if anything below fails. The trap covers a command erroring;
  # baseline classification covers what it cannot reach (SIGKILL, a lost server).
  trap "command herdr workspace close $ws >/dev/null 2>&1" EXIT INT TERM

  hl_api tab rename "$t1" agents >/dev/null
  local right
  right="$(hl_api pane split --pane "$p1" --direction right --cwd "$repo" --no-focus \
           | jq -r '.result.pane.pane_id')"
  hl_api pane run "$p1" "claude" >/dev/null
  hl_api pane run "$right" "codex" >/dev/null

  local label_
  for label_ in editor runtime git; do
    hl_make_tab "$ws" "$label_" "$repo" >/dev/null
  done

  hl_api workspace rename "$ws" "$label" >/dev/null
  trap - EXIT INT TERM   # the workspace is complete; stop closing it on exit
  hl_api workspace focus "$ws" >/dev/null
  hl_api tab focus "$t1" >/dev/null
}

# hl_repair — create only the missing managed tabs, then rename. Preferred over
# close-and-rebuild because the workspace may hold a running agent the user cares
# about. Unmanaged tabs are not this function's business.
hl_repair() {
  local ws="$1" repo="$2" label tabs have
  label="$(hl_label "$repo")"
  tabs="$(hl_api tab list --workspace "$ws")" || exit 1
  local want
  for want in $MANAGED_TABS; do
    have=$(print -r -- "$tabs" | jq -r --arg l "$want" \
            '.result.tabs[] | select(.label == $l) | .tab_id' | head -1)
    [[ -n "$have" ]] && continue
    hl_make_tab "$ws" "$want" "$repo" >/dev/null
  done
  hl_api workspace rename "$ws" "$label" >/dev/null
  hl_api workspace focus "$ws" >/dev/null
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: sections F and G pass. G2 in particular must show **zero** `tab create` calls.

- [ ] **Step 5: Commit**

```bash
git add dot_config/herdr/executable_layout.sh .scripts/test-hdev.sh
git commit -m "Build and repair project workspaces"
```

---

### Task 8: `tab-goto.sh` and the Alt+letter tab jumps

**Files:**
- Create: `dot_config/herdr/executable_tab-goto.sh`
- Modify: `dot_config/herdr/config.toml`
- Modify: `.scripts/test-hdev.sh` (section H)

**Interfaces:**
- Produces: `tab-goto.sh <label>` → focuses the uniquely-labelled tab in the active workspace.

- [ ] **Step 1: Write the failing tests**

```zsh
# --- H: tab-goto ------------------------------------------------------------
print -r -- "-- H: tab jumps resolve by label"
mock_reset; mock_tabs agents editor runtime git
OUT="$(HERDR_ACTIVE_WORKSPACE_ID=w7 zsh "$TABGOTO" runtime 2>&1)"; RC=$?
rc_is 0 "H1 a known label resolves"
logged "tab focus w7:t3" "H1 focuses the tab carrying that label"

# Order-independence: repair appends, and herdr has no `tab move`.
mock_reset; mock_tabs git agents editor runtime
OUT="$(HERDR_ACTIVE_WORKSPACE_ID=w7 zsh "$TABGOTO" git 2>&1)"; RC=$?
logged "tab focus w7:t1" "H2 resolution follows the label, not the position"

mock_reset; mock_tabs agents editor
OUT="$(HERDR_ACTIVE_WORKSPACE_ID=w7 zsh "$TABGOTO" git 2>&1)"; RC=$?
rc_is 1 "H3 a missing label fails"
unlogged "tab focus" "H3 no tab is focused"

mock_reset; mock_tabs agents agents
OUT="$(HERDR_ACTIVE_WORKSPACE_ID=w7 zsh "$TABGOTO" agents 2>&1)"; RC=$?
rc_is 1 "H4 an ambiguous label fails rather than picking one"
unlogged "tab focus" "H4 no tab is focused"
```

(Inserted above the existing `finish` call from Task 2, which already gates the exit status.)

- [ ] **Step 2: Run to verify they fail**

Expected: FAIL — `tab-goto.sh` does not exist.

- [ ] **Step 3: Implement**

Create `dot_config/herdr/executable_tab-goto.sh`:

```zsh
#!/usr/bin/env zsh
# tab-goto.sh <label> — focus a managed tab in the active workspace.
# Managed by chezmoi (source: dot_config/herdr/executable_tab-goto.sh).
#
# By LABEL, never by index. herdr 0.8.2 has no `tab move`, so repair can only append
# and a repaired workspace's managed tabs can be in any order; the user's own alt+t
# tab also shifts every position after it. An index would silently land on the wrong
# tab, which is worse than not moving at all.
emulate -L zsh
setopt local_options no_unset pipe_fail

label="${1:?usage: tab-goto.sh <label>}"

# Resolving through the globally-focused workspace is racy: persistence is a shared
# session view, so another attached client can change focus between the keypress and
# the query. Herdr documents active-context variables for [[keys.command]]; if they
# are absent, say so rather than guessing.
ws="${HERDR_ACTIVE_WORKSPACE_ID:-${HERDR_WORKSPACE_ID:-}}"
[[ -n "$ws" ]] || {
  print -ru2 -- "tab-goto: no active workspace in the environment."
  print -ru2 -- "    Expected HERDR_ACTIVE_WORKSPACE_ID from the keybinding context."
  exit 1 }

tabs="$(command herdr tab list --workspace "$ws" 2>&1)" || {
  print -ru2 -- "tab-goto: tab list failed: $tabs"; exit 1 }

ids=( ${(f)"$(print -r -- "$tabs" | jq -r --arg l "$label" \
       '.result.tabs[] | select(.label == $l) | .tab_id')"} )
ids=( ${ids:#} )

(( ${#ids} == 0 )) && { print -ru2 -- "tab-goto: no tab labelled '$label'"; exit 1 }
(( ${#ids} > 1 ))  && { print -ru2 -- "tab-goto: ${#ids} tabs labelled '$label' — refusing to guess"; exit 1 }

command herdr tab focus "${ids[1]}" >/dev/null
```

- [ ] **Step 4: Bind the keys**

Append to `dot_config/herdr/config.toml`:

```toml
# Tab jumps. `switch_tab` is range-only ("prefix+1..9") — there is no switch_tab_1,
# and tab.focus takes a tab_id, not an index. These resolve by label instead, which
# also survives repair appending a tab out of order.
[[keys.command]]
key = "alt+a"
type = "shell"
command = "~/.config/herdr/tab-goto.sh agents"
description = "tab: agents"

[[keys.command]]
key = "alt+e"
type = "shell"
command = "~/.config/herdr/tab-goto.sh editor"
description = "tab: editor"

[[keys.command]]
key = "alt+r"
type = "shell"
command = "~/.config/herdr/tab-goto.sh runtime"
description = "tab: runtime"

[[keys.command]]
key = "alt+g"
type = "shell"
command = "~/.config/herdr/tab-goto.sh git"
description = "tab: git"
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
zsh .scripts/test-hdev.sh
```

Expected: all sections A-H pass; the suite exits 0.

- [ ] **Step 6: Verify the injected context for real**

This is the assumption the spec flags as unverified. Temporarily add:

```toml
[[keys.command]]
key = "alt+0"
type = "shell"
command = "env | grep -i herdr > /tmp/herdr-keyenv.txt"
description = "debug: dump key context"
```

Apply, start `herdr`, press `alt+0`, then read `/tmp/herdr-keyenv.txt`.

Expected: `HERDR_ACTIVE_WORKSPACE_ID` present. **If it is absent**, note which variables *are* injected and adjust `tab-goto.sh`'s lookup accordingly — do not fall back to global focus. Remove the debug binding afterwards.

- [ ] **Step 7: Commit**

```bash
chezmoi apply ~/.config/herdr
git add dot_config/herdr/ .scripts/test-hdev.sh
git commit -m "Resolve tab jumps by label and bind Alt+a/e/r/g"
```

---

### Task 9: The plugin and its `--current` repair mode

A plugin action runs from inside an existing workspace. Plain `layout.sh` would match that workspace by cwd, focus it, exit 0 and apply nothing — a silent no-op, the most confusing possible outcome. `--current` is a distinct mode, not a shortcut.

**Files:**
- Create: `dot_config/herdr/plugin/herdr-plugin.toml`
- Modify: `dot_config/herdr/executable_layout.sh`

**Interfaces:**
- Consumes: `HERDR_WORKSPACE_ID` from the plugin context.
- Produces: action `dev.layout.apply`.

- [ ] **Step 1: Write the manifest**

```toml
# dev.layout — apply the project layout to the current workspace.
# Managed by chezmoi (source: dot_config/herdr/plugin/herdr-plugin.toml).
# Registered with: herdr plugin link ~/.config/herdr/plugin
#
# Registration is GLOBAL across named sessions, not per-session. Rollback therefore
# needs `herdr plugin unlink dev.layout` even if the trial session is gone.
id = "dev.layout"
name = "Project layout"
version = "0.1.0"
min_herdr_version = "0.8.0"
description = "Create any missing agents/editor/runtime/git tabs in this workspace"
platforms = ["macos"]

[[actions]]
id = "apply"
title = "Apply project layout"
contexts = ["workspace"]
command = ["/bin/zsh", "-c", "exec \"$HOME/.config/herdr/layout.sh\" --current"]
```

- [ ] **Step 2: Implement `--current`**

Extend `main` in `layout.sh`:

```zsh
  if [[ "$mode" == current ]]; then
    local ws="${HERDR_WORKSPACE_ID:-}"
    [[ -n "$ws" ]] || die "no HERDR_WORKSPACE_ID — --current only runs as a plugin action"

    # The workspace's own cwd, taken from its panes: --current targets by context,
    # never by a path lookup, which is what made the plain path mode a no-op here.
    local repo
    repo="$(hl_api pane list --workspace "$ws" | jq -r '.result.panes[0].cwd')"
    [[ -n "$repo" && "$repo" != null ]] || die "workspace $ws has no pane cwd to work from"
    repo="${repo:A}"

    # The worktree guard is a property of the design, not of one entry point. A
    # workspace created by hand in a wt worktree could otherwise be repaired — and
    # grown — through the plugin, reopening the husk hazard hdev refuses.
    if [[ -f "$repo/.git" ]]; then
      hl_notify "Project layout" "Refusing: $repo is a linked worktree."
      die "$repo is a linked worktree — refusing (see the worktree guard)"
    fi

    # Same lock as the path mode. Two plugin invocations, or a plugin racing an hdev,
    # would otherwise both see a tab missing and both create it.
    hl_lock "$repo"

    local verdict; verdict="$(hl_classify "$ws" "$(hl_label "$repo")")" || exit 1
    case "$verdict" in
      complete)
        hl_notify "Project layout" "Already complete — nothing to do." ;;
      provisional)
        hl_repair "$ws" "$repo"
        hl_notify "Project layout" "Repaired missing tabs in $(hl_label "$repo")." ;;
      malformed:*)
        hl_notify "Project layout" "Refusing: ${verdict#malformed: }"
        die "$ws is ${verdict#malformed: }" ;;
    esac
    exit 0
  fi
```

And add:

```zsh
# A key-invoked action whose result is buried in a log file is indistinguishable from
# a broken keybinding, so outcomes are surfaced in the UI.
hl_notify() {
  command herdr notification show "$1" --body "$2" >/dev/null 2>&1 || true
}
```

- [ ] **Step 3: Apply and link**

```bash
chezmoi apply ~/.config/herdr
herdr plugin link ~/.config/herdr/plugin
herdr plugin list
```

Expected: `dev.layout` listed.

- [ ] **Step 4: Verify all three outcomes by hand**

In a herdr session, inside a workspace built by `hdev`:

```bash
herdr plugin action invoke dev.layout.apply
```

Expected: a notification saying "Already complete". Then close the `git` tab and invoke again — expected: the tab is recreated and the notification says so. Confirm no duplicate workspace appears in the sidebar either time.

- [ ] **Step 5: Commit**

```bash
git add dot_config/herdr/
git commit -m "Add the dev.layout plugin with an explicit repair mode"
```

---

### Task 10: Live topology gate

Mocked tests cannot catch CLI churn — a stub defines its own acceptance and keeps passing after the real binary changes its flags. This is the only thing that can.

**Files:**
- Create: `.scripts/test-hdev-topology.sh`

- [ ] **Step 1: Write the script**

```zsh
#!/usr/bin/env zsh
# Live gate for hdev/layout.sh against the REAL herdr binary.
#
# Mocked tests cannot detect CLI churn: the stub accepts whatever it was written to
# accept and keeps passing after herdr changes a flag or a JSON shape. Only the real
# binary can, so this runs against it — in an isolated named session, never the live
# one.
#
# A named session isolates the socket and runtime state. It does NOT isolate plugin
# registration, which is global — hence the distinct plugin id below. Reusing
# `dev.layout` would let teardown unlink the plugin the live setup depends on.
#
# Run manually, unsandboxed: zsh .scripts/test-hdev-topology.sh
set -u
SESSION=hdev-test
PLUGIN_ID=dev.layout.test
h() { command herdr --session "$SESSION" "$@" }

pass=0 fail=0
ok()   { print -r -- "  PASS: $1"; pass=$((pass+1)) }
bad()  { print -r -- "  FAIL: $1"; fail=$((fail+1)) }

cleanup() {
  h server stop >/dev/null 2>&1 || true
  command herdr plugin unlink "$PLUGIN_ID" >/dev/null 2>&1 || true
  [[ -n "${SCRATCH:-}" ]] && rm -rf "$SCRATCH"
}
trap cleanup EXIT INT TERM

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/hdev-live.XXXXXX")"
REPO="$SCRATCH/Code/Test/proj"
mkdir -p "$REPO" && git -C "$REPO" init -q && git -C "$REPO" commit -q --allow-empty -m init

print -r -- "=== live topology gate (session: $SESSION) ==="

# 1. Cold bootstrap: no server running.
h server stop >/dev/null 2>&1 || true
HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO" \
  && ok "cold bootstrap builds a workspace" || bad "cold bootstrap failed"

# 2. Topology is what we think it is.
WS=$(h workspace list | jq -r '.result.workspaces[0].workspace_id')
for l in agents editor runtime git; do
  n=$(h tab list --workspace "$WS" | jq -r --arg l "$l" \
        '[.result.tabs[] | select(.label == $l)] | length')
  [[ "$n" == 1 ]] && ok "exactly one '$l' tab" || bad "'$l' tab count = $n"
done
AT=$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="agents") | .tab_id')
n=$(h pane list --workspace "$WS" | jq -r --arg t "$AT" '[.result.panes[] | select(.tab_id==$t)] | length')
[[ "$n" == 2 ]] && ok "agents holds 2 panes" || bad "agents holds $n panes"

# 3. Idempotency: a second run focuses, never duplicates.
HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO" >/dev/null
n=$(h workspace list | jq -r '.result.workspaces | length')
[[ "$n" == 1 ]] && ok "a second run does not duplicate" || bad "$n workspaces after a second run"

# 4. Extra tabs survive.
h tab create --workspace "$WS" --label notes >/dev/null
HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO" >/dev/null
h tab list --workspace "$WS" | jq -e '.result.tabs[] | select(.label=="notes")' >/dev/null \
  && ok "an unmanaged tab survives" || bad "the unmanaged tab was removed"

# 5. Concurrency, on the schedule that actually breaks it: B scans, A builds and
#    releases, THEN B acquires. Launching two at once mostly proves nothing.
REPO2="$SCRATCH/Code/Test/proj2"
mkdir -p "$REPO2" && git -C "$REPO2" init -q && git -C "$REPO2" commit -q --allow-empty -m init
# B sleeps BEFORE taking the lock, so it arrives after A has built and released —
# the stale-observation schedule. Launching two at once would usually serialise
# harmlessly and prove nothing.
( HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 HL_LOCK_DELAY=3 ~/.config/herdr/layout.sh "$REPO2" ) &
B=$!
sleep 0.2
HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO2" >/dev/null 2>&1
wait $B 2>/dev/null || true
n=$(h pane list | jq -r --arg d "$REPO2" \
      '[.result.panes[] | select(.cwd == $d) | .workspace_id] | unique | length')
[[ "$n" == 1 ]] && ok "the delayed-acquisition race yields one workspace" || bad "$n workspaces for one repo"

# 6. Split directions, not just pane counts. Two panes side by side and two stacked
#    are both "2"; only the geometry says which layout was actually built.
RT=$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="runtime") | .tab_id')
h pane layout --pane "$(h pane list --workspace "$WS" | jq -r --arg t "$RT" \
    '[.result.panes[] | select(.tab_id==$t)][0].pane_id')" \
  | jq -e '.result | tostring | test("down|vertical|row")' >/dev/null \
  && ok "runtime is split down" || bad "runtime is not split down"

# 7. The plugin: link under a DISTINCT id, invoke it, unlink. Registration is global,
#    so reusing dev.layout would let this teardown unlink the real one.
PDIR="$SCRATCH/plugin"; mkdir -p "$PDIR"
sed "s/^id = .*/id = \"$PLUGIN_ID\"/" ~/.config/herdr/plugin/herdr-plugin.toml > "$PDIR/herdr-plugin.toml"
command herdr plugin link "$PDIR" >/dev/null \
  && ok "the plugin links" || bad "plugin link failed"
h tab close "$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="git") | .tab_id')" >/dev/null
h plugin action invoke "$PLUGIN_ID.apply" >/dev/null 2>&1   # session-scoped: the
# topology lives in hdev-test, and a bare `herdr plugin action invoke` would run it
# against the default session instead.
n=$(h tab list --workspace "$WS" | jq -r '[.result.tabs[] | select(.label=="git")] | length')
[[ "$n" == 1 ]] && ok "the plugin action repairs a closed managed tab" || bad "git tab count = $n after repair"

print -r -- "=== $pass passed, $fail failed ==="
(( fail == 0 ))
```

- [ ] **Step 2: Confirm the race hook is in the right place**

`HL_LOCK_DELAY` (added in Task 5's `hl_lock`) sleeps **before** acquiring the lock, which is what makes the delayed-acquisition schedule deterministic: B arrives late, A completes and releases, then B acquires and must rescan underneath the lock.

A delay placed *after* acquisition would prove nothing — it would only slow down a caller that already holds the lock, which is the case that was never in doubt. Verify `hl_lock` contains:

```zsh
  [[ -n "${HL_LOCK_DELAY:-}" ]] && sleep "$HL_LOCK_DELAY"
```

immediately before the `zsystem flock` call.

- [ ] **Step 3: Run it**

```bash
zsh .scripts/test-hdev-topology.sh
```

Run **unsandboxed**. Expected: all pass. Note this starts and stops a `hdev-test` session; the live session is untouched.

- [ ] **Step 4: Commit**

```bash
git add .scripts/test-hdev-topology.sh dot_config/herdr/executable_layout.sh
git commit -m "Add the live topology gate against the real herdr binary"
```

---

### Task 11: Integrations under chezmoi

Cold restore is the sole justification for these — Claude and Codex are "session identity only" in Herdr's matrix, so sidebar status is identical with or without them. Every touchpoint needs a chezmoi owner: `.chezmoiignore` allowlists both `.claude/*` (lines 57-66) and `.codex/*` (lines 73-78), so anything unowned is silently dropped on the next provision.

**Files:**
- Modify: `.chezmoiignore`
- Modify: `dot_claude/modify_private_settings.json`
- Modify: `dot_codex/modify_private_config.toml`
- Create: `dot_codex/modify_private_hooks.json`
- Create: the two hook scripts (exact names from Step 2)

- [ ] **Step 1: Back up the real config first**

```bash
mkdir -p ~/.local/state/herdr-trial-backup
cp ~/.claude/settings.json ~/.local/state/herdr-trial-backup/settings.json
cp ~/.codex/config.toml ~/.local/state/herdr-trial-backup/config.toml
cp ~/.codex/hooks.json ~/.local/state/herdr-trial-backup/hooks.json 2>/dev/null || true
```

- [ ] **Step 2: Install against fixtures and diff**

Do **not** install into the real config yet. Use scratch config dirs:

```bash
export FIX="$(mktemp -d "${TMPDIR}/herdr-fix.XXXXXX")"
mkdir -p "$FIX/claude" "$FIX/codex"
CLAUDE_CONFIG_DIR="$FIX/claude" herdr integration install claude
CODEX_HOME="$FIX/codex" herdr integration install codex
find "$FIX" -type f | sort
```

Record exactly which files appeared and which keys changed. Report **key names only** — never paste `settings.json`, `hooks.json` or `config.toml`, which carry credentials and machine state.

If `CLAUDE_CONFIG_DIR` / `CODEX_HOME` turn out not to be honoured by the installer, stop and report: installing straight into the real config without a diff first is not an acceptable substitute.

- [ ] **Step 2b: Prove the uninstall is clean, still against fixtures**

Reversibility is what makes this task acceptable, so demonstrate it before touching
real config. Seed an unrelated hook first, so preservation is actually tested:

```bash
jq '.hooks += {mine: {command: "/bin/true"}}' "$FIX/codex/hooks.json" > "$FIX/codex/hooks.json.new" \
  && mv "$FIX/codex/hooks.json.new" "$FIX/codex/hooks.json"
cp -R "$FIX" "$FIX.before"

CLAUDE_CONFIG_DIR="$FIX/claude" herdr integration uninstall claude
CODEX_HOME="$FIX/codex" herdr integration uninstall codex

diff -r "$FIX.before" "$FIX" | sed 's/^/  /'
jq -e '.hooks.mine' "$FIX/codex/hooks.json" >/dev/null && echo "unrelated hook preserved"
jq -e '.hooks.herdr' "$FIX/codex/hooks.json" >/dev/null && echo "WARNING: herdr entry survived"
grep -q 'hooks = true' "$FIX/codex/config.toml" && echo "features.hooks left set (expected)"
```

Expected: the unrelated hook survives, Herdr's entry is gone, `features.hooks` remains
set. **If the unrelated hook does not survive, stop** — the uninstall is destructive to
config it does not own, and rollback would cost you unrelated settings.

- [ ] **Step 2c: Immutable baseline, then authorise**

The Step 1 copies live in a directory chezmoi and Herdr both write to. Take a
read-only snapshot outside it:

```bash
BK=~/.local/state/herdr-trial-backup/$(date +%Y%m%d-%H%M%S)
mkdir -p "$BK" && cp ~/.claude/settings.json ~/.codex/config.toml "$BK"/ 2>/dev/null
cp ~/.codex/hooks.json "$BK"/ 2>/dev/null || true
chmod -R a-w "$BK" && ls -l "$BK"
```

**Stop here and get explicit confirmation before Step 3.** Everything to this point is
reversible by deleting a scratch directory; everything after modifies real agent
configuration.

- [ ] **Step 3: Bring the hook scripts under chezmoi**

Copy each installed hook script into the chezmoi source with an `executable_` prefix, at the path matching its target (as reported by `herdr integration status`):

Copy from `$FIX.before` — the snapshot taken in Step 2b **before** the uninstall. `$FIX`
itself no longer holds the hook scripts; the uninstall deleted them, which is exactly
what Step 2b proved.

```bash
mkdir -p ~/.local/share/chezmoi/dot_claude/hooks
cp "$FIX.before/claude/hooks/herdr-agent-state.sh" \
   ~/.local/share/chezmoi/dot_claude/hooks/executable_herdr-agent-state.sh
cp "$FIX.before/codex/herdr-agent-state.sh" \
   ~/.local/share/chezmoi/dot_codex/executable_herdr-agent-state.sh
```

- [ ] **Step 4: Re-include them in `.chezmoiignore`**

Both blocks are allowlists. Add to the `.claude` block (after line 66):

```
!.claude/hooks/
.claude/hooks/*
!.claude/hooks/herdr-agent-state.sh
```

And to the `.codex` block (after line 78):

```
!.codex/herdr-agent-state.sh
!.codex/hooks.json
```

- [ ] **Step 5: Give `hooks.json` an owner**

This is the dangerous gap: without it, reprovisioning deploys Codex's hook script *and* sets `features.hooks = true` while never writing the registration connecting them — cold restore silently dead, every visible artifact present and correct.

Create `dot_codex/modify_private_hooks.json`, merge-preserving so other hook registrations survive:

```
#!/usr/bin/env bash
# modify_ script: stdin is the current ~/.codex/hooks.json (empty on first run),
# stdout replaces it. Adds only Herdr's entries and leaves everything else intact.
set -euo pipefail
current="$(cat)"
[ -z "$current" ] && current='{}'
printf '%s' "$current" | jq \
  --arg cmd "$HOME/.codex/herdr-agent-state.sh" \
  '.hooks = ((.hooks // {}) + {herdr: {command: $cmd}})'
```

Use the exact key shape observed in Step 2 — this is the expected shape; correct it to what the installer actually wrote if they differ.

- [ ] **Step 6: Pin `features.hooks`**

In `dot_codex/modify_private_config.toml`, beside the existing `features.*` pins:

```
{{- $config = setValueAtPath "features.hooks" true $config -}}
```

Herdr's uninstall deliberately leaves this flag set, so rollback restores its prior value explicitly — nothing else will.

- [ ] **Step 7: Merge Claude's hook registration**

In `dot_claude/modify_private_settings.json`, which already owns the `hooks` block, add Herdr's entry alongside the existing `SessionStart` hooks — matching the shape observed in Step 2. Do not let the installer write this file; the two would fight on every `chezmoi apply`.

- [ ] **Step 8: Apply and verify**

```bash
chezmoi apply ~/.claude ~/.codex
herdr integration status | grep -E 'claude|codex'
```

Run **unsandboxed** — `~/.claude/hooks` and `~/.claude/settings.json` are write-denied under the sandbox. Expected: both report **installed**.

- [ ] **Step 9: Confirm chezmoi is settled**

```bash
chezmoi diff ~/.claude ~/.codex
```

Expected: empty. A non-empty diff means the installer and a `modify_` script are fighting — fix before committing.

- [ ] **Step 10: Commit**

```bash
git add .chezmoiignore dot_claude/ dot_codex/
git commit -m "Bring the herdr agent integrations under chezmoi"
```

---

### Task 12: Cold restore, against the real config

**Files:**
- Create: `.scripts/test-hdev-integrations.sh`

- [ ] **Step 1: Write the script**

```zsh
#!/usr/bin/env zsh
# Cold-restore check for the Herdr trial.
#
# Deliberately does NOT install anything: Task 11 deployed the integrations through
# chezmoi, and this verifies what chezmoi deployed. Installing here would test a
# different artefact from the one that ships.
#
# Uses a named session so the live one is untouched — but note that integrations
# themselves are global; this reads real ~/.claude and ~/.codex state.
#
# Run manually, unsandboxed: zsh .scripts/test-hdev-integrations.sh
set -u
SESSION=hdev-restore
h() { command herdr --session "$SESSION" "$@" }
pass=0 fail=0
ok()  { print -r -- "  PASS: $1"; pass=$((pass+1)) }
bad() { print -r -- "  FAIL: $1"; fail=$((fail+1)) }
trap 'h server stop >/dev/null 2>&1 || true; [[ -n "${SCRATCH:-}" ]] && rm -rf "$SCRATCH"' EXIT INT TERM

command herdr integration status | grep -q '^claude: installed' \
  && ok "the claude integration is installed" || bad "claude integration missing"
command herdr integration status | grep -q '^codex: installed' \
  && ok "the codex integration is installed" || bad "codex integration missing"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/hdev-restore.XXXXXX")"
REPO="$SCRATCH/proj"
mkdir -p "$REPO" && git -C "$REPO" init -q && git -C "$REPO" commit -q --allow-empty -m init

HERDR_SESSION="$SESSION" HDEV_NO_ATTACH=1 ~/.config/herdr/layout.sh "$REPO"
print -r -- "  Attach with:  herdr --session $SESSION"
print -r -- "  Wait until BOTH agents in the 'agents' tab have started and are at an idle"
print -r -- "  prompt — layout.sh launches them, so do not start them by hand. They must"
print -r -- "  each report a session ref before the restart, which the next check enforces."
print -r -- "  Then detach (alt+w) and press Enter here."
read -r

# Identity, not just a count: two agents before and two after proves nothing if they
# are different sessions. Capture the native session refs and compare them.
# AgentInfo's field is `agent`, not `kind`, and `agent_session` is NULLABLE. Comparing
# {kind, agent_session} would have compared {null, null} against {null, null} and
# passed no matter what happened — so require a non-null ref first.
BEFORE=$(h agent list | jq -rS '[.result.agents[] | {agent, session: .agent_session}] | sort')
BEFORE_N=$(h agent list | jq -r '[.result.agents[]] | length')
NOREF=$(h agent list | jq -r '[.result.agents[] | select(.agent_session == null)] | length')

[[ "$NOREF" == "0" && "$BEFORE_N" != "0" ]] \
  && ok "every agent reports a native session ref ($BEFORE_N agents)" \
  || { bad "$NOREF of $BEFORE_N agents have no session ref — restore cannot be tested"; \
       print -r -- "=== $pass passed, $fail failed ==="; exit 1; }

h server stop >/dev/null 2>&1
sleep 2

# `workspace list` does NOT start a server — it returns server_not_running. Start one
# explicitly, the same way layout.sh does.
(command herdr --session "$SESSION" server >/dev/null 2>&1 &)
for i in {1..40}; do h workspace list >/dev/null 2>&1 && break; sleep 0.25; done
sleep 3

AFTER=$(h agent list | jq -rS '[.result.agents[] | {agent, session: .agent_session}] | sort')
AFTER_N=$(h agent list | jq -r '[.result.agents[]] | length')

[[ "$BEFORE_N" != "0" ]] && ok "agents were running before the restart ($BEFORE_N)" \
  || bad "no agents were running — the test proves nothing"
[[ "$AFTER" == "$BEFORE" && "$BEFORE_N" != "0" ]] \
  && ok "the same native agent sessions resumed" \
  || bad "sessions differ after restart (before=$BEFORE_N after=$AFTER_N)"

print -r -- "=== $pass passed, $fail failed ==="
(( fail == 0 ))
```

- [ ] **Step 2: Run it**

```bash
zsh .scripts/test-hdev-integrations.sh
```

Expected: agents resume. **If they do not**, cold restore is the integrations' only justification — record the result and raise dropping them, per the spec's rollback path.

- [ ] **Step 3: Commit**

```bash
git add .scripts/test-hdev-integrations.sh
git commit -m "Add the cold-restore check for the agent integrations"
```

---

### Task 13: Trial log

The exit criteria need evidence collected as it happens; reconstructing four weeks from
memory is how a trial talks itself into a conclusion.

**Files:**
- Create: `docs/superpowers/runs/2026-08-27-herdr-trial-log.md` — **untracked**

A running log is execution state, not a design record. Per the storage policy,
`docs/superpowers/runs/` is never tracked; only the durable conclusion is folded back
into the spec at the end. Committing the log under `plans/` would track exhaust.

- [ ] **Step 1: Confirm the directory is ignored**

```bash
mkdir -p docs/superpowers/runs
git check-ignore -v docs/superpowers/runs/probe.md || echo "WARNING: runs/ is NOT ignored"
```

Expected: a `.gitignore` rule is printed. **If the warning appears**, add
`docs/superpowers/runs/` to `.gitignore` and commit that one-line change — the log must
not become tracked by accident.

- [ ] **Step 2: Create the log**

```markdown
# Herdr trial log

Started: 2026-08-27 · Decide by: 2026-09-24 (four weeks)
Spec: `docs/superpowers/specs/2026-08-27-herdr-trial-design.md`

## Thresholds

| Criterion | Threshold | Running |
|---|---|---|
| Cold restore | >=90% over >=10 attempts | 0/0 |
| Wrong-workspace events | 0 | 0 |
| Husk incidents | 0 | 0 |
| Half-built repairs after week 1 | 0 | 0 |
| Alt scheme remapped? | no | no |
| Status *noticed*, weekly | >=1/week | - |

Fewer than ten restore attempts means the criterion is unmet, not passed by default.

## Noticed-vs-polled

The one that decides it. Log each time a Herdr status display prompted action on a
blocked or finished agent *before* it would otherwise have been checked. Status is
screen-detected for both Claude and Codex, so this also tests whether that inference
is trustworthy.

| Date | What the sidebar showed | Would it have been noticed otherwise? |
|---|---|---|

## Incidents

| Date | What happened | Cause |
|---|---|---|
```

- [ ] **Step 3: Confirm it is untracked**

```bash
git status --short docs/superpowers/runs/
```

Expected: empty. Nothing to commit for this task.

---

---

## Execution corrections

Recorded as the plan is executed, so the permanent record does not contradict what was
built. Each was found by running the code, not by reading it.

| # | Correction | Why |
|---|---|---|
| 1 | `herdr config check`, not `herdr status client`, validates the config (Task 1) | `status client` reports nothing about config validity — a bogus key gives byte-identical output. It also exits 0 either way, so the string is the signal |
| 2 | `no_bg_nice` added to `layout.sh` | zsh's default `BG_NICE` renices backgrounded jobs; where `setpriority` is denied that kills the server start outright |
| 3 | Explicit `\|\| exit 1` instead of `setopt err_return` | `err_return` does not fire for a command whose status is already tested, so a failed focus or create fell through to `hl_attach` and reported success |
| 4 | `mock_reset` unsets `HL_*` as well as `MOCK_*` | `HL_READY_TRIES=2` leaked from C3's timeout test into C4, silently shortening an unrelated bootstrap |
| 5 | Tests C4, D6, D7, A5, and paired presence assertions on C1/C2 | Each covered a mutation the suite could not previously detect: deleting the server start, swallowing a failure, honouring an fzf selection, and running at all |
| 6 | `hl_api` validates JSON at the boundary; every jq consumer propagates failure | Malformed responses became actionable state: a jq failure inside `ids=( $(...) )` discards status, so corrupt pane JSON read as "no workspace found" and would have built a duplicate; corrupt tab JSON returned `provisional` with rc=0 and let repair mutate |
| 7 | Stub JSON defaults are plain assignments, not `${VAR:-{...}}` | A brace inside a `:-` default ends the expansion early in bash, appending a stray `}}`. jq printed a parse error **and still extracted the right value**, so three tests passed against a corrupt fixture |
| 8 | `hl_api_json` for calls that must return a payload | `jq` exits 0 on empty input, so an empty response degraded into "no workspace found" (→ duplicate) or "provisional" (→ repair mutates), both rc=0. Empty stays legal only for focus/run/rename/close |
| 9 | Error detection reads the parsed envelope, not a `'"error"'` substring | A substring test rejects valid data merely containing the word — a tab labelled `error`, an agent status, a repo path. It did correctly catch a genuine error envelope; the structural check keeps that (F1d) while dropping the false positives (F1c) |
| 10 | Stub gained `MOCK_EMPTY_FOR` | Setting `MOCK_*_LIST=""` hits the stub's defaults and yields valid JSON, so the empty-response path was unreachable from a fixture |
| 11 | `hl_label` resolves **both** sides before comparing | `hdev` passes `${repo:A}`, so on macOS a repo under `/tmp` arrives as `/private/tmp/...` while `$HOME` is not resolved — the prefix never matched and the label degraded to the full absolute path. Same failure for any `~/Code` behind a symlink |
| 12 | `hl_id` validates mandatory ids with `jq -er` | `hl_api_json` proves a payload parses, not that `workspace_id`/`tab_id`/`pane_id` exist. Without it a reshaped response yields `null`, which then gets passed to the next command as a pane id |
| 13 | Fixture workspace id parameterised (`MOCK_WS_ID`) | The stub answered `w7` for both a pre-existing workspace and a newly created one, so "the other workspace is not focused" became unfalsifiable once build began focusing its own result |
| 14 | The cleanup trap is armed as soon as a workspace id parses, not after all three ids | A response with a valid `workspace_id` but no `tab_id` exited 1 *having created the workspace* and never closed it — the check meant to prevent orphans was creating one (G7b) |
| 15 | `hl_id` requires a non-empty JSON **string**, and the trap argument is `${(q)}`-quoted | `jq -er` only rejects null/false: `7` and `{}` pass with exit 0, so an API reshape could hand nonsense to herdr, and that value is interpolated into a trap command (G7c) |
| 16 | Stub gained `MOCK_SERVER_NEVER_READY` and a marker file | Lets the bootstrap be tested as a down → start → ready transition rather than two frozen states |

Assertions about **absence** (`unlogged`, `count_logged … 0`) always pass when nothing
ran at all. Every one is paired with a presence assertion, and each gate was confirmed
by mutation — break the implementation, watch the specific test go red.

## Self-review

**Spec coverage.** Worktree guard → T3. Bootstrap/readiness → T4. Path identity, lock-before-scan, ambiguity → T5. Managed baseline, malformed-without-mutation, rename window → T6, T7. Construction with explicit IDs, `--cwd`, `--no-focus`, trap → T7. Label-resolved tab jumps → T8. Plugin `--current` + notifications → T9. Live churn gate + concurrency schedule + distinct plugin id → T10. Integrations, all four chezmoi owners, fixtures, key-names-only diffs → T11. Cold restore → T12. Exit criteria evidence → T13. Theme + `onboarding` + `resume_agents_on_restore` → T1.

Branch/preflight → T0. Attach after build (`exec herdr`) → T4. `--current` inheriting the worktree guard and the lock → T9.

**Not covered by a task, by design:** rollback (a procedure in the spec, executed only if the trial fails) and the Neovim navigation regression (an explicit non-goal).

**Type consistency.** `hl_api`, `hl_server_ready`, `hl_ensure_server`, `hl_lock`, `hl_find_workspace`, `hl_classify`, `hl_label`, `hl_make_tab`, `hl_build`, `hl_repair`, `hl_notify` — each defined once and called under that name. `MANAGED_TABS` and `BUILDING_SUFFIX` are set in T4 and used from T6 on. `hl_reconcile`/`hl_build` are stubbed in T5 and replaced in T6/T7, which is stated at both sites.

**Known soft spots**, to resolve with observed behaviour rather than assumption: the `[[keys.command]]` context variables (T8 step 6), whether `CLAUDE_CONFIG_DIR`/`CODEX_HOME` are honoured by the installer (T11 step 2), and the exact hook-registration key shapes (T11 steps 5 and 7).
