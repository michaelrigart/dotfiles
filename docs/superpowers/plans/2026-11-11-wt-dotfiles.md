# `wt` Checkouts for the Dotfiles Implementation Plan

**Status:** Implemented (branch `feat/wt-dotfiles`; the dotfiles have no MR); executed once, do not run again. The Rulings at the end record where the run departed from the text below.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dotfiles `wt` sibling (`~/.local/share/chezmoi-<branch>`) gets the same sandbox protection as a `~/Code` repository, the suites test the checkout they run from, and the instructions make every dotfiles branch a `wt` checkout.

**Architecture:** One new work root, `~/.local/share/chezmoi-*`, joins `allowWrite` and the `$roots` list that every root-keyed `denyWrite` entry is built from, plus one denial beyond parity (the sibling's top-level `.git` file). The settings suite pins the shape; the live write-boundary suite probes a sibling; two budget-capped `claude -p` runs measure whether `allowWrite` honours the glob. The instruction text changes last, so the line runs under the rules it replaces.

**Tech Stack:** jq inside the chezmoi `modify_` script; bash test suites run through `./tests/run.sh`; `claude -p --settings` for the measurement.

**Spec:** `docs/superpowers/specs/2026-11-11-wt-dotfiles-design.md` (signed off 2026-11-11, Codex `xr-1794356582-1589df6b`).

## Global Constraints

- The new root is exactly `~/.local/share/chezmoi-*`. No grant wider than that: `~/.local/share` holds mise runtimes and other executables.
- No change to `wt`, `dev`, `wt-rm`, `layout.sh` or `xreview`. No new permission rule of any kind (no new prompt).
- A sibling ends with every denial a `~/Code` repository has, plus `~/.local/share/chezmoi-*/.git`.
- Specs and plans are permanent. The only spec edits are its Status line and section 4's measured results, recorded in section 1.
- Suites are executed (`./tests/<name>.test.sh` or `./tests/run.sh <name>`), never through an interpreter. Report results as passed/total.
- Never start a Bash call with `cd`; use absolute paths or `git -C`.
- Implementers do not commit. They run only their task's suites and report. The controller re-checks `git -C /Users/michael/.local/share/chezmoi-feat-wt-dotfiles branch --show-current` (must be `feat/wt-dotfiles`) and commits each task.
- `live-write-boundary` runs sandboxed only, never with the sandbox off.
- `chezmoi apply`, `wt-rm` and merging are Michael's. This repo is public: nothing private in any file.
- This line is the `wt` path's live check: report every permission prompt, classifier denial, sandbox denial in this checkout or pane problem. When a step of the `wt` path fails, stop and report to the driver (`chezmoi-c2`) rather than work around it.

## Review Focus

1. A path that only resembles a sibling (`~/.local/share/chezmoifoo/x`, `~/.local/share/x-chezmoi-y/f`, `~/.local/share/mise/installs/x`) gets no write grant (Task 1, allowWrite semantics).
2. A sibling-shaped symlink to `~/.config` gives no write into `~/.config` (Task 2, `sibling_symlink_escape`).
3. A sibling probe whose ordinary write fails never reads as a pass: INCONCLUSIVE, and the sibling denial probes are not reported DENIED (Task 2, cases W2 and W4).
4. A future sibling pre-created by a sandboxed command cannot be seeded with agent configuration: the deny globs match any `chezmoi-*` name (Task 1 samples under `chezmoi-not-yet`; Task 2 scratch mode).
5. A repository nested deeper inside a sibling keeps its `.git`, objects and index writable; only the sibling's own top-level `.git` is denied (Task 1, allowed samples).

## Calls made in this plan, not in the spec

- The sibling `.git` entry is appended last to the top-level `.git` list in both the script and the suite.
- The live probe picks its sibling this way: a session started inside `~/.local/share/chezmoi-<x>` probes that checkout ("existing" mode); any other session creates `~/.local/share/chezmoi-<stamp>` ("scratch" mode), which cleanup removes.
- An ordinary write into the sibling that fails prints `sibling_write=DENIED` and an `INCONCLUSIVE:` line, and skips the sibling battery. That key is not counted as a failure. The suite exits 2 only when nothing else failed. Otherwise it exits with its failure count, and the `INCONCLUSIVE:` line comes before `failed_keys=`, which stays last. Through `run.sh` a kv suite with a non-zero exit is a FAIL row either way, so it is never a pass.
- `write-boundary-probe` follows. It does not mirror the root list, but the sibling choice and the INCONCLUSIVE path are logic that can be checked against a throwaway HOME. The exit-2 branch itself cannot be checked there, because every other key fails in a throwaway HOME, so review covers it.
- Suite audit outcomes. `codex-daemon` and `unifi-network-mcp` gain `--source`. `claude-settings` is kept: a pure filter read from `$SRC`, whose HOME paths are samples. `live-write-boundary` measures the main root on purpose and gains the sibling probe. `write-boundary-probe` is kept: it uses a throwaway HOME. `process-replay/t_*.py` are kept: their `~/.local/share/chezmoi` strings are leak-detection fixtures, and no source file is read through them.
- `global.md` names the sibling path only if the `wt` bullet keeps its current line count; `AGENTS.md` names it either way.
- Section 4's runs add a few things to the spec's design:
  - Each probe command ends with a working-directory write as its completion marker.
  - A run counts as executed only when its transcript shows the exact command and the marker exists.
  - Run B also probes `.git`.
  - Both runs pass `--disallowedTools Write,Edit,NotebookEdit`, so only sandboxed Bash can write.
  - An INCONCLUSIVE run is repeated once.

---

### Task 1: The fifth sandbox root and its settings tests

**Depends on:** none.

**Files:**
- Modify: `dot_claude/modify_private_settings.json:439-519`
- Test: `tests/claude-settings.test.sh:408-580`

**Interfaces:**
- Produces: emitted settings whose `.sandbox.filesystem.allowWrite` is `["~/Code","~/.local/share/chezmoi","~/.local/share/chezmoi-*","~/Documents","~/Library/Mobile Documents/iCloud~md~obsidian"]` and whose `denyWrite` is built from `$roots` in that same order, with `"~/.local/share/chezmoi-*/.git"` appended to the top-level `.git` list. Task 4 uses `printf '{}' | HOME="$HOME" /bin/bash dot_claude/modify_private_settings.json` as its overlay source.

- [ ] **Step 1: Update the expectations so they fail**
  - `EXP_ALLOW_WRITE` and `ROOTS` gain `"~/.local/share/chezmoi-*"` right after `"~/.local/share/chezmoi"`. `EXP_DENY_WRITE`'s top-level `.git` list becomes `["~/Code/.git", "~/Documents/.git", "~/Library/Mobile Documents/iCloud~md~obsidian/**/.git", "~/.local/share/chezmoi-*/.git"]`.
  - Counts: denyWrite `213` → `264`; harness worktree entries `72` → `90` (label: 5 roots x (5 agent paths + the .git file) x 3 depths); lazygit and glab `16` → `20`; glab `8` → `10`; entries ending in `/.git` `15` → `19`. The sorted top-level `.git` list is `["~/.local/share/chezmoi-*/.git","~/Code/.git","~/Documents/.git","~/Library/Mobile Documents/iCloud~md~obsidian/**/.git"]`. Labels that count roots say five, not four.
  - Glob samples, with `S="$H/.local/share/chezmoi-feat-x"`:
    - denied: `$S/.mcp.json`, `$S/.codex/config.toml`, `$S/.claude/settings.local.json`, `$S/.claude/worktrees/agent-1/.git`, `$S/.claude/worktrees/agent-1/.mcp.json`, `$S/.git`, `$S/Org/repo/.git/hooks/pre-commit`, and `$H/.local/share/chezmoi-not-yet/.claude/settings.json` (Review Focus 4).
    - allowed: `$S/README.md`, `$S/tests/fixtures/r/.git`, `$S/tests/fixtures/r/.git/objects/ab/cd` and `$S/tests/fixtures/r/.git/index` (Review Focus 5).
    - `$S` joins the lazygit and glab root loop (line 545).
  - New allowWrite semantics check (Review Focus 1). Run the same `GLOB_RX` over `.sandbox.filesystem.allowWrite` as `glob_granted <path>`:
    - granted: `$H/.local/share/chezmoi-feat-x/f`;
    - not granted: `$H/.local/share/chezmoifoo/x`, `$H/.local/share/x-chezmoi-y/f`, `$H/.local/share/mise/installs/x` and `$H/.local/bin/x`.
- [ ] **Step 2: Run and watch it fail.** `./tests/claude-settings.test.sh` → FAIL on the exact-array, count and new sample assertions. A cold external cache gives exit 2 with an `INCONCLUSIVE:` line instead. Warm it outside the sandbox with `command chezmoi --source /Users/michael/.local/share/chezmoi-feat-wt-dotfiles managed >/dev/null` and rerun.
- [ ] **Step 3: Implement.**
  - Add `"~/.local/share/chezmoi-*"` to `allowWrite` and to `$roots` (after `~/.local/share/chezmoi` in both), and append `"~/.local/share/chezmoi-*/.git"` to the top-level `.git` list.
  - Comments:
    - The `allowWrite` comment names the `wt` siblings and why the grant is no wider.
    - The "where sessions start" list names a dotfiles `wt` sibling.
    - The `.git` comment covers the sibling `.git` denial. Every match there is a linked-worktree `.git` file, denied so that one session cannot repoint another's checkout. Its cost: a sandboxed `git worktree repair` or `move` in a sibling fails.
- [ ] **Step 4: Run and watch it pass.** `./tests/run.sh claude-settings` → `ok`, passed/total reported.

### Task 2: The live sibling probe

**Depends on:** none.

**Files:**
- Modify: `tests/live-write-boundary.test.sh`
- Test: `tests/write-boundary-probe.test.sh`

**Interfaces:**
- Produces keys:
  - `sibling_write` (WRITABLE or DENIED);
  - the root-loop battery with `k=sibling` (`sibling_git_hooks` … `sibling_lazygit_dotfile`);
  - `sibling_git_file`;
  - `sibling_symlink_escape`.
- In existing mode `sibling_git_file` is checked with `denied_existing "$sib/.git"`; in scratch mode with `denied "$sib/.git"`. When `sibling_write=DENIED`, `sibling_git_file=SKIPPED` is printed and the battery is not run.
- The INCONCLUSIVE line starts `INCONCLUSIVE: sibling:`, names the path whose write failed, and says to run from a session started in a sibling.

- [ ] **Step 1: Write the failing probe-suite cases** in `write-boundary-probe.test.sh`. Extend the `mkdir` stub: with `STUB_SIBLING_MSG` set, it refuses any argument matching `*/.local/share/chezmoi-*` with that message. Cases, against the existing throwaway HOME `$H`:
  - **W1 scratch sibling** (start `$T/start`):
    - output has `sibling_write=WRITABLE` and a `sibling_mcp_json=` line that is not `SKIPPED`;
    - after the run, `$H/.local/share` holds no `chezmoi-zz-write-boundary-*` entry (link included).
  - **W2 refused sibling** (`STUB_SIBLING_MSG="Operation not permitted"`, start `$T/start`):
    - `sibling_write=DENIED`, an `INCONCLUSIVE: sibling:` line, `sibling_git_file=SKIPPED`, and no `sibling_mcp_json=` line;
    - `failed_keys=` does not list `sibling_write`, and stays the last line, after the INCONCLUSIVE line.
  - **W3 session in a sibling** (start `$H/.local/share/chezmoi-wt`, holding a `.git` file `gitdir: /nowhere`):
    - `sibling_write=WRITABLE`;
    - a `sibling_git_file=` line that is not `SKIPPED` or `ABSENT`;
    - the `.git` file is byte-identical afterwards, and no `chezmoi-zz-write-boundary-*` directory was ever made (the stub logs `mkdir` arguments to `$T/mkdir.log`; check it).
  - **W4 read-only session sibling** (W3's directory at `chmod 555`, restored in the trap): `sibling_write=DENIED` and an `INCONCLUSIVE: sibling:` line.
- [ ] **Step 2: Run and watch them fail.** `./tests/write-boundary-probe.test.sh` → W1–W4 FAIL (no `sibling_*` keys yet); the existing cases still pass.
- [ ] **Step 3: Implement in `live-write-boundary.test.sh`.**
  - Choose the sibling as set out under "Calls made". In scratch mode, add `$sib` to `probes` before `mkdir`.
  - Write `$sib/$stamp-w` as the ordinary write. On success, run the root-loop battery with `root=$sib` and `k=sibling`, non-vault and not `~/Code`.
  - `sibling_symlink_escape`, run in both modes:
    - add `$HOME/.local/share/chezmoi-$stamp-link` and `$HOME/.config/$stamp` to `probes`;
    - `ln -s "$HOME/.config"` at the link. If `ln` fails, the key reads DENIED;
    - otherwise creating `link/$stamp` must fail: DENIED passes, WRITABLE counts as a failure.
  - `cleanup` prints the INCONCLUSIVE line before `failed_keys=`, and exits 2 when `fail=0` and the sibling was inconclusive.
  - Extend the header comment to cover the sibling probe.
- [ ] **Step 4: Run and watch them pass.** `./tests/run.sh write-boundary-probe` → `ok`, passed/total.
- [ ] **Step 5: The live probe catches a sibling without denials.** Run `./tests/run.sh live-write-boundary` sandboxed from this session; the exact name lifts its gate. This session started in the sibling and the deployed settings predate this branch, so expect:
  - a FAIL row whose `failed_keys` holds `sibling_*` denial keys and no other key, with `sibling_write=WRITABLE`;
  - `sibling_symlink_escape=DENIED`, since the deployed settings cannot create another sibling.
  Report the exact `failed_keys` line. Any non-sibling key there means the deployed settings differ from main: report it, don't fix it.

### Task 3: Suites render from the checkout they run from

**Depends on:** none.

**Files:**
- Modify: `tests/codex-daemon.test.sh:194,198`, `tests/unifi-network-mcp.test.sh:114`

- [ ] **Step 1: Write the failing case in each suite**, named "renders from the checkout it runs from, not the default source".
  - Make a decoy default source `$T/decoy/chezmoi/.chezmoidata/broken.toml` containing `= not toml`.
  - Run the suite's existing render command with `XDG_DATA_HOME="$T/decoy"` and assert it still renders. In codex-daemon, also run `plutil -lint` on the output; in unifi-network-mcp, the existing value checks.
- [ ] **Step 2: Run and watch them fail.** `./tests/codex-daemon.test.sh` and `./tests/unifi-network-mcp.test.sh` → the new case FAILs: without `--source`, chezmoi reads the decoy. If it passes, the decoy does not reach `execute-template`. Pick one that does (a broken `.chezmoi.toml.tmpl` or `.chezmoitemplates` entry in the decoy), and say which.
- [ ] **Step 3: Implement.** Add `--source "$ROOT"` (codex-daemon's variable for the checkout) to both renders at lines 194 and 198, and `--source "$SRC"` to the unifi render at line 114.
- [ ] **Step 4: Run and watch them pass.** `./tests/run.sh codex-daemon unifi-network-mcp` → both `ok`, passed/total.
- [ ] **Step 5: Confirm the kept outcomes.** Check the "Calls made" claims:
  - `rg -n 'local/share/chezmoi' tests/process-replay` shows only fixture strings;
  - every other `chezmoi` render or `managed` call in `tests/*.sh`, `chezmoi-wrapper`'s stub aside, already passes `--source`.
  Report any exception rather than fixing it outside this task.

### Task 4: Measure the settings (spec section 4)

**Depends on:** Task 1. Run by `sp-standard`. `claude` and the scratch sibling's `mkdir`/`rm` run unsandboxed after a sandboxed attempt fails with sandbox evidence.

**Files:**
- Modify: `docs/superpowers/specs/2026-11-11-wt-dotfiles-design.md` (section 1, the "Whether `allowWrite` honours a glob" bullet only)
- Conditional: `dot_claude/modify_private_settings.json`, `tests/claude-settings.test.sh` (step 7)

- [ ] **Step 1: Preconditions.**
  - `jq '[.sandbox.filesystem.allowWrite[], .sandbox.filesystem.denyWrite[]] | map(select(startswith("~/.local/share/chezmoi-"))) | length' ~/.claude/settings.json` prints `0`. The deployed settings predate this branch, so any sibling denial in run B is the overlay's.
  - Record `claude --version`.
- [ ] **Step 2: Overlay.**
  - In the scratchpad, write `overlay.json` = `printf '{}' | HOME="$HOME" /bin/bash dot_claude/modify_private_settings.json | jq '{sandbox: (.sandbox | .allowUnsandboxedCommands = false)}'`.
  - `jq -e '.sandbox.filesystem.allowWrite | index("~/.local/share/chezmoi-*")' overlay.json` succeeds.
- [ ] **Step 3: Scratch directories.**
  - `P="$HOME/.local/share/chezmoi-zz-wt-probe-$$"` and `A="$HOME/Code/zz-wt-probe-a-$$"`.
  - `mkdir -p "$P/.codex" "$A"`. The `.codex` directory pre-exists so that `.codex/**` is what gets measured.
- [ ] **Step 4: Run A** (working directory `$A`).
  - Probe command, exactly: `touch $P/a-ordinary; touch ./a-done`, with `$P` expanded. The probes are joined by `;`, so each runs whatever the one before it did, and the working-directory marker comes last.
  - Run: `claude -p "Use only the Bash tool. Run exactly this one command, unchanged, then stop: <probe command>"`, with `--settings overlay.json --permission-mode default --disallowedTools Write,Edit,NotebookEdit --output-format stream-json --verbose --max-turns 3 --max-budget-usd 1 --no-session-persistence --model sonnet </dev/null`. Keep stdout and stderr.
  - **Ran:** the stream holds exactly one Bash `tool_use`, its `input.command` equals the probe command byte for byte, and `$A/a-done` exists. Anything else is INCONCLUSIVE: repeat once, then report it.
  - Verdict, from the filesystem:
    - **settings loaded:** exit 0, the final `result` event has `subtype == "success"`, and stderr carries no settings error;
    - **glob honoured:** `$P/a-ordinary` exists; absent means ignored or taken literally.
- [ ] **Step 5: Run B** (working directory `$P`, same flags).
  - Probe command, exactly: `touch ./.mcp.json; touch ./.codex/config.toml; touch ./.lazygit.yml; touch ./.git; touch ./b-ordinary`. The ordinary write comes last and is both the working-directory grant and the completion marker.
  - **Ran:** the same transcript check as run A, with `$P/b-ordinary` as the marker. Without both, the run measured nothing: repeat once, then report INCONCLUSIVE.
  - Verdict: `.mcp.json`, `.codex/config.toml`, `.lazygit.yml` and `.git` must all be absent.
- [ ] **Step 6: Stop conditions.** Stop and report to the controller, who reports to `chezmoi-c2`, if:
  - either run shows the settings failed to load (spec: Michael chooses options);
  - any run-B probe file exists;
  - either run stays INCONCLUSIVE.
- [ ] **Step 7: Only if run A found the glob ignored.**
  - Drop `"~/.local/share/chezmoi-*"` from `allowWrite` alone; `$roots` and the `.git` entry stay.
  - `EXP_ALLOW_WRITE` goes back to the four roots, and the allowWrite semantics check expects `chezmoi-feat-x/f` not granted.
  - The `allowWrite` comment says a sibling is written only by its own session's working-directory grant.
  - Run `./tests/run.sh claude-settings`.
- [ ] **Step 8: Record.** Under the section 1 glob bullet, add one sub-bullet "Measured 2026-11-11 (Claude Code `<version>`)" that gives:
  - run A's result and the decision kept or taken;
  - run B's five probe results;
  - one line on how they were run (overlay from the modify script, `allowUnsandboxedCommands: false`, verdict from the filesystem).
- [ ] **Step 9: Clean up.** `rm -rf "$P" "$A"`. If that is refused, put the exact command in the report.

### Task 5: Instruction text

**Depends on:** Task 4. This is the last task, per spec section 5.

**Files:**
- Modify: `.chezmoitemplates/agents/global.md:21-32`, `.chezmoitemplates/agents/claude-code.md:31`, `AGENTS.md:20-29,44-46`
- Sweep: `README.md`. Its `~/.local/share/chezmoi` lines are provisioning steps for the main checkout and stay; change only what the sweep finds.
- Test: `tests/agent-instructions.test.sh:246-247,260,280-281`

- [ ] **Step 1: Change the pins so they fail.**
  - Replace the pin at 246 with `need_flat global.md 'Every new branch in `~/Code` or the dotfiles is one, small changes included: never a plain branch (`git switch -c`) or a harness worktree there, and `using-git-worktrees` takes `wt` as declared, without asking.'`.
  - Turn the pin at 260 into an absence check on `The dotfiles never use` (label: "global.md no longer keeps wt out of the dotfiles").
  - Replace the pin at 280 with `need_flat claude-code.md 'A plan runs entirely in its line'"'"'s checkout; never create a worktree for one of its tasks.'`, plus an absence check on `(dotfiles: a harness worktree)`.
  - Add `need_flat global.md 'For the dotfiles, the pushed branch is the end.'`.
  - Keep `Harness worktrees follow their tool's lifecycle.` pinned.
- [ ] **Step 2: Run and watch it fail.** `./tests/agent-instructions.test.sh` → the three changed pins FAIL; the Finishing pin passes.
- [ ] **Step 3: Implement.**
  - `global.md`:
    - the scope sentence becomes the pinned one;
    - `The dotfiles never use \`wt\`.` goes;
    - the sibling path `~/.local/share/chezmoi-<branch>` is named only if the bullet keeps its line count;
    - the file stays at 150 lines or fewer, each at most 100 characters.
  - `claude-code.md`: drop `(dotfiles: a harness worktree)`, keeping 50 lines or fewer.
  - `AGENTS.md`, shared-checkout bullet:
    - the main checkout `~/.local/share/chezmoi` stays on `main`, never switched, because Michael applies from it;
    - every branch is a `wt` checkout at `~/.local/share/chezmoi-<branch>`, run by its own session with its own Codex pane;
    - the harness-worktree clause goes.
  - `AGENTS.md`, preview bullet: in a sibling, previews are `command chezmoi --source <checkout> cat <target>` and `… apply --dry-run --verbose`, because a bare `command chezmoi` renders the main checkout.
  - Grep `tests/` for any pin on the replaced `AGENTS.md` text and update it.
- [ ] **Step 4: Run and watch it pass.** `./tests/run.sh agent-instructions` → `ok`, passed/total.

---

## Finishing (the controller, after Task 5)

1. Full suite `./tests/run.sh`, then `./tests/run.sh xreview git-forge-guard wt-functions`, both on the final commit; report passed/total per run.
2. Final whole-branch review (`sp-architect`), then Codex pre-merge: `xreview -C /Users/michael/.local/share/chezmoi-feat-wt-dotfiles dispatch --checkpoint pre-merge --diff main...feat/wt-dotfiles`. Iterate to approval. Fix every finding in its round.
3. Final pre-merge commit: spec and plan `**Status:** Implemented (branch \`feat/wt-dotfiles\`; the dotfiles have no MR)`, the plan marked executed once, and Rulings filled in. A commit after the last review needs a new review.
4. `git -C /Users/michael/.local/share/chezmoi-feat-wt-dotfiles push origin feat/wt-dotfiles`, in its own Bash call.
5. Report to `chezmoi-c2`. After the merge, Michael runs `chezmoi apply`, `./tests/run.sh live-write-boundary` sandboxed in a fresh session, and `wt-rm feat/wt-dotfiles`.

## Rulings

Made during the run, each with its reason. Plan review approved: `xr-1794357300-27308c6f`.

1. **Measured result.** Run A found that `allowWrite` does not honour the `chezmoi-*` glob. Step 7 therefore ran: the entry left `allowWrite` and stays in `$roots`, the sibling `.git` denial stays, and the spec's section 1 records both runs. A sibling is written only by its own session.
2. **Post-merge check, replacing Finishing step 5's "a fresh session".** The sibling probe measures only from a session started in a sibling. From anywhere else it reads FAIL (exit 2) with an `INCONCLUSIVE: sibling:` line. A sibling session that predates the apply shows the pre-apply `sibling_*` failures. Michael's order:
   1. `chezmoi apply`.
   2. Quit and restart Claude Code in `~/.local/share/chezmoi-feat-wt-dotfiles`.
   3. `./tests/run.sh live-write-boundary`, sandboxed. Expect `ok`, with `sibling_write=WRITABLE` and no `failed_keys`.
   4. Only then `wt-rm feat/wt-dotfiles`. After that, the check needs a throwaway `wt` line.
3. **Run B attribution.** With no overlay, Claude Code already denies `.mcp.json`, `.git/config*` and the checkout's `.git` file under a session's working directory. Task 2 measured this before the apply. Run B's verdict that the root-keyed denials bite therefore rests on `.codex/config.toml` and `.lazygit.yml`, as section 1 says. This also shows that the spec's background line ("Claude Code's built-in denial covers only the session's own `.claude/settings*.json`") is incomplete. It has no design consequence, and the spec otherwise stays as signed off.
4. **run.sh.** Under a kv suite's FAIL row, `tests/run.sh` now prints that suite's `INCONCLUSIVE:` lines, so an inconclusive sibling run explains itself. This adds files to Task 2's list (`tests/run.sh`, `tests/run.test.sh`). No kv value is echoed, because only INCONCLUSIVE lines and their indented continuations are shown, and of the four kv suites only `live-write-boundary` prints one.
5. **Task 5 wording.** The cap ruled for `global.md`: naming the sibling path made it 151 lines, so `global.md` says "a sibling checkout `<repo>-<branch>` beside the main one" and `AGENTS.md` names `~/.local/share/chezmoi-<branch>`. `README.md` keeps its "Managing Dotfiles" example, which is Michael's own flow on `main` and needs no branch switch.
6. **Batch and commits.** Tasks 1–3 ran as one parallel batch, under the global "Parallel tasks" rule. Implementers did not commit; the controller committed each task and each fix round.
7. **Minor findings left.**
   - The decoy setup is duplicated in two standalone suites (codex-daemon and unifi-network-mcp).
   - Under a kv FAIL row, `run.sh` prints the INCONCLUSIVE line after `failed_keys`.
   - A ragged comment wrap in `tests/claude-settings.test.sh`.
   All are display or comment only; the final review triaged them as leave.
8. **Process.**
   - Task 5's third fix round was a pure reflow. The controller checked it with a word diff instead of a reviewer seat, and the final review covers it.
   - This Status and these Rulings were committed before the Codex pre-merge review, not after it, so the approved commit is the last one.
