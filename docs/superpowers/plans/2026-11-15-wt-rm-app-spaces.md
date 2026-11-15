# wt-rm closes app spaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repository the controller loads the `plan-run` skill first; it overrides superpowers.

**Goal:** `wt-rm` closes the checkout's Herdr app spaces through one shared rule (`checkout-spaces`), Retire and the menu use that rule instead of their own, and xreview and `dev` pick the app for any caller outside a TUI pane.

**Architecture:** A new zsh helper in the app's folder (`bin/checkout-spaces list|check|close <checkout>`) owns which app spaces are the checkout's and when they may close. `wt-rm` calls `check`, then its unchanged TUI close, then `close`; Retire calls `list` and then `wt-rm`. The front-end rule in xreview and `dev` shrinks to "a TUI variable, else the app".

**Tech Stack:** zsh (helper, `dot_config/zsh/functions`, retire), bash (xreview), jq, the app's `herdr-app` and herdr-core's `hc` CLIs (stubbed in tests), JavaScript (menu patch).

**Spec:** `docs/superpowers/specs/2026-11-15-wt-rm-app-spaces-design.md` (signed off 2026-11-15). Read it before your task; section numbers below are its.

## Global Constraints

- Work only in `/Users/michael/.local/share/chezmoi-feat-wt-rm-app-spaces` on `feat/wt-rm-app-spaces`; check `git branch --show-current` before each commit.
- No test or step runs anything against the live Herdr app, herdr-core, the TUI, or a real checkout: no unstubbed `herdr-app`, `hc`, `herdr`, `wt-rm` or `git worktree remove`. `tests/dev-topology.test.sh` is never run by an agent.
- Never edit a deployed file (`~/.config/...`, `~/.local/bin/...`); edit the chezmoi source.
- Out of bounds (parallel lines): `dot_config/herdr-app/mods/resume/`, `dot_config/herdr-app/keys.json.tmpl`, `wt-app --prompt`, any new popup mod.
- The helper's pinned PATH, verbatim and unconditional (no override variable): `PATH=$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin`. `/opt/homebrew/bin/herdr-app` is the live app on Michael's machine, so the one suite case that simulates "no app" runs a scratch copy of the helper with `:/opt/homebrew/bin` cut from that line (Task 2), never the helper itself with a stub removed.
- The helper runs every `hc` call with `HC_TERMINAL_ID` and `HC_SCOPE` removed (`env -u HC_TERMINAL_ID -u HC_SCOPE`); it reads the caller's `HC_TERMINAL_ID` only for the caller check.
- Execute suites (`./tests/x.test.sh` or `./tests/run.sh <name>`), never `bash tests/x.test.sh`. Report totals as passed/total. Read `tests/AGENTS.md` before changing a suite.
- Tests: one case per new behaviour or plausible regression, extending existing cases first; no variant matrices.
- Commits: small, imperative mood, no agent attribution, no explanatory comments beyond the surrounding style.
- A new file a suite loads gets its `.scripts/test-audit/subjects.tsv` row (and a `tests/missing-subject.test.sh` row where its suite's guard lists it) in the same commit.

## Review Focus

1. A checkout or space folder spelled through a symlink is still the checkout's; a sibling sharing the prefix (`proj-feat-other` for `proj-feat`) never is. → Task 2 test `symlinked space folder is own`.
2. `herdr-app ls` exiting 0 with something other than `{spaces: [...]}` (an `{"error": ...}` answer) refuses; it is never read as "no spaces". → Task 2 test `a listing without spaces refuses`.
3. The checkout already deleted (wt-rm's registration path): the helper still closes spaces made there. → Task 2 test `a gone checkout's space closes`; Task 3 Q12 extension.
4. A `space.close` that fails partway stops at once, names what closed and what failed, and `wt-rm` removes nothing. → Task 2 test `a failed close stops and names`; Task 3 U7.
5. A caller PATH that shadows `herdr-app`, `hc` or `jq` is ignored by the helper (it pins PATH). → Task 2 test `the helper ignores a caller PATH`.

---

### Task 1: Outside both front ends means the app (spec §1)

**Depends on:** none

**Files:**
- Modify: `dot_local/bin/executable_xreview:25-30` (the `FRONT_END` rule and its comment)
- Modify: `dot_config/zsh/functions:183-186` (`dev`'s `app=` rule and its comment)
- Modify: `.chezmoitemplates/agents/claude-code.md:12-13`
- Modify: `tests/fixtures/agent-instructions/rules.tsv` (row `cc-excluded-front-end`) and whatever else `agent-instructions` pins for that line
- Modify: `tests/xreview.test.sh` (top-level unset near line 45; FE section near line 432; every other case that sets `HC_TERMINAL_ID`, e.g. P1b near line 1443)
- Modify: `tests/dev.test.sh` (top-level unset near line 39; K section near line 1432)
- Modify: `tests/wt-functions.test.sh` (`setup()` near line 440; the "T app" case near line 2240)
- Modify: `tests/dev-topology.test.sh:67-68`

**Interfaces:**
- Produces: the rule "`HERDR_ENV` or `HERDR_PANE_ID` non-empty → TUI; otherwise → app", identical in xreview (`FRONT_END=tui|app`) and `dev` (`app=0|1`). Suites select the TUI by exporting `HERDR_PANE_ID=w0:p0` at their top; an app case clears it with `HERDR_PANE_ID=`.

- [ ] **Step 1: Update the case tables (failing first)**

`tests/xreview.test.sh`: after the top-level `unset ... HERDR_PANE_ID`, add `export HERDR_PANE_ID=w0:p0` with a one-line comment (the TUI unless a case clears it; outside both front ends is the app). In the FE section and every other case that sets `HC_TERMINAL_ID` for the app, prefix `HERDR_PANE_ID=`. FE2 becomes `HERDR_PANE_ID= HERDR_ENV=1 HC_TERMINAL_ID=t9`. Replace FE4 with:

```bash
fresh
out="$(HERDR_PANE_ID= fe_dispatch)"
is "FE4 neither front end's variable is the app" \
   "$(printf '%s' "$out" | grep -c '^xr-')/$(called '^app-pane pane list')/$(called '^herdr ')" "1/1/0"
```

`tests/dev.test.sh`: after line 39's unset, `export HERDR_PANE_ID=w0:p0` (same comment). The K section keeps its unset at its start; update its header comment to the new rule. Replace K4 with:

```zsh
run_dev "'$R1'"
eq "$(<$OS_ARG)" "$R1" "K4 neither front end's variable: open-space"
eq "$(<$LAYOUT_ARG)" "" "K4 neither front end's variable: layout.sh is never invoked"
```

`tests/wt-functions.test.sh`: in `setup()`, after the unset, `export HERDR_PANE_ID=w0:p0`; the "T app" case runs `HERDR_PANE_ID= HC_TERMINAL_ID=t9 run "$REPO" wt --no-focus feature/app main` and its comment states the new rule.

`tests/dev-topology.test.sh:67-68`: keep the unset, then `export HERDR_PANE_ID=dev-topology DEV_OPEN_SPACE=/usr/bin/false` with the comment "the topology is the TUI's; a wrong pick must never reach the real app".

- [ ] **Step 2: Run the focused suites; FE4 and K4 fail**

Run: `./tests/dev.test.sh 2>&1 | grep -E 'FAIL|passed'` — Expected: K4 FAILs only.
(xreview's FE4 is checked in Step 4; its suite takes about 8 minutes.)

- [ ] **Step 3: Change the rule**

xreview: `if [ -n "${HERDR_ENV:-}" ] || [ -n "${HERDR_PANE_ID:-}" ]; then FRONT_END=tui; else FRONT_END=app; fi`, comment citing spec 2026-11-15 §1 (a TUI pane gets the TUI; anywhere else, plain terminals included, the app). `dev`: `[[ -z "${HERDR_ENV-}" && -z "${HERDR_PANE_ID-}" ]] && app=1`, same comment. `claude-code.md` lines 12-13 become, verbatim:

```
  - `xreview` and `wt` act on the Herdr front end the caller runs in, the TUI's workspace from a
    TUI pane and the app's space from anywhere else; a pane only in the other one is not found.
```

Update `rules.tsv`'s `cc-excluded-front-end` expected sentence to match (keep its `\;` escaping), and any render fixture `agent-instructions` compares.

- [ ] **Step 4: Run the suites**

Run each and expect every assertion to pass:
`./tests/dev.test.sh` · `./tests/run.sh agent-instructions` · `./tests/run.sh wt-functions` (heavy, ~150 s) · `./tests/run.sh xreview` (heavy, ~8.5 min; also runs `xreview-*`) · `zsh -n tests/dev-topology.test.sh` (syntax only; never run it).

- [ ] **Step 5: Commit**

```bash
git add dot_local/bin/executable_xreview dot_config/zsh/functions .chezmoitemplates/agents/claude-code.md tests/fixtures/agent-instructions tests/xreview.test.sh tests/dev.test.sh tests/wt-functions.test.sh tests/dev-topology.test.sh
git commit -m "Pick the Herdr app for callers outside a TUI pane"
```

---

### Task 2: `checkout-spaces`, the one rule (spec §2)

**Depends on:** none

**Files:**
- Create: `dot_config/herdr-app/bin/executable_checkout-spaces` (zsh, mode 755 in git)
- Modify: `tests/herdr-app.test.sh` (its guard list at line 19; retire's refusal and close-set cases at lines 111-198 and the `allcmds` case near line 245 move to the helper; new cases)
- Modify: `tests/fixtures/herdr-app/stubs/herdr-app`, `tests/fixtures/herdr-app/stubs/hc` (new knobs below)
- Modify: `.scripts/test-audit/subjects.tsv` (new row after `executable_retire`'s, same columns: `zsh	herdr-app	herdr-app,herdr-app-xreview`), `tests/missing-subject.test.sh` (a `missing herdr-app` row for the helper)

**Interfaces:**
- Produces: `~/.config/herdr-app/bin/checkout-spaces <list|check|close> <checkout>`.
  - `<checkout>`: absolute path; need not exist. Compared resolved (`${x:A}`).
  - `list`: stdout one JSON object `{"spaces":[<space id>...],"terminals":[<address>...],"records":[<record>...]}`, exact-folder spaces first, then subfolder spaces; `terminals` include sub-agents (string or `.terminal`), in space order; `records` are `shared.json`'s `"resume.sessions"[<address>]` for those terminals, in that order (unreadable file: `[]`). Exit 0, or 1 when the app is unreachable.
  - `check`: exit 0 safe (or nothing to close), 1 refused; each reason on stderr as `checkout-spaces: refusing — <reason>`.
  - `close`: `check`, then resume lines on stdout (`retire`'s current format: a heading, then `  <app>: cd <cwd> && <cmd>`), warnings on stderr, `herdr-app do space.close {"id":<id>,"confirmed":true}` per space in list order, then a re-list. Exit 0, or 1 on any refusal or failed or incomplete close.
  - No `herdr-app` on the pinned PATH: every verb exits 0, calls nothing; `list` prints `{"spaces":[],"terminals":[],"records":[]}`.
  - Usage error: exit 2.
- Stub knobs this task adds (Task 4 uses them too): herdr-app stub — `$STUB_DIR/ls-raw` (when present, `ls` prints it verbatim, exit 0), `$STUB_DIR/stuck-<id>` (`space.close` answers `{}` but the space stays listed), `$STUB_DIR/closefail-<id>` (`space.close` prints `{"error":"stub"}`, exit 1). hc stub — `$STUB_DIR/hc-ls-fail` (`ls` exits 1). Document each in the stub's header comment.

- [ ] **Step 1: Move and add the cases (failing first)**

In `tests/herdr-app.test.sh` add `cs() { "$bin/checkout-spaces" "$@" </dev/null }` beside `retire()` (the guard-list entry comes in Step 3, with the file). `newworld`'s `unset` line also unsets `STUB_LS_DOWN` and `STUB_WTRM_CLOSE`, so no knob leaks into the next world (file knobs live in the per-world `$STUB_DIR`). Retarget, keeping each case's world setup and descriptions:
- `busy-working`/`busy-blocked`, `inside`, `subagent`, `subspace`, `wandered-in`, `unaskable`, `editor-*`: `cs check $wt`; expect rc non-zero and `not_did 'space.close'` (drop the `wt-rm` half of those patterns).
- `subspace-idle`, `wandered-out`: `cs close $wt`; keep their `did`/`not_did`/`before` assertions, with `before 'sp-sub' 'herdr-app ls'`-style ordering replaced by "sp-wt closes before sp-sub".
- `unaskable-foreign`: now `cs check $wt` expects rc 1 and the output names `tNEW1` (description: "another space's terminal that cannot be asked about refuses").
- `allcmds`: `cs close $wt >$world/out`, same assertion (three resume commands printed).

New cases, each in its own `newworld`:

```zsh
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
  check "no app: nothing is called" not_did 'herdr-app'
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
for how in missing failing; do
  if [[ $how == failing ]]; then : > $STUB_DIR/hc-ls-fail; else print '{"terminals":[]}' > $STUB_DIR/hc-ls.json; fi
  cs check $wt >/dev/null 2>&1; rc=$?
  check "a sub-agent whose status hc ls does not give refuses ($how)" test $rc -eq 1
done

newworld badrecords; print 'not json' > $HERDR_APP_HOME/shared.json
cs close $wt >$world/out 2>$world/err; rc=$?
check "unreadable records still close" test $rc -eq 0
check "...and name the agents without a record" grep -q 't1' $world/err

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
```

Adjust world details (stub knobs, `add_space`, `launched_in`/`now_in`) to what the suite already offers; the assertions above are the contract.

- [ ] **Step 2: Run, expect the helper cases to fail (no helper yet)**

Run: `./tests/herdr-app.test.sh 2>&1 | tail -3` — Expected: the suite runs (no guard exit), the helper cases fail (a few negative assertions may pass vacuously), retire's remaining cases pass.

- [ ] **Step 3: Write `executable_checkout-spaces`**

Add the helper to the suite's guard list (line 19) now that the file exists.

zsh, `emulate -L zsh`, `setopt pipe_fail no_unset`; header comment: what it is, the three verbs, that it is the one rule for `wt-rm` and Retire (spec 2026-11-15 §2). First lines: save `caller=${HC_TERMINAL_ID:-}`, then the PATH line exactly as in Global Constraints, alone on its line (the no-app test edits that line's end), then `home=${HERDR_APP_HOME:-$HOME/.config/herdr-app}`. Port the rule from `executable_retire` (lines 32-34, 36, 72-123, 126-133), then change exactly what spec §2 changes:
- `herdr-app` absent (`(( $+commands[herdr-app] ))` after the PATH pin): the "no app" exits above.
- `herdr-app ls` must exit 0 and satisfy `jq -e 'type == "object" and (.spaces | type == "array")'`, else `refusing — cannot read the Herdr app's spaces — open its window, then retry`.
- Sub-agents: when the set has any, `hc ls --all --json` must exit 0, parse, and list every sub-agent address (`.terminals[].address`); else refuse naming them. Busy = `working` or `blocked` in either listing (`--all` keeps finished terminals, which plain `hc ls` hides).
- Another local space's terminal that `hc get` cannot answer, or answers without `.foreground.cwd`: refuse naming it and its space (`where_is`).
- `close`: after `check` passes, print the records; when `shared.json` exists but `jq` cannot read it, or an agent terminal of the set (`.app` set in the listing) has no record, print one stderr line naming each; close in list order and stop at the first failure (non-zero exit or an `error` key), printing the ids closed so far and the failing id; then re-list and refuse if any id of the set is still there.

- [ ] **Step 4: Run the suite**

Run: `./tests/run.sh herdr-app missing-subject` — Expected: every assertion passes. Then `git ls-files -s dot_config/herdr-app/bin/executable_checkout-spaces` shows mode `100755`.

- [ ] **Step 5: Commit**

```bash
git add dot_config/herdr-app/bin/executable_checkout-spaces tests/herdr-app.test.sh tests/fixtures/herdr-app/stubs .scripts/test-audit/subjects.tsv tests/missing-subject.test.sh
git commit -m "Add checkout-spaces, the rule for a checkout's app spaces"
```

---

### Task 3: `wt-rm` closes the app spaces (spec §3)

**Depends on:** Task 1 (same files: `dot_config/zsh/functions`, `tests/wt-functions.test.sh`), Task 2 (the helper's verbs and exit codes)

**Files:**
- Modify: `dot_config/zsh/functions` — new `_wt_app_spaces` beside `_wt_stop_herdr_workspaces` (line ~1130); call sites in `wt-rm` (line ~1650) and `_wt_rm_registration` (line ~1540); `wt-rm`'s header comment step 2 (line ~1566); the messages listed below
- Test: `tests/wt-functions.test.sh` (section U, after U4 near line 2420; Q12 near line 1641; assertions on changed messages at lines ~1863, 2564, 4402, 4416, 4429, 4436)

**Interfaces:**
- Consumes: `checkout-spaces check|close <dest>` (Task 2), exit 0 or non-zero.
- Produces: `_wt_app_spaces <check|close> <dest>` — runs `$HOME/.config/herdr-app/bin/checkout-spaces "$1" "$2"`; returns 0 without running anything when that file is not executable; otherwise its status.

- [ ] **Step 1: Write the failing cases**

Add a helper near the fixture:

```zsh
# app_spaces_stub [check-rc] [close-rc] — checkout-spaces in the scratch HOME, logging each call to $HLOG
app_spaces_stub() {
  mkdir -p "$HOME/.config/herdr-app/bin"
  print -r -- "#!/bin/sh
echo \"checkout-spaces \$*\" >> '$HLOG'
case \$1 in check) exit ${1:-0} ;; close) exit ${2:-0} ;; esac" > "$HOME/.config/herdr-app/bin/checkout-spaces"
  chmod +x "$HOME/.config/herdr-app/bin/checkout-spaces"
}
```

After U4, three cases on U1's world (own TUI workspace `w7`, a `mkhook` teardown marker as in U2):
- **U5** `app_spaces_stub 0 0`; `wt-rm` → `rc_is 0`; in `$HLOG`, `checkout-spaces check <dest>` precedes `workspace close w7`, which precedes `checkout-spaces close <dest>` (compare `grep -n` line numbers); the checkout is removed.
- **U6** `app_spaces_stub 1 0` → `rc_is 1`; `hunlogged "workspace close"`; `hunlogged "checkout-spaces close"`; the teardown marker is absent; the checkout survives.
- **U7** `app_spaces_stub 0 1` → `rc_is 1`; `hlogged "workspace close w7"`; the teardown marker is absent; the checkout survives.

Q12: call `app_spaces_stub` right before its final retry (`chmod 700 "$Q12_REG"`), clear `$HLOG`, and after `rc_is 0` add `hlogged "checkout-spaces check $Q12"` and `hlogged "checkout-spaces close $Q12"`.

Change the existing message assertions to the new wording (Step 3).

- [ ] **Step 2: Run, expect U5-U7, the Q12 additions and the message assertions to fail**

Run: `./tests/run.sh wt-functions 2>&1 | grep -E 'FAIL|passed'`

- [ ] **Step 3: Implement**

`_wt_app_spaces` as in Interfaces. In `wt-rm`, replace the step-2 line with:

```zsh
    _wt_app_spaces check "$dest" || { print -ru2 -- "wt-rm: nothing was closed or removed."; return 1 }
    _wt_stop_herdr_workspaces "$dest" || return 1
    _wt_app_spaces close "$dest" || {
      print -ru2 -- "wt-rm: the Herdr app's spaces for $dest are not all closed (its Herdr workspaces are) — nothing was removed. Retry: wt-rm $qb"
      return 1 }
```

and the same three calls around `_wt_stop_herdr_workspaces` in `_wt_rm_registration`. Messages: every "Herdr workspaces closed" becomes "Herdr workspaces and app spaces closed"; check 2's two messages say "closing Herdr workspaces and app spaces". The header comment's step 2 says it checks the app's spaces, closes the TUI's workspaces, then closes the app's (spec 2026-11-15 §3).

- [ ] **Step 4: Run**

Run: `./tests/run.sh wt-functions` — Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add dot_config/zsh/functions tests/wt-functions.test.sh
git commit -m "Close the checkout's app spaces in wt-rm"
```

---

### Task 4: Retire and the menu use the rule (spec §4, §5)

**Depends on:** Task 2

**Files:**
- Modify: `dot_config/herdr-app/bin/executable_retire` (rewrite to spec §4; header comment updated)
- Modify: `dot_config/herdr-app/patches/worktree-actions.js` (`closing()`, `inside`, the busy check and unused imports go; `retire()` per spec §5)
- Modify: `tests/fixtures/herdr-app/stubs/wt-rm` (knob below)
- Test: `tests/herdr-app.test.sh` (retire's remaining cases)

**Interfaces:**
- Consumes: `checkout-spaces list <checkout>` (Task 2), via `$here/checkout-spaces`; the stub knobs from Task 2.
- Produces: stub wt-rm knob `STUB_WTRM_CLOSE=<checkout>`: after logging, the stub runs `"$STUB_CHECKOUT_SPACES" close "$STUB_WTRM_CLOSE"` and exits 1 if it fails; `newworld` exports `STUB_CHECKOUT_SPACES=$bin/checkout-spaces`.

- [ ] **Step 1: Update retire's cases (failing first)**

- Delete the `dirty` case (`wt-rm` refuses a dirty checkout itself).
- `ok`, `warned`, `fail`, `reopen`, `fresh`, `ownrecords`, `norecords`: export `STUB_WTRM_CLOSE=$wt`. In `ok` and `fail`, replace "the space closes before wt-rm runs" with `check "retire closes no space itself before wt-rm" before 'wt-rm ' 'space.close'`. `ok` also calls `records cid-claude cid-codex` first: its two agents need records, or `close`'s missing-record warning on stderr keeps the tab open and "success closes its own tab" fails.
- New:

```zsh
newworld listdown; export STUB_LS_DOWN=1
retire $wt >/dev/null 2>&1; rc=$?
check "an unreachable app refuses retire" test $rc -ne 0
check "...before wt-rm runs" not_did 'wt-rm '

newworld refusedearly; export STUB_WTRM_RC=1
print | "$bin/retire" $wt >$world/out 2>&1
check "a wt-rm that closed nothing offers no reopen" not_did 'space.new'
grep -q 'Enter reopens' $world/out; check "...and does not ask" test $? -ne 0
```

- [ ] **Step 2: Run, expect the changed cases to fail**

Run: `./tests/herdr-app.test.sh 2>&1 | grep -E 'FAIL|passed'`

- [ ] **Step 3: Rewrite retire**

Keep from today: usage, `folder=${1:A}` and its existence check, sourcing `~/.config/zsh/functions` (require only `_wt_git` and `_wt_primary`), the main-checkout, detached-HEAD and placement refusals, `refuse()`, step 5's `wt-rm` run through `tee`, step 6's success handling and the reopen block (`session-written`, `open-space`). Drop `_wt_assert_worktree`, `_wt_hook_check`, `_wt_rm_lock_class`, `_wt_clean`, the close set, all `hc` and `herdr-app` calls, the record printing and the close loop. New: before `wt-rm`, `listing=$("$here/checkout-spaces" list "$folder") || refuse "cannot read the app's spaces (is the window open?)."`, `spaces=( $(jq -r '.spaces[]' <<<"$listing") )`, `records=$(jq -c .records <<<"$listing")`. On failure: offer the reopen only when `$#spaces` is non-zero, `$folder` exists, and a fresh `list` succeeds and contains none of `$spaces`; otherwise print why there is nothing to reopen and `exit $rc`.

`worktree-actions.js` `retire(space, { top, main })`: `target = spaces().find((s) => !s.machine && s.folder === main)`; if found, `tab.new` in it and `space.select` it, else `space.new` at `main` (both as today). Its comment: the tab never goes in a space that may close (`wt` puts every worktree beside the main checkout), and what closes is `checkout-spaces`' to decide. Remove `closing`, `inside`, and the now-unused `agents` and `notify` imports.

- [ ] **Step 4: Run**

Run: `./tests/run.sh herdr-app` — Expected: all pass. If `/opt/homebrew/bin/node` exists: `node --check dot_config/herdr-app/patches/worktree-actions.js` exits 0 (otherwise note it; `herdr-app check` runs at Michael's `respaces`).

- [ ] **Step 5: Commit**

```bash
git add dot_config/herdr-app/bin/executable_retire dot_config/herdr-app/patches/worktree-actions.js tests/herdr-app.test.sh tests/fixtures/herdr-app/stubs/wt-rm
git commit -m "Retire through wt-rm and checkout-spaces"
```

---

## After the last task (the controller)

- `./tests/run.sh --changed` on the final commit (it runs the heavy `xreview`, `wt-functions` and `test-audit` suites whose subjects changed); quote its `needs: heavy` lines in the report.
- Pre-merge cross-review, the spec's Status line set to `Implemented` with the PR, this plan marked completed, the PR with the spec's acceptance list as unchecked items.
