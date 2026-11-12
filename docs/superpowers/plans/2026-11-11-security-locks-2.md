# Security locks 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented (branch `fix/security-locks`; the dotfiles use no MR). Completed 2026-11-12; do not run this plan again.

**Goal:** Close the six repository-side gaps of the 2026-11-11 setup review: `op-edit` plaintext in Neovim state, world-readable Bundler tokens, an unsandboxed fallback, the Codex daemon pin wording, the unpinned ha-mcp, and the apply-window guard's wildcard matcher.

**Architecture:** Five independent edits to existing files, each pinned by one assertion in the suite that already owns the file (one new suite, for `op-edit`). No new mechanism; nothing is deployed from the branch.

**Tech Stack:** chezmoi source files, zsh functions, POSIX sh launcher, a bash `modify_` script emitting JSON through `jq`, bash and zsh test suites under `tests/`.

**Spec:** `docs/superpowers/specs/2026-11-11-security-locks-2-design.md` (Approved 2026-11-11; decisions D1-D5 at their defaults).

## Global Constraints

- Scope is the spec's six repository changes only. Item 7 (sshd) has no code. Item 4 under D2-A has no repository file beyond the `AGENTS.md` wording; option B is not built.
- Zero new permission prompts: no `ask` rule is added anywhere.
- One test per behaviour change, as the spec names it. A review finding gets code only when a real caller can reach it; otherwise it becomes a line under Rulings.
- This repository is public: no token, hostname or private path beyond those already in the tree.
- Suites are executed (`./tests/<name>.test.sh` or `./tests/run.sh <name>`), never run through an interpreter prefix. No `cd … &&` compounds; use paths relative to the checkout or `git -C`.
- Tasks 1-4 are one batch: no dependency between them, disjoint files, no shared test resource. Their implementers are dispatched together in this checkout, do not commit and run only their focused suite. The controller then commits the tasks one at a time (staging only that task's files), reviews each on exactly its commit, and runs `./tests/run.sh` once for the batch. Task 5 follows, then Task 6. Commit messages are imperative, with no agent attribution.
- Another branch (`fable-review`) adds a `.sandbox.enabled` assertion to `tests/claude-settings.test.sh`: do not add one here.
- No comments or docs beyond the ones a step names.

## Review Focus

Checked against the spec; each line is a condition no task's test exercises.

1. **A live `~/.claude/settings.json` that already carries `"failIfUnavailable": false`.** Expected: the render still says true. Covered without a new test: the template replaces the `sandbox` key wholesale (its header comment), and Task 1's assertion reads the rendered block.
2. **`op-edit` on a machine or SSH session where `EDITOR` is `vim`.** Expected: `nvim` with the flags still runs. Task 3's test asserts it.
3. **A hook matcher written as a pipe list rather than a regex.** Expected: Claude Code 2.1.322 fires the guard on `Edit`, `Write` and `NotebookEdit`. No suite can observe the harness; the reviewer checks the string is exactly `Edit|Write|NotebookEdit`, the script's own set (`executable_xreview-apply-guard.sh:54`).
4. **Bundler under the sandbox after the deny.** Expected: it skips the unreadable file silently and `pg` still builds from the `zshenv` export. Inferred in the spec; verified after apply, not on the branch.
5. **The deployed file's mode after the rename.** Expected: 0600. A suite could only pin the file name; Michael's after-apply `stat` checks it.

---

### Task 1: Settings template: sandbox fail-closed, Bundler denies, guard matcher

**Depends on:** none

**Files:**
- Modify: `dot_claude/modify_private_settings.json` (deny list near `:132-135`; hook comments `:313-315`, `:324-326`; matcher `:347`; sandbox block `:371-379`; `credentials.files` `:381-399`)
- Modify: `tests/xreview-apply-guard.test.sh:4` (comment only)
- Test: `tests/claude-settings.test.sh` (`EXP_DENY` `:25`, `EXP_CREDENTIALS` `:339`, matcher pin `:816-819`)

- [ ] **Step 1: Write the failing assertions** in `tests/claude-settings.test.sh`:
  - `EXP_DENY` gains `"Read(~/.config/bundler/**)","Edit(~/.config/bundler/**)"` after the unifi-network pair.
  - `EXP_CREDENTIALS` gains `"~/.config/bundler/config"` after `"~/.config/unifi-network/env"`.
  - Beside the existing sandbox assertions of section F: `jq_is '.sandbox.failIfUnavailable' true "the sandbox refuses to run commands unsandboxed when it cannot start"`.
  - The apply-guard pin expects `Edit|Write|NotebookEdit`; its label becomes `xreview-apply-guard runs once, on the tools it inspects` and the comment above it says so.
- [ ] **Step 2: Run** `./tests/claude-settings.test.sh`. Expected: exactly four new failures (deny array, credentials list, `failIfUnavailable` null, matcher `*`).
- [ ] **Step 3: Change the template.**
  - Deny list: `"Read(~/.config/bundler/**)", "Edit(~/.config/bundler/**)"` after the unifi-network pair, under a comment `# Bundler's forge tokens, rendered by chezmoi`.
  - `credentials.files`: `{ "path": "~/.config/bundler/config", "mode": "deny" }` after the unifi-network entry.
  - Sandbox block: `"failIfUnavailable": true` after `"enabled": true`, with a comment saying that without it a sandbox that cannot start only warns and commands run unsandboxed, and that the key is never removed to get going again.
  - Apply-window guard entry: matcher `Edit|Write|NotebookEdit`.
  - The two comments that explain the wildcard now say the matcher is the script's own tool set; the fail-open sentence keeps its conclusion (D5) and gives the spec's reason: any Bash write bypasses the guard, so failing closed would protect nothing.
  - `tests/xreview-apply-guard.test.sh:4`: the header no longer says "wildcard matcher … every tool call"; it says the guard runs on every Edit, Write and NotebookEdit call. The inert-case reasoning stays.
- [ ] **Step 4: Run** `./tests/claude-settings.test.sh` and `./tests/xreview-apply-guard.test.sh`. Expected: both exit 0, no failures.

Commit (controller): `Fail closed without a sandbox, deny Bundler's config and narrow the apply guard's matcher`

### Task 2: Bundler config: private file, non-secret keys in zshenv

**Depends on:** none

**Files:**
- Rename: `dot_config/bundler/config.tmpl` → `dot_config/bundler/private_config.tmpl` (`git mv`)
- Modify: `dot_config/zsh/zshenv` (the "Bundler config vars" block, `:55-58`)
- Test: `tests/zshenv.test.sh`

- [ ] **Step 1: Write the failing assertions** in `tests/zshenv.test.sh`, using its `probe` helper to read the environment a child process receives, not the shell variable: `probe '/usr/bin/printenv BUNDLE_JOBS'` prints `8` and `probe '/usr/bin/printenv BUNDLE_BUILD__PG'` prints `--with-opt-dir=/opt/homebrew/opt/libpq` (an assignment without `export` must fail them). Labels: `zshenv exports BUNDLE_JOBS` and `zshenv exports the pg build option`.
- [ ] **Step 2: Run** `./tests/zshenv.test.sh`. Expected: the two new assertions fail with empty values.
- [ ] **Step 3: Implement.**
  - `git mv dot_config/bundler/config.tmpl dot_config/bundler/private_config.tmpl`.
  - Remove the `BUNDLE_BUILD__PG` and `BUNDLE_JOBS` lines from the template; the YAML header and the two token lines stay byte-identical.
  - `zshenv`: `export BUNDLE_JOBS=8` and `export BUNDLE_BUILD__PG="--with-opt-dir=/opt/homebrew/opt/libpq"` in the Bundler block, with one comment line: the non-secret settings live here because the user config holds tokens and is unreadable in the agent sandbox.
- [ ] **Step 4: Run** `./tests/zshenv.test.sh`; expected exit 0. Then `grep -c onepasswordRead dot_config/bundler/private_config.tmpl` prints 2, and `git status --short` shows a rename, not a delete plus an untracked file.

Commit (controller), after `git diff --cached` shows no secret: `Render Bundler's config private and move its non-secret keys to zshenv`

### Task 3: `op-edit` keeps the note out of Neovim's state

**Depends on:** none

**Files:**
- Modify: `dot_config/zsh/functions` (`op-edit`: header comment `:17-18`, editor call `:67`)
- Create: `tests/op-edit.test.sh` (zsh, mode 755)

- [ ] **Step 1: Write the failing suite** `tests/op-edit.test.sh`, on the pattern of `tests/chezmoi-wrapper.test.sh` (zsh shebang, `emulate -L zsh`, `SRC=${0:A:h:h}`, exit 2 when `$FUNCS` is missing, `_pass`/`_fail`, a temp dir removed on EXIT, `path=($T/bin /usr/bin /bin)`, `source $FUNCS`). Stubs in `$T/bin`:
  - `chezmoi`: `source-path` with no argument prints `$T/src`; `source-path <arg>` exits 1 (so the argument is taken as an item name); anything else exits 0.
  - `op`: `read` prints a fixed note body; `item edit` exits 0.
  - `nvim` and `vim`: each appends its own name and its arguments, one per line, to `$T/argv`, then appends a line to its last argument (the temp file) so `op-edit` sees a change.
  Assertions, after `op-edit "Some note"` with `EDITOR=nvim`, and again with `EDITOR=vim`:
  - the recorded program is `nvim` (never `vim`);
  - argv contains `-n`;
  - argv contains `-i` immediately followed by `NONE`;
  - argv contains `-c` immediately followed by an argument that includes `noundofile`;
  - the last argument is the temp file, preceded by `--`.
- [ ] **Step 2: Run** `./tests/op-edit.test.sh`. Expected: the flag assertions fail (argv is the path alone), and the `EDITOR=vim` case records `vim`.
- [ ] **Step 3: Implement** in `op-edit`: the editor call becomes `nvim -n -i NONE -c 'set noundofile nobackup nowritebackup' -- "$tmp"`, no `$EDITOR`. The header comment gains one sentence: the editor is always Neovim, started without swap, ShaDa, undo or backup files, so the note's text stays out of Neovim's state.
- [ ] **Step 4: Run** `./tests/op-edit.test.sh`; expected exit 0. Then `./tests/run.sh chezmoi-wrapper` (same sourced file); expected its usual total.

Commit (controller): `Start op-edit's Neovim without swap, ShaDa, undo or backup files`

### Task 4: Pin ha-mcp at 9.1.2

**Depends on:** none

**Files:**
- Modify: `dot_local/bin/executable_ha-mcp` (`:42`, header comment)
- Test: `tests/ha-mcp.test.sh` (`:82`, `:141`)

- [ ] **Step 1: Change the two expected exec lines** in `tests/ha-mcp.test.sh` from `ha-mcp@latest` to `ha-mcp==9.1.2`.
- [ ] **Step 2: Run** `./tests/ha-mcp.test.sh`. Expected: those assertions fail (section B once, section H once per curl exit code).
- [ ] **Step 3: Implement**, as `dot_local/bin/executable_unifi-network-mcp` does: a `version=9.1.2` variable near the top and `exec mise exec uv -- uvx --python "$python" "ha-mcp==$version"`. One header comment line gives the bump procedure from the spec: read the release's changes, edit `version=` and the two test lines, apply, restart the apps.
- [ ] **Step 4: Run** `./tests/ha-mcp.test.sh`; expected exit 0.

Commit (controller): `Pin ha-mcp at 9.1.2`

### Task 5: `AGENTS.md` wording

**Depends on:** Task 2

**Files:**
- Modify: `AGENTS.md` (`:11`, the `codex` launcher bullet `:86-90`)

- [ ] **Step 1:** Line 11 names `dot_config/bundler/private_config.tmpl`.
- [ ] **Step 2:** The `codex` launcher bullet gains the D2-A rule, in at most three lines: the daemon would update itself outside Homebrew, so it is pinned to the CLI's package with `codex app-server daemon update --from-cli`; Michael re-runs that after every `brew upgrade codex`, when no review is active, then runs the `live-codex-daemon` canary.
- [ ] **Step 3: Run** `./tests/run.sh agent-instructions`; expected its usual total (the suite reads the fragments, not `AGENTS.md`, so this only proves nothing else moved). `rg -n 'bundler/config.tmpl' AGENTS.md README.md dot_claude dot_config tests .scripts` prints nothing.

Commit (controller): `Name the private Bundler template and the Codex daemon pin in AGENTS.md`

### Task 6: Close-out

**Depends on:** Tasks 1-5

- [ ] **Step 1:** Final whole-branch review (`sp-architect`) of `main..HEAD` against the spec; fix findings in scope, record trade-offs under Rulings below.
- [ ] **Step 2: Stop gate, item 4's measurement.** It is Michael's (the daemon socket is denied to the sandbox): after his `--from-cli` pin, `codex app-server daemon version` shows equal CLI and running versions, and after two scheduled cycles `current` still names the CLI's release. With the evidence: record it under the spec's item 4 and go on to Step 3. Without it: set the spec's Status to `In progress`, run Steps 4 and 5 on that commit, push the branch and report the line blocked on the measurement. Steps 3 and 6 then wait for it; the pre-merge review never runs before the measurement.
- [ ] **Step 3:** Commit the final content: the measurement in the spec, and `**Status:** Implemented` (branch `fix/security-locks`) in the spec and this plan. Every later step runs on this commit; a fix after it repeats Steps 4 to 6 on the new head.
- [ ] **Step 4:** `./tests/run.sh xreview git-forge-guard wt-functions` (the three heavy suites; `dot_config/zsh/functions` changed). The machine-wide lock may make this wait.
- [ ] **Step 5:** `./tests/run.sh` on that commit; report every suite as passed/total.
- [ ] **Step 6:** Codex pre-merge review of that commit (`xreview dispatch --checkpoint pre-merge`), then push the branch. No merge.

## Rulings

- **Item 4's measurement gates the pre-merge review** (Codex plan review, round 1). The spec asks for it before that review, so without it the branch is pushed `In progress` and the review waits.
- **The Brewfile comment follows the rename** (Task 2 review). `dot_config/homebrew/Brewfile.tmpl` named the old template path; Task 5 updates that one comment, though the spec lists only `AGENTS.md:11`.
- **Template comments carry no apostrophe** (Task 1). The jq program sits in a single-quoted bash string, so the deny comment reads "Forge tokens for Bundler" where the plan said "Bundler's forge tokens".
- **The matcher pin derives from the guard's case arm** (final review), not from the literal `Edit|Write|NotebookEdit` that Task 1 and the spec's Test line name. Still one assertion and still red on `*`, as the spec asks; it also fails when a tool is added to the arm alone, which `xreview-skill` would otherwise pass. Cost: a `sed` extractor tied to the arm's line format.
- **The stale "every tool call" comment in the guard script is fixed** (Task 1 review), though the spec's "nothing else" list missed it: it restates the changed fact.
- **`op-edit`'s test pins the backup flags too** (Task 3 review). The spec names `noundofile`; the same assertion now also requires `nobackup` and `nowritebackup`, which the function's comment promises.
- **`AGENTS.md`'s list of zsh suites is completed** (final review) in the edit that adds `op-edit`.
- **Not done, for Michael:** `op-edit`'s Neovim still yanks to the macOS clipboard (LazyVim restores `clipboard=unnamedplus` after `-c`). Closing that changes item 1, so it needs a spec change.
- **Item 4 is measured on fenrir only** (close-out). The spec's "hercules too" is an after-apply step for Michael; the canary's stale R1 precondition is the driver's to raise, outside this line.
- **The branch was rebased onto main `eb60a84`** (close-out) before the final suites and the pre-merge review; no conflicts.
