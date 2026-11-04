# Driver-run `wt` checkouts, each reviewed in its own Codex pane

**Status:** Implemented on `driver-wt` (no MR)
**Date:** 2026-11-03
**Branch:** `driver-wt` (harness worktree; the dotfiles have no MR, the pushed branch is the end)
**Sign-off:** Michael, 2026-11-03. That includes two rulings he made after a scoping pass found a
flaw: the review path is `xreview -C <checkout>`, which replaces the earlier lone-`cd` idea, and
driver-run `wt` gets a no-focus mode, which widens the earlier "no change to `wt`".

## Problem

Every line of work in a `~/Code` repository runs in the driver's checkout today. Every pre-merge
review of those lines therefore goes through that checkout's one Codex pane. xreview runs one
dispatch per pane at a time (spec 2026-10-01 §4.9), so the reviews of parallel lines queue.

A `wt` checkout has its own Herdr workspace and its own Codex pane. But `global.md` forbids an agent
to create one ("Never create one, and never offer or run `wt-rm`"). Three things stand in the way
once that rule changes:

1. **The sandbox.** `wt` writes git configuration (`git worktree add`), drives the herdr socket,
   and writes state under `~/.local/state` (mise trust, the layout lock). Sandboxed, it fails
   partway and can leave a branch behind.
2. **Reaching the line's pane.** xreview derives its state, thread, round counter and pane from the
   cwd (`state_dir`, `pane_root` and `find_pane`, `dot_local/bin/executable_xreview:114-180`). A
   `cd` lasts only inside the session's working directories, and a `wt` checkout is a sibling,
   outside them. The apply-window guard has the same blind spot: it picks the window from the
   hook's cwd (`dot_claude/executable_xreview-apply-guard.sh:33-36`). A fix round in a sibling
   checkout is therefore never confined. Neither is one in a harness worktree, whose files
   subagents edit from the driver's cwd.
3. **Focus.** `layout.sh` focuses the new workspace and its tab
   (`dot_config/herdr/executable_layout.sh:374-375`, `:412-413`, `:416`, `:505`). Each driver-run
   `wt` would move Michael's Herdr view.

## Goals, non-goals, anti-goals

- **Goal:** the driver may open a `wt` checkout for each independent line of work in a `~/Code`
  repository. Each line then gets its own Herdr workspace and its own Codex pane, so the pre-merge
  reviews of parallel lines run in parallel. Teardown stays Michael's.
- **Excluded: the dotfiles.** Their `wt` checkout would land at `~/.local/share/chezmoi-<slug>`,
  outside the sandbox's write list. Dotfiles lines keep using harness worktrees.
- **Non-goals:** agent teardown, `wt` for Codex, `wt` for the dotfiles.
- **Anti-goals:**
  - an allow rule for `wt`;
  - a new permission prompt;
  - a change to the worktree guard;
  - a worktree per plan task (the parallel-tasks rule in `claude-code.md` stays).

## Design

### 1. `wt` runs outside the sandbox

- `"wt *"` joins `sandbox.excludedCommands` in `dot_claude/modify_private_settings.json`, after the
  five entries there. Its comment says why: git configuration writes, the herdr socket and state
  under `~/.local/state`. Sandboxed, `wt` fails partway and can leave a branch behind.
- **No allow rule.** The other excluded tools have none. Their calls pass through the auto-mode
  classifier, which accepted xreview 371/371, herdr 9/9 and docker 15/15 in recent transcripts. An
  allow rule would let an unsandboxed `wt` skip the classifier, and the classifier is the check on
  the accepted risks below.
- `"wt *"` needs a space after `wt`, so it cannot match `wt-rm`, `wt-prepare` or `wt-teardown`.
- As for the other excluded tools, the exclusion applies only when `wt` is the first command of the
  Bash call, on its own. That is why §4's mode is a flag: an environment-variable prefix would put
  the call back in the sandbox.
- **The worktree guard needs no change.** It gates `git worktree unlock` and `remove`, never
  creation (`dot_claude/executable_worktree-guard.sh:3-6`).
- **Pins in `claude-settings`:**
  - the list is exactly the six entries;
  - the `wt` pattern matches `wt --no-focus <branch> <start>` and `wt <branch>`;
  - it matches none of `wt-rm …`, `wt-prepare …`, `wt-teardown …` and `command wt-rm …`;
  - no allow rule matches a `wt` call.

  The matching uses the suite's own model of Claude Code's rule matching (`MATCHES`), which is
  calibrated on a fixture there. The live check (§6) confirms the real behaviour.

### 2. `xreview -C <checkout>`

- **A global option, with `git -C` semantics.** `xreview -C <checkout> <subcommand> [args]` enters
  `<checkout>` before any subcommand runs. Every per-checkout lookup then resolves from it:
  - the state directory (thread, pin, round counter, turn records, apply window);
  - the pane (`pane_root`, `find_pane`);
  - the branch, and the default range of a pre-merge dispatch;
  - the ledger path.

  Relative paths after it, such as the body file or `--diff <repo-path>:<range>`, resolve in the
  checkout.
- **Every subcommand honours it (ruling).** Each one reads per-checkout state:
  - `dispatch`;
  - `collect` (the turn record, the pane for a sliced round, and the receipt's branch);
  - `apply` (the window and the diff);
  - `round`, `thread` and `init` (the counter, the thread, the pin and the pane);
  - `receipts` (the ledger, found from the cwd);
  - `tier` (the checkpoint thread, when no thread is named).

  `help` ignores the option. Rejected:
  - a per-subcommand flag: a subcommand that lacked it would act on the driver's checkout without
    a word, and `round --reset` would drop the wrong thread;
  - resolving only the state paths from the option while keeping the caller's cwd: every git and
    ledger call would then need the path passed through.
- **Refusals.** `-C` refuses before anything is touched when its value is missing, when the
  directory cannot be entered, and when it is not inside a git work tree. A typo then never falls
  back to the caller's checkout.
- **Help.** Every help form still prints the usage and touches nothing, with or without `-C`. The
  usage names `-C <checkout>`.
- **A nonce from another checkout (ruling).** Using different checkouts within one line is the new
  mistake `-C` makes possible. Two forms of it are silent or misleading today:
  - `collect` without the dispatch's `-C` finds no turn record. It stops on "ambiguous: no turn on
    record", which the cross-review skill says to report and never retry.
  - `apply <nonce>` without it opens a window on the driver's checkout, scoped to the driver's
    branch diff. The guard (§3) then denies the driver's own unrelated edits.

  Both now first look for the nonce's turn record (`turns/<nonce>`) under every checkout's state
  directory. When it is on record under another checkout and not here, they refuse with "was
  dispatched from another checkout", naming that state directory. A nonce on record nowhere keeps
  today's behaviour: collect refuses as ambiguous, and apply opens the window.
- **The metric (ruling).** `.scripts/measure-interventions.py` counts `xreview -C <dir> dispatch`
  and `collect` as dispatches and collects. Without that, every review of a `wt` line drops out of
  the safe-autonomy metric.
- **Already in place:** a harness worktree inside a `wt` checkout reviews in that checkout's pane
  (`pane_root`; section Q2 of the xreview suite).

### 3. The apply-window guard keys by the edited file's checkout

- **The rule.** The guard takes the window from the checkout that holds the edited file: the git
  toplevel of the file's directory, never the hook's cwd. The marker stays
  `<state>/xreview/<key>/applying`, with the key derived as xreview's `state_dir` derives it.
- **What follows:**
  - a fix round in a `wt` checkout stays confined, whatever the driver's cwd;
  - the harness-worktree blind spot closes: a harness worktree's files, edited from the driver's
    cwd, answer to the harness worktree's window, and the main checkout's window no longer claims
    them;
  - a hook that runs outside any repository still polices a file inside one.
- **Details (rulings):**
  - **Stdin is drained first,** as the path-resolution guard does, so an early exit never hands the
    writer an EPIPE.
  - **No window anywhere, no work.** When no `<state>/xreview/*/applying` exists, the guard allows
    before it parses anything or calls git. The inert path stays at least as cheap as today's.
  - **A path that does not exist yet** (a Write into a new directory) belongs to the checkout that
    holds its nearest existing ancestor. Today such a Write is allowed, because `cd` into its
    directory fails.
  - **NotebookEdit is policed by its `notebook_path`.** Today it carries no `file_path`, which reads
    as no path, so it is allowed.
  - **The deny text names the checkout:** its remedy becomes `xreview -C <root> apply --done`. A bare
    `xreview apply --done` from the driver's cwd closes nothing. The deny text's first line stays
    as it is, because `measure-interventions` classifies on it.
- **Unchanged:**
  - fail-open on anything unexpected (missing jq, an unparseable payload, a path outside every
    checkout);
  - the test-path allowance;
  - the `XREVIEW_GUARD=off` bypass;
  - no `onFailure` setting (spec 2026-11-01-security-locks §1).
- **Accepted:**
  - a file belongs to the innermost checkout that holds it, so a submodule or a nested repository is
    its own checkout and answers to its own window;
  - a path inside a `.git` directory has no work tree and is not policed.
- **Ruling (2026-11-04).** The path model has four rules: the payload path is folded lexically; its
  nearest existing ancestor is resolved physically and the missing tail appended; a final symlink is
  allowed; the checkout is the git toplevel of that ancestor. Measured on Claude Code 2.1.316, Edit,
  Write and NotebookEdit refuse to write through a final symlink (direct, chained or dangling) and name
  the target, fold `..` lexically and resolve the existing prefix physically. If a future Claude Code
  writes through final symlinks, a redirection through a link fails open, which suits a narrow guard.

### 4. No-focus mode

- **The chain.** `wt --no-focus <branch> [<start>]` calls `dev --no-focus <checkout>`, which calls
  `layout.sh --no-focus --worktree <primary> <checkout>`. Michael's own `wt`, `dev` and `layout.sh`
  calls are unchanged and keep focusing.
- **A flag, not an environment variable (ruling).** The top-level call must start with `wt` and
  carry no prefix, or it runs sandboxed (§1). A variable threaded below `wt` would also let an
  exported variable silently stop Michael's own `wt` from focusing. So `layout.sh` ignores any
  inherited value of its internal setting.
- **One focus helper in `layout.sh`.** It runs `workspace focus`, then `tab focus` when a tab is
  named. Under `--no-focus` it does nothing. All four focus points use it: a new workspace, an
  existing one in path mode, a new worktree workspace, and an already-open one. Creation already
  passes `--no-focus` to herdr (`workspace create`, `worktree open`, `tab create`, `pane split`).
- **No client handover.** `--no-focus` also skips the handover in `hl_attach`. Handing the terminal
  to the herdr client is the largest focus change of all, and from a Bash tool call it would block
  on a TUI. Inside a Herdr pane, the handover is already skipped.
- **Only the first argument (ruling).** `wt`, `dev` and `layout.sh` each accept `--no-focus` only as
  their first argument. `wt` takes no other option, and its start point stays whatever the caller
  gives. Requiring an explicit start point is the rule's job (§5), not the flag's: the flag names
  what it does.
- **Panes: option A.** The new workspace's agents tab gets a Claude pane and a Codex pane, as today.
  The Claude pane stays idle, and Michael can take it over.

### 5. The instruction text

- **`global.md`, "Repositories and worktrees."** The `wt` bullet, which today says "Never create
  one, and never offer or run `wt-rm`", says instead:
  - the driver may open a `wt` checkout for each independent line of work, as
    `wt --no-focus <branch> <local-branch>`; a remote start point sets an upstream;
  - it names each checkout it opened in its report;
  - never in the dotfiles;
  - teardown stays Michael's: never offer or run `wt-rm`; if he explicitly asks, use
    `command wt-rm <branch>`, never `git worktree remove`;
  - a harness worktree follows its own tool's lifecycle.
- **`claude-code.md`:**
  - `wt` joins the Excluded tools bullet, which already says first command, never pipe or prefix;
  - the Cross-review bullet says that a `wt` checkout's line passes `-C <checkout>` to every
    `xreview` call;
  - the parallel-tasks rule stays: one worktree per plan or branch, never one per task.
- **Line caps.** Both files are at their pinned caps (`global.md` 150 of 150, `claude-code.md` 50 of
  50), so the rewrite adds no line.
- **The cross-review skill** (`dot_claude/skills/cross-review/SKILL.md`). Its Dispatching section
  says:
  - a `wt` line passes the same `-C <checkout>` to every call: dispatch, collect, apply and
    `round --reset`;
  - relative paths after `-C` resolve in the checkout;
  - a "dispatched from another checkout" refusal is resolved by running the call again with the
    dispatch's `-C`, and is never escalated.
- **It lands last,** after the live check, so the rule goes live only once the mechanism has been
  shown to work.

### 6. Live check

After Michael's apply (see Rollout), a driver session started in a `~/Code` repository checks four
things:

- **`wt` opens without a prompt and without moving the view.** It runs
  `wt --no-focus <branch> <start>`, which gets no prompt and no classifier denial. Herdr's focused
  workspace is the same before and after (`herdr workspace list`, field `focused`). The new
  workspace's agents tab holds two panes, Claude and Codex, both in the checkout.
- **The review reaches the line's pane.** It runs `xreview -C <checkout> dispatch --checkpoint spec
  <body>` and collects the result. The turn runs in that checkout's Codex pane.
- **Two lines review in parallel (ruling).** It opens a second checkout the same way and dispatches
  to both, back to back. The second dispatch does not wait on the first one's pane. This is the goal
  itself, so it is observed.
- **Work in the checkout goes through (ruling).** It edits a file in a checkout with the Edit tool
  and commits it with `git -C`, with no prompt. A line's work depends on this; see the accepted
  risks.

The plan gives the exact commands. The check uses a scratch repository, so no project's
`.worktreehook` runs.

## Prompt budget

There is no new prompt and no new allow rule. `wt` reaches the classifier, as xreview, herdr and
docker do. The apply guard can deny more than today (§3), but only while a window is open, and only
for files the review never saw.

## Accepted risks

- `wt` runs unsandboxed. It copies the `.worktreeinclude` files and trusts the mise config (spec
  2026-10-27).
- It runs the repository's working-tree `.worktreehook` (curato and VM.Portal have one), which an
  agent can write. The classifier is the check, which is one reason there is no allow rule.
- Checkouts pile up while they wait for teardown, so every report lists the ones opened.
- **Inferred, not verified:** edits and commands in a sibling checkout, outside the session's
  working directories, go to the classifier rather than to a prompt. The live check observes this.
  If they do prompt, the remedy is `~/Code` in `permissions.additionalDirectories` (or `/add-dir`),
  which widens a permission boundary and is Michael's call.
- **Inferred, not verified:** the classifier accepts a `wt --no-focus` call. If it denies one, the
  remedy is an `autoMode.allow` rule, which is also Michael's call.

## Facts checked (2026-11-03, main 2d70049)

- `wt` is a zsh function in the agent's shell snapshot (`type wt`), so a Bash call reaches it. It
  has no PATH wrapper.
- `herdr workspace list` reports `focused` for each workspace, so focus can be observed without
  Michael watching.
- The review ledger is keyed by the git common directory (`common_dir` in
  `dot_claude/xreview-ledger.py`). A receipt dispatched from a `wt` checkout is therefore found by
  the pre-merge gate from any checkout of the repository.
- The line numbers cited above hold at main 2d70049.

**Facts corrected (2026-11-04, Task 8 attempt 1).**
- The snapshot holds `wt` but none of its helpers: it leaves out every function whose name starts
  with a single `_` (measured: 200 plain names, 4 `__` names, 0 `_x` names). So in an agent's shell
  `wt`, `dev`, `wt-prepare`, `wt-rm` and the `chezmoi` wrapper break at their first helper.
- The `chezmoi` wrapper then fails open: `edit -a` is not refused.
- **Remedy, a ruling inside this design.** A public `functions-reload <helper>` loader. Each of those
  functions checks for its first helper, and if it is missing, reloads the file and re-runs itself.
- A PATH wrapper alone, as the plan's miss list suggested, would not be reached, because the
  snapshot's function shadows it.

## Testing

- **Focused suites:**
  - `claude-settings`;
  - `xreview` (heavy; once per batch);
  - `measure-interventions` and `xreview-apply-guard`;
  - `dev` and `wt-functions` (heavy);
  - `agent-instructions` and `xreview-skill`.
- **On the final commit:** the full `./tests/run.sh`, and before the pre-merge review
  `./tests/run.sh xreview git-forge-guard wt-functions`.

## Rollout and rollback

The work runs in this order:

1. the settings exclusion and its tests;
2. `xreview -C` and the guard re-key, with tests;
3. `wt` no-focus, with tests;
4. Michael runs `chezmoi apply` of the branch;
5. the live check;
6. the instruction text;
7. the pre-merge review and the push. Michael then merges and applies main.

A sandboxed `wt` attempt can fail partway and leave a branch behind. That is why the live check
comes after the apply.

Rollback: revert the branch's commits and apply. Michael tears down any checkout opened during the
check with `command wt-rm`.

## Out of scope

- agent teardown, `wt` for Codex and `wt` for the dotfiles;
- enforcing the dotfiles exclusion or an explicit start point inside `wt` itself: the rule does
  that, and Michael's own `wt` in the dotfiles must keep working.
