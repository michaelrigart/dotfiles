# `wt` checkouts for the dotfiles

**Status:** Approved
**Date:** 2026-11-11
**Sign-off:** Michael, 2026-11-11 (Codex spec review approved, `xr-1794356582-1589df6b`)
**Branch:** `feat/wt-dotfiles`, in the `wt` checkout `~/.local/share/chezmoi-feat-wt-dotfiles`: the
first dotfiles `wt` line, run before its own rules change (Michael, 2026-11-11; see section 5)
**Supersedes:** only the dotfiles exclusion in `docs/superpowers/specs/2026-11-03-driver-wt-design.md`
(Scope "Excluded: the dotfiles", its Non-goals and Out of scope entries). The rest of that spec stands.

## Why

Every new branch in a `~/Code` repository is a `wt` checkout with its own Herdr workspace, Claude
Code session and Codex pane, handed to that session by the driver. The dotfiles are the one
exception: their lines run in Claude Code harness worktrees under `.claude/worktrees/`, or on a
branch in the shared main checkout. Michael wants one workflow everywhere.

The exception has costs:

- A harness worktree is locked to the session that made it (lock reason
  `claude session <name> (pid …)`). `git worktree remove` refuses it, the WT guard denies
  `git worktree unlock`, and Michael removes it by hand or waits for the session to end
  (`managed-mods-lock`, 2026-11-11).
- A harness worktree sits inside the chezmoi source, and chezmoi walks the whole source tree.
  While one exists, `command chezmoi` and the test suites render its stale `global.md` from the
  main checkout, and `agent-instructions` reports false failures (measured 2026-11-06). Michael's
  wrapper apply, which renders a fresh clone, is not affected.
- A branch in the shared main checkout moves every other session there, and blocks Michael's
  `chezmoi apply`, which the wrapper runs only from a clean `main` equal to origin's.

The driver-wt spec (2026-11-03) excluded the dotfiles for one reason: their `wt` checkout lands at
`~/.local/share/chezmoi-<slug>`, outside the sandbox's write list. `wt`, `dev`, `wt-rm` and
`xreview -C` already work there, and that spec kept Michael's own `wt` in the dotfiles working on
purpose.

## What a sibling gets from the sandbox today

`sandbox.filesystem.allowWrite` in `dot_claude/modify_private_settings.json` lists four work roots:
`~/Code`, `~/.local/share/chezmoi`, `~/Documents` and the vault. Every root-keyed `denyWrite` entry
is built from the same list (`$roots`). For a sibling `~/.local/share/chezmoi-<slug>`:

- **The line's own session can write it**, because Claude Code grants a session its working
  directory. Its commits work too: a linked worktree's index, refs and objects live under
  `~/.local/share/chezmoi/.git`, which is a root, and its git configuration, commondir and hooks
  there are already denied.
- **No root-keyed denial reaches it.** Its sandboxed commands can write `.mcp.json`, `.codex/`,
  `.lazygit.yml`, and the agent configuration of harness worktrees nested in it, all of which a
  later session or Codex in that checkout loads outside the sandbox. Claude Code's built-in denial
  covers only the session's own `.claude/settings*.json`. In a `~/Code` repository every one of
  these is denied.
- **Project configuration and memory carry over.** Claude Code keys both to the main checkout's
  root, so a sibling session loads the dotfiles memory and raises no trust dialog
  (`dot_claude/hooks/executable_memory-health.sh` documents the keying; no `wt` sibling has an
  entry of its own in `~/.claude.json`).
- **Another session cannot write it with a sandboxed command**, for example the driver in the
  main checkout. Its Edit and Write tools are not sandboxed, so a spec still lands; a shell write
  does not.

## Goals

- Every new dotfiles branch is a `wt` checkout, opened, handed over and torn down exactly like a
  `~/Code` line.
- A dotfiles sibling has the same sandbox protection as a `~/Code` repository.
- The main checkout stays on `main`, so Michael can `chezmoi apply` at any time.

## Non-goals

- Moving the chezmoi source into `~/Code`.
- Any change to `wt`, `dev`, `wt-rm`, `layout.sh` or `xreview`.
- A refusal or guard against a harness worktree or a plain branch in the dotfiles. The rule does
  that, as it does for `~/Code`.
- hercules.

## Anti-goals

- A write grant wider than `chezmoi-*` siblings. `~/.local/share` holds mise runtimes and other
  executables.
- A sibling with less protection than a `~/Code` repository.
- A new permission prompt.

## Design

### 1. A fifth sandbox root

Add `~/.local/share/chezmoi-*` to `allowWrite` and to `$roots`. Every root-keyed denial then covers
each sibling as it covers a `~/Code` repository: git hooks, git configuration and commondir, the
linked-worktree module forms, agent configuration at depths 0, 1 and 2 and in harness worktrees
at the three fixed depths, harness worktree `.git` files, and the tool configuration (`.lazygit.yml`,
the lazygit and glab files in git directories). The comment above `allowWrite` and the "where
sessions start" comment name the new root.

- One denial goes beyond parity: `~/.local/share/chezmoi-*/.git`. A `~/Code` sibling's `.git`
  stays writable only because it sits at the depth of real repositories' `.git` directories
  (spec 2026-10-30, residual V7). Under `chezmoi-*` every match is a linked-worktree `.git` file,
  the shape that spec already denies for harness worktrees so that one session cannot repoint
  another's checkout at planted configuration (an fsmonitor, run by Starship, herdr or a hook's
  git call). Cost: a sandboxed `git worktree repair` or `git worktree move` in a sibling fails;
  `wt` and `wt-rm` run unsandboxed and are unaffected. (Driver's call.)
- The glob matches only names that start with `chezmoi-` directly under `~/.local/share`. Nothing
  lives there today: chezmoi keeps its state in `~/.config/chezmoi` and its cache in
  `~/.cache/chezmoi`. A sandboxed command may now create a directory of that shape; nothing loads
  code from one except a session started in it, and the denials cover that session.
- The deny side already uses mid-path globs (`~/Code/*/HEAD`), so it is known to work. Whether
  `allowWrite` honours a glob is not known; section 4 measures it.
  - Honoured: keep the entry.
  - Ignored or taken literally: drop it from `allowWrite` and keep it in `$roots`. The line's own
    session keeps its working-directory grant and every denial; only another session's sandboxed
    shell writes into a sibling fail. Record the measured result in this spec.
  - The settings fail to load with it: stop and bring Michael options.

### 2. Instructions

- `.chezmoitemplates/agents/global.md`, the "`wt` worktrees" bullet:
  - "Every new branch in `~/Code` is one" covers the dotfiles too.
  - "The dotfiles never use `wt`." is removed.
  - "For the dotfiles, the pushed branch is the end." (Finishing) stays.
  - Whether to name the dotfiles' sibling path is the builder's call. The file stays within its
    150 lines.
- `.chezmoitemplates/agents/claude-code.md`, "Parallel tasks": "(dotfiles: a harness worktree)" is
  removed. The file stays within its 50 lines.
- `AGENTS.md`, the shared-checkout bullet: the main checkout stays on `main` (Michael applies from
  it); every branch is a `wt` checkout at `~/.local/share/chezmoi-<branch>`, run by its own
  session; agents there preview with `command chezmoi --source <checkout> …`. Sweep `AGENTS.md` and
  `README.md` for other main-checkout or harness-worktree assumptions. Specs and plans are
  permanent and are not edited.
- `tests/agent-instructions.test.sh`: the pins on "The dotfiles never use `wt`." and on "(dotfiles:
  a harness worktree)" become assertions that the phrases are gone; the new scope sentence gets a
  pin. "Harness worktrees follow their tool's lifecycle." stays pinned.

### 3. Tests

- `tests/claude-settings.test.sh`: `EXP_ALLOW_WRITE` and `ROOTS` gain the sibling root, and the
  per-root path checks include a sibling (`.mcp.json`, `.codex/config.toml`, a nested harness
  worktree `.git` denied; an ordinary file allowed).
- `tests/live-write-boundary.test.sh`: a sibling probe beside the existing root probes, with the
  same stamp-based cleanup, requiring an ordinary write to succeed and `.mcp.json` to fail. That
  pair only means something from a session that can write the sibling: if section 4's run A finds
  the `allowWrite` glob ignored, the probe needs a session started in a sibling, and an ordinary
  write that fails is reported as INCONCLUSIVE (exit 2), never as a pass.
  `tests/write-boundary-probe.test.sh` follows if it mirrors the root list.
- `tests/claude-settings.test.sh` also pins the sibling `.git` denial (the `.git` entry count and
  list), and the live probe checks it.
- A suite run from a sibling must test the sibling. Audit the suites that hard-code
  `~/.local/share/chezmoi` (`process-replay/t_*.py`, `claude-settings`, `live-write-boundary`,
  `write-boundary-probe`) or render templates without `--source` (`codex-daemon.test.sh:194,198`,
  `unifi-network-mcp.test.sh:114`): those reading source files resolve the checkout they run
  from; those measuring the main root on purpose keep it.

### 4. Measurement before the pre-merge review

Two throwaway, budget-capped `claude -p --settings <file>` runs carry the new sandbox block, with
`allowUnsandboxedCommands: false` so that no probe can be retried outside the sandbox (the
`live-deny-modes` pattern; `claude` itself runs unsandboxed because it writes session state under
`~/.claude`). Each run is told the exact probe commands, and the verdict is read from the
filesystem afterwards, never from the model's account. A scratch sibling
`~/.local/share/chezmoi-<probe>` is created beforehand and removed afterwards.

- **Run A, working directory outside the sibling** (a scratch directory under `~/Code`): the
  settings load, and an ordinary file written into the scratch sibling exists afterwards or not.
  That answers the `allowWrite` glob question, and only that: from outside, a denial cannot be
  told apart from a missing grant.
- **Run B, working directory the scratch sibling**: an ordinary file is written (the
  working-directory grant), while `.mcp.json`, `.codex/config.toml` and `.lazygit.yml` are not.
  That shows the root-keyed denials bite whatever run A found. A run B in which the ordinary
  write also fails measured nothing, and is not a pass.

Both results go into section 1 before the pre-merge review.

### 5. This line is the live check

A failure of the `wt` path after the merge would block every dotfiles line, the fixing one
included, because the new rules ban the fallbacks. So this change runs as the first dotfiles `wt`
line, under the rules it replaces, by Michael's ruling of 2026-11-11:

- The driver, in the main checkout's session, opens the line with
  `wt --no-focus feat/wt-dotfiles main`, writes and commits this spec in the sibling, reviews it
  with `xreview -C <sibling>`, and hands the line to the sibling's session.
- The instruction text (`global.md`, `claude-code.md`, `AGENTS.md` and their pins) is the plan's
  last task, after the settings, the tests and section 4's measurement.
- When a step of the `wt` path fails, the line stops and the driver tells Michael. Until the
  merge the old rules still allow a harness worktree, so the line can move there.
- Until Michael applies the merged settings, the line's own sibling has no root-keyed denials
  (see "What a sibling gets from the sandbox today"). Accepted for this one line.

After the merge:

- Michael: `chezmoi apply`, a fresh session, `./tests/run.sh live-write-boundary` sandboxed, and
  `wt-rm feat/wt-dotfiles`.
- The driver updates its memory notes on harness worktrees and `wt` dispatch.

## Left to the builder

- Wording and wrapping in the fragments and `AGENTS.md`, within the line caps.
- Whether `global.md` names the dotfiles' sibling path.
- The suite audit's per-suite outcome.
