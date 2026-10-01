# Herdr/wt simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the three verified wt/Herdr bugs and delete the machinery behind two of them, as specified in the design.

**Architecture:** Workspace identity moves from pane cwd to Herdr's `worktree.checkout_path` provenance, in both `wt-rm` and `layout.sh`. `wt-rm` closes only the checkout's own workspace, and delegates its last process check to `wt-teardown scan`. `layout.sh` stops classifying workspaces: it focuses and adds missing tabs. Worktrees are Git-locked at creation, and the guard adds the two lock-crossing shapes to today's sibling rule.

**Tech Stack:** zsh (functions, layout.sh, wt-teardown, the zsh suites), bash 3.2 (the guard, phase.sh, the bash suites), jq, git 2.56, herdr 0.9.3, chezmoi.

**Spec:** `docs/superpowers/specs/2026-10-01-herdr-wt-simplification-design.md` (commit `cfb2ff5`). Read it before any task; section numbers below (§1–§13) refer to it.

## Global Constraints

- Run every suite through `./tests/run.sh <name>` or by executing it (`./tests/x.test.sh`). Never prefix an interpreter, and never brace-expand suite names.
- Run one full suite at a time; never run several suites in parallel.
- Report test totals as passed/total.
- Lock reason string, byte-identical everywhere: `wt-managed; remove with command wt-rm`.
- Every herdr call in `layout.sh`, `tab-goto.sh` and `phase.sh` goes through the session-threaded wrapper; never a bare `command herdr` there.
- In zsh, never name a local variable `path` (it is the array tied to PATH).
- Library functions in `dot_config/zsh/functions` use `builtin cd`, never bare `cd` (a suite checks this).
- No new permission prompts; the guard denies silently with an actionable reason.
- Do not edit `dot_local/bin/executable_codex`, `dot_local/bin/executable_xreview`, `dot_codex/executable_herdr-codex-pane-map.py`, `dot_codex/modify_private_config.toml`, `dot_claude/skills/cross-review/`, or their tests. `AGENTS.md` is edited only in Task 12, after main (with Option B) is merged in.
- Commits: small, imperative mood, no agent attribution of any kind. Re-check `git branch --show-current` is `herdr-wt-simplify` right before each commit.
- `wt-rm` is Michael's. Implementers run it only through the test suites, against scratch fixtures; never against a real worktree.

## Review Focus

1. **A checkout path reached through a symlink.** `~/Code` may sit behind a symlink. `wt-rm` must still recognise the checkout's own workspace when Herdr reports the provenance through the link. Test: Task 3, U10.
2. **A worktree whose setup failed.** It must be locked, still preparable with `wt-prepare`, and still removable with `wt-rm`. Tests: Task 4, LK1–LK4.
3. **A multi-line Bash command whose second line removes or unlocks.** The guard must catch it, while a heredoc body or a comment that spells the command must not trigger a deny. Tests: Task 6.
4. **A `.worktreeinclude` entry that is a directory.** It must arrive recursively with file modes kept. Test: Task 5, CP3.
5. **`HERDR_SESSION` naming a session that does not exist.** `wt-rm` handles the default session and does not refuse. Test: Task 3, U11.

---

### Task 0: Pre-build gate (controller, not a subagent)

**Files:**
- Modify: `docs/superpowers/specs/2026-10-01-herdr-wt-simplification-design.md:3` (status line)

- [ ] **Step 1: Confirm Option B is merged.**

Run: `git -C /Users/michael/.local/share/chezmoi-herdr-wt-simplify merge-base --is-ancestor xreview-option-b main && echo merged`
Expected: `merged`. If not, stop; the build does not start (spec §11).

- [ ] **Step 2: Merge main into the branch.**

Run: `git -C /Users/michael/.local/share/chezmoi-herdr-wt-simplify merge --no-edit main`
Expected: a clean merge. Any conflict needs resolution before Step 3.

- [ ] **Step 3: Record the baseline.**

Run each suite one at a time: `./tests/run.sh wt-functions`, `./tests/run.sh wt-teardown`, `./tests/run.sh dev`, `./tests/run.sh worktree-guard`, `./tests/run.sh herdr-phase`, `./tests/run.sh claude-settings`.
Expected: all green. Write the passed/total per suite into the run notes (`docs/superpowers/runs/`, never committed).

- [ ] **Step 4: Set the spec status.**

Change `**Status:** Approved` to `**Status:** In progress (branch herdr-wt-simplify; the dotfiles have no MR)`.

- [ ] **Step 5: Commit.**

```bash
git add docs/superpowers/specs/2026-10-01-herdr-wt-simplification-design.md
git commit -m "Mark the Herdr/wt simplification as in progress"
```

---

### Task 1: `wt-teardown scan`

Tier: `sp-standard`. Spec §2.

**Files:**
- Modify: `dot_local/bin/executable_wt-teardown`
- Test: `tests/wt-teardown.test.sh`

**Interfaces:**
- Produces: `WT_WORKTREE=<abs-dir> wt-teardown scan`. It prints one `<pid> <command>` line per process whose cwd is at or under the directory. Exit 0 = listing trusted (possibly empty). Exit 1 = untrusted listing, missing lsof, a control character in the path, or a bad `WT_WORKTREE`. Exit 64 = usage, including `scan` combined with `--pidfile` or `--sweep`. It never signals.

- [ ] **Step 1: Give the lsof stub a controllable exit status and add a `spawn_in` helper.**

In `tests/wt-teardown.test.sh`, change the raw branch of the `$T/bin/lsof` stub heredoc from:

```zsh
if [[ "$(cat "$d/mode" 2>/dev/null)" == raw ]]; then
  cat "$d/raw"
  exit 0
fi
```

to:

```zsh
if [[ "$(cat "$d/mode" 2>/dev/null)" == raw ]]; then
  cat "$d/raw"
  exit "$(cat "$d/rc" 2>/dev/null || echo 0)"
fi
```

Then make `mk_raw` reset it, and add the helper below `spawn`:

```bash
mk_raw()  { printf "$@" > "$T/bin/raw"; echo raw > "$T/bin/mode"; : > "$T/bin/calls"; rm -f "$T/bin/drop_after" "$T/bin/rc"; }
# spawn_in <dir> <cmd...> — spawn, detached, with its cwd in <dir>.
spawn_in() { ( cd "$1" || exit 1; shift; "$@" >/dev/null 2>&1 & echo $! ); }
```

- [ ] **Step 2: Write the failing `scan` tests.**

Append before the final `RESULT` line:

```bash
echo
echo "U. scan reports occupants and signals nothing"
mk_live </dev/null
out="$(srun scan)"; is "an idle worktree scans clean" "$?" "0"
is "and reports nothing" "$out" ""
is "scan reads the process list exactly once" "$(cat "$T/bin/calls")" "1"

occ="$(spawn command sleep 300)"
mk_live <<EOF
$occ sleep $WT/tmp/deep
EOF
out="$(srun scan)"; is "scan exits 0 when the worktree is occupied" "$?" "0"
has "and prints pid and command" "$out" "^$occ sleep"
sleep 0.3
is "scan signals nothing" "$(kill -0 "$occ" 2>/dev/null; echo $?)" "0"
kill -9 "$occ" 2>/dev/null

sib="$(spawn command sleep 300)"
mk_live <<EOF
$sib sleep ${WT}-two/x
EOF
out="$(srun scan)"; is "a sibling suffix is not an occupant" "$out" ""
kill -9 "$sib" 2>/dev/null

out="$(srun --sweep ruby scan)"; is "scan with --sweep is a usage error" "$?" "64"
out="$(srun --pidfile tmp/pids/x.pid scan)"; is "scan with --pidfile is a usage error" "$?" "64"
out="$(WT_WORKTREE= zsh "$SUBJECT" scan 2>&1)"; is "scan needs WT_WORKTREE" "$?" "1"
out="$(PATH=/bin WT_WORKTREE="$WT" /bin/zsh "$SUBJECT" scan 2>&1)"
is "scan without lsof fails closed" "$?" "1"
has "and names lsof" "$out" "lsof is unavailable"

echo
echo "V. scan fails closed on a listing it cannot trust"
mk_raw ''
out="$(srun scan)"; is "an empty listing fails scan closed" "$?" "1"
has "and says the list was unreadable" "$out" "could not read the process list"
mk_raw 'p1\0R1\0claunchd\0fcwd\0nnot/absolute\0'
out="$(srun scan)"; is "a relative cwd fails scan closed" "$?" "1"
mk_raw 'pnot-a-pid\0R1\0claunchd\0fcwd\0n/\0'
out="$(srun scan)"; is "a non-numeric pid fails scan closed" "$?" "1"
mk_raw 'p1\0R1\0claunchd\0fcwd\0n/\0p4321\0R1\0chalfway\0fcwd\0n%s\0' "$WT"
echo 1 > "$T/bin/rc"
out="$(srun scan)"; is "a nonzero lsof exit fails scan closed even with records" "$?" "1"
case "$out" in
  *halfway*) _fail "records from a failed scan are not reported" ;;
  *)         _pass "records from a failed scan are not reported" ;;
esac
mk_raw 'p1\0R1\0claunchd\0fcwd\0n%s\0' "/outside\\np99\\ncphantom\\nfcwd\\nn$WT"
out="$(srun scan)"; is "a rendered path outside the checkout parses" "$?" "0"
case "$out" in
  *phantom*) _fail "escaped text never becomes a record" ;;
  *)         _pass "escaped text never becomes a record" ;;
esac

echo
echo "W. scan compares against lsof's LC_ALL=C rendering"
BS="$T/back\\slash-co"; mkdir -p "$BS"
mk_raw 'p1\0R1\0claunchd\0fcwd\0n/\0p4242\0R1\0cdaemon\0fcwd\0n%s\0' "$T/back\\\\slash-co"
out="$(PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$BS" zsh "$SUBJECT" scan 2>&1)"
is "a backslash path scans" "$?" "0"
has "and matches lsof's doubled backslash" "$out" "^4242 daemon"
CTL="$T/ctrl"$'\n'"co"; mkdir -p "$CTL"
mk_raw 'p1\0R1\0claunchd\0fcwd\0n/\0'
out="$(PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$CTL" zsh "$SUBJECT" scan 2>&1)"
is "a control character in the path fails closed" "$?" "1"
has "and says why" "$out" "control character"
U8="$T/café-co"; mkdir -p "$U8"
mk_raw 'p1\0R1\0claunchd\0fcwd\0n/\0p4244\0R1\0cdaemon\0fcwd\0n%s\0' "$T/caf\\xc3\\xa9-co"
out="$(PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$U8" zsh "$SUBJECT" scan 2>&1)"
is "a non-ASCII path scans" "$?" "0"
has "and matches the pinned rendering" "$out" "^4244 daemon"

echo
echo "X. scan against the real lsof"
mkdir -p "$WT/deep" "${WT}-extra"
inside="$(spawn_in "$WT/deep" sleep 60)"
outside="$(spawn_in "${WT}-extra" sleep 60)"
RU="$T/réal-çheckout"; mkdir -p "$RU/deep"
u8pid="$(spawn_in "$RU/deep" sleep 60)"
sleep 1
out="$(PATH=/usr/sbin:/usr/bin:/bin WT_WORKTREE="$WT" zsh "$SUBJECT" scan 2>&1)"
is "the real lsof listing is read" "$?" "0"
has "a real process inside is reported" "$out" "^$inside sleep"
case "$out" in
  *"$outside sleep"*) _fail "a real process in the sibling path is not reported" ;;
  *)                  _pass "a real process in the sibling path is not reported" ;;
esac
for loc in C en_US.UTF-8; do
  out="$(LC_ALL=$loc PATH=/usr/sbin:/usr/bin:/bin WT_WORKTREE="$RU" zsh "$SUBJECT" scan 2>&1)"
  is "a real non-ASCII checkout scans (LC_ALL=$loc)" "$?" "0"
  has "and its occupant is found (LC_ALL=$loc)" "$out" "^$u8pid sleep"
done
kill -9 "$inside" "$outside" "$u8pid" 2>/dev/null
```

- [ ] **Step 3: Run the suite to see the new cases fail.**

Run: `./tests/run.sh wt-teardown`
Expected: FAIL. `scan` is still an unknown verb and exits 64, so sections U–X fail.

- [ ] **Step 4: Implement the verb.**

In `dot_local/bin/executable_wt-teardown`:

```zsh
usage() {
  print -ru2 -- "usage: $PROG [--pidfile REL]... [--sweep COMMAND]... setup|teardown"
  print -ru2 -- "       $PROG scan"
  exit 64
}
```

Replace the verb dispatch:

```zsh
case "$VERB" in
  setup)    exit 0 ;;
  teardown) ;;
  scan)     (( ${#PIDFILES} || ${#SWEEPS} )) && usage ;;
  *)        usage ;;
esac
```

Directly after the closing brace of `_scan`, add:

```zsh
# scan: report occupants for wt-rm's last check, signal nothing.
if [[ "$VERB" == scan ]]; then
  _scan "$WT"
  exit $?
fi
```

Change the `# Everything below is the teardown verb.` comment to `# Everything below serves the teardown and scan verbs.`

- [ ] **Step 5: Run the suite.**

Run: `./tests/run.sh wt-teardown`
Expected: PASS, every section A–X; record passed/total.

- [ ] **Step 6: Commit.**

```bash
git add dot_local/bin/executable_wt-teardown tests/wt-teardown.test.sh
git commit -m "Add a scan verb to wt-teardown"
```

---

### Task 2: `wt-rm` check 4 uses `wt-teardown scan`

Tier: `sp-standard`. Spec §2.

**Files:**
- Modify: `dot_config/zsh/functions` (delete `_wt_lsof_render` and `_wt_live_processes` together with their comment blocks; edit check 4 in `wt-rm`)
- Test: `tests/wt-functions.test.sh` (stubs, `setup`, section V)

**Interfaces:**
- Consumes: `WT_WORKTREE=<dest> wt-teardown scan` from Task 1, resolved through PATH.
- Produces: `wt-rm` refusal messages; the existing strings `still in use by a running process` and `could not read the process list` (the latter now printed by wt-teardown) stay.

- [ ] **Step 1: Point the suite at the source helper and the new lsof format.**

In `tests/wt-functions.test.sh`, after `chmod +x "$STUBS/layout.sh" "$STUBS/herdr" "$STUBS/lsof"`, add a wrapper. The source file is mode 644, so a symlink would not be executable:

```zsh
TEARDOWN_SRC="$(cd "${0:h}/.." && pwd)/dot_local/bin/executable_wt-teardown"
[[ -r "$TEARDOWN_SRC" ]] || { print -ru2 -- "cannot read $TEARDOWN_SRC"; exit 2 }
print -r -- "#!/bin/sh
exec zsh '$TEARDOWN_SRC' \"\$@\"" > "$STUBS/wt-teardown"
chmod +x "$STUBS/wt-teardown"
```

Replace the format selection and emission in the lsof stub with the one format `_scan` asks for:

```bash
case " $* " in
  *" -F0pcnR "*) ;;
  *) echo "lsof stub: unexpected invocation: $*" >&2; exit 1 ;;
esac
while IFS=$'\t' read -r pid cmd cwd; do
  [ -n "$pid" ] || continue
  printf 'p%s\0R1\0c%s\0fcwd\0n%s\0\n' "$pid" "$cmd" "$cwd"
done <<< "${MOCK_LSOF_SPEC:-}"
exit "${MOCK_LSOF_RC:-0}"
```

Leave the `MOCK_LSOF_RAW` branch in place.

- [ ] **Step 2: Rewrite section V to the delegated shape.**

Keep these cases as they are: `live-cwd`, `live-deep`, `live-sib`, `live-order`, `lsof-empty`, `lsof-once`, `lsof-rc`. Their messages still hold, because wt-teardown prints `could not read the process list` to stderr.

Delete these cases; Task 1 now covers them in `wt-teardown.test.sh`: `lsof-torn`, the real-lsof `_wt_live_processes` block (`live-real`), the backslash block, the control-character block, the non-ASCII block, the real two-locale block, `lsof-literal`, `lsof-emptyname`, `lsof-relname`, `lsof-badpid`, `lsof-notcwd`. Also delete the `REALLSOF` capture, which only they used.

Replace the `no-lsof` case with:

```zsh
setup
run "$REPO" wt no-teardown
NOTD="$HOME/Code/Org/repo-no-teardown"
NOTDP=$(mkd)
for b in env git mkdir; do ln -s "$(command -v $b)" "$NOTDP/$b"; done
OUT="$(cd "$REPO" && source "$FUNCS" && export PATH="$NOTDP" && wt-rm no-teardown 2>&1)"; RC=$?
rc_is 1 "a missing wt-teardown aborts removal instead of skipping the scan"
has "could not scan for processes" "the abort says the scan could not run"
[[ -d "$NOTD" ]] && _pass "the checkout survives when processes cannot be scanned" \
                 || _fail "the checkout survives when processes cannot be scanned"
```

- [ ] **Step 3: Run the suite to see the new case fail.**

Run: `./tests/run.sh wt-functions`
Expected: FAIL on "a missing wt-teardown aborts removal…", because the old code still calls lsof directly. The kept V cases fail too, since the stub now rejects `-F0pcn`.

- [ ] **Step 4: Delegate check 4.**

In `wt-rm`, replace:

```zsh
    local busy line
    busy="$(_wt_live_processes "$dest")" || return 1
```

with:

```zsh
    local busy line
    busy="$(WT_WORKTREE="$dest" command wt-teardown scan)" || {
      print -ru2 -- "wt-rm: could not scan for processes still in $dest — refusing."
      return 1
    }
```

Delete `_wt_lsof_render` and `_wt_live_processes` and their comment blocks. In the ordering comment above `wt-rm`, change item 7 to say check 4 is `wt-teardown scan`, and drop its description of the three bounds. Those bounds now live on `_scan`, and the full argument stays in the hook-protocol and teardown-helper specs.

- [ ] **Step 5: Run the suite.**

Run: `./tests/run.sh wt-functions`
Expected: PASS; record passed/total.

- [ ] **Step 6: Commit.**

```bash
git add dot_config/zsh/functions tests/wt-functions.test.sh
git commit -m "Delegate wt-rm's process check to wt-teardown scan"
```

---

### Task 3: `wt-rm` closes only the checkout's own workspace

Tier: `sp-standard`; reviewer `sp-reviewer` with the spec §1 text in the brief. Safety-critical: read spec §1 in full first.

**Files:**
- Modify: `dot_config/zsh/functions`: replace `_wt_herdr_runtime_matches` and `_wt_stop_herdr_workspaces`; keep `_wt_stopped_herdr_has_checkout` as is.
- Test: `tests/wt-functions.test.sh` (herdr stub, `setup`, section U)

**Interfaces:**
- Produces: `_wt_herdr_read <is-default> <session>` (always addresses `--session <session>`; the first argument is kept for the call sites' symmetry), which sets globals `_WT_HWS` and `_WT_HPANES` and returns 0 (read), 3 (server not running) or 1 (unusable). It also produces `_wt_herdr_classify <dest>`, which sets global arrays `_WT_OWN` (workspace ids) and `_WT_FOREIGN` (message lines) and returns 0 or 1, and `_wt_herdr_label <id>`. `_wt_stop_herdr_workspaces <dest>` keeps its name and its 0/1 contract.

- [ ] **Step 1: Make the suite hermetic, and let the stub answer per session.**

In `setup()`, add as its first line:

```zsh
  unset HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION HERDR_ENV
```

In the herdr stub, model Herdr's routing: a bare call goes to `$HERDR_SESSION` (else the default), and `--session` overrides it. This lets a test catch a bare call that should have been explicit. Replace the stub's two session lines

```bash
session=default
[ "${1:-}" = --session ] && session="$2"
```

with

```bash
session="${HERDR_SESSION:-default}"
[ "${1:-}" = --session ] && session="$2"
```

Then make the `workspace list` and `pane list` arms prefer a team-specific answer:

```bash
  *"workspace list")
    if [ "$closed" -eq 1 ]; then
      printf '%s' '{"result":{"workspaces":[]}}'
    elif [ "$session" = team ] && [ -n "${MOCK_H_TEAM_WORKSPACES:-}" ]; then
      printf '%s' "$MOCK_H_TEAM_WORKSPACES"
    else
      printf '%s' "${MOCK_H_WORKSPACES:-}"
    fi
    exit "${MOCK_H_LIST_RC:-0}" ;;
  *"pane list")
    if [ "$closed" -eq 1 ]; then
      printf '%s' '{"result":{"panes":[]}}'
    elif [ "$session" = team ] && [ -n "${MOCK_H_TEAM_PANES:-}" ]; then
      printf '%s' "$MOCK_H_TEAM_PANES"
    else
      printf '%s' "${MOCK_H_PANES:-}"
    fi
    exit "${MOCK_H_LIST_RC:-0}" ;;
```

Add `MOCK_H_TEAM_WORKSPACES MOCK_H_TEAM_PANES` to the `unset MOCK_LSOF_RAW` line in `setup()`. Add these helpers next to `lsof_spec`:

```zsh
# session_json <name> <default> <running> — one session-list entry with a socket path.
session_json() {
  print -r -- "{\"default\":$2,\"name\":\"$1\",\"running\":$3,\"session_dir\":\"$ROOTTMP/$1\",\"socket_path\":\"$ROOTTMP/$1.sock\"}"
}
sessions() { local IFS=,; print -r -- "{\"sessions\":[$*]}" }
```

- [ ] **Step 2: Rewrite section U.**

Replace everything from `print -r -- "U. wt-rm — Herdr workspace shutdown…"` up to, but not including, the `builtin cd` static check with:

```zsh
print -r -- "U. wt-rm — Herdr workspace shutdown and persisted-state safety"

# U1: the workspace whose provenance is the checkout is closed, and removal proceeds.
setup
run "$REPO" wt herdr-close
HCLOSE="$HOME/Code/Org/repo-herdr-close"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[
  {\"workspace_id\":\"w7\",\"label\":\"herdr-close\",\"worktree\":{\"checkout_path\":\"$HCLOSE\",\"is_linked_worktree\":true}}]}}"
export MOCK_H_PANES="{\"result\":{\"panes\":[{\"workspace_id\":\"w7\",\"pane_id\":\"w7:p1\",\"cwd\":\"$HCLOSE/src\"}]}}"
run "$REPO" wt-rm herdr-close
rc_is 0 "U1 wt-rm closes the checkout's own workspace and removes it"
hlogged "workspace close w7" "U1 the workspace whose provenance is the checkout is closed"
[[ -d "$HCLOSE" ]] && _fail "U1 the checkout is removed" || _pass "U1 the checkout is removed"

# U2 (bug 1): a pane of the PRIMARY's workspace that cd'd into the checkout must not get
# the primary's workspace closed. Refuse, and close nothing at all.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && touch "$WT_MAIN/foreign-teardown-ran"
exit 0'
run "$REPO" wt foreign-pane
HFOREIGN="$HOME/Code/Org/repo-foreign-pane"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[
  {\"workspace_id\":\"w1\",\"label\":\"Org/repo\",\"worktree\":{\"checkout_path\":\"$REPO\",\"is_linked_worktree\":false}},
  {\"workspace_id\":\"w7\",\"label\":\"foreign-pane\",\"worktree\":{\"checkout_path\":\"$HFOREIGN\",\"is_linked_worktree\":true}}]}}"
export MOCK_H_PANES="{\"result\":{\"panes\":[
  {\"workspace_id\":\"w1\",\"pane_id\":\"w1:p2\",\"cwd\":\"$HFOREIGN/app\"},
  {\"workspace_id\":\"w7\",\"pane_id\":\"w7:p1\",\"cwd\":\"$HFOREIGN\"}]}}"
run "$REPO" wt-rm foreign-pane
rc_is 1 "U2 a pane of another workspace inside the checkout refuses removal"
has "w1:p2" "U2 the refusal names the pane"
has "Org/repo" "U2 the refusal names the other workspace"
hunlogged "workspace close" "U2 nothing is closed, not even the checkout's own workspace"
[[ -f "$REPO/foreign-teardown-ran" ]] && _fail "U2 teardown is skipped" || _pass "U2 teardown is skipped"
[[ -d "$HFOREIGN" ]] && _pass "U2 the checkout survives" || _fail "U2 the checkout survives"

# U3: a workspace with no provenance at all (made by hand) is never closed for a pane cwd.
setup
run "$REPO" wt plain-ws
HPLAIN="$HOME/Code/Org/repo-plain-ws"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES='{"result":{"workspaces":[{"workspace_id":"w9","label":"scratch"}]}}'
export MOCK_H_PANES="{\"result\":{\"panes\":[{\"workspace_id\":\"w9\",\"pane_id\":\"w9:p1\",\"cwd\":\"$HPLAIN/deep\"}]}}"
run "$REPO" wt-rm plain-ws
rc_is 1 "U3 a pane cwd alone never makes a workspace closable"
hunlogged "workspace close" "U3 the provenance-less workspace is not closed"

# U4: a workspace whose provenance is a nested repository inside the checkout refuses.
setup
run "$REPO" wt nested
HNEST="$HOME/Code/Org/repo-nested"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[
  {\"workspace_id\":\"w4\",\"label\":\"vendored\",\"worktree\":{\"checkout_path\":\"$HNEST/vendor/lib\",\"is_linked_worktree\":false}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
run "$REPO" wt-rm nested
rc_is 1 "U4 a nested repository's workspace refuses removal"
has "inside the checkout" "U4 the refusal says why"
hunlogged "workspace close" "U4 nothing is closed"

# U5: any named session other than $HERDR_SESSION refuses before anything is read or closed.
setup
run "$REPO" wt named
HNAMED="$HOME/Code/Org/repo-named"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)" "$(session_json team false true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HNAMED\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
run "$REPO" wt-rm named
rc_is 1 "U5 a named Herdr session refuses removal"
has "session 'team'" "U5 the refusal names the session"
hunlogged "workspace close" "U5 nothing is closed"
[[ -d "$HNAMED" ]] && _pass "U5 the checkout survives" || _fail "U5 the checkout survives"

# U6: the session named by $HERDR_SESSION is a target alongside the default.
setup
run "$REPO" wt targeted
HTGT="$HOME/Code/Org/repo-targeted"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)" "$(session_json team false true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HTGT\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
HERDR_SESSION=team run "$REPO" wt-rm targeted
rc_is 0 "U6 the HERDR_SESSION session is handled, not refused"
hlogged "--session team workspace close w7" "U6 its own workspace is closed"
hlogged "workspace close w7" "U6 the default session's own workspace is closed too"

# U7: running wt-rm from inside the workspace it would close refuses.
setup
run "$REPO" wt selfclose
HSELF="$HOME/Code/Org/repo-selfclose"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HSELF\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
HERDR_WORKSPACE_ID=w7 HERDR_SOCKET_PATH="$ROOTTMP/default.sock" run "$REPO" wt-rm selfclose
rc_is 1 "U7 wt-rm refuses to close the workspace it runs in"
has "run wt-rm from another workspace" "U7 the refusal says what to do"
hunlogged "workspace close" "U7 nothing is closed"

# U8: HERDR_SESSION does not hide the caller's own session from the self-close check.
setup
run "$REPO" wt selfclose2
HSELF2="$HOME/Code/Org/repo-selfclose2"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)" "$(session_json team false true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HSELF2\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
export MOCK_H_TEAM_WORKSPACES='{"result":{"workspaces":[]}}' MOCK_H_TEAM_PANES='{"result":{"panes":[]}}'
HERDR_SESSION=team HERDR_WORKSPACE_ID=w7 HERDR_SOCKET_PATH="$ROOTTMP/default.sock" \
  run "$REPO" wt-rm selfclose2
rc_is 1 "U8 the caller's session is found by socket, not by HERDR_SESSION"
hunlogged "workspace close" "U8 nothing is closed"

# U9: the converse — a caller in another session may close the default's workspace w7.
setup
run "$REPO" wt otherses
HOTHER="$HOME/Code/Org/repo-otherses"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)" "$(session_json team false true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HOTHER\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
export MOCK_H_TEAM_WORKSPACES='{"result":{"workspaces":[]}}' MOCK_H_TEAM_PANES='{"result":{"panes":[]}}'
HERDR_SESSION=team HERDR_WORKSPACE_ID=w7 HERDR_SOCKET_PATH="$ROOTTMP/team.sock" \
  run "$REPO" wt-rm otherses
rc_is 0 "U9 a same-numbered workspace in another session is not the caller's"
hlogged "workspace close w7" "U9 the default session's own workspace is closed"

# U10 (review focus 1): provenance reported through a symlinked path is still own.
setup
run "$REPO" wt linked-path
HLINK="$HOME/Code/Org/repo-linked-path"
ln -s "$HOME/Code" "$ROOTTMP/codelink"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$ROOTTMP/codelink/Org/repo-linked-path\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
run "$REPO" wt-rm linked-path
rc_is 0 "U10 provenance through a symlink resolves to the checkout"
hlogged "workspace close w7" "U10 the symlink-reported workspace is closed as own"

# U11 (review focus 5): HERDR_SESSION naming no listed session changes nothing.
setup
run "$REPO" wt ghost
HGHOST="$HOME/Code/Org/repo-ghost"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HGHOST\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
HERDR_SESSION=ghost run "$REPO" wt-rm ghost
rc_is 0 "U11 a HERDR_SESSION with no matching session is not a refusal"

# U19: with HERDR_SESSION naming another session, the default session is still the one
# read for the default's occupancy. A bare call there would read team and miss w1:p2.
setup
run "$REPO" wt routed
HROUTED="$HOME/Code/Org/repo-routed"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)" "$(session_json team false true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[
  {\"workspace_id\":\"w1\",\"label\":\"Org/repo\",\"worktree\":{\"checkout_path\":\"$REPO\"}}]}}"
export MOCK_H_PANES="{\"result\":{\"panes\":[{\"workspace_id\":\"w1\",\"pane_id\":\"w1:p2\",\"cwd\":\"$HROUTED\"}]}}"
export MOCK_H_TEAM_WORKSPACES='{"result":{"workspaces":[]}}' MOCK_H_TEAM_PANES='{"result":{"panes":[]}}'
HERDR_SESSION=team run "$REPO" wt-rm routed
rc_is 1 "U19 the default session is read explicitly even when HERDR_SESSION names another"
has "w1:p2" "U19 the default session's foreign pane is found"
hlogged "--session default workspace list" "U19 the default session is addressed by name"

# U12: a close failure keeps the checkout and skips teardown.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && touch "$WT_MAIN/herdr-close-teardown-ran"
exit 0'
run "$REPO" wt herdr-fail
HFAIL="$HOME/Code/Org/repo-herdr-fail"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w8\",\"worktree\":{\"checkout_path\":\"$HFAIL\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}' MOCK_H_CLOSE_RC=1
run "$REPO" wt-rm herdr-fail
rc_is 1 "U12 a failed Herdr workspace close aborts removal"
has "could not close Herdr workspace" "U12 the close failure is named"
[[ -f "$REPO/herdr-close-teardown-ran" ]] && _fail "U12 teardown is skipped" || _pass "U12 teardown is skipped"
run "$REPO" git worktree list --porcelain
has "$HFAIL" "U12 the checkout is still a registered worktree"

# U13: an exit-zero error envelope from close is a close failure.
setup
run "$REPO" wt herdr-envelope
HENVELOPE="$HOME/Code/Org/repo-herdr-envelope"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w8e\",\"worktree\":{\"checkout_path\":\"$HENVELOPE\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}' \
       MOCK_H_CLOSE_OUT='{"error":{"code":"busy","message":"not closed"}}'
run "$REPO" wt-rm herdr-envelope
rc_is 1 "U13 an exit-zero error envelope from close aborts removal"
[[ -d "$HENVELOPE" ]] && _pass "U13 the checkout survives" || _fail "U13 the checkout survives"

# U14: dirt flushed by closing the own workspace is caught by check 2.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && touch "$WT_MAIN/herdr-flush-teardown-ran"
exit 0'
run "$REPO" wt herdr-flush
HFLUSH="$HOME/Code/Org/repo-herdr-flush"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w9\",\"worktree\":{\"checkout_path\":\"$HFLUSH\"}}]}}"
export MOCK_H_PANES="{\"result\":{\"panes\":[{\"workspace_id\":\"w9\",\"pane_id\":\"w9:p1\",\"cwd\":\"$HFLUSH/deep\"}]}}"
export MOCK_H_CLOSE_TOUCH="$HFLUSH/flushed-by-herdr.txt"
run "$REPO" wt-rm herdr-flush
rc_is 1 "U14 dirt flushed by Herdr shutdown is caught"
has "closing Herdr workspaces left changes" "U14 check 2 reports the flush"
[[ -f "$REPO/herdr-flush-teardown-ran" ]] && _fail "U14 teardown does not run" || _pass "U14 teardown does not run"

# U15: a stopped default session that remembers the checkout refuses.
setup
run "$REPO" wt herdr-stopped
HSTOP="$HOME/Code/Org/repo-herdr-stopped"
mkdir -p "$ROOTTMP/default"
print -r -- "{\"version\":3,\"workspaces\":[{\"id\":\"w10\",\"tabs\":[{\"panes\":{\"1\":{\"cwd\":\"$HSTOP\"}}}]}]}" \
  > "$ROOTTMP/default/session.json"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true false)")"
run "$REPO" wt-rm herdr-stopped
rc_is 1 "U15 persisted state in the stopped default session blocks removal"
has "stopped Herdr session 'default'" "U15 the refusal identifies the session"
has "Start it with: herdr" "U15 the refusal gives the recovery command"
[[ -d "$HSTOP" ]] && _pass "U15 the checkout survives" || _fail "U15 the checkout survives"

# U16: unrelated stopped state does not block removal.
setup
run "$REPO" wt unrelated-state
UNRELATED="$HOME/Code/Org/repo-unrelated-state"
mkdir -p "$ROOTTMP/default"
print -r -- '{"version":3,"workspaces":[{"id":"w1","tabs":[{"panes":{"1":{"cwd":"/somewhere/else"}}}]}]}' \
  > "$ROOTTMP/default/session.json"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true false)")"
run "$REPO" wt-rm unrelated-state
rc_is 0 "U16 unrelated stopped Herdr state does not block removal"

# U17: invalid session discovery fails closed before anything is disrupted.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && touch "$WT_MAIN/bad-state-teardown-ran"
exit 0'
run "$REPO" wt bad-herdr-state
BADSTATE="$HOME/Code/Org/repo-bad-herdr-state"
export MOCK_H_SESSION_LIST='not-json'
run "$REPO" wt-rm bad-herdr-state
rc_is 1 "U17 invalid Herdr session discovery fails closed"
has "invalid session list" "U17 the malformed response is diagnosed"
[[ -f "$REPO/bad-state-teardown-ran" ]] && _fail "U17 teardown is skipped" || _pass "U17 teardown is skipped"

# U18: running-but-unreachable is not "stopped".
setup
run "$REPO" wt unreachable-herdr
UNREACHABLE="$HOME/Code/Org/repo-unreachable-herdr"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES='{"error":{"code":"server_not_running","message":"not reachable"}}'
run "$REPO" wt-rm unreachable-herdr
rc_is 1 "U18 a running-but-unreachable Herdr session fails closed"
has "reported running but its API is unreachable" "U18 the discrepancy is explicit"
[[ -d "$UNREACHABLE" ]] && _pass "U18 the checkout survives" || _fail "U18 the checkout survives"
```

Also update section M's `n7` fixture to the new session shape: replace its `MOCK_H_SESSION_LIST` line with `export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"`.

- [ ] **Step 3: Run the suite to see the new cases fail.**

Run: `./tests/run.sh wt-functions`
Expected: FAIL on U2, U3 (the old code closes by pane cwd), U5 (the old code closes in team), U7, U8, U10 and U19.

- [ ] **Step 4: Replace the Herdr step.**

In `dot_config/zsh/functions`, delete `_wt_herdr_runtime_matches` with its comment, and replace `_wt_stop_herdr_workspaces` with its comment. Keep `_wt_stopped_herdr_has_checkout` between them unchanged. Insert:

```zsh
# _wt_herdr_read <is-default> <session> — load one running session's workspace and pane
# lists into _WT_HWS and _WT_HPANES. 0 loaded, 3 server not running, 1 unusable answer.
_wt_herdr_read() {
  emulate -L zsh
  local session="$2" kind out rc
  # Always --session, the default included: a bare call follows HERDR_SOCKET_PATH or
  # HERDR_SESSION, which can name another session than the one being read.
  local -a hargs=(--session "$session")
  for kind in workspace pane; do
    out="$(command herdr $hargs $kind list 2>&1)"; rc=$?
    if (( rc )) || ! print -r -- "$out" | jq -e . >/dev/null 2>&1; then
      print -ru2 -- "wt-rm: Herdr session '$session' returned an invalid $kind list — refusing."
      return 1
    fi
    print -r -- "$out" | jq -e 'type == "object" and .error.code? == "server_not_running"' \
      >/dev/null 2>&1 && return 3
    if ! print -r -- "$out" | jq -e --arg k "${kind}s" \
        'type == "object" and (.result[$k] | type == "array") and (has("error") | not)' \
        >/dev/null 2>&1; then
      print -ru2 -- "wt-rm: Herdr session '$session' returned an unexpected $kind list — refusing."
      return 1
    fi
    if [[ "$kind" == workspace ]]; then typeset -g _WT_HWS="$out"; else typeset -g _WT_HPANES="$out"; fi
  done
  return 0
}

_wt_herdr_label() {
  print -r -- "$_WT_HWS" | jq -r --arg w "$1" \
    '[.result.workspaces[] | select(.workspace_id == $w) | (.label // "")][0] // ""' 2>/dev/null
}

# _wt_herdr_classify <dest> — from the loaded session, _WT_OWN is every workspace whose
# provenance is exactly <dest>; _WT_FOREIGN describes every other pane or workspace in it.
# Pane cwd follows `cd`, so it never makes a workspace own.
_wt_herdr_classify() {
  emulate -L zsh
  local dest="$1" i
  local -a recs
  typeset -ga _WT_OWN _WT_FOREIGN
  _WT_OWN=() _WT_FOREIGN=()
  recs=( ${(0)"$(print -r -- "$_WT_HWS" | jq -j '
    .result.workspaces[]
    | select((.worktree.checkout_path? | type) == "string" and (.worktree.checkout_path | length) > 0)
    | (.workspace_id | if type == "string" and length > 0 then . else error("workspace without id") end),
      "\u0000", .worktree.checkout_path, "\u0000"')"} ) || return 1
  (( ${#recs} % 2 == 0 )) || return 1
  for (( i = 1; i <= ${#recs}; i += 2 )); do
    if [[ "${recs[i+1]:A}" == "$dest" ]]; then
      _WT_OWN+=( "${recs[i]}" )
    elif [[ "${recs[i+1]:A}" == "$dest"/* ]]; then
      _WT_FOREIGN+=( "workspace ${recs[i]} '$(_wt_herdr_label "${recs[i]}")' is for ${recs[i+1]}, inside the checkout" )
    fi
  done
  recs=( ${(0)"$(print -r -- "$_WT_HPANES" | jq -j --arg d "$dest" '
    .result.panes[]
    | select((.cwd | type) == "string" and (.cwd == $d or (.cwd | startswith($d + "/"))))
    | (.workspace_id | if type == "string" and length > 0 then . else error("pane without workspace id") end),
      "\u0000", (.pane_id // "?" | tostring), "\u0000", .cwd, "\u0000"')"} ) || return 1
  (( ${#recs} % 3 == 0 )) || return 1
  for (( i = 1; i <= ${#recs}; i += 3 )); do
    (( ${_WT_OWN[(Ie)${recs[i]}]} )) && continue
    _WT_FOREIGN+=( "pane ${recs[i+1]} of workspace ${recs[i]} '$(_wt_herdr_label "${recs[i]}")' is at ${recs[i+2]}" )
  done
  return 0
}

# Close the checkout's own Herdr workspaces, after refusing if anything else is in it.
# Spec: docs/superpowers/specs/2026-10-01-herdr-wt-simplification-design.md §1.
_wt_stop_herdr_workspaces() {
  emulate -L zsh
  setopt local_options pipe_fail
  (( $+commands[herdr] )) || return 0
  (( $+commands[jq] )) || {
    print -ru2 -- "wt-rm: jq is unavailable, so Herdr workspace state cannot be verified — refusing."
    return 1
  }
  local dest="${1:A}" listing rc count i name is_default running sdir sock caller="" default_name="" state id close_out f
  local -a tname tdefault trunning tdir hargs
  local -A own
  listing="$(command herdr session list --json 2>&1)"; rc=$?
  if (( rc )) || ! print -r -- "$listing" | jq -e \
      'type == "object" and (.sessions | type == "array") and
       all(.sessions[]; (.name | type == "string" and length > 0) and
                        (.default | type == "boolean") and
                        (.running | type == "boolean") and
                        (.session_dir | type == "string" and length > 0) and
                        ((.socket_path // "") | type == "string"))' \
      >/dev/null 2>&1; then
    print -ru2 -- "wt-rm: Herdr returned an invalid session list — refusing."
    return 1
  fi
  count="$(print -r -- "$listing" | jq -r '.sessions | length')" || return 1
  for (( i = 0; i < count; i++ )); do
    name="$(print -r -- "$listing" | jq -er --argjson i "$i" '.sessions[$i].name')" || return 1
    is_default="$(print -r -- "$listing" | jq -r --argjson i "$i" '.sessions[$i].default | tostring')" || return 1
    running="$(print -r -- "$listing" | jq -r --argjson i "$i" '.sessions[$i].running | tostring')" || return 1
    sdir="$(print -r -- "$listing" | jq -er --argjson i "$i" '.sessions[$i].session_dir')" || return 1
    sock="$(print -r -- "$listing" | jq -r --argjson i "$i" '.sessions[$i].socket_path // ""')" || return 1
    if [[ "$is_default" != true && "$name" != "${HERDR_SESSION:-}" ]]; then
      print -ru2 -- "wt-rm: Herdr session '$name' exists, and wt-rm handles only the default session — refusing."
      print -ru2 -- "    Stop and delete it (herdr session delete ${(q-)name}), then retry command wt-rm."
      return 1
    fi
    [[ "$is_default" == true ]] && default_name="$name"
    [[ -n "${HERDR_SOCKET_PATH:-}" && "$sock" == "$HERDR_SOCKET_PATH" ]] && caller="$name"
    tname+=( "$name" ); tdefault+=( "$is_default" ); trunning+=( "$running" ); tdir+=( "$sdir" )
  done
  [[ -n "$caller" ]] || caller="$default_name"

  # Pass 1: every refusal is decided before anything closes.
  for (( i = 1; i <= ${#tname}; i++ )); do
    name="${tname[i]}"
    if [[ "${trunning[i]}" != true ]]; then
      _wt_stopped_herdr_has_checkout "$name" "${tdir[i]}" "$dest"; state=$?
      case "$state" in
        0)
          print -ru2 -- "wt-rm: stopped Herdr session '$name' still remembers $dest — refusing."
          if [[ "${tdefault[i]}" == true ]]; then
            print -ru2 -- "    Start it with: herdr    then retry command wt-rm."
          else
            print -ru2 -- "    Start it with: herdr session attach ${(q-)name}    then retry command wt-rm."
          fi
          return 1 ;;
        1) continue ;;
        *) return 1 ;;
      esac
    fi
    _wt_herdr_read "${tdefault[i]}" "$name"; state=$?
    if (( state == 3 )); then
      print -ru2 -- "wt-rm: Herdr session '$name' reported running but its API is unreachable — refusing."
      return 1
    fi
    (( state == 0 )) || return 1
    _wt_herdr_classify "$dest" || {
      print -ru2 -- "wt-rm: could not read Herdr workspace state in session '$name' — refusing."
      return 1
    }
    if (( ${#_WT_FOREIGN} )); then
      print -ru2 -- "wt-rm: other Herdr workspaces in session '$name' are using $dest — refusing."
      for f in $_WT_FOREIGN; do print -ru2 -- "    $f"; done
      print -ru2 -- "    cd them out of the checkout or close them, then retry command wt-rm."
      return 1
    fi
    if [[ "$name" == "$caller" && -n "${HERDR_WORKSPACE_ID:-}" ]] \
       && (( ${_WT_OWN[(Ie)$HERDR_WORKSPACE_ID]} )); then
      print -ru2 -- "wt-rm: this shell runs in Herdr workspace $HERDR_WORKSPACE_ID, which belongs to $dest — run wt-rm from another workspace."
      return 1
    fi
    own[$name]="${(j: :)_WT_OWN}"
  done

  # Pass 2: close the own workspaces, then confirm nothing is left in the checkout.
  for (( i = 1; i <= ${#tname}; i++ )); do
    [[ "${trunning[i]}" == true ]] || continue
    name="${tname[i]}"
    hargs=(--session "$name")
    for id in ${(s: :)own[$name]}; do
      close_out="$(command herdr $hargs workspace close "$id" 2>&1)"; rc=$?
      if (( rc )) \
        || { [[ -n "$close_out" ]] && ! print -r -- "$close_out" | jq -e . >/dev/null 2>&1; } \
        || { [[ -n "$close_out" ]] && print -r -- "$close_out" | jq -e \
               'type == "object" and has("error")' >/dev/null 2>&1; }; then
        print -ru2 -- "wt-rm: could not close Herdr workspace '$id' in session '$name' — refusing to remove $dest."
        return 1
      fi
    done
    _wt_herdr_read "${tdefault[i]}" "$name"; state=$?
    if (( state == 3 )); then
      print -ru2 -- "wt-rm: Herdr session '$name' became unreachable before workspace closure could be verified — refusing."
      return 1
    fi
    (( state == 0 )) || return 1
    _wt_herdr_classify "$dest" || return 1
    if (( ${#_WT_OWN} || ${#_WT_FOREIGN} )); then
      print -ru2 -- "wt-rm: Herdr session '$name' still has workspace(s) at $dest after close — refusing."
      return 1
    fi
  done
  return 0
}
```

In `wt-rm`, change the comment above the `_wt_stop_herdr_workspaces "$dest" || return 1` call to: `# Close the checkout's own Herdr workspaces; refuse first if anything else is in it (spec §1).`

- [ ] **Step 5: Run the suite.**

Run: `./tests/run.sh wt-functions`
Expected: PASS; record passed/total.

- [ ] **Step 6: Commit.**

```bash
git add dot_config/zsh/functions tests/wt-functions.test.sh
git commit -m "Close only the checkout's own Herdr workspace in wt-rm"
```

---

### Task 4: Lock worktrees at creation

Tier: `sp-mechanical`. Spec §3.

**Files:**
- Modify: `dot_config/zsh/functions` (`_wt_create_or_prepare`)
- Test: `tests/wt-functions.test.sh` (section N)

**Interfaces:**
- Consumes: `_wt_herdr_lock_reason` (unchanged name and string).

- [ ] **Step 1: Write the failing tests.**

Add a helper next to `sha()`:

```zsh
# lock_reason_of <worktree> — the lock reason git records for it, or nothing.
lock_reason_of() {
  git -C "$REPO" worktree list --porcelain | awk -v p="$1" '
    /^worktree /{ cur = substr($0, 10) }
    /^locked/   { if (cur == p) { sub(/^locked ?/, ""); print } }'
}
```

Append to section N, before `print -r -- "O. wt-rm teardown"`:

```zsh
# Locked at creation (spec §3): a failed setup never reaches dev, which used to be the
# only place the lock was applied.
setup
mkhook "$REPO" '#!/bin/sh
exit 5'
run "$REPO" wt lk1
rc_is 1 "LK1 a failed setup fails wt"
eq "$(lock_reason_of "$HOME/Code/Org/repo-lk1")" "wt-managed; remove with command wt-rm" \
  "LK1 a new branch's worktree is locked from creation"

setup
git -C "$REPO" branch lk2
mkhook "$REPO" '#!/bin/sh
exit 5'
run "$REPO" wt lk2
eq "$(lock_reason_of "$HOME/Code/Org/repo-lk2")" "wt-managed; remove with command wt-rm" \
  "LK2 an existing branch's new worktree is locked from creation"
mkhook "$REPO" '#!/bin/sh
exit 0'
run "$REPO" wt-prepare lk2
rc_is 0 "LK3 wt-prepare works on a worktree locked at creation"
run "$REPO" wt-rm lk2
rc_is 0 "LK4 wt-rm removes a worktree locked at creation"
[[ -d "$HOME/Code/Org/repo-lk2" ]] && _fail "LK4 the locked checkout is gone" \
                                   || _pass "LK4 the locked checkout is gone"
```

- [ ] **Step 2: Run the suite to see them fail.**

Run: `./tests/run.sh wt-functions`
Expected: FAIL on LK1 and LK2 (no lock).

- [ ] **Step 3: Lock at creation.**

In `_wt_create_or_prepare`, change the two `worktree add` lines to:

```zsh
        _wt_git worktree add --lock --reason "$(_wt_herdr_lock_reason)" "$dest" "$branch" || return 1
```

```zsh
        _wt_git worktree add --lock --reason "$(_wt_herdr_lock_reason)" "$dest" -b "$branch" ${start:+"$start"} || return 1
```

Replace the comment above `_wt_herdr_lock_reason` with: `# The lifecycle lock: wt applies it at creation and dev re-applies it; only wt-rm crosses it, with Git's double force, after every check. Herdr's one --force cannot.`

- [ ] **Step 4: Run the suite.**

Run: `./tests/run.sh wt-functions`
Expected: PASS; record passed/total.

- [ ] **Step 5: Commit.**

```bash
git add dot_config/zsh/functions tests/wt-functions.test.sh
git commit -m "Lock wt worktrees at creation"
```

---

### Task 5: Carry `.worktreeinclude` files with `cp`

Tier: `sp-mechanical`. Spec §8.

**Files:**
- Modify: `dot_config/zsh/functions` (`_wt_do_prepare`, the `_wt_manifest` comment)
- Modify: `dot_config/homebrew/Brewfile.tmpl` (drop `tap "satococoa/tap", trusted: true` and `brew "satococoa/tap/wtcp" …`)
- Modify: `dot_local/bin/executable_wt-rm`, `dot_local/bin/executable_wt-prepare` (comments that mention wtcp)
- Test: `tests/wt-functions.test.sh` (stubs, `setup`, sections D, M, N)

- [ ] **Step 1: Replace the wtcp tests with copy tests.**

Delete the `$STUBS/wtcp` stub and its `chmod`, `WLOG` (in `setup()`'s export and truncate lines), `MOCK_WTCP_RC`, and the header comment's mentions of wtcp.

In section D: replace the `MOCK_WTCP_RC=1 run "$REPO" wt e` case with the CP1 case below, and delete the "missing wtcp" case.

In section M:
- replace the `n3` case with CP2;
- delete the `n5` and `n6` cases, which test the presence of a tool that no longer exists;
- drop the `: > "$WLOG"` resets.

In section N's `o5` case, delete the `[[ -s "$WLOG" ]]` assertion (the `a.env` re-copy assertion already covers it) and change its `: > "$DLOG"; : > "$WLOG"` reset to `: > "$DLOG"`. The suite runs under `set -u`, so any remaining `$WLOG` aborts it. Confirm with `rg -n 'WLOG|MOCK_WTCP' tests/wt-functions.test.sh`, which must print nothing.

Add:

```zsh
# CP1: a copy that fails stops wt with the recovery message (spec §8).
setup
print -r -- "env.local" > "$REPO/.worktreeinclude"
print -r -- "secret" > "$REPO/env.local"
chmod 000 "$REPO/env.local"
run "$REPO" wt e
chmod 600 "$REPO/env.local"
rc_is 1 "CP1 a failed copy fails wt"
has "entry 'env.local'" "CP1 the failure names the entry that could not be copied"
has "wt-prepare e && wt e" "CP1 the failure prints the recovery command"
[[ -d "$HOME/Code/Org/repo-e" ]] && _pass "CP1 the worktree is left in place to recover" \
                                 || _fail "CP1 the worktree is left in place to recover"

# CP2: a failed copy aborts prepare before the setup hook.
setup
run "$REPO" wt n3
print -r -- "a.env" > "$REPO/.worktreeinclude"; print -r -- "A" > "$REPO/a.env"
mkhook "$REPO" '#!/bin/sh
touch "$WT_MAIN/setup-ran"; exit 0'
chmod 000 "$REPO/a.env"
run "$REPO" wt-prepare n3
chmod 600 "$REPO/a.env"
rc_is 1 "CP2 a failed copy fails prepare"
[[ -f "$REPO/setup-ran" ]] && _fail "CP2 setup is skipped after a copy failure" \
                           || _pass "CP2 setup is skipped after a copy failure"

# CP3 (review focus 4): modes survive, and a directory entry arrives whole.
setup
printf 'config/master.key\nsecrets.d\n' > "$REPO/.worktreeinclude"
mkdir -p "$REPO/config" "$REPO/secrets.d/inner"
print -r -- "KEY" > "$REPO/config/master.key"; chmod 600 "$REPO/config/master.key"
print -r -- "IN" > "$REPO/secrets.d/inner/x.env"; chmod 640 "$REPO/secrets.d/inner/x.env"
run "$REPO" wt cp3
rc_is 0 "CP3 a nested file and a directory entry are carried"
eq "$(stat -f %Lp "$HOME/Code/Org/repo-cp3/config/master.key")" "600" "CP3 master.key keeps mode 600"
eq "$(<"$HOME/Code/Org/repo-cp3/secrets.d/inner/x.env")" "IN" "CP3 the directory's nested file arrived"
eq "$(stat -f %Lp "$HOME/Code/Org/repo-cp3/secrets.d/inner/x.env")" "640" "CP3 nested modes survive"
```

- [ ] **Step 2: Run the suite to see CP1–CP3 fail.**

Run: `./tests/run.sh wt-functions`
Expected: FAIL on "CP1 the failure names the entry…": the old code reports the whole copy, not the entry. With the stub gone, the real `wtcp` (or its absence) runs, so the remaining CP results on the old code are incidental.

- [ ] **Step 3: Replace wtcp with cp.**

In `_wt_do_prepare`, replace the whole `if (( ${#_WT_CARRY} )); then … fi` block (the wtcp presence check, the `MISE_NO_ENV` comment and the `wtcp` call) with:

```zsh
  local entry
  for entry in $_WT_CARRY; do
    if ! { mkdir -p -- "$dest/${entry:h}" && cp -pR -- "$main/$entry" "$dest/$entry" }; then
      print -ru2 -- "wt: copying .worktreeinclude entry '$entry' into $dest failed."
      print -ru2 -- "    The worktree exists — fix the copy, then: wt-prepare $qb && wt $qb"
      return 1
    fi
  done
```

In `_wt_manifest`'s comment, replace the paragraph starting `Filtering is required for correctness` with: `Entries already present at the destination are skipped, never overwritten: a local edit in the worktree wins.`

Remove these two lines from `dot_config/homebrew/Brewfile.tmpl`:

```
tap "satococoa/tap", trusted: true
brew "satococoa/tap/wtcp"              # carries gitignored env files into new git worktrees (the wt() function in zsh/functions)
```

In `executable_wt-rm`, change `# wtcp or herdr on PATH — which wt-rm needs to close Herdr workspaces before it can` to `# herdr on PATH — which wt-rm needs to close Herdr workspaces before it can`.

In `executable_wt-prepare`, change the first comment line of the zshenv paragraph to `# zshenv is not optional: without it a bare zsh has no XDG variables and no`, and the next line to `# Homebrew on PATH. Only the XDG base`. Keep the rest of that comment.

- [ ] **Step 4: Run the suite.**

Run: `./tests/run.sh wt-functions`
Expected: PASS; record passed/total.

- [ ] **Step 5: Check that no live reference to wtcp remains.**

Run: `rg -n 'wtcp|satococoa' dot_config dot_local dot_claude tests .scripts README.md`
Expected: no output. The section L comment "(through wtcp)" in `wt-functions.test.sh` is one such reference: reword it to "(through the copy)".

- [ ] **Step 6: Commit.**

```bash
git add dot_config/zsh/functions dot_config/homebrew/Brewfile.tmpl dot_local/bin/executable_wt-rm dot_local/bin/executable_wt-prepare tests/wt-functions.test.sh
git commit -m "Carry .worktreeinclude files with cp instead of wtcp"
```

---

### Task 6: The worktree guard adds the lock-crossing shapes

Tier: `sp-standard`. Spec §4.

**Files:**
- Modify: `dot_claude/executable_worktree-guard.sh` (rewrite)
- Modify: `dot_claude/modify_private_settings.json` (the two-line "Second entry" comment)
- Test: `tests/worktree-guard.test.sh`

- [ ] **Step 1: Update and extend the tests.**

In `tests/worktree-guard.test.sh`:
- Retitle `echo "== the one denied shape: literal absolute wt sibling =="` to `echo "== rule 3: literal absolute wt sibling =="`.
- Flip two cases from allow to deny, because chained segments are now checked:

```bash
expect deny  "preceding command"            "$TMP" "cd /tmp && git worktree remove $SIB"
expect deny  "removal in a second clause"   "$TMP" "git worktree remove $TMP/nope; git worktree remove \"$SIB\""
```

- Replace their comment with `# Every command segment is checked (spec §4); a chained removal is caught.`
- Insert before `echo "== bypass switch, any position =="`:

```bash
echo "== rules 1 and 2: crossing the lifecycle lock, any target =="
expect deny  "unlock"                       "$TMP" 'git worktree unlock ../anything'
expect deny  "unlock under -C"              "$TMP" "git -C $REPO worktree unlock repo-topic"
expect deny  "unlock after sudo"            "$TMP" 'sudo git worktree unlock x'
expect deny  "unlock after env prefix"      "$TMP" 'GIT_TRACE=1 git worktree unlock x'
expect deny  "unlock chained"               "$TMP" 'git status && git worktree unlock x'
expect deny  "unlock on the second line"    "$TMP" 'git status
git worktree unlock x'
expect deny  "remove -f -f"                 "$TMP" 'git worktree remove -f -f ../anything'
expect deny  "remove -ff"                   "$TMP" 'git worktree remove -ff ../anything'
expect deny  "remove --force --force"       "$TMP" 'git worktree remove --force --force rel'
expect deny  "remove -f --force"            "$TMP" "git -C $REPO worktree remove -f --force rel"
expect_reason_contains "lock-crossing deny names the remedy" \
  "$TMP" 'git worktree unlock x' "command wt-rm <branch>"
expect allow "single force, not a sibling"  "$TMP" "git worktree remove --force $REPO/.claude/worktrees/scratch"
expect allow "lock"                         "$TMP" 'git worktree lock x'
expect allow "add"                          "$TMP" 'git worktree add ../x'

echo "== text that only spells the command =="
expect allow "quoted unlock"                "$TMP" 'echo "git worktree unlock x"'
expect allow "bash -c quoted (documented)"  "$TMP" 'bash -c "git worktree unlock x"'
expect allow "comment after a command"      "$TMP" 'git status # ; git worktree unlock x'
expect allow "heredoc body line"            "$TMP" "cat <<'EOF'
git worktree unlock x
git worktree remove -ff y
EOF"
expect allow "heredoc with dash"           "$TMP" $'cat <<-EOF\n\tgit worktree unlock x\n\tEOF'
expect deny  "unlock after a here-string"   "$TMP" $'cat <<< hello\ngit worktree unlock x'
expect deny  "unlock across a continuation" "$TMP" $'git worktree \\\nunlock x'
expect deny  "-f -f across a continuation"  "$TMP" $'git worktree remove -f \\\n  -f ../x'
expect deny  "a command after the heredoc"  "$TMP" "cat <<EOF
text
EOF
git worktree unlock x"
```

- Insert before `echo "== degenerate input fails open =="`:

```bash
echo "== jq absent fails open =="
out=$(jq -n --arg c 'git worktree unlock x' '{tool_input:{command:$c}}' \
      | env PATH=/bin /bin/bash "$GUARD" 2>/dev/null)
if [ -z "$out" ]; then pass=$((pass + 1)); echo '  ok   no jq allows'
else fail=$((fail + 1)); echo '  FAIL no jq allows'; fi
```

- [ ] **Step 2: Run the suite to see the new cases fail.**

Run: `./tests/run.sh worktree-guard`
Expected: FAIL on every rules 1/2 deny (including the here-string and continuation cases), on the two flipped chained cases and on "a command after the heredoc".

- [ ] **Step 3: Rewrite the guard.**

Replace `dot_claude/executable_worktree-guard.sh` with:

```bash
#!/usr/bin/env bash
# PreToolUse(Bash) guard: wt worktrees are retired with `command wt-rm`, never raw git.
# Denies, in any command segment:
#   1. git worktree unlock                      (crosses the lifecycle lock)
#   2. git worktree remove with two or more forces (crosses it too)
#   3. git worktree remove of a literal absolute wt sibling (covers a hand-unlocked one)
# A correctness catch, not a security boundary: the Git lock is the boundary.
# Every internal failure allows. Bypass: WT_GUARD=off anywhere in the command.
# Bash 3.2 compatible. Tests: tests/worktree-guard.test.sh
# Spec: docs/superpowers/specs/2026-10-01-herdr-wt-simplification-design.md §4
set -uo pipefail
set -f

allow() { exit 0; }
deny() {
  printf '%s' "$1" | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}' \
    2>/dev/null || exit 0
  exit 0
}

payload=$(cat)
case "$payload" in *worktree*) ;; *) allow ;; esac
command -v jq >/dev/null 2>&1 || allow
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || allow
[ -n "$cmd" ] && [ "$cmd" != null ] || allow
case "$cmd" in *WT_GUARD=off*) allow ;; esac

REMEDY="Retire a wt worktree with:

    command wt-rm <branch>

(\`command\` matters: it reaches the PATH wrapper, which loads the full lifecycle in a
non-interactive shell.) A worktree owned by another tool goes through that tool's own
lifecycle. For a deliberate manual reconciliation, re-run with WT_GUARD=off."

NL=$'\n'; TAB=$'\t'
prefix_re='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(sudo[[:space:]]+)?git([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]-][^[:space:]]*)?)*[[:space:]]+worktree[[:space:]]+'

# sibling_of <abs-target> — print "<repo-dir> <slug>" when the target is a wt sibling.
sibling_of() {
  local target=$1 parent base acc="" rest seg
  [ -d "$target" ] || return 1
  parent=$(dirname "$target"); base=$(basename "$target"); rest=$base
  while [ "${rest#*-}" != "$rest" ]; do
    seg=${rest%%-*}
    if [ -n "$acc" ]; then acc="$acc-$seg"; else acc=$seg; fi
    rest=${rest#*-}
    if [ -d "$parent/$acc" ] && [ -e "$parent/$acc/.git" ]; then
      printf '%s %s\n' "$parent/$acc" "${base#"$acc"-}"
      return 0
    fi
  done
  return 1
}

# target_of <args> — the literal absolute target, quote-aware, or nothing.
target_of() {
  local tok rest after target="" quoted=""
  for tok in $1; do
    case "$tok" in -*) continue ;; esac
    case "$tok" in
      \"*|\'*)
        q=${tok:0:1}; rest=${tok#?}
        case "$rest" in
          *"$q"*) target=${rest%%"$q"*}; after=${rest#*"$q"}
                  case "$after" in ""|[\;\&\|\)\<\>]*) quoted=1 ;; *) return 0 ;; esac ;;
          *) return 0 ;;
        esac ;;
      *) target=$tok ;;
    esac
    break
  done
  case "$target" in /*) ;; *) return 0 ;; esac
  [ -z "$quoted" ] && target=${target%%[;&|)<>]*}
  printf '%s\n' "${target%/}"
}

check() {
  local seg=$1 sub args force=0 tok f target sib
  seg=${seg%%"$NL"*}   # a quoted string may span lines; only its first line can be a command
  printf '%s' "$seg" | grep -Eq "${prefix_re}(remove|unlock)([[:space:]]|\$)" || return 0
  sub=$(printf '%s' "$seg" | sed -E "s#${prefix_re}##")
  case "$sub" in
    unlock*) deny "\`git worktree unlock\` crosses the wt lifecycle lock.

$REMEDY" ;;
  esac
  args=${sub#remove}
  for tok in $args; do
    case "$tok" in
      --force) force=$((force + 1)) ;;
      --*) ;;
      -*) f=${tok//[!f]/}; force=$((force + ${#f})) ;;
    esac
  done
  [ "$force" -ge 2 ] && deny "\`git worktree remove\` forced twice crosses the wt lifecycle lock.

$REMEDY"
  target=$(target_of "$args")
  [ -n "$target" ] || return 0
  sib=$(sibling_of "$target") || return 0
  deny "Raw \`git worktree remove\` on a wt-managed worktree.

$target is the wt sibling of the repository at ${sib%% *}. Raw removal skips Herdr
workspace closure and the project teardown hook, and live processes write the path back.
The directory slug is \"${sib#* }\"; a slug maps '/' to '-', so use the branch name.

$REMEDY"
}

# Quote-aware split into command segments. Quoted text, comments and heredoc bodies
# never start a segment.
seg="" quote="" pending="" body="" cont=""
while IFS= read -r line || [ -n "$line" ]; do
  if [ -n "$body" ]; then
    t=$line
    while [ "${t#"$TAB"}" != "$t" ]; do t=${t#"$TAB"}; done
    [ "$t" = "$body" ] && body=""
    continue
  fi
  i=0; n=${#line}
  while [ "$i" -lt "$n" ]; do
    c=${line:$i:1}
    if [ -n "$quote" ]; then
      seg="$seg$c"
      if [ "$c" = "$quote" ]; then quote=""
      elif [ "$c" = '\' ] && [ "$quote" = '"' ]; then i=$((i + 1)); seg="$seg${line:$i:1}"; fi
      i=$((i + 1)); continue
    fi
    case "$c" in
      \'|\") quote=$c; seg="$seg$c" ;;
      \\)
        if [ $((i + 1)) -ge "$n" ]; then cont=1   # backslash-newline joins the next line
        else i=$((i + 1)); seg="$seg$c${line:$i:1}"; fi ;;
      \#) case "$seg" in ''|*[[:space:]]) break ;; *) seg="$seg$c" ;; esac ;;
      \;|\||\&|\(|\)) check "$seg"; seg="" ;;
      \<)
        if [ "${line:$((i + 1)):2}" = '<<' ]; then
          seg="$seg<<<"; i=$((i + 2))            # a here-string, never a heredoc
        elif [ "${line:$((i + 1)):1}" = '<' ]; then
          rest=${line:$((i + 2))}; rest=${rest#-}
          rest=${rest#"${rest%%[![:space:]]*}"}
          d=${rest%%[[:space:];|&<>()]*}; d=${d//\'/}; d=${d//\"/}; d=${d//\\/}
          [ -n "$d" ] && pending=$d
          seg="$seg<<"; i=$((i + 1))
        else
          seg="$seg$c"
        fi ;;
      *) seg="$seg$c" ;;
    esac
    i=$((i + 1))
  done
  if [ -n "$quote" ]; then
    seg="$seg
"
  elif [ -n "$cont" ]; then
    cont=""
  else
    check "$seg"; seg=""
    if [ -n "$pending" ]; then body=$pending; pending=""; fi
  fi
done <<EOF
$cmd
EOF
check "$seg"
allow
```

- [ ] **Step 4: Run the suite.**

Run: `./tests/run.sh worktree-guard`
Expected: PASS, every case old and new; record passed/total. If "quoted pipe slug + semicolon" fails, check the quote branch in the scanner before touching `target_of`.

- [ ] **Step 5: Update the settings comment.**

In `dot_claude/modify_private_settings.json`, replace:

```
        # Second entry: the worktree guard. Denies raw `git worktree remove` on a wt
        # sibling worktree, which skips Herdr workspace closure and leaves husk directories.
```

with:

```
        # Second entry: the worktree guard. Denies `git worktree unlock`, a double-forced
        # `git worktree remove`, and raw removal of a wt sibling: wt-rm owns that lifecycle.
```

Run: `./tests/run.sh claude-settings`
Expected: PASS; record passed/total.

- [ ] **Step 6: Commit.**

```bash
git add dot_claude/executable_worktree-guard.sh dot_claude/modify_private_settings.json tests/worktree-guard.test.sh
git commit -m "Deny lock-crossing worktree commands in every command segment"
```

---

### Task 7: `layout.sh`: focus first, add missing tabs; delete the plugin

Tier: `sp-standard`. Spec §5 (path mode, build, worktree mode), §6.

**Files:**
- Modify: `dot_config/herdr/executable_layout.sh`
- Delete: `dot_config/herdr/plugin/herdr-plugin.toml` (the whole directory)
- Modify: `.chezmoiremove` (append the plugin tombstone)
- Modify: `dot_config/zsh/functions` (the `dev` comment naming the plugin)
- Test: `tests/dev.test.sh` (sections D, E, F0, F1, G, H, K, L)

**Interfaces:**
- Produces in `layout.sh`: `hl_find_workspace <repo>` (prints an id or nothing; 1 on API failure), `hl_ensure_eager_tabs <ws> <repo>`, `hl_agents_split <pane> <repo>`, `hl_fill_new <ws> <root-tab> <root-pane> <repo>`.

- [ ] **Step 1: Rewrite the tests.**

In `tests/dev.test.sh`:
- Delete section E (the `cls` helper and E1–E6), section H (H1–H5) and section K (K1–K10), together with their headers. Add `print -r -- "-- E: an existing workspace is never refused"` with the cases below in E's place.
- Delete F1c (it used `cls`).
- Update the header comment's section list: E is now "existing workspaces: focus, add missing tabs"; G is build; drop "repair" and "--current".

Replace D5 with:

```zsh
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
```

Append to section D:

```zsh
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
```

New section E:

```zsh
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
```

Append to section L, before `# --- M:`:

```zsh
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
```

In section G:
- G1: expect `workspace create --cwd $R1 --label Netronix/curato --no-focus`, with no `(building)`.
- G5: delete the "renamed to the final label" assertion, and change the ordering check to `[[ "$(<$HLOG)" == *"workspace focus w7"*"tab focus w7:t4"* ]]` with label "G5 focus precedes the agents-tab focus".
- G6: keep `unlogged "workspace rename"`, relabelled "G6 a build never renames".

- [ ] **Step 2: Run the suite to see the new cases fail.**

Run: `./tests/run.sh dev`
Expected: FAIL on D5, D8, E1–E6 and L6 (which die as malformed) and G1 (which uses the building label).

- [ ] **Step 3: Rewrite the path-mode machinery in `layout.sh`.**

Delete:
- `BUILDING_SUFFIX`;
- `hl_notify`, `hl_die_notify` and `HL_DIE`, with their comments;
- `hl_classify`, `hl_reconcile` and `hl_repair`;
- the `--current` branch of `main`, and `--current` in the header usage and in the `${1:?…}` usage string;
- in `main`'s `make-tab` branch, the `HL_DIE=die` line and the comment that mentions it;
- in `hl_context_repo`, replace every `"$HL_DIE"` call with `die` (Task 8 rewrites that function; until then it must not reference the deleted variable).

Then add or replace:

```zsh
# hl_find_workspace <repo> — the workspace for this checkout, or nothing. Identity is
# Herdr's provenance (worktree.checkout_path), which does not follow `cd`. A workspace
# that predates provenance is matched by a pane at the repo root, and only one carrying
# no provenance at all can be matched that way. Several candidates: the first, with a warning.
hl_find_workspace() {
  local repo="$1" list panes matched i
  local -a recs ids
  # stderr: this function's stdout is its return value.
  [[ -n "${HL_TRACE_LOCK:-}" ]] && print -ru2 -- "SCAN"
  [[ -n "${HL_SCAN_DELAY:-}" ]] && sleep "$HL_SCAN_DELAY"
  list="$(hl_api_json workspace list)" || return 1
  recs=( ${(0)"$(print -r -- "$list" | jq -j '
    .result.workspaces[]
    | select((.worktree.checkout_path? | type) == "string" and (.worktree.checkout_path | length) > 0)
    | .workspace_id, "\u0000", .worktree.checkout_path, "\u0000"')"} ) \
    || { print -ru2 -- "layout.sh: could not read workspace provenance"; return 1 }
  for (( i = 1; i < ${#recs}; i += 2 )); do
    [[ "${recs[i+1]:A}" == "$repo" ]] && ids+=( "${recs[i]}" )
  done
  if (( ${#ids} == 0 )); then
    panes="$(hl_api_json pane list)" || return 1
    matched="$(print -r -- "$panes" | jq -r --arg d "$repo" --argjson ws "$list" '
      ([$ws.result.workspaces[] | select(.worktree == null) | .workspace_id]) as $bare
      | .result.panes[] | select(.cwd == $d) | .workspace_id
      | select(. as $w | $bare | index($w))' | awk '!seen[$0]++')" \
      || { print -ru2 -- "layout.sh: could not read workspace ids from pane list"; return 1 }
    ids=( ${(f)matched} )
    ids=( ${ids:#} )
  fi
  (( ${#ids} == 0 )) && return 0
  (( ${#ids} > 1 )) && print -ru2 -- "layout.sh: ${#ids} workspaces for $repo (${ids[*]}) — using ${ids[1]}"
  print -r -- "${ids[1]}"
}

# hl_ensure_eager_tabs <ws> <repo> — create each EAGER tab no tab carries the label of.
# Shapes, pane counts, duplicates and the workspace label are the user's business.
hl_ensure_eager_tabs() {
  local ws="$1" repo="$2" tabs label n
  tabs="$(hl_api_json tab list --workspace "$ws")" || return 1
  for label in $EAGER_TABS; do
    n=$(print -r -- "$tabs" | jq -r --arg l "$label" '[.result.tabs[] | select(.label == $l)] | length') \
      || return 1
    (( n > 0 )) && continue
    hl_make_tab "$ws" "$label" "$repo" >/dev/null || return 1
  done
}

# hl_agents_split <pane> <repo> — claude in <pane>, the Codex pane command in a split to
# its right. `pane run`, not `agent start`, which blocks until the agent reports ready.
hl_agents_split() {
  local pane="$1" repo="$2" out right
  out="$(hl_api_json pane split --pane "$pane" --direction right --cwd "$repo" --no-focus)" || return 1
  right="$(hl_id "$out" '.result.pane.pane_id' "the agents split pane")" || return 1
  hl_api pane run "$pane" "claude" >/dev/null || return 1
  hl_api pane run "$right" "$CODEX_CMD" >/dev/null || return 1
}

# hl_fill_new <ws> <root-tab> <root-pane> <repo> — the eager baseline in a workspace
# created a moment ago: its root tab becomes agents, the other eager tabs are appended.
hl_fill_new() {
  local ws="$1" tab="$2" pane="$3" repo="$4" l
  hl_api tab rename "$tab" agents >/dev/null || return 1
  hl_agents_split "$pane" "$repo" || return 1
  for l in $EAGER_TABS; do
    [[ "$l" == agents ]] && continue
    hl_make_tab "$ws" "$l" "$repo" >/dev/null || return 1
  done
}

hl_build() {
  local repo="$1" out ws tab pane
  out="$(hl_api_json workspace create --cwd "$repo" --label "$(hl_label "$repo")" --no-focus)" || return 1
  # Arm the close trap the moment a workspace id exists, before parsing anything else.
  ws="$(hl_id "$out" '.result.workspace.workspace_id' "a workspace id")" || return 1
  trap "$HL_HERDR_Q workspace close ${(q)ws} >/dev/null 2>&1" EXIT INT TERM
  tab="$(hl_id "$out" '.result.tab.tab_id' "a first tab id")" || return 1
  pane="$(hl_id "$out" '.result.root_pane.pane_id' "a root pane id")" || return 1
  hl_fill_new "$ws" "$tab" "$pane" "$repo" || return 1
  trap - EXIT INT TERM
  hl_api workspace focus "$ws" >/dev/null || return 1
  hl_api tab focus "$tab" >/dev/null || return 1
}
```

In `hl_populate_tab`, replace the `agents)` arm with `agents) hl_agents_split "$pane" "$repo" || return 1 ;;`.

In `main`, the path-mode block becomes:

```zsh
  if [[ "$mode" == path ]]; then
    hl_lock "$repo" || exit 1
    local ws; ws="$(hl_find_workspace "$repo")" || exit 1
    if [[ -n "$ws" ]]; then
      hl_ensure_eager_tabs "$ws" "$repo" || exit 1
      hl_api workspace focus "$ws" >/dev/null || exit 1
    else
      hl_build "$repo" || exit 1
    fi
  fi
```

`hl_open_worktree` keeps everything up to and including `[[ "$linked" == true ]] || die …`. Replace everything after that (the `verdict=…` line and its `case` block) with the following, drop `verdict managed tabs` from its `local` line, and delete `hl_adopt_worktree`:

```zsh
  if [[ "$already" == false ]]; then
    trap "$HL_HERDR_Q workspace close ${(q)ws} >/dev/null 2>&1" EXIT INT TERM
    hl_fill_new "$ws" "$tab" "$pane" "$repo" || return 1
    trap - EXIT INT TERM
    hl_api workspace focus "$ws" >/dev/null || return 1
    hl_api tab focus "$tab" >/dev/null || return 1
  else
    hl_ensure_eager_tabs "$ws" "$repo" || return 1
    hl_api workspace focus "$ws" >/dev/null || return 1
  fi
```

- [ ] **Step 4: Delete the plugin, and add the tombstone.**

```bash
git rm -r dot_config/herdr/plugin
```

Append to `.chezmoiremove`:

```
# The dev.layout plugin, retired 2026-10-01: `dev .` does what its action did. Its Herdr
# registration is separate: `herdr plugin unlink dev.layout` once after apply.
.config/herdr/plugin
```

In `dot_config/zsh/functions`, replace the `dev` comment lines `# Resolution only. Everything about Herdr lives in layout.sh, which is also what the` and `# \`dev.layout.apply\` plugin action calls — one topology definition, two entry points.` with `# Resolution only. Everything about Herdr lives in layout.sh.`

- [ ] **Step 5: Run the suites.**

Run: `./tests/run.sh dev`, then `./tests/run.sh wt-functions`.
Expected: both PASS; record passed/total.

- [ ] **Step 6: Commit.**

```bash
git add dot_config/herdr/executable_layout.sh .chezmoiremove dot_config/zsh/functions tests/dev.test.sh
git commit -m "Focus existing workspaces and add missing tabs instead of classifying them"
```

---

### Task 8: `--make-tab` resolves its repo from provenance

Tier: `sp-mechanical`. Spec §5 (`--make-tab`).

**Files:**
- Modify: `dot_config/herdr/executable_layout.sh` (`hl_context_repo`; delete `hl_is_native_worktree_workspace`)
- Test: `tests/dev.test.sh` (section N)

- [ ] **Step 1: Write the tests.**

In section N, replace N7 with:

```zsh
# A linked checkout without provenance still gets its tab: its repo is the pane's toplevel.
mk "mock_topology '$WT' 'curato-feature' $FULL" --make-tab editor
rc_is 0 "N7 a linked checkout without provenance gets its editor tab"
logged "tab create --workspace w7 --label editor --cwd $WT --no-focus" \
  "N7 created in the pane's own checkout"
```

Add after N7b:

```zsh
# Provenance outranks the first pane's cwd.
mk "mock_topology '$R1' 'curato-feature' $FULL
  export MOCK_WS_LIST='{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"label\":\"curato-feature\",\"worktree\":{\"checkout_path\":\"$WT\",\"is_linked_worktree\":true}}]}}'" \
  --make-tab editor
logged "tab create --workspace w7 --label editor --cwd $WT --no-focus" \
  "N7c the workspace's provenance decides the repo, not where its first pane stands"
```

- [ ] **Step 2: Run the suite to see them fail.**

Run: `./tests/run.sh dev`
Expected: FAIL on N7 and N7c (the native-workspace guard refuses, and the first pane's cwd decides the repo).

- [ ] **Step 3: Implement.**

Replace `hl_context_repo` with the version below, and delete `hl_is_native_worktree_workspace`:

```zsh
# hl_context_repo <ws> — the checkout a workspace belongs to, into HL_CONTEXT_REPO: its
# Herdr provenance, else its first pane's git toplevel. A global, not stdout, because
# `die` inside a command substitution would kill only the subshell.
hl_context_repo() {
  local ws="$1" list cpath cwd root
  list="$(hl_api_json workspace list)" || die "could not read the workspace list"
  cpath="$(print -r -- "$list" | jq -r --arg w "$ws" '
    [.result.workspaces[] | select(.workspace_id == $w) | .worktree.checkout_path
     | select(type == "string" and length > 0)][0] // ""')" || die "could not read workspace $ws"
  if [[ -n "$cpath" ]]; then
    typeset -g HL_CONTEXT_REPO="${cpath:A}"
    return 0
  fi
  cwd="$(hl_api_json pane list --workspace "$ws" | jq -r '.result.panes[0].cwd')" \
    || die "could not read the workspace's panes"
  [[ -n "$cwd" && "$cwd" != null ]] || die "workspace $ws has no pane cwd to work from"
  root="$(hl_git -C "${cwd:A}" rev-parse --show-toplevel 2>/dev/null)" \
    || die "${cwd:A} is not inside a git repository — refusing"
  [[ -n "$root" ]] || die "${cwd:A} is not inside a git repository — refusing"
  typeset -g HL_CONTEXT_REPO="${root:A}"
}
```

- [ ] **Step 4: Run the suites.**

Run: `./tests/run.sh dev`, then `./tests/run.sh wt-functions`.
Expected: both PASS; record passed/total.

- [ ] **Step 5: Check that no deleted name survives.**

Run: `rg -n 'hl_classify|hl_reconcile|hl_repair|hl_adopt_worktree|hl_is_native|hl_notify|HL_DIE|BUILDING_SUFFIX|--current' dot_config tests/dev.test.sh`
Expected: no output.

- [ ] **Step 6: Commit.**

```bash
git add dot_config/herdr/executable_layout.sh tests/dev.test.sh
git commit -m "Resolve the lazy tab's repo from workspace provenance"
```

---

### Task 9: `phase.sh` drops pins

Tier: `sp-mechanical`. Spec §7.

**Files:**
- Modify: `dot_config/herdr/executable_phase.sh`, `dot_config/herdr/plugin-phase/herdr-plugin.toml`, `dot_config/herdr/config.toml`
- Test: `tests/herdr-phase.test.sh`

- [ ] **Step 1: Update the tests.**

In `tests/herdr-phase.test.sh`:
- Delete `ICON_FLAG`, and all of section E ("a pin overrides what git says").
- In A, replace the `--help documents pin` case with `case "$OUT" in *pin*) _fail "--help no longer offers pin";; *) _pass "--help no longer offers pin";; esac`.
- In C, change `-eq 4` to `-eq 3` and the label to "each report accounts for all three phase tokens".
- In I, change both `for tok in active review merged parked` loops to `for tok in active review merged`, and add:

```bash
  grep -q 'parked' "$CONF" && _fail "the sidebar no longer renders \$parked" \
                           || _pass "the sidebar no longer renders \$parked"
  grep -Eq 'pin-parked|"unpin"' "$MANIFEST" && _fail "the plugin no longer offers pin actions" \
                                            || _pass "the plugin no longer offers pin actions"
```

Also add a usage case: `run pin --workspace w2 parked; [ "$RC" -ne 0 ] && _pass "pin is gone" || _fail "pin is gone"`.

- [ ] **Step 2: Run the suite to see them fail.**

Run: `./tests/run.sh herdr-phase`
Expected: FAIL in A, C and I, and on "pin is gone".

- [ ] **Step 3: Implement.**

In `executable_phase.sh`:
- delete `ICON_FLAG`, `pin_file`, the pin block at the top of `derive`, `path_of`, `cmd_pin`, `cmd_unpin`, and the `pin)` and `unpin)` dispatch arms;
- change `report`'s loop to `for t in active review merged; do`;
- reduce the usage text to `phase.sh refresh [--force] [--workspace ID]` and `phase.sh --help`, with `Phases: active, review, merged.`;
- drop `STATE_DIR` and the `HERDR_PHASE_STATE_DIR` line if nothing else uses them (check with `rg -n STATE_DIR`);
- in `derive`'s comment, change "a pin wins outright, then" to "whether work is still local comes first, then".

In `plugin-phase/herdr-plugin.toml`, delete the two `[[actions]]` blocks (`pin-parked`, `unpin`). In `config.toml`, delete the row entry `{ token = "$parked", fg = "#bb9af7" },` and change the comment `Four tokens` to `Three tokens`.

If `herdr-phase.test.sh` passes `HERDR_PHASE_STATE_DIR` in `run()`, leave it; an unused variable is harmless. Delete it only if `STATE_DIR` was removed.

- [ ] **Step 4: Run the suite.**

Run: `./tests/run.sh herdr-phase`
Expected: PASS; record passed/total.

- [ ] **Step 5: Commit.**

```bash
git add dot_config/herdr/executable_phase.sh dot_config/herdr/plugin-phase/herdr-plugin.toml dot_config/herdr/config.toml tests/herdr-phase.test.sh
git commit -m "Drop the unused phase pins"
```

---

### Task 10: `dev-topology` tests the source

Tier: `sp-standard`. Spec §9, §11 (lock-file tombstones). It needs live herdr and runs unsandboxed. If a sandboxed run fails with a socket denial, re-run with the sandbox disabled; never disable the sandbox for any other suite.

**Files:**
- Modify: `tests/dev-topology.test.sh`
- Modify: `.chezmoiremove`

- [ ] **Step 1: Point the gate at the source.**

After the `h()` definition, add:

```zsh
ROOT="${0:A:h:h}"
SRC_LAYOUT="$ROOT/dot_config/herdr/executable_layout.sh"
SRC_TABGOTO="$ROOT/dot_config/herdr/executable_tab-goto.sh"
SRC_FUNCS="$ROOT/dot_config/zsh/functions"
SRC_TEARDOWN="$ROOT/dot_local/bin/executable_wt-teardown"
for f in "$SRC_LAYOUT" "$SRC_TABGOTO" "$SRC_FUNCS" "$SRC_TEARDOWN"; do
  [[ -r "$f" ]] || { print -ru2 -- "dev-topology: missing $f"; exit 2 }
done
STATE_BEFORE=$(ls ~/.local/state/herdr-layout 2>/dev/null | wc -l | tr -d ' ')
```

After `SCRATCH=…` and before the first layout call, add:

```zsh
mkdir -p "$SCRATCH/bin" "$SCRATCH/state" || exit 1
print -r -- "#!/bin/sh
exec zsh '$SRC_LAYOUT' \"\$@\"" > "$SCRATCH/bin/layout.sh"
print -r -- "#!/bin/sh
exec zsh '$SRC_TEARDOWN' \"\$@\"" > "$SCRATCH/bin/wt-teardown"
chmod +x "$SCRATCH/bin/layout.sh" "$SCRATCH/bin/wt-teardown"
export PATH="$SCRATCH/bin:$PATH" DEV_LAYOUT="$SCRATCH/bin/layout.sh" XDG_STATE_HOME="$SCRATCH/state"
```

Then make these replacements throughout:
- `~/.config/herdr/layout.sh` → `"$DEV_LAYOUT"`;
- `source ~/.config/zsh/functions` → `source "$SRC_FUNCS"`;
- `~/.config/herdr/tab-goto.sh runtime` → `zsh "$SRC_TABGOTO" runtime`;
- `( cd "$PRIMARY" && command wt-rm live-wt )` → `( cd "$PRIMARY" && source "$SRC_FUNCS" && HERDR_SESSION="$SESSION" wt-rm live-wt )`.

- [ ] **Step 2: Replace the plugin section with live repair and manual-split checks.**

Delete:
- `PLUGIN_ID`, `plugin_linked`, and the plugin-unlink line in `cleanup()`;
- section 7 from `PDIR=` through the "the plugin action repairs a closed managed tab" assertion;
- the plugin-unlink verification block before the schema check.

Keep 7a (smart-splits) and 7b (the label jump). Insert before 7a:

```zsh
# 7. dev re-adds a closed eager tab (what the retired plugin action did), and a manual
#    split never stops dev from focusing (bug 2).
close_rc=0
h tab close "$(h tab list --workspace "$WS" | jq -r '.result.tabs[] | select(.label=="runtime") | .tab_id')" >/dev/null \
  || close_rc=$?
readd_rc=0
HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 "$DEV_LAYOUT" "$REPO" >/dev/null 2>&1 || readd_rc=$?
n=$(h tab list --workspace "$WS" | jq -r '[.result.tabs[] | select(.label=="runtime")] | length')
[[ "$close_rc" == 0 && "$readd_rc" == 0 && "$n" == 1 ]] \
  && ok "dev re-adds a closed runtime tab" \
  || bad "re-add rc=$close_rc/$readd_rc, runtime tabs=$n"
h pane split --pane "$(h pane list --workspace "$WS" | jq -r --arg t "$AT" \
  '[.result.panes[] | select(.tab_id==$t)][0].pane_id')" --direction down --no-focus >/dev/null
split_rc=0
HERDR_SESSION="$SESSION" DEV_NO_ATTACH=1 "$DEV_LAYOUT" "$REPO" >/dev/null 2>&1 || split_rc=$?
[[ "$split_rc" == 0 ]] && ok "a manual split does not stop dev from focusing" \
                       || bad "dev after a manual split rc=$split_rc"
```

7a selects the agents panes with `APANES[1]` and `APANES[2]`, which are still the first two panes after the extra split; leave it as is.

- [ ] **Step 3: Assert that nothing leaks.**

Before the final summary line, add:

```zsh
STATE_AFTER=$(ls ~/.local/state/herdr-layout 2>/dev/null | wc -l | tr -d ' ')
[[ "$STATE_AFTER" == "$STATE_BEFORE" ]] \
  && ok "no lock file leaked into ~/.local/state/herdr-layout" \
  || bad "lock files in ~/.local/state/herdr-layout went from $STATE_BEFORE to $STATE_AFTER"
command herdr plugin list 2>/dev/null | grep -q 'dev.layout.test' \
  && bad "a dev.layout.test plugin registration exists" \
  || ok "no test plugin registration exists"
```

The second assertion fails until Michael runs `herdr plugin unlink dev.layout.test`, which is a post-apply step. If it fails only for that reason, report it in the run notes and the final report; do not unlink it yourself.

- [ ] **Step 4: Add the lock-file tombstones.**

Append to `.chezmoiremove`:

```
# Lock files leaked by dev-topology runs before 2026-10-01, which now keep their state
# in a scratch directory. Both patterns match test fixtures only.
.local/state/herdr-layout/*dev-live.*
.local/state/herdr-layout/*scratchpad-probe*
```

- [ ] **Step 5: Run the gate.**

Run, from a Herdr pane: `./tests/run.sh dev-topology` (the exact name lifts the `test-requires` gate). If the run is refused by the sandbox (socket denial), re-run it unsandboxed.
Expected: PASS, except possibly the stale `dev.layout.test` assertion (see Step 3); record passed/total.

- [ ] **Step 6: Commit.**

```bash
git add tests/dev-topology.test.sh .chezmoiremove
git commit -m "Run the live topology gate against the source tree"
```

---

### Task 11: Cut comment essays

Tier: `sp-standard`. Spec §10. One commit per file group, comment-only.

**Files:**
- Modify: `dot_config/zsh/functions`, `dot_config/herdr/executable_layout.sh`, `dot_config/herdr/executable_phase.sh`, `dot_config/herdr/executable_tab-goto.sh`, `dot_local/bin/executable_wt-teardown`, `dot_local/bin/executable_wt-rm`, `dot_local/bin/executable_wt-prepare`

- [ ] **Step 1: Cut, file by file.**

Keep three things:
- footgun warnings (for example "never name a local `path`", "`zsystem flock` locks are per-process", "`-z` is required");
- the reason for a non-obvious line, in one or two sentences;
- a one-line pointer to the spec holding the full argument.

Cut incident narratives (dates, "Observed…", "Measured…"), restatements of spec reasoning, and history of earlier revisions. Where an essay explains a still-live design point, leave one sentence and the pointer, for example `# Why no INT/TERM trap: docs/superpowers/specs/2026-07-30-worktree-hook-protocol-design.md §9.4.`

- [ ] **Step 2: Prove each commit is comment-only.**

For each file, before committing, run:

```bash
git diff -U0 -- <file> | grep '^[+-]' | grep -v '^[+-][+-]' | grep -Ev '^[+-][[:space:]]*(#.*)?$'
```

Expected: no output. Any line printed is a code change and must be undone.

- [ ] **Step 3: Run the affected suites, one at a time.**

Run: `./tests/run.sh wt-functions`, `./tests/run.sh dev`, `./tests/run.sh wt-teardown`, `./tests/run.sh herdr-phase`.
Expected: each PASS with the same passed/total as before this task.

- [ ] **Step 4: Commit per group.**

```bash
git add dot_config/zsh/functions dot_local/bin/executable_wt-rm dot_local/bin/executable_wt-prepare
git commit -m "Trim the lifecycle function comments to what the code cannot say"
git add dot_config/herdr/executable_layout.sh dot_config/herdr/executable_tab-goto.sh dot_config/herdr/executable_phase.sh
git commit -m "Trim the Herdr script comments to what the code cannot say"
git add dot_local/bin/executable_wt-teardown
git commit -m "Trim the wt-teardown comments to what the code cannot say"
```

---

### Task 12: Docs check, verification, status (controller)

**Files:**
- Modify (only if wording is now wrong): `AGENTS.md`, `README.md`
- Modify: `docs/superpowers/specs/2026-10-01-herdr-wt-simplification-design.md` (status; append "Implementation notes")
- Modify: `docs/superpowers/plans/2026-10-01-herdr-wt-simplification.md` (completion banner)

- [ ] **Step 1: Check the docs for stale claims.**

Run: `rg -n 'dev.layout|--current|wtcp|phase.sh pin|parked|classif|repair' AGENTS.md README.md dot_config dot_claude`
Expected: no live claim that is now false. Edit `AGENTS.md` only if a line there became false; the `dev-topology` row stays accurate as written.

- [ ] **Step 2: Run the full default set, then the gate.**

Run: `./tests/run.sh`, then `./tests/run.sh dev-topology` (unsandboxed, from a Herdr pane).
Expected: everything green except the documented stale-registration assertion; record passed/total per suite.

- [ ] **Step 3: Record the deviations.**

Append `## Implementation notes` to the spec. It lists every ruling and deviation made during execution, including the interpretation that heredoc bodies and comments count as non-segment text in §4.

- [ ] **Step 4: Run the pre-merge cross-review.**

Run `xreview round --reset`, then dispatch with `--checkpoint pre-merge --diff main..herdr-wt-simplify`. Fix verified findings and re-dispatch until approve.

- [ ] **Step 5: Set the final status.**

Set `**Status:** Implemented (branch herdr-wt-simplify; the dotfiles have no MR)` in the spec. Add a banner under the plan title, with the date of that commit: `> **Completed <date>.** Do not re-run; the execution banners above bound that run only.` Commit both. Any commit after the last pre-merge approval needs a new pre-merge round.

- [ ] **Step 6: Push the branch.**

Run, as its own Bash call: `git push origin herdr-wt-simplify`
Never merge.

- [ ] **Step 7: Report.**

Final report to Michael:
- the one-time post-apply steps: `herdr plugin unlink dev.layout`, `herdr plugin unlink dev.layout.test`, `brew uninstall wtcp && brew untap satococoa/tap`;
- the offer to update the two Obsidian Herdr/worktree notes;
- one state line: pushed, review receipt, open items, next step.
