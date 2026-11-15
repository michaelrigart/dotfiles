# xreview and wt on the Herdr desktop app — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repository the `plan-run` skill governs the run and overrides those templates.

**Status:** In progress (branch `feat/herdr-app-native-tools`)

**Goal:** `xreview` and `wt`/`dev` act on the Herdr app when run from an app terminal, and on the TUI otherwise, so the app's adapters shrink to compatibility wrappers.

**Architecture:** One three-line front-end rule (in xreview's bash and in `dev`'s zsh) picks the TUI or the app from the caller's environment. xreview sends its pane calls to `herdr` or to `xreview-app-pane` (the app shim, moved into the dotfiles with one fix); `dev` opens the checkout with `layout.sh` or with the app's `open-space`. xreview's lock moves from the pane to the checkout.

**Tech Stack:** bash (xreview), zsh (functions, the helper, the app scripts), jq, chezmoi source layout, the repository's shell test suites.

**Spec:** `docs/superpowers/specs/2026-11-14-herdr-app-native-tools-design.md` (§ numbers below are its sections).

## Global Constraints

- Front-end rule, exactly: `HERDR_ENV` or `HERDR_PANE_ID` non-empty → TUI; else `HC_TERMINAL_ID` non-empty → app; else TUI. No override variable.
- The TUI path's behaviour, calls and messages stay as they are; every existing TUI assertion keeps passing unchanged unless a task names it.
- Never type into a live Codex: an uncertain process state is a failed read, never "freed".
- No unsandboxed path runs a program found through a caller PATH folder, except wt's lifecycle and repository hooks (deliberate).
- Pinned PATH, where a task pins one: `$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin` (xreview-app: `/usr/bin:/bin:/usr/sbin:/sbin`).
- Every suite whose cases reach xreview's pane code or `dev`/`wt` clears `HC_TERMINAL_ID HC_SCOPE HC_TERMINAL_SOCKET HERDR_ENV HERDR_PANE_ID` at its top (or in its per-case setup) unless a case sets them. This session's own terminal is an app terminal: run every suite from it, so a missing clear fails here.
- Suites are executed (`./tests/x.test.sh`), never through an interpreter; report totals as passed/total.
- A new or moved file a suite loads gets its `.scripts/test-audit/subjects.tsv` row in the same commit.
- `claude-code.md` stays within 50 lines; `global.md` is not edited.
- No agent attribution in commits. Check `git branch --show-current` before each commit.

## Review Focus

1. **App window closed** while the caller is an app terminal: xreview refuses naming the Herdr app and its window, never a TUI message and never a TUI fallback (Task 1 test FE5).
2. **`HC_TERMINAL_ID` set but empty** (a scrubbed environment): the TUI, in both xreview and `dev` (Task 1 FE4, Task 2 K4).
3. **A checkout path with a space** on the app path: `open-space` receives it as one argument (Task 2 K6); xreview's lock digest of it locks (existing "sp ace" case keeps passing, Task 1).
4. **A detached or non-sibling linked checkout opened by `dev` from the app:** `_wt_prepare_for_herdr` refuses before `open-space` runs (Task 2 K5).
5. **A suite run from an app terminal:** the TUI cases still take the TUI path (Global Constraints; verified by running each suite from this session).

---

### Task 1: xreview picks the front end; the lock is per checkout

**Depends on:** none

**Files:**
- Modify: `dot_local/bin/executable_xreview` (after the PATH pin at line 24; the 11 `herdr pane` call sites at 183, 206, 223, 250, 264, 389, 524, 526, 558, 590, 634; the messages at 184, 187, 351, 374, 1342, 1928; `warn_pane_map_untrusted`'s call at 1317; `lock_pane` 644-679 and its calls at 1337, 1907)
- Test: `tests/xreview.test.sh`

**Interfaces:**
- Produces: `FRONT_END` (`tui` | `app`) and `PANE_CLI` (`herdr` | `xreview-app-pane`), set once at the top; every pane call is `"$PANE_CLI" pane …`. `lock_key <root>`: prints the lowercase SHA-256 hex of `<root>`'s bytes. `lock_pane <pane> <root>`: locks `$XDG_STATE_HOME/xreview/locks/$(lock_key <root>).lock`; its messages still name `<pane>`.
- Consumes: nothing. `xreview-app-pane` arrives in Task 5; until then only the suite's stub exists.

- [ ] **Step 1: Clear the front-end variables in the suite.** Add `HC_TERMINAL_ID HC_SCOPE HC_TERMINAL_SOCKET HERDR_ENV HERDR_PANE_ID` to the `unset` at the top of `tests/xreview.test.sh` (beside `XREVIEW_MAX_ROUNDS`).

- [ ] **Step 2: Write the failing front-end cases** as a new section `FE` after the herdr stub is written. Create `$STUB/xreview-app-pane` as a copy of `$STUB/herdr` whose log line reads `app-pane <args>` instead of `herdr <args>` (`sed 's/%sherdr %s/%sapp-pane %s/'`). Cases, each a fresh plan dispatch of `b.md`:
  - `FE1` `HC_TERMINAL_ID=t9`: a nonce is printed; `$CALLS` has `app-pane pane list` and no line starting `herdr `.
  - `FE2` `HERDR_ENV=1 HC_TERMINAL_ID=t9`: `herdr pane list` logged, no `app-pane`.
  - `FE3` `HERDR_PANE_ID=w1:p2 HC_TERMINAL_ID=t9`: as FE2.
  - `FE4` `HC_TERMINAL_ID=` (empty) and nothing else: as FE2.
  - `FE5` `HC_TERMINAL_ID=t9` with the app-pane stub's `pane list` exiting 1 with no output: exit 1, stderr has `cannot list the Herdr app's panes - is its window open?`, and no `herdr ` call.
  - `FE6` `HC_TERMINAL_ID=t9`: `xreview-rpc hooks-status` is never called (the pane-map warning is the TUI's); without it (TUI), it still is.

- [ ] **Step 3: Write the failing lock cases.** Change `LOCKF` in section P to `$XDG_STATE_HOME/xreview/locks/$(printf '%s' "$CWD" | shasum -a 256 | cut -c1-64).lock`; P1's message stays `another dispatch is using the Codex pane w1:p2; …`. Add:
  - `P1b`: with that lock held, `HC_TERMINAL_ID=t9 XREVIEW_LOCK_WAIT=0.5` dispatch refuses with `another dispatch is using the Codex pane w1:p2` (the app stub reports the same pane id): the two front ends share the checkout's lock.
  - Change P7 to `lock_pane wP:p7 /a/b` and look for `locks/<sha256 of /a/b>.lock`; add `P7b`: `lock_pane x /a/b` held in one process does not block `lock_pane x /a_b` with `XREVIEW_LOCK_WAIT=0.5` in another; `P7c`: `lock_pane x "/$(printf 'd%.0s' {1..300})"` succeeds and its lock file name is 69 bytes.
  - P4b's `grep -c 'cannot open .*w1_p2.lock'` becomes `cannot open .*\.lock`, and P8's `(.*w1_p2.lock)` becomes `(.*/<the CWD digest>.lock)`. P8's interpreter swap (`sed` over `lock_pane`'s range) keeps reaching only the flock helper, because the digest is computed in `lock_key`, outside that range; P7's extracted source takes `lock_key` along with `lock_pane`.

- [ ] **Step 4: Run them and see them fail.** Run: `./tests/run.sh xreview` (exact name: lifts the heavy gate). Expected: FE1, FE5, FE6, P1b, P7, P7b, P7c FAIL; everything else PASS.

- [ ] **Step 5: Implement.**
  - After the PATH line: the §5.1 rule sets `FRONT_END`; `PANE_CLI=herdr` for `tui`, `xreview-app-pane` for `app`.
  - The 11 call sites become `"$PANE_CLI" pane …`, arguments unchanged.
  - Messages: `cannot list herdr panes - is herdr running?` and `cannot read herdr's pane list` stay for `tui`; for `app` they read `cannot list the Herdr app's panes - is its window open?` and `cannot read the Herdr app's pane list`. The four `(herdr pane get)` / `(herdr pane process-info)` parentheticals name `$PANE_CLI` instead of the literal `herdr`.
  - `warn_pane_map_untrusted` is called only when `FRONT_END=tui`.
  - `lock_key <root>`, a function of its own defined just before `lock_pane`: `/usr/bin/python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"`. `lock_pane <pane> <root>` names its file `$(lock_key "$2").lock` (a failed or empty key dies `cannot name the lock for the Codex pane <pane>; no review was started. Michael's call: report this and stop.`). Both callers pass `"$(pane_root)"`.
  - Update the header comment where it says the pane is a "herdr pane".

- [ ] **Step 6: Run the suite and see it pass.** Run: `./tests/run.sh xreview` from this session's app terminal. Expected: every `xreview*` suite PASS, passed/total printed.

- [ ] **Step 7: Commit.** `git add dot_local/bin/executable_xreview tests/xreview.test.sh` then `git commit -m "Let xreview drive the Herdr app's Codex pane and lock per checkout"`.

### Task 2: `dev` (and so `wt`) opens an app space from the app

**Depends on:** none

**Files:**
- Modify: `dot_config/zsh/functions` (`dev`, 145-194; its header comment 140-144)
- Test: `tests/dev.test.sh`, `tests/wt-functions.test.sh`, `tests/dev-topology.test.sh` (the clear only)

**Interfaces:**
- Produces: `dev [--no-focus] <repo>` from an app caller runs `${DEV_OPEN_SPACE:-$HOME/.config/herdr-app/bin/open-space} [--no-focus] <resolved repo>`; a linked checkout runs `_wt_prepare_for_herdr <main> <repo>` first, as on the TUI path. `wt` reaches it unchanged through `dev "$_WT_DEST"`.
- Consumes: nothing (the real `open-space` gains its PATH pin in Task 6).

- [ ] **Step 1: Clear the variables.** `dev.test.sh`: `unset HC_TERMINAL_ID HC_SCOPE HC_TERMINAL_SOCKET HERDR_ENV HERDR_PANE_ID` near the top, after the git environment exports. `wt-functions.test.sh`: add `HC_TERMINAL_ID HC_SCOPE HC_TERMINAL_SOCKET HERDR_PANE_ID` to `setup()`'s `unset`. `dev-topology.test.sh`: add the same five to its environment setup.

- [ ] **Step 2: Write the failing cases.** `dev.test.sh`: an `open-space` stub in `$STUBS` writing `$*` to `$OS_ARG` (one argument per line, so K6 can count them), and `run_dev` passing `DEV_OPEN_SPACE="$STUBS/open-space"`; a new section `K: front end`:
  - `K1` `HC_TERMINAL_ID=t9`, `dev --no-focus '$R1'`: `$OS_ARG` is `--no-focus` / `$R1`; `$LAYOUT_ARG` empty.
  - `K2` `HC_TERMINAL_ID=t9`, `dev --no-focus '$WT'`: rc 0; `$OS_ARG` is `--no-focus` / `${WT:A}`; `git -C "$R1" worktree list --porcelain` shows `$WT` locked with `_wt_herdr_lock_reason`'s text; `$LAYOUT_ARG` empty.
  - `K3` `HERDR_ENV=1 HC_TERMINAL_ID=t9`, `dev '$R1'`: `$LAYOUT_ARG` is `$R1`; `$OS_ARG` empty. Same with `HERDR_PANE_ID=w1:p2` instead of `HERDR_ENV`.
  - `K4` `HC_TERMINAL_ID=` (empty): `layout.sh`, not `open-space`.
  - `K5` `HC_TERMINAL_ID=t9`, a linked checkout that is detached (`git -C "$WT2" checkout -q --detach`): rc 1, `is detached`, `$OS_ARG` empty.
  - `K6` `HC_TERMINAL_ID=t9`, a repository under `$CODE/Netronix/sp ace`: `$OS_ARG` holds exactly one path line, the repository with its space.
  `wt-functions.test.sh`: an `open-space` stub logging to `$OLOG` (reset in `setup()`), `DEV_OPEN_SPACE` exported beside `DEV_LAYOUT`; a case after the `T --no-focus` ones: `HC_TERMINAL_ID=t9 run "$REPO" wt --no-focus feature/app main`: rc 0, the checkout exists, `$OLOG` is exactly `--no-focus $HOME/Code/Org/repo-feature-app`, `$DLOG` empty.

- [ ] **Step 3: Run them and see them fail.** Run: `./tests/dev.test.sh` and `./tests/run.sh wt-functions`. Expected: K1, K2, K5, K6 and the wt app case FAIL; the rest PASS.

- [ ] **Step 4: Implement** in `dev`, after the `-e "$repo/.git"` check: the §5.1 rule inline; for the app, a linked checkout goes through `_wt_primary` and `_wt_prepare_for_herdr` exactly as now, then `"${DEV_OPEN_SPACE:-$HOME/.config/herdr-app/bin/open-space}" "${focus[@]}" "$repo"` and `return $?`; the TUI path is untouched. The header comment says resolution only, and that the front end decides between `layout.sh` and `open-space`.

- [ ] **Step 5: Run and see them pass.** Run: `./tests/dev.test.sh`, `./tests/run.sh wt-functions` from this session's app terminal. Expected: PASS, passed/total printed.

- [ ] **Step 6: Commit.** `git add dot_config/zsh/functions tests/dev.test.sh tests/wt-functions.test.sh tests/dev-topology.test.sh` then `git commit -m "Open wt and dev checkouts as Herdr app spaces from the app"`.

### Task 3: The instruction line

**Depends on:** none

**Files:**
- Modify: `.chezmoitemplates/agents/claude-code.md` (the **Excluded tools** bullet, 8-11)
- Test: `tests/fixtures/agent-instructions/rules.tsv`, `tests/agent-instructions.test.sh` (render pins, if any name the line count)

- [ ] **Step 1: Add the rule row** `cc-excluded-front-end` to `rules.tsv` (anchor `act on the Herdr front end`, required `yes`, sentence: `` `xreview` and `wt` act on the Herdr front end the caller runs in, the app's space or the TUI's workspace; a pane only in the other one is not found. ``, description `xreview and wt follow the caller's front end`).

- [ ] **Step 2: Run and see it fail.** Run: `./tests/agent-instructions.test.sh`. Expected: the new rule FAILS.

- [ ] **Step 3: Add the sub-bullet** under **Excluded tools**, after the "Do setup in a separate call" sub-bullet, with exactly that sentence (wrapped at the file's width, `  - ` indent).

- [ ] **Step 4: Run and see it pass.** Run: `./tests/agent-instructions.test.sh` and `./tests/run.sh claude-settings`. Expected: PASS; `claude-code.md` ≤ 50 lines.

- [ ] **Step 5: Commit.** `git add .chezmoitemplates/agents/claude-code.md tests/fixtures/agent-instructions/rules.tsv tests/agent-instructions.test.sh` then `git commit -m "Say that xreview and wt follow the caller's Herdr front end"`.

### Task 4: Rebase onto line 1's merge (controller)

**Depends on:** Tasks 1-3, and `chore/herdr-app-in-chezmoi` merged into `main`

- [ ] **Step 1: Check line 1 has merged.** Run: `git -C <checkout> fetch origin` then `git -C <checkout> ls-tree -r --name-only origin/main dot_config/herdr-app/bin | head`. Expected: `dot_config/herdr-app/bin/executable_xreview-app` and the other scripts listed. If not: report "waiting for line 1" with the state line and stop the run there.

- [ ] **Step 2: Rebase.** Run: `git -C <checkout> rebase origin/main`. Expected: clean (this line has not touched `dot_config/herdr-app`, `.chezmoiignore` or the `herdr-app` suites); a conflict is resolved by sp-standard.

- [ ] **Step 3: Re-run Tasks 1-3's suites** from this session's app terminal. Expected: PASS.

### Task 5: The shim becomes `xreview-app-pane`, without the caller's hc identity; `xreview-app` becomes a wrapper

**Depends on:** Task 4

**Files:**
- Move: `dot_config/herdr-app/xreview-shim/executable_herdr` → `dot_local/bin/executable_xreview-app-pane` (`git mv`, mode 755)
- Move/split: the shim's cases from `tests/herdr-app-xreview.test.sh` → `tests/xreview-app-pane.test.sh` (zsh shebang); stubs and fixture stay in `tests/fixtures/herdr-app/`
- Modify: `dot_config/herdr-app/bin/executable_xreview-app` (it checks for the shim today, so it changes in the commit that removes it), `.chezmoiignore` (drop the `xreview-shim` re-include), `.scripts/test-audit/subjects.tsv`
- Test: `tests/herdr-app-xreview.test.sh` (its `xreview-app` section)

**Interfaces:**
- Consumes: Task 1's call forms (unchanged since the shim was written).
- Produces: `~/.local/bin/xreview-app-pane pane <seven forms>`, behaviour as §5.3; every `hc` call made as `command env -u HC_TERMINAL_ID -u HC_SCOPE hc …` through one wrapper function. `xreview-app [args…]`: `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, then `exec "${XREVIEW_APP_XREVIEW:-$HOME/.local/bin/xreview}" "$@"`.

- [ ] **Step 1: Move the files.** `git mv` the shim and create `tests/xreview-app-pane.test.sh` holding every case of `tests/herdr-app-xreview.test.sh` that runs the shim (its find_pane, get, process-info, keys/run/read, report, refusal and shape sections), pointed at `dot_local/bin/executable_xreview-app-pane` and `tests/fixtures/herdr-app/`; the `xreview-app` section stays in `tests/herdr-app-xreview.test.sh`. Drop `.chezmoiignore`'s `xreview-shim` line. Subject rows: the helper (`zsh`, suite `xreview-app-pane`, loaded by `xreview-app-pane,xreview`), the new suite.

- [ ] **Step 2: Write the failing cases.**
  - `xreview-app-pane.test.sh`: the `hc` stub appends `id=${HC_TERMINAL_ID-unset} scope=${HC_SCOPE-unset}` to its log line; the suite exports `HC_TERMINAL_ID=t87 HC_SCOPE=s1` for every case and asserts, after the keys, run and read cases and one get, that every `hc` log line carries `id=unset scope=unset`. Replace the copied jq filters' line-number comments with a drift check: each copied xreview filter must appear verbatim (`grep -F`) in `dot_local/bin/executable_xreview`, one `PASS: drift: <function>` per filter.
  - `herdr-app-xreview.test.sh`'s `xreview-app` section: with a hostile PATH first (a folder holding `grep`, `jq` and `xreview` that touch a marker), `xreview-app round` runs the `$XREVIEW_APP_XREVIEW` stand-in, which records its arguments and PATH: the arguments arrive unchanged, the PATH it sees is `/usr/bin:/bin:/usr/sbin:/sbin`, no `PINNED_PATH` is set by the wrapper, and the marker never appears. The cases about the shim folder and xreview's PATH line are deleted.

- [ ] **Step 3: Run and see it fail.** Run: `./tests/xreview-app-pane.test.sh`, `./tests/herdr-app-xreview.test.sh`. Expected: the identity assertions and the new wrapper cases FAIL; the moved cases and the drift checks PASS.

- [ ] **Step 4: Implement** the wrapper `hc_()` (or equivalent) in the helper and route its `hc get/keys/send/read` calls through it; update the header comment (it is xreview's app pane helper, called through `PANE_CLI`, not a `herdr` on PATH; the identity rule and why, citing §5.3). Replace `xreview-app`'s body with the Interfaces' two lines and a comment saying it remains for sessions recorded with its path until the TUI is retired (§5.7).

- [ ] **Step 5: Run and see it pass.** Run: `./tests/xreview-app-pane.test.sh`, `./tests/run.sh herdr-app xreview`. Expected: PASS.

- [ ] **Step 6: Commit.** `git add -A dot_local/bin/executable_xreview-app-pane dot_config/herdr-app/xreview-shim dot_config/herdr-app/bin/executable_xreview-app tests/xreview-app-pane.test.sh tests/herdr-app-xreview.test.sh .chezmoiignore .scripts/test-audit/subjects.tsv` then `git commit -m "Move the app pane shim into the dotfiles as xreview-app-pane, without the caller's hc identity"`.

### Task 6: The app side becomes thin

**Depends on:** Tasks 2, 5

**Files:**
- Modify: `dot_config/herdr-app/bin/executable_wt-app`, `executable_claude-app`, `executable_open-space`, `executable_close-own-tab`, `dot_config/herdr-app/programs.json.tmpl`
- Test: `tests/herdr-app.test.sh`

**Interfaces:**
- Consumes: `dev`'s app path (Task 2): `DEV_OPEN_SPACE` names the `open-space` it runs.
- Produces: compatibility wrappers per §5.6; `open-space`/`close-own-tab` with a pinned PATH.

- [ ] **Step 1: Write the failing cases.** First the fixture: once `open-space` and `close-own-tab` pin PATH, the suite's stubs on the caller's PATH no longer reach them. The suite's scratch `HOME` gets a `.local/bin` holding the trusted stubs (`herdr-app`, `hc`, `fzf`, `claude`, `wt-rm`), exported `HOME` covers every case, and `DEV_OPEN_SPACE` points at the rendered `open-space`, so `wt-app` → `wt` → `dev` runs the script under test. Then, in `herdr-app.test.sh`:
  - `wt-app --no-focus newbranch` creates the checkout through `wt`: the stub log shows `space.new` for `<dest>` and the focus given back, as today.
  - `wt-app --prompt` with `newbranch` on stdin closes its own tab (`tab.close` logged).
  - `claude-app --x y` starts `claude --x y` and nothing else.
  - A new space's Claude tab argv is `["claude"]`; the reopen default too; `programs.json` renders with no `claude` override.
  - `open-space` and `close-own-tab`, run with a PATH whose first folder shadows `herdr-app` and `jq` with marker-touching stubs: each succeeds, the trusted stub log shows its expected calls (`space.new`/`pane.split`, `tab.close`), and the marker never appears.

- [ ] **Step 2: Run and see them fail.** Run: `./tests/run.sh herdr-app`. Expected: the new cases FAIL.

- [ ] **Step 3: Implement** per §5.6:
  - `wt-app`: `--prompt`/`--no-focus` handling as now; source `~/.config/zsh/functions` and call `wt ${nofocus:+--no-focus} "$@"`; close the tab as now. Caller PATH kept.
  - `claude-app`: `exec claude "$@"`.
  - `open-space` and `close-own-tab`: the pinned PATH as their first command.
  - `open-space`'s Claude argv and the reopen default: `claude`.
  - `programs.json.tmpl`: drop the `claude` override.
  - Comments: each wrapper says it remains for sessions recorded with its path, until the TUI is retired (§5.7).

- [ ] **Step 4: Run and see them pass.** Run: `./tests/run.sh herdr-app`. Expected: PASS.

- [ ] **Step 5: Commit.** `git add dot_config/herdr-app tests/herdr-app.test.sh tests/fixtures/herdr-app` then `git commit -m "Shrink the Herdr app's wt and claude adapters to wrappers and pin the app scripts' PATH"`.

### Task 7: Pre-merge verification (controller)

**Depends on:** Tasks 1-6

- [ ] **Step 1:** Run `./tests/run.sh --changed` from this session's app terminal; quote the `needs: heavy` lines. Expected: every suite PASS or its documented gate.
- [ ] **Step 2:** `command chezmoi --source <checkout> apply --dry-run --verbose` shows `~/.local/bin/xreview-app-pane` added, `~/.config/herdr-app/xreview-shim/herdr` removed, and the wrapper changes; nothing else unexpected.
- [ ] **Step 3:** Cross-review (pre-merge), PR with the acceptance checklist of spec §7 as unchecked items and the `wt-rm` command for the checkout, per the global instructions.
