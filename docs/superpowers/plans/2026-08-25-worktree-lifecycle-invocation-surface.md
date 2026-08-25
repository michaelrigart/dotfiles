# Worktree Lifecycle Invocation Surface Implementation Plan

**Status:** In progress
**Date:** 2026-08-25

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **This plan is not re-runnable.** Once its tasks are complete, its status becomes `Implemented` and it must not be executed again. The task ordering and one-off instructions below apply to a single execution; they are not repository policy.

**Goal:** Make worktree retirement and recovery callable from a non-interactive shell, and catch the raw `git worktree remove` that bypassed them.

**Architecture:** Two thin zsh loaders on `$PATH` source the existing functions file and dispatch to the unchanged `wt-rm` / `wt-prepare` functions — no protocol logic moves. A `PreToolUse(Bash)` hook denies the one command shape that produced the husks: a literal absolute target matching the `wt` sibling convention. A written rule in the 1Password-backed agent instructions states the convention.

**Tech Stack:** zsh (wrappers, `test-wt-functions.sh`), Bash 3.2 (hook scripts and their suites, macOS system bash), `jq`, chezmoi.

**Spec:** `docs/superpowers/specs/2026-08-24-worktree-lifecycle-invocation-surface-design.md`

## Global Constraints

- **Edit chezmoi sources only**, never a deployed dotfile. Everything below is under `~/.local/share/chezmoi/`.
- **Hook scripts are Bash 3.2 compatible** (macOS system bash): no associative arrays, no `mapfile`, no `${x,,}`.
- **Guards fail open.** No `set -e`. Every failure path calls `allow()`. Anything unparseable is allowed. A guard that breaks unrelated commands is worse than no guard.
- **`deny`, never `ask`.** These are correctness catches, not danger gates — "prompt on danger, not mechanism".
- **Wrappers use zsh**, and must not use `set -u` (`zshenv` tests unset variables by design).
- **No agent attribution** in any commit message — no `Co-authored-by`, no session links, no "Generated with".
- **Branch:** `worktree-invocation-surface`, already created, spec committed at `b912836`.
- Test commands: `zsh .scripts/test-wt-functions.sh`, `bash .scripts/test-worktree-guard.sh`, `bash .scripts/test-claude-settings.sh`.

## File Structure

| File | Responsibility |
|---|---|
| `dot_local/bin/executable_wt-rm` | Create. Non-interactive entry point → `wt-rm` function. |
| `dot_local/bin/executable_wt-prepare` | Create. Non-interactive entry point → `wt-prepare` function. |
| `.scripts/test-wt-functions.sh` | Modify. Append section: wrapper reachability, arg preservation, exit status, degenerate functions files. |
| `dot_claude/executable_worktree-guard.sh` | Create. PreToolUse(Bash) guard. |
| `.scripts/test-worktree-guard.sh` | Create. Guard suite, mirroring `test-git-forge-guard.sh`. |
| `dot_claude/modify_private_settings.json` | Modify (lines 142–149). Append second PreToolUse entry. |
| `.scripts/test-claude-settings.sh` | Modify (lines 321–328). Pin both guards by index; keep SessionStart assertion. |

---

### Task 0: Open the design record for implementation

The design-record policy has three states, and `Approved` → `Implemented` skips the middle one. `In progress` means "being implemented or reviewed", so it is set when execution starts, not at the end.

**Files:**
- Modify: `docs/superpowers/plans/2026-08-25-worktree-lifecycle-invocation-surface.md` (header)
- Modify: `docs/superpowers/specs/2026-08-24-worktree-lifecycle-invocation-surface-design.md` (header)

**Interfaces:**
- Consumes: nothing.
- Produces: both records read `**Status:** In progress`. Task 4 Step 9 is the only place that may move them past it.

- [ ] **Step 1: Set both records In progress and commit**

Change `**Status:** Approved` to `**Status:** In progress` in both files.

```bash
cd ~/.local/share/chezmoi
git add docs/superpowers/
git commit -m "docs: open the worktree invocation surface record for implementation"
```

There is no MR reference yet — it is added in Task 4 Step 7, once the MR exists.

---

### Task 1: PATH wrappers for `wt-rm` and `wt-prepare`

Both wrappers are one deliverable — the invocation surface — and share a test section. They differ in one word.

**Files:**
- Create: `dot_local/bin/executable_wt-rm`
- Create: `dot_local/bin/executable_wt-prepare`
- Test: `.scripts/test-wt-functions.sh` (append a new section at end of file, before the final `export HOME="$REAL_HOME"` / summary block)

**Interfaces:**
- Consumes: the existing `wt-rm` and `wt-prepare` zsh functions from `dot_config/zsh/functions`. Neither is modified.
- Produces: executables deployed to `~/.local/bin/wt-rm` and `~/.local/bin/wt-prepare`. `XDG_BIN_HOME` is already on `PATH` (`dot_config/zsh/zshenv:8,15`).

- [ ] **Step 1: Write the failing tests**

Append to `.scripts/test-wt-functions.sh`, immediately **before** the closing `export HOME="$REAL_HOME"` line. The suite's helpers (`_pass`, `_fail`, `eq`, `setup`) are already defined above.

```zsh
# --- non-interactive wrappers (invocation-surface design §4.3, §7) -----------
# The wrappers exist because the lifecycle functions are only defined in an
# interactive shell. These cases run them the way an agent would: a bare `zsh`
# with no interactive rc, invoking the file by path.
print -r -- ""
print -r -- "Q. PATH wrappers reach the functions from a non-interactive shell"

WRAPDIR="$(cd "${0:h}/.." && pwd)/dot_local/bin"

# Source mode is NOT asserted: chezmoi derives the deployed 0755 from the
# `executable_` prefix, and the tracked modes in this repo are inconsistent
# (executable_git-forge-guard.sh is 100644, executable_app-cleaner is 100755).
# Step 6 verifies the mode that actually matters, on the deployed file.
for w in wt-rm wt-prepare; do
  [[ -f "$WRAPDIR/executable_$w" && -r "$WRAPDIR/executable_$w" ]] \
    && _pass "$w wrapper source exists and is readable" \
    || _fail "$w wrapper source exists and is readable"
done

# A wrapper with no arguments must reach the function and hit its own usage
# error — proof the dispatch happened, not that the file merely ran.
for w in wt-rm wt-prepare; do
  OUT="$(zsh "$WRAPDIR/executable_$w" 2>&1)"; RC=$?
  has "usage: $w <branch>" "$w wrapper dispatches to the function"
  rc_is 1 "$w wrapper propagates the function's exit status"
done

# Arguments must survive, including a branch containing a slash. `wt-rm` reports
# the derived sibling path in its does-not-exist refusal, so the slug proves the
# argument arrived intact.
setup
OUT="$(cd "$REPO" && zsh "$WRAPDIR/executable_wt-rm" 'feature/foo' 2>&1)"; RC=$?
has "repo-feature-foo" "wrapper preserves an argument containing a slash"

# Degenerate functions files. The empty case is the one that exercises the
# recursion guard: the file is readable, so the readability check passes, and
# only `$+functions` stands between the bare call and an infinite PATH loop.
FAKECONF="$ROOTTMP/fakeconf"
mkdir -p "$FAKECONF/zsh"
cp "$(cd "${0:h}/.." && pwd)/dot_config/zsh/zshenv" "$FAKECONF/zsh/zshenv"

# Recursion must be REACHABLE for this case to mean anything: a command named
# `wt-rm` has to exist on PATH, or removing the guard would give
# command-not-found rather than the infinite loop the guard exists to stop.
FAKEBIN="$ROOTTMP/fakebin"
mkdir -p "$FAKEBIN"
ln -sf "$WRAPDIR/executable_wt-rm" "$FAKEBIN/wt-rm"

: > "$FAKECONF/zsh/functions"
OUT="$(PATH="$FAKEBIN:$PATH" XDG_CONFIG_HOME="$FAKECONF" \
       zsh "$FAKEBIN/wt-rm" x 2>&1)"; RC=$?
has "did not define wt-rm" "empty functions file is refused, not recursed into"
rc_is 1 "empty functions file exits 1"

rm -f "$FAKECONF/zsh/functions"
OUT="$(XDG_CONFIG_HOME="$FAKECONF" zsh "$WRAPDIR/executable_wt-rm" x 2>&1)"; RC=$?
has "cannot read" "missing functions file is refused"
rc_is 1 "missing functions file exits 1"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh .scripts/test-wt-functions.sh 2>&1 | tail -25`

Expected: the `Q.` section reports FAILs — the wrapper files do not exist yet, so the existence checks fail and the dispatch checks produce `zsh: no such file or directory`.

- [ ] **Step 3: Write the `wt-rm` wrapper**

Create `dot_local/bin/executable_wt-rm`:

```zsh
#!/usr/bin/env zsh
# wt-rm — non-interactive entry point for worktree retirement.
#
# The lifecycle commands are zsh functions sourced by ~/.zshrc, so they resolve
# only in an interactive shell. Agents, scripts and cron run non-interactively,
# where raw `git worktree remove` was the only reachable option — and that path
# gets none of the protocol's guarantees (hook-protocol design §10). Six husk
# directories under ~/Code/Netronix came from exactly that.
#
# Interactive shells never reach this file: a zsh function shadows a PATH command.
#
# See docs/superpowers/specs/2026-08-24-worktree-lifecycle-invocation-surface-design.md §4.3

emulate -L zsh
set -f          # no globbing on branch names

conf="${XDG_CONFIG_HOME:-$HOME/.config}"

# zshenv is not optional: without it a bare zsh has no XDG variables, no wtcp or
# zellij on PATH, and no ZELLIJ_SOCKET_DIR — which wt-rm needs to find the session
# it must stop. Only the XDG base variables are guarded with `test "$X" ||`, so
# sourcing re-prepends PATH and re-runs `brew --prefix`; both are harmless in a
# process that exits immediately.
#
# No `set -u`: zshenv tests unset variables by design.
for f in zshenv functions; do
  [[ -r "$conf/zsh/$f" ]] || {
    print -ru2 -- "wt-rm: cannot read $conf/zsh/$f"; exit 1 }
  source "$conf/zsh/$f"
done

# The script and the function share a name. If the functions file is present but
# does not define wt-rm, the bare call below resolves back to THIS script through
# PATH and recurses without limit. A readability check does not cover that: the
# dangerous case is a file that exists and is readable but empty.
(( $+functions[wt-rm] )) || {
  print -ru2 -- "wt-rm: $conf/zsh/functions did not define wt-rm."; exit 1 }

wt-rm "$@"
```

- [ ] **Step 4: Write the `wt-prepare` wrapper**

Create `dot_local/bin/executable_wt-prepare` — identical but for the command name. Repeated in full deliberately; do not symlink or dispatch on `$0`, which trades a readable 25-line file for basename magic.

```zsh
#!/usr/bin/env zsh
# wt-prepare — non-interactive entry point for worktree recovery.
#
# Companion to the wt-rm wrapper. `wt-prepare <branch> && wt <branch>` is the
# documented resume path after a failed teardown (hook-protocol design §9.3), so a
# non-interactive caller that aborts a removal needs it to finish the job.
#
# Interactive shells never reach this file: a zsh function shadows a PATH command.
#
# See docs/superpowers/specs/2026-08-24-worktree-lifecycle-invocation-surface-design.md §4.3

emulate -L zsh
set -f          # no globbing on branch names

conf="${XDG_CONFIG_HOME:-$HOME/.config}"

# zshenv is not optional: without it a bare zsh has no XDG variables and no wtcp
# on PATH, which wt-prepare needs to copy the manifest. Only the XDG base
# variables are guarded, so sourcing re-prepends PATH; harmless in a process that
# exits immediately. No `set -u`: zshenv tests unset variables by design.
for f in zshenv functions; do
  [[ -r "$conf/zsh/$f" ]] || {
    print -ru2 -- "wt-prepare: cannot read $conf/zsh/$f"; exit 1 }
  source "$conf/zsh/$f"
done

# Recursion guard: script and function share a name, so a functions file that
# loads but defines nothing would send the bare call back through PATH to here.
(( $+functions[wt-prepare] )) || {
  print -ru2 -- "wt-prepare: $conf/zsh/functions did not define wt-prepare."; exit 1 }

wt-prepare "$@"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zsh .scripts/test-wt-functions.sh 2>&1 | tail -25`

Expected: the `Q.` section is all PASS, and the final `passed: N  failed: 0`.

If `usage: wt-prepare <branch>` does not match, read the actual usage string from `dot_config/zsh/functions:590` and correct the assertion — the wrapper is right, the expectation was guessed.

- [ ] **Step 6: Verify the deployed result is executable**

Run: `chezmoi apply --dry-run --verbose ~/.local/bin/wt-rm ~/.local/bin/wt-prepare`

Expected: both listed as new files with mode `0755`. chezmoi derives the mode from the `executable_` prefix; no `chmod` is needed in the source tree.

- [ ] **Step 7: Commit**

```bash
cd ~/.local/share/chezmoi
git add dot_local/bin/executable_wt-rm dot_local/bin/executable_wt-prepare .scripts/test-wt-functions.sh
git commit -m "feat(wt): add non-interactive entry points for wt-rm and wt-prepare

The lifecycle commands are zsh functions sourced by .zshrc, so they resolve only
in an interactive shell. Non-interactive callers had raw \`git worktree remove\`
as their only option, which the hook protocol leaves unguaranteed.

Thin loaders, no protocol logic moved. The \$+functions check is a recursion
guard: script and function share a name, so a functions file that loads but
defines nothing would send the bare call back through PATH."
```

---

### Task 2: The `worktree-guard.sh` PreToolUse hook

**Files:**
- Create: `dot_claude/executable_worktree-guard.sh`
- Create: `.scripts/test-worktree-guard.sh`

**Interfaces:**
- Consumes: the PreToolUse payload shape used by `test-git-forge-guard.sh:25-27` — `{hook_event_name, tool_name, cwd, tool_input:{command}}` on stdin.
- Produces: `~/.claude/worktree-guard.sh` after apply. Emits nothing (allow) or a `hookSpecificOutput.permissionDecision == "deny"` JSON object. Task 3 wires it.

- [ ] **Step 1: Write the failing test suite**

Create `.scripts/test-worktree-guard.sh`:

```bash
#!/usr/bin/env bash
# Mocked tests for dot_claude/executable_worktree-guard.sh.
#
# The guard is a PreToolUse(Bash) hook: it reads the payload on stdin and either
# stays silent (allow) or prints a permissionDecision=deny object. It fires on
# every Bash call, so a false deny blocks real work — most cases pin the ALLOW
# side, and the deny set is deliberately one command shape.
#
# Run: bash .scripts/test-worktree-guard.sh   (bash, sandboxed is fine)

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$SRC/dot_claude/executable_worktree-guard.sh"
[ -f "$GUARD" ] || { echo "missing guard: $GUARD" >&2; exit 1; }

pass=0; fail=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wt-guard.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# run <cwd> <command> -> prints the guard's stdout
run() {
  local cwd=$1 cmd=$2
  jq -n --arg c "$cmd" --arg d "$cwd" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
    | bash "$GUARD"
}

# expect <allow|deny> <label> <cwd> <command>
expect() {
  local want=$1 label=$2 cwd=$3 cmd=$4 out got
  out=$(run "$cwd" "$cmd")
  if [ -z "$out" ]; then
    got=allow
  elif printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
    got=deny
  else
    got="malformed: $out"
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1)); printf '  FAIL %s (want %s, got %s)\n' "$label" "$want" "$got"
  fi
}

# raw <stdin> -> asserts the guard allows whatever degenerate input it is handed
expect_raw_allow() {
  local label=$1 payload=$2 out
  out=$(printf '%s' "$payload" | bash "$GUARD" 2>/dev/null)
  if [ -z "$out" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1)); printf '  FAIL %s (want allow, got %s)\n' "$label" "$out"
  fi
}

# ---------------------------------------------------------------- fixtures
# A primary repo and its wt-convention sibling. The guard classifies by looking
# for a sibling directory that is a repo, so both must exist on disk.
REPO="$TMP/repo"
mkdir -p "$REPO" && git -C "$REPO" init -q 2>/dev/null
SIB="$TMP/repo-topic"
mkdir -p "$SIB"
# A project-local worktree, owned by another tool.
mkdir -p "$REPO/.worktrees/repo-topic"
mkdir -p "$REPO/.claude/worktrees/scratch"
# A slug containing a shell metacharacter, and one containing spaces.
HOSTILE="$TMP/repo-x|y"; mkdir -p "$HOSTILE"
# A REAL sibling pair whose names contain spaces. This one WOULD be denied if
# the parser resolved it, so the allow below proves the bail-out, not an accident.
mkdir -p "$TMP/my repo" && git -C "$TMP/my repo" init -q 2>/dev/null
SPACED="$TMP/my repo-topic"; mkdir -p "$SPACED"

echo "== the one denied shape: literal absolute wt sibling =="
expect deny  "absolute sibling target"      "$TMP" "git worktree remove $SIB"
expect deny  "with -C, absolute target"     "$TMP" "git -C $REPO worktree remove $SIB"
expect deny  "--force before the target"    "$TMP" "git worktree remove --force $SIB"
# The exact shapes of the six commands that produced the husks.
expect deny  "observed: pipe after"         "$TMP" "git worktree remove $SIB 2>&1 | tail -3"
expect deny  "observed: && echo after"      "$TMP" "git worktree remove $SIB && echo done"
expect deny  "observed: --force + pipe"     "$TMP" "git worktree remove --force $SIB 2>&1 | tail -2"
expect deny  "trailing semicolon"           "$TMP" "git worktree remove $SIB;"
# Scope is a standalone, beginning-anchored invocation. A PRECEDING command puts
# the removal mid-string, where no regex can bind a target to the right
# invocation — so it fails open, by design rather than by accident.
expect allow "preceding command"            "$TMP" "cd /tmp && git worktree remove $SIB"
expect allow "decoy remove token"           "$TMP" "echo remove \"$SIB\" && git worktree remove $TMP/nope"
expect allow "removal in a second clause"   "$TMP" "git worktree remove $TMP/nope; git worktree remove \"$SIB\""
expect deny  "double-quoted target"         "$TMP" "git worktree remove \"$SIB\""
expect deny  "single-quoted target"         "$TMP" "git worktree remove '$SIB'"
expect deny  "quoted slug with a pipe"      "$TMP" "git worktree remove \"$HOSTILE\""
expect deny  "double-quoted + semicolon"    "$TMP" "git worktree remove \"$SIB\";"
expect deny  "single-quoted + semicolon"    "$TMP" "git worktree remove '$SIB';"
expect deny  "quoted pipe slug + semicolon" "$TMP" "git worktree remove \"$HOSTILE\";"
expect deny  "quoted then &&"               "$TMP" "git worktree remove \"$SIB\" && echo hi"
# "$SIB"suffix concatenates into a DIFFERENT path, so denying on the quoted part
# would name the wrong directory. Fail open instead.
expect allow "quoted + glued suffix"        "$TMP" "git worktree remove \"$SIB\"suffix"
expect allow "quoted + glued .bak"          "$TMP" "git worktree remove '$SIB'.bak"

echo "== prune is always allowed (design §5.2) =="
expect allow "prune"                        "$TMP" 'git worktree prune'
expect allow "prune with expire"            "$TMP" 'git worktree prune --expire=now'
expect allow "list"                         "$TMP" 'git worktree list'

echo "== worktrees this protocol does not own =="
expect allow "project-local .worktrees"     "$TMP" "git worktree remove $REPO/.worktrees/repo-topic"
expect allow "harness .claude/worktrees"    "$TMP" "git worktree remove $REPO/.claude/worktrees/scratch"
expect allow "sibling that is not a repo"   "$TMP" "git worktree remove $TMP/orphan-thing"

echo "== documented blind spots, which must fail OPEN (design §5.3) =="
expect allow "relative target"              "$REPO" 'git worktree remove ../repo-topic'
expect allow "relative target under -C"     "$TMP"  "git -C $REPO worktree remove ../repo-topic"
expect allow "unique-suffix identifier"     "$TMP"  'git worktree remove repo-topic'
expect allow "variable target"              "$TMP"  'git worktree remove "$WORKTREE_PATH"'
expect allow "real spaced sibling bails"    "$TMP"  "git worktree remove \"$SPACED\""

echo "== false positives: mentions, not invocations =="
expect allow "rg mentioning the command"    "$TMP" "rg \"git worktree remove\" docs/"
expect allow "shell comment"                "$TMP" "# git worktree remove $SIB"
expect allow "heredoc mentioning it"        "$TMP" "cat <<EOF
run git worktree remove later
EOF"
expect allow "plain ls"                     "$TMP" 'ls -la'

echo "== bypass switch, any position =="
expect allow "bypass leading"   "$TMP" "WT_GUARD=off git worktree remove $SIB"
expect allow "bypass middle"    "$TMP" "cd /tmp && WT_GUARD=off git worktree remove $SIB"
expect allow "bypass trailing"  "$TMP" "git worktree remove $SIB # WT_GUARD=off"

echo "== degenerate input fails open =="
expect_raw_allow "empty payload"        ''
expect_raw_allow "malformed JSON"       'not json at all { worktree remove'
expect_raw_allow "no command key"       '{"tool_name":"Bash","tool_input":{}}'
expect_raw_allow "null command"         '{"tool_input":{"command":null}}'

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `bash .scripts/test-worktree-guard.sh`

Expected: exits 1 immediately with `missing guard: .../dot_claude/executable_worktree-guard.sh`.

- [ ] **Step 3: Write the guard**

Create `dot_claude/executable_worktree-guard.sh`:

```bash
#!/usr/bin/env bash
# PreToolUse(Bash) guard for raw worktree removal.
#
# Enforces the worktree rule from ~/.config/agents/GLOBAL.md that prose alone
# cannot guarantee: a wt-managed sibling worktree is retired with `wt-rm`, never
# raw `git worktree remove`. Raw removal skips session shutdown, so live
# processes rewrite into the deleted path — six husk directories came from that.
#
# Scope is deliberately ONE command shape (design §5.1): a literal ABSOLUTE
# target matching the wt sibling convention. Relative targets, -C-relative
# targets, unique-suffix identifiers, variable targets, native worktree tools and
# WT_GUARD=off are documented blind spots that fail open (§5.3). This is a
# correctness catch, not a security boundary.
#
# `git worktree prune` is ALWAYS allowed: it touches only $GIT_DIR/worktrees,
# acts only where the directory is already gone, and is what git prescribes after
# a manual removal — the reconciliation path of hook-protocol design §10.
#
# SAFETY: a guard that breaks unrelated commands is worse than no guard. There is
# no `set -e`; every failure path calls allow(); anything unparseable is allowed.
# The on-disk sibling check is itself the main false-positive defence: the guard
# denies only when the target exists RIGHT NOW next to a real repository.
#
# Bypass for a one-off: put WT_GUARD=off anywhere in the command.
#
# Bash 3.2 compatible (macOS system bash). Tests: .scripts/test-worktree-guard.sh

set -uo pipefail
set -f   # no pathname expansion — command text is never a glob

allow() { exit 0; }

# A deny reason contains paths and quotes, so it goes through jq -Rs rather than
# hand-escaping. If jq fails, allow.
deny() {
  printf '%s' "$1" | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}' \
    2>/dev/null || exit 0
  exit 0
}

payload=$(cat)
[ -n "$payload" ] || allow
command -v jq >/dev/null 2>&1 || allow

# Fast path. This hook fires on EVERY Bash call, so the common case must cost no
# subprocess at all — a shell-builtin substring test before any JSON parsing.
case "$payload" in
  *"worktree remove"*) ;;
  *) allow ;;
esac

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || allow
[ -n "$cmd" ] || allow
[ "$cmd" = "null" ] && allow

case "$cmd" in *WT_GUARD=off*) allow ;; esac

# Anchored at the start of the first line. Every one of the six observed husk
# commands BEGAN with the removal — pipes and `&& echo` came after, nothing
# before. A preceding command (`cd x && git worktree remove ...`) is out of scope
# and fails open, because a regex that matches mid-command cannot tell which
# invocation a later token belongs to.
first=$(printf '%s\n' "$cmd" | head -1)
verb_re='^[[:space:]]*(sudo[[:space:]]+)?git([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]-][^[:space:]]*)?)*[[:space:]]+worktree[[:space:]]+remove([[:space:]]+|$)'
printf '%s' "$first" | grep -Eq "$verb_re" || allow

# Extraction is BOUND to that invocation: drop the matched prefix and read the
# target from what remains. Scanning for a `remove` token instead would pick up
# `echo remove /other && git worktree remove /real` and name the wrong directory.
strip_re='^[[:space:]]*(sudo[[:space:]]+)?git([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]-][^[:space:]]*)?)*[[:space:]]+worktree[[:space:]]+remove[[:space:]]*'
args=$(printf '%s' "$first" | sed -E "s#$strip_re##")

target=""
quoted=""
rest=""
after=""
for tok in $args; do
  case "$tok" in
    -*) continue ;;
  esac
  # A quoted target keeps its quote characters after word splitting, so `/*`
  # would never match and `git worktree remove "/abs/path"` — the COMMON form —
  # would sail through. Take everything between the opening quote and the next
  # one, which also drops any operator glued on after the close (`"/p";`).
  # A token with no closing quote is a quoted path containing spaces: it split
  # across tokens, so bail rather than act on a truncated path.
  case "$tok" in
    \"*)
      rest=${tok#\"}
      case "$rest" in
        *\"*)
          target=${rest%%\"*}
          after=${rest#*\"}
          # Whatever follows the closing quote must be a shell operator. Otherwise
          # the word CONCATENATES into a different path ("/p"x -> /px), and acting
          # on the quoted part would deny the wrong directory.
          case "$after" in
            ""|[\;\&\|\)\<\>]*) quoted=1 ;;
            *) target=""; break ;;
          esac
          ;;
        *) target=""; break ;;
      esac
      ;;
    \'*)
      rest=${tok#\'}
      case "$rest" in
        *\'*)
          target=${rest%%\'*}
          after=${rest#*\'}
          case "$after" in
            ""|[\;\&\|\)\<\>]*) quoted=1 ;;
            *) target=""; break ;;
          esac
          ;;
        *) target=""; break ;;
      esac
      ;;
    *) target=$tok; quoted="" ;;
  esac
  case "$target" in
    /*) break ;;
    *)  target=""; break ;;
  esac
done
[ -n "$target" ] || allow

# Unquoted only: word splitting leaves a trailing shell metacharacter glued to
# the token (`... remove /path;`). Inside quotes those are literal filename
# characters, so trimming them there would corrupt a legitimate target.
[ -z "$quoted" ] && target=${target%%[;&|)]*}
target=${target%/}
[ -d "$target" ] || allow

# Sibling classification, filesystem only — no git subprocess. For each hyphen in
# the basename, test whether <parent>/<prefix> is a repository. Splitting at every
# hyphen rather than the first is required: repository names contain hyphens, as
# VM.Portal-duplicate-alerts shows.
parent=$(dirname "$target")
base=$(basename "$target")

acc=""
rest="$base"
matched=""
while [ "${rest#*-}" != "$rest" ]; do
  seg=${rest%%-*}
  if [ -n "$acc" ]; then acc="$acc-$seg"; else acc=$seg; fi
  rest=${rest#*-}
  if [ -d "$parent/$acc" ] && [ -e "$parent/$acc/.git" ]; then
    matched=$acc
    break
  fi
done
[ -n "$matched" ] || allow

slug=${base#"$matched"-}

deny "Raw \`git worktree remove\` on a wt-managed worktree.

$target is the wt sibling of the repository at $parent/$matched.

Removing it with raw git skips session shutdown and the project teardown hook.
Live processes then write back into the deleted path, which is what leaves husk
directories behind. Retire it through the protocol instead:

    wt-rm <branch>

The directory slug is \"$slug\". That is not always the branch name — a slug maps
'/' to '-', so a branch containing a slash differs. Use the branch you were
working on.

If this worktree belongs to another tool (a native or harness worktree), use that
tool's own lifecycle command; this rule covers the wt sibling convention only.

For a deliberate manual reconciliation, re-run with WT_GUARD=off in the command."
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `bash .scripts/test-worktree-guard.sh`

Expected: every case `ok`, then `passed: 41  failed: 0`.

This guard and suite were validated end-to-end before this plan was written; 41/41 is a verified number, not an estimate.

If `bypass trailing` fails, note that `# WT_GUARD=off` is matched by the substring test before the verb check — that is intended.

If any *deny* case reports allow, debug in this order: (1) does the fixture sibling exist on disk, (2) does `verb_re` match — test it in isolation with `printf '%s' "$cmd" | grep -E "$verb_re"`, (3) does target extraction find the path.

- [ ] **Step 5: Verify the guard costs nothing on the common path**

Run:

```bash
time (for i in $(seq 1 50); do
  printf '{"tool_input":{"command":"ls -la"}}' | bash dot_claude/executable_worktree-guard.sh
done)
```

Expected: well under 2s total. Any Bash call that does not mention `worktree remove` must exit at the `case` fast path without spawning `jq`.

- [ ] **Step 6: Commit**

```bash
cd ~/.local/share/chezmoi
git add dot_claude/executable_worktree-guard.sh .scripts/test-worktree-guard.sh
git commit -m "feat(claude): guard raw git worktree remove on wt siblings

Denies one shape: a literal absolute target that is the wt sibling of a real
repository. Everything else fails open — relative and suffix targets, variable
targets, worktrees owned by other tools, and prune, which git itself prescribes
after a manual removal.

The on-disk sibling check doubles as the false-positive defence: a mention in a
heredoc or doc only denies if that worktree exists right now."
```

---

### Task 3: Wire the guard into settings

**Files:**
- Modify: `dot_claude/modify_private_settings.json:142-149`
- Modify: `.scripts/test-claude-settings.sh:321-328`

**Interfaces:**
- Consumes: `dot_claude/executable_worktree-guard.sh` from Task 2, deployed to `~/.claude/worktree-guard.sh`.
- Produces: a second `hooks.PreToolUse` array entry. The forge guard stays at index `0`; the worktree guard is index `1`.

- [ ] **Step 1: Update the settings assertions to expect both guards**

Replace `.scripts/test-claude-settings.sh` lines 321–328 with:

```bash
echo "N. both Bash guards are wired as PreToolUse hooks"
# Index-pinned, not just length-checked. These assertions are positional, so a
# reordering would silently retarget them at the wrong guard rather than fail.
jq_is '.hooks.PreToolUse | length' 2 "exactly two PreToolUse entries"
jq_is '.hooks.PreToolUse[0].matcher' 'Bash' "forge guard matches the Bash tool"
jq_is '.hooks.PreToolUse[0].hooks[0].command' 'bash $HOME/.claude/git-forge-guard.sh' \
      'entry 0 runs the forge guard, $HOME left for the shell to expand'
jq_is '.hooks.PreToolUse[1].matcher' 'Bash' "worktree guard matches the Bash tool"
jq_is '.hooks.PreToolUse[1].hooks[0].command' 'bash $HOME/.claude/worktree-guard.sh' \
      'entry 1 runs the worktree guard, $HOME left for the shell to expand'
# The SessionStart hook must survive alongside them — adding PreToolUse replaced the
# whole hooks object once during development.
jq_is '.hooks.SessionStart | length' 1 "SessionStart hook still present"
```

- [ ] **Step 2: Run the settings suite to verify it fails**

Run: `bash .scripts/test-claude-settings.sh 2>&1 | grep -A8 "^N\."`

Expected: `exactly two PreToolUse entries` FAILs, reporting `1`. The two `[1]` assertions FAIL with `null`.

- [ ] **Step 3: Add the second PreToolUse entry**

In `dot_claude/modify_private_settings.json`, replace the `"PreToolUse"` array (lines 142–149) with:

```json
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              { "type": "command", "command": "bash $HOME/.claude/git-forge-guard.sh" }
            ]
          },
          {
            "matcher": "Bash",
            "hooks": [
              { "type": "command", "command": "bash $HOME/.claude/worktree-guard.sh" }
            ]
          }
        ]
```

Add above it, after the existing forge-guard comment block:

```
        # Second entry: the worktree guard. Denies raw `git worktree remove` on a wt
        # sibling worktree, which skips session shutdown and leaves husk directories.
        # Order is load-bearing — test-claude-settings.sh pins each guard by index.
        # Tests in .scripts/test-worktree-guard.sh.
```

- [ ] **Step 4: Run the settings suite to verify it passes**

Run: `bash .scripts/test-claude-settings.sh 2>&1 | tail -5`

Expected: `passed: N  failed: 0`.

- [ ] **Step 5: Verify the modify script still emits valid JSON**

The file is a chezmoi `modify_` script, not static JSON — it receives the current settings on stdin and pipes through `jq`. A syntax error inside the jq program is only visible when it runs:

```bash
printf '{}' | bash dot_claude/modify_private_settings.json | jq -e '.hooks.PreToolUse | length == 2'
```

Expected: prints `true`. If it errors, the jq program has a syntax error — check for a missing comma between the two array entries.

- [ ] **Step 6: Confirm the real apply is a clean diff**

Run: `chezmoi diff ~/.claude/settings.json`

Expected: only the added PreToolUse entry. If unrelated keys appear, stop — the modify script is dropping tool-written keys and that is a separate bug.

- [ ] **Step 7: Commit**

```bash
cd ~/.local/share/chezmoi
git add dot_claude/modify_private_settings.json .scripts/test-claude-settings.sh
git commit -m "feat(claude): wire the worktree guard as a second PreToolUse hook

The settings suite asserted exactly one PreToolUse entry and read the forge guard
at index 0, so adding a guard broke it. Assertions now pin each guard to its own
index: positional checks would otherwise retarget silently on a reorder rather
than fail. SessionStart stays asserted — adding PreToolUse replaced the whole
hooks object once before."
```

---

### Task 4: The written rule

The prose lives in the 1Password item `Private/Agent instructions` (notes field), rendered by three identical templates. **The spec does not authorize an agent to write to it** — this task prepares the text and verifies the result; Michaël makes the edit.

**Files:**
- Modify (by Michaël): 1Password item `Private/Agent instructions`, notes field
- Renders to: `~/.config/agents/GLOBAL.md`, `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`

**Interfaces:**
- Consumes: the wrappers from Task 1 (the rule names commands that must exist) and the guard from Tasks 2–3 (the rule the guard backstops).
- Produces: no code. Ordering matters — a rule naming `wt-rm` before it is on `$PATH` would be unfollowable, the exact failure this whole plan corrects.

- [ ] **Step 1: Confirm the wrappers are actually deployed first**

```bash
chezmoi apply ~/.local/bin/wt-rm ~/.local/bin/wt-prepare
zsh -c 'command -v wt-rm && command -v wt-prepare'
```

Expected: both print `/Users/michael/.local/bin/...`. This is the check the original design failed: do not write the rule until this passes.

- [ ] **Step 2: Hand Michaël the exact text**

Present this for the "Development" section of the agent instructions, after the existing `wt <branch>` sentence:

> Worktree teardown goes through `wt-rm <branch>`, never raw `git worktree remove`.
> Raw removal skips the Zellij session shutdown and the project teardown hook, so
> live processes write back into the deleted directory and leave a husk behind.
> `wt-rm` and `wt-prepare` are on `$PATH`, so they work from a non-interactive
> shell too. Agents do not create `wt`-managed sibling worktrees — that stays an
> interactive command, because `wt` attaches to a Zellij session. Native or
> harness worktrees (`EnterWorktree`, an agent's `isolation: "worktree"`) are
> owned by their own lifecycle tool and are outside this rule.

Note for Michaël: `op` is the one command that must run with the sandbox disabled, and a full `chezmoi apply` needs `op` signed in with the desktop app approved.

- [ ] **Step 3: Verify the rendered result after Michaël applies**

```bash
chezmoi apply ~/.config/agents/GLOBAL.md ~/.claude/CLAUDE.md ~/.codex/AGENTS.md
for f in ~/.config/agents/GLOBAL.md ~/.claude/CLAUDE.md ~/.codex/AGENTS.md; do
  printf '%s: ' "$f"; grep -c 'wt-rm <branch>' "$f"
done
```

Expected: `1` for all three. A `0` on one means that template did not re-render — re-run `chezmoi apply` for it specifically.

- [ ] **Step 4: End-to-end check that the guard fires and names the right remedy**

With a real sibling worktree present, confirm the guard denies and the message is actionable:

```bash
printf '{"tool_input":{"command":"git worktree remove /Users/michael/Code/Netronix/curato-issue-99"}}' \
  | bash ~/.claude/worktree-guard.sh | jq -r '.hookSpecificOutput.permissionDecisionReason' | head -5
```

Expected: no output if no such directory exists (correct — the guard denies only what is on disk). To see a real deny, substitute a sibling worktree that currently exists, or reuse the suite's filesystem fixture:

```bash
T=$(mktemp -d); mkdir -p "$T/repo" && git -C "$T/repo" init -q && mkdir -p "$T/repo-topic"
printf '{"tool_input":{"command":"git worktree remove %s/repo-topic"}}' "$T" \
  | bash ~/.claude/worktree-guard.sh | jq -r '.hookSpecificOutput.permissionDecisionReason' | head -6
rm -rf "$T"
```

Do **not** create one with `wt` — that is an interactive command that switches Zellij sessions, and creating a `wt` sibling is exactly what the rule in Step 2 tells agents not to do.

- [ ] **Step 5: Run the full suite before claiming anything**

Status must never be set on unverified work. Run every suite, sandbox-off — `test-wt-functions.sh` drives real git and zellij stubs:

```bash
cd ~/.local/share/chezmoi
zsh  .scripts/test-wt-functions.sh    | tail -3
bash .scripts/test-worktree-guard.sh  | tail -3
bash .scripts/test-claude-settings.sh | tail -3
bash .scripts/test-git-forge-guard.sh | tail -3
```

All four must end `failed: 0`. The forge-guard suite is included because Task 3 touches the settings object it shares.

If any suite fails, stop here. Do not proceed to Step 6 — a failing suite with an `Implemented` record is exactly the false history this ordering exists to prevent.

- [ ] **Step 6: Open the MR**

Follow the repo's MR/PR template if one exists; otherwise a short what / why / how-to-verify. No agent attribution anywhere in the title or description.

- [ ] **Step 7: Cite the MR while review is active**

The records stay `In progress` — they are still being reviewed — but must now carry the reference.

In both files, change `**Status:** In progress` to `**Status:** In progress — MR !<n>`.

```bash
cd ~/.local/share/chezmoi
git add docs/superpowers/
git commit -m "docs: reference MR !<n> on the worktree invocation surface record"
git push
```

- [ ] **Step 8: Wait for review and CI**

Do not proceed until review is complete and every required check has passed. `In progress` is the correct state for the whole of this step, however long it takes.

- [ ] **Step 9: Set Implemented — the final pre-merge commit**

Only once implementation and review are both complete and merging is the next action:

In both files, change `**Status:** In progress — MR !<n>` to `**Status:** Implemented — MR !<n>`.

```bash
cd ~/.local/share/chezmoi
git add docs/superpowers/
git commit -m "docs: mark the worktree invocation surface design and plan Implemented — MR !<n>"
git push
git log --oneline main..HEAD
```

Expected: eight commits — the spec, the plan, the In progress flip, the wrappers, the guard, the settings wiring, the MR reference, and this status commit. The spec and plan were both committed before execution began, which is why the count starts at two.

Adding the merge SHA afterwards is optional and never requires a status-only follow-up MR.
