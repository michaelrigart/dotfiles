# Sandboxed sessions cannot plant git configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress

**Goal:** No sandboxed command can write git configuration, a configuration redirect, or a
`.git` entry where no repository may be, under any work root. Git outside the sandbox refuses
fake git directories.

**Architecture:**
- **Settings template:** 39 new `sandbox.filesystem.denyWrite` entries in
  `dot_claude/modify_private_settings.json`.
- **Global git configuration:** `safe.bareRepository = explicit` in `dot_config/git/config`.
- **Instructions:** a reworded escape line in the Claude-only instructions fragment.
- **Tests:** pinned by `claude-settings`, a new `git-config` suite and `agent-instructions`.
  `live-write-boundary` gets probes for after Michael's apply.

**Tech Stack:** bash 3.2 and jq (the modify script), bash suites, git 2.56 (Homebrew) and
2.54 (Apple).

**Spec:** `docs/superpowers/specs/2026-10-30-sandbox-git-config-plant-design.md` (signed off
2026-10-30).
Read §1–§4, Costs and Testing before any task.

## Global Constraints

- **Edit only the source.** Never `~/.claude/settings.json` or any other deployed file, and
  never run `chezmoi apply`; that is Michael's.
- **Running suites:**
  - focused runs use `./tests/run.sh <exact-suite-name>`, executed and never prefixed with an
    interpreter;
  - full runs are serialised: `lockf -k /tmp/claude-501/chezmoi-fullsuite.lock ./tests/run.sh`.
- **`live-write-boundary` runs only sandboxed.** Never with the sandbox disabled. Its
  acceptance run is Michael's, after apply.
- **The modify script's jq program** is one single-quoted shell string. It may hold no
  apostrophe anywhere, and no backslash in a jq comment.
- **Every denyWrite entry starts with one of the four work roots plus a slash.** The roots are
  `~/Code`, `~/.local/share/chezmoi`, `~/Documents` and
  `~/Library/Mobile Documents/iCloud~md~obsidian`. `$TMPDIR` stays fully writable.
- **Commits:**
  - imperative, with no agent attribution;
  - re-check `git branch --show-current` (`fix/sandbox-git-config-plant`) right before each;
  - check `git diff --cached` before each.
- **New suites:** mode 755 (`git add --chmod=+x`), a correct shebang, and exit 2 when the file
  under test is missing.
- **The repository is public.** Nothing private goes in any file.

## Review Focus

1. **An entry that over-matches would deny every git write.** Examples: `.git/**/config`, or
   a `.git` deny at depth 1, 2 or 3. Commits, refs, the index, `HEAD`, a branch named
   `config`, `config-x` or `commondir`, and repositories at depths 1 and 3 must stay writable.
   Owned by Task 1's glob-semantics cases.
2. **The depth-0 forms.** The chezmoi checkout's own `.git/config` and a harness worktree's
   `.git` file directly under the chezmoi root must be denied through `**/` matching zero
   directories. Task 1.
3. **Non-isolated git with a bare repository.** A suite or helper running git inside a bare
   repository without its own `GIT_CONFIG_GLOBAL` would break once the global setting
   deploys. Task 5 runs the full suite with the branch's global configuration.
4. **The vault fixture.** It must still run its agent-configuration probes after losing its
   `.git`. Task 4.
5. **Cleanup in `~/Code`.** A live-suite fixture whose `.git/config` cannot be deleted
   sandboxed must not leave a husk. Task 4 moves it back to `$TMPDIR` before removing it.

## File map

| File | Change | Task |
|---|---|---|
| `dot_claude/modify_private_settings.json` | denyWrite entries and their comment | 1 |
| `tests/claude-settings.test.sh` | exact array, invariants, glob-semantics cases | 1 |
| `dot_config/git/config` | `[safe]` block | 2 |
| `tests/git-config.test.sh` | new suite | 2 |
| `.chezmoitemplates/agents/claude-code.md` | escape line (lines 5–6) | 3 |
| `tests/agent-instructions.test.sh` | two `need` assertions | 3 |
| `docs/superpowers/specs/2026-10-16-sandbox-write-boundary-design.md` | two pointer lines | 3 |
| `tests/live-write-boundary.test.sh` | git probes, vault split, `.git` probes, behaviour probe | 4 |

Tasks 1–4 have disjoint files and no shared test resource, so they can run as one batch.
Task 5 follows them.

---

### Task 1: Deny git configuration and misplaced `.git` in the settings template

**Depends on:** none

**Files:**
- Modify: `dot_claude/modify_private_settings.json:421-450`, the `denyWrite` expression and
  the comment above it.
- Test: `tests/claude-settings.test.sh:362-410`.

**Interfaces:**
- Produces: the deployed `sandbox.filesystem.denyWrite` array, 181 entries. Task 4 measures
  it after apply. Its order:
  1. the existing per-root hooks (16);
  2. the chezmoi hooks (4);
  3. the git configuration set (24);
  4. the agent configuration (120);
  5. the harness worktree `.git` files (12);
  6. the three top-level `.git` entries;
  7. `.obsidian` (2).

- [ ] **Step 1: Write the failing expectations in `tests/claude-settings.test.sh`**

  Replace the comment at 362–373. It must say: git configuration and `commondir` are denied
  in every root (spec 2026-10-30 §1); `.git` is denied at `~/Code`, at `~/Documents`,
  anywhere in the vault, and as a harness worktree's `.git` file (§2); and objects, refs, the
  index and `$TMPDIR` stay writable.

  Add the configuration set beside `GITFILES`:

  ```bash
  GITCONF='[".git/config*",".git/commondir",".git/worktrees/*/config*",".git/worktrees/*/commondir",".git/modules/**/config*",".git/modules/**/commondir"]'
  ```

  Build `EXP_DENY_WRITE` in the order above. The new parts are:

  ```jq
  + [$r[] as $root | $c[] | "\($root)/**/\(.)"]
  + [$r[] as $root | "\($root)/.claude/worktrees/*/.git", "\($root)/*/.claude/worktrees/*/.git", "\($root)/*/*/.claude/worktrees/*/.git"]
  + ["~/Code/.git", "~/Documents/.git", "~/Library/Mobile Documents/iCloud~md~obsidian/**/.git"]
  ```

  Change these assertions:
  - remove `no deny glob reaches a git configuration file` (line 392);
  - widen line 394's filter to accept entries ending in `/.git`, relabelled
    `every deny glob names a git path, .obsidian or an agent configuration file`;
  - line 407: `select(test("/\\.claude/worktrees/"))` now counts 72, labelled
    `exactly 72 harness worktree entries: 4 roots x (5 agent paths + the .git file) x 3 depths`.

  Add these assertions:
  - `denyWrite has 181 entries`;
  - `each work root denies all six git configuration forms`: every
    `"\($root)/**/\($c)"` for each root and each `GITCONF` member is present;
  - `every config* entry sits directly in a git directory, a linked worktree's or a
    submodule's`: every entry ending in `config*` matches
    `/\.git/(worktrees/\*/|modules/\*\*/)?config\*$`;
  - `the only entries ending in .git are the three top-level ones and the twelve harness
    forms`: 15 entries end in `/.git`, and those without `/.claude/worktrees/` are exactly
    the three above.

  Add a glob-semantics block. A jq function converts an entry to the regex Claude Code
  compiles it to (spec §1, "How these compile"):
  - `~` becomes `$HOME`;
  - regex metacharacters are escaped;
  - `**/` becomes `(.*/)?`, a remaining `**` becomes `.*`, and `*` becomes `[^/]*`;
  - the result is wrapped as `^…(/.*)?$`.

  A path is denied if and only if some entry's regex matches it. With `H=$HOME`:
  - **Denied:**
    - `H/Code/Org/repo/.git/config`, `H/Code/tagteam/.git/config.lock`,
      `H/.local/share/chezmoi/.git/config`;
    - `H/Documents/a/b/c/.git/config.worktree`, `H/Code/Org/repo/.git/commondir`;
    - `H/Code/Org/repo/.git/worktrees/w/commondir`,
      `H/Code/Org/repo/.git/worktrees/w/config.worktree`;
    - `H/Code/Org/repo/.git/modules/plays/roles/x/config`,
      `H/Code/Org/repo/.git/modules/x/worktrees/y/config.worktree`;
    - `H/Code/.git`, `H/Documents/.git`,
      `H/Library/Mobile Documents/iCloud~md~obsidian/Documents/MSB/x/.git`;
    - `H/Code/Org/repo/.claude/worktrees/agent-1/.git`,
      `H/.local/share/chezmoi/.claude/worktrees/agent-1/.git`.
  - **Allowed:**
    - `H/Code/Org/repo/.git/objects/ab/cdef`, `H/Code/Org/repo/.git/index`,
      `H/Code/Org/repo/.git/HEAD`;
    - `H/Code/Org/repo/.git/refs/heads/config`, `…/refs/heads/config-x`,
      `…/refs/heads/commondir`;
    - `H/Code/Org/repo/.git/worktrees/w/gitdir`, `H/Code/Org/repo/.git/worktrees/w/HEAD`;
    - `H/Code/tagteam/.git/index`, `H/Code/Netronix/ansible-roles/r/.git/index`;
    - `H/Code/Org/repo-branch/.git` (a `wt` sibling's `.git` file, a residual);
    - `/private/tmp/claude-501/x/.git/config`;
    - `H/Code/Org/repo/node_modules/pkg/.claude/settings.local.json`.

  Each sample gets its own labelled PASS or FAIL.

- [ ] **Step 2: Run it and see it fail**

  Run: `./tests/run.sh claude-settings`
  Expected: red. The exact-array, count, six-forms and `.git` assertions fail, and the
  glob-semantics "Denied" cases fail.

- [ ] **Step 3: Implement the entries in the template's `denyWrite` expression**

  - Add `[".git/config*", ".git/commondir", ".git/worktrees/*/config*", ".git/worktrees/*/commondir", ".git/modules/**/config*", ".git/modules/**/commondir"] as $gitconf`.
  - Concatenate the new parts in the order of the Interfaces block.
  - Rewrite the comment at 421–439. It keeps what still holds and drops "Git configuration
    files, objects, refs and the index stay writable, so sandboxed git config, branch -u, clone
    and submodule keep working." It adds, in one or two lines each:
    - git configuration and `commondir` are denied in every root, by spec 2026-10-30;
    - `config*` covers the lock files;
    - `.git` is denied where no repository may be, plus harness worktree `.git` files;
    - objects, refs and the index stay writable, and `$TMPDIR` is untouched.

  No apostrophes, and no backslash in a comment.

- [ ] **Step 4: Run it and see it pass**

  Run: `./tests/run.sh claude-settings`
  Expected: green, with passed equal to total.

- [ ] **Step 5: Commit**

  ```bash
  git add dot_claude/modify_private_settings.json tests/claude-settings.test.sh
  git commit -m "Deny git configuration writes in every work root"
  ```

### Task 2: Git refuses fake git directories

**Depends on:** none

**Files:**
- Modify: `dot_config/git/config` (append a block at the end).
- Create: `tests/git-config.test.sh`.

**Interfaces:**
- Produces: the global setting `safe.bareRepository = explicit`. Task 5 runs the full suite
  with this file as `GIT_CONFIG_GLOBAL`.

- [ ] **Step 1: Write the suite `tests/git-config.test.sh`**

  The suite is bash with `  PASS:`/`  FAIL:` lines and a final `passed: N  failed: M`, the
  idiom of `git-signing-config`.
  - **Setup:** it exits 2 if `$SRC/dot_config/git/config` is missing. All work is in
    `T=$(mktemp -d "${TMPDIR:-/tmp}/gitconfig.XXXXXX")`, removed by a trap.
  - **Isolation:** every git call runs with
    `GIT_CONFIG_GLOBAL="$SRC/dot_config/git/config" GIT_CONFIG_NOSYSTEM=1`.
  - **Commits:** they add
    `-c commit.gpgsign=false -c user.name=t -c user.email=t@t`, so no signing agent is ever
    asked.
  - **Fixtures:**
    - `$T/fake`: `HEAD` = `ref: refs/heads/main`, `objects/`, `refs/`, and a `config` with
      `[probe] key = fake`.
    - `$T/fake2`: the same, plus `core.bare = false` and `core.worktree = $T/wtree`.

  Assertions:
  - `safe.bareRepository is explicit`: `git config --file <source> --get safe.bareRepository`
    prints `explicit`.
  - `a fake git directory is refused`: `git -C "$T/fake" rev-parse --git-dir` exits non-zero,
    and its stderr contains `safe.bareRepository`.
  - `a fake git directory's config is not read`: `git -C "$T/fake" config probe.key` prints
    nothing.
  - `a fake git directory with core.worktree is refused`: `git -C "$T/fake2" status` exits
    non-zero.
  - `Apple git refuses it too`: run with
    `/Library/Developer/CommandLineTools/usr/bin/git`. When that is not executable, report
    PASS with the note `(no Command Line Tools git)`.
  - `--git-dir still opens it`: `git --git-dir="$T/fake" config probe.key` prints `fake`.
  - `a repository works, inside its .git too`: init and commit in `$T/r`; then
    `git -C "$T/r/.git" rev-parse --git-dir` prints `.`.
  - `a linked worktree works`: `git -C "$T/r" worktree add -q "$T/wt" -b b1`, then
    `git -C "$T/wt" status --short` exits 0.
  - `a bare remote works`: all exit 0:
    - `git init -q --bare "$T/o.git"`;
    - a push from `$T/r` to `$T/o.git`;
    - `git clone -q "$T/o.git" "$T/c"`;
    - `git -C "$T/c" fetch -q`;
    - `git ls-remote "$T/o.git"`.

- [ ] **Step 2: Run it and see it fail**

  Run: `chmod 755 tests/git-config.test.sh && ./tests/run.sh git-config`
  Expected: red. `safe.bareRepository is explicit`, the two refusals, `config is not read`
  and the Apple git case fail; the rest pass.

- [ ] **Step 3: Append to `dot_config/git/config`**

  ```
  [safe]
      bareRepository = explicit
  ```

- [ ] **Step 4: Run it and see it pass**

  Run: `./tests/run.sh git-config` and `./tests/run.sh git-signing-config`.
  Expected: both green.

- [ ] **Step 5: Commit**

  ```bash
  git add --chmod=+x tests/git-config.test.sh
  git add dot_config/git/config
  git commit -m "Refuse fake git directories in the global git config"
  ```

### Task 3: Instructions and the superseded record

**Depends on:** none

**Files:**
- Modify: `.chezmoitemplates/agents/claude-code.md:5-6`.
- Modify: `tests/agent-instructions.test.sh`, near the other `need` calls at 106–117.
- Modify: `docs/superpowers/specs/2026-10-16-sandbox-write-boundary-design.md`: one line
  after line 64, one after the Out-of-scope entry on git configuration.

- [ ] **Step 1: Write the failing assertions**

  Add these to `tests/agent-instructions.test.sh`:

  ```bash
  need claude-code.md '  - Needs the escape: `op`, and git configuration writes in any repository: `init`,' \
    "claude-code.md names git configuration writes in any repository as needing the escape"
  need claude-code.md '    `clone`, `config`, `remote add`, `submodule`, `worktree add`, tracking a remote branch.' \
    "the escape line lists the git commands that write configuration"
  ```

- [ ] **Step 2: Run it and see it fail**

  Run: `./tests/run.sh agent-instructions`
  Expected: red. The two new assertions fail.

- [ ] **Step 3: Replace lines 5–6 of the fragment with exactly the two lines above**

  The fragment stays at 50 lines; no line exceeds 92 columns.

- [ ] **Step 4: Add the two pointer lines to the 2026-10-16 spec**

  Change nothing else in it.
  - After line 64 (the end of the "Git, decided 2026-10-17" bullet), indented two spaces:
    `Superseded for configuration on 2026-10-30 by [the git configuration plant spec](2026-10-30-sandbox-git-config-plant-design.md).`
  - After the line `trusts that repository's metadata as it trusts its code.` (the end of
    the Out-of-scope entry "A repository's git configuration …", line 459 before the first
    insertion), indented two spaces:
    `Superseded on 2026-10-30 by [the git configuration plant spec](2026-10-30-sandbox-git-config-plant-design.md).`

- [ ] **Step 5: Run it and see it pass**

  Run: `./tests/run.sh agent-instructions`
  Expected: green, with the line-cap assertion `claude-code.md is at most 50 lines (50)`.

- [ ] **Step 6: Commit**

  ```bash
  git add .chezmoitemplates/agents/claude-code.md tests/agent-instructions.test.sh \
    docs/superpowers/specs/2026-10-16-sandbox-write-boundary-design.md
  git commit -m "Say git configuration writes need the escape in any repository"
  ```

### Task 4: Live probes for the deployed denies

**Depends on:** none. The suite encodes the post-apply state; it reads no file of Tasks 1–3.

**Files:**
- Modify: `tests/live-write-boundary.test.sh`.

**Interfaces:**
- Consumes: spec Testing, "`live-write-boundary`".
- Produces: these new keys:
  - `${k}_git_config`, `${k}_git_config_lock`, `${k}_git_config_worktree`,
    `${k}_git_commondir`;
  - `${k}_git_worktree_config`, `${k}_git_worktree_commondir`, `${k}_git_worktree_gitdir`;
  - `${k}_git_module_config`, `${k}_git_module_commondir`,
    `${k}_git_module_config_worktree`, `${k}_git_module_worktree_config`;
  - `${k}_harness_worktree_git_file`;
  - `vault_git_dir`, `vault_git_file`;
  - `code_root_git_file`, `documents_root_git_file`;
  - `chezmoi_top_git_config`;
  - `behaviour_setup` (printed only on failure), `behaviour_commit`, `behaviour_config`,
    `behaviour_push_u`, `behaviour_worktree_add`, `behaviour_case_config`,
    `behaviour_case_commondir`.

- [ ] **Step 1: Split the root loop**

  The vault is the root whose path ends in `iCloud~md~obsidian`.
  - **The other three roots:** keep today's `mkdir -p` of the `.git` fixture directories.
  - **The vault:** `mkdir -p` only the non-git directories (`$r/.claude/*`, `$ar/...`,
    `$nm/.claude`, `$m/plain/hooks`). It runs its agent-configuration probes unchanged, plus:
    - `denied vault_git_dir "$b/org/repo/.git/"`;
    - `denied vault_git_file "$b/org/.git"`.
  - Update the header comments to match.

- [ ] **Step 2: Replace the git probes for the three non-vault roots**

  - `denied`:
    - `config`, `config.lock`, `config.worktree`, `commondir`;
    - `worktrees/wt/config.worktree`, `worktrees/wt/commondir`;
    - `modules/sub/config`, `modules/sub/commondir`, `modules/sub/config.worktree`;
    - `modules/sub/worktrees/swt/config.worktree`.
  - `allowed`: `worktrees/wt/gitdir`.
  - Keep the hooks, module-hooks, objects, index and `refs/heads/{config,hooks}` probes.
  - Drop the `*_writable` git-config keys.
  - `allowed_off_base` stays only for `.claude/commands` and `.claude/agents`.
  - In every root: `denied "${k}_harness_worktree_git_file"
    "$ar/.claude/worktrees/wt1/.git"`. Create `$ar/.claude/worktrees/wt1` in the fixture.
  - Informational, outside the vault only, printed with the `# info` prefix like the rename
    probe and not counted. Add `$b/plain` to the fixture's `mkdir -p`. Then create the file
    `$b/plain/.git`, report `WRITABLE` or `DENIED`, and remove it; report `ABSENT` if
    `$b/plain` is missing. The text says it is a residual (spec Residuals).

- [ ] **Step 3: Add the top-level probes**

  - `denied code_root_git_file "$HOME/Code/.git"`.
  - `denied documents_root_git_file "$HOME/Documents/.git"`.
  - `chezmoi_top_git_config`: a new helper `denied_existing <key> <path>`. It reports `ABSENT`
    (a failure) unless `<path>` is a file, then opens it with `( : >> "<path>" )`, which
    writes nothing, and reports `DENIED` or `WRITABLE`. Apply it to
    `$HOME/.local/share/chezmoi/.git/config`.

- [ ] **Step 4: Add the behaviour probe**

  - **Isolation:** its git calls run with `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1`,
    and commits add `-c user.name=t -c user.email=t@t`.
  - **Setup:**
    - `TB=$(mktemp -d "${TMPDIR:-/tmp}/$stamp-b.XXXXXX")`;
    - a bare `$TB/origin.git`;
    - `$TB/r` with one commit on `main`, `origin` pointing at the bare repository, and `main`
      pushed;
    - then `mkdir -p "$HOME/Code/$stamp-b"` and `mv "$TB/r" "$HOME/Code/$stamp-b/r"`.
  - **A setup failure stops the probe.** If any setup command fails, or `R/.git/config`
    is not a file after the move, the suite prints `behaviour_setup=FAIL`, counts one
    failure, and runs none of the probes below. Without this, a missing repository would let
    the denial probes read `DENIED`.
  - **Probes**, with R = `$HOME/Code/$stamp-b/r`:
    - `behaviour_commit`: an empty commit succeeds → `OK`, else `FAIL`;
    - `behaviour_config`: `git -C R config probe.key 1` fails → `DENIED`, else `WRITABLE`;
    - `behaviour_push_u`: `git -C R push -u origin HEAD:refs/heads/b1` exits 0, the remote
      has `b1`, and `git -C R config branch.main.merge` prints nothing → `OK`, else `FAIL`;
    - `behaviour_worktree_add`:
      `git -C R worktree add -q "$HOME/Code/$stamp-b/wt" -b wtb` fails → `DENIED`, else
      `WRITABLE`;
    - `behaviour_case_config`: `( : >> R/.git/CONFIG )` → `DENIED` or `WRITABLE`;
    - `behaviour_case_commondir`: `denied` on `R/.git/COMMONDIR`, which removes it again if
      it was created.
  - **Cleanup:** `cleanup()` moves `$HOME/Code/$stamp-b/r` into `$TB` when it exists, then
    removes `$HOME/Code/$stamp-b` and `$TB`. The move comes first because `rm -rf` cannot
    delete a denied `.git/config` in place. Add both paths to `probes`.

- [ ] **Step 5: Check the mechanics before apply, sandboxed**

  The sandbox is on, the settings are not yet applied, and the run is not the acceptance run.
  - Run: `bash -n tests/live-write-boundary.test.sh`, then
    `./tests/run.sh live-write-boundary`.
  - Expected: red, but only on keys whose result changes at apply:
    - `WRITABLE`:
      - the new git `denied` probes of Step 2 and `${k}_harness_worktree_git_file`;
      - `vault_git_dir`, `vault_git_file`, `code_root_git_file`, `documents_root_git_file`;
      - `behaviour_config`, `behaviour_worktree_add`, `behaviour_case_config`,
        `behaviour_case_commondir`.
    - `FAIL`: `behaviour_push_u`, because the push records `branch.main.merge` while the
      repository's configuration is still writable.
    - The session's own repository and its common directory already fall under Claude
      Code's built-in rule, so some of these may read `DENIED` already. That is expected:
      `chezmoi_top_git_config`, and the chezmoi root's fixture probes when the session
      started in the chezmoi checkout or one of its harness worktrees.
  - Every other key passes, `behaviour_setup=FAIL` does not appear, and no `cleanup=LEFT`
    appears.
  - `ls -d ~/Code/zz-write-boundary-* ~/Documents/zz-write-boundary-* ~/Code/.git
    ~/Documents/.git` finds nothing.

- [ ] **Step 6: Commit**

  ```bash
  git add tests/live-write-boundary.test.sh
  git commit -m "Probe the git configuration denies in the live write-boundary suite"
  ```

### Task 5: Integration run and handoff

**Depends on:** Tasks 1, 2, 3 and 4

**Files:** none changed, unless a run turns up a fix; that fix goes in the task that owns the
file.

- [ ] **Step 1: Full suite with the branch's global git configuration**

  Run: `lockf -k /tmp/claude-501/chezmoi-fullsuite.lock env GIT_CONFIG_GLOBAL="$PWD/dot_config/git/config" ./tests/run.sh`
  Expected: every suite green, reported as passed/total per suite.

  For any red suite, rerun it alone without the variable (`./tests/run.sh <name>`).
  - If it is green then, the bare-repository setting broke it. Fix the suite or the helper,
    for example with `--git-dir`, in the owning task's files.
  - If it is red either way, check the same suite on `main` before calling it pre-existing.

- [ ] **Step 2: Confirm the scope of the change**

  - `git diff main...HEAD --stat` touches only the files in the file map, plus the plan and
    the spec.
  - `git diff main...HEAD -- dot_claude/modify_private_settings.json` changes only the
    `denyWrite` expression and its comment.

- [ ] **Step 3: Hand the post-apply checks to Michael**

  These are listed in the final report, not run here:
  1. In a fresh session started in a `~/Code` repository, run sandboxed
     `./tests/run.sh live-write-boundary`: all keys pass. Repeat from a session started in a
     `wt` sibling.
  2. In his shell, `git -C <some bare repository> log` is refused, and the `--git-dir` form
     works.
  3. Over the next week, `~/.local/state/agent-audit/prompts.jsonl` shows no prompt naming a
     path these entries cover.

## Post-review amendments

The final whole-branch review, and the spec amendment of 2026-10-30 that followed it, change
the plan in these ways. They supersede the task text above where they differ; the task text is
left as written.

- **209 entries, not 181.** The reviews added 28 `denyWrite` entries to the 39 planned
  (67 new on 142): 12 worktree-module forms (`config*`, `commondir` and `hooks` under
  `.git/worktrees/*/modules/**`, for each root), 4 `HEAD` entries (`~/Code/HEAD`,
  `~/Documents/HEAD`, the vault's `**/HEAD`, `~/Code/*/HEAD`), and 12 tool-configuration
  entries (`<root>/**/.lazygit.yml`, `<root>/**/.git/**/lazygit.yml`,
  `<root>/**/.git/glab-cli/config.yml`). `claude-settings` pins the exact array of 209, the
  new glob cases and the widened invariant. `live-write-boundary` gets probes for the HEAD,
  worktree-module and tool-configuration keys, and the three Unicode-fold keys.
- **The Task 3 escape line is three lines**, not two.
- **The Apple-git check skips instead of passing.** When Apple git is absent, `git-config`
  prints a skip line that `tests/run.sh` does not count as a pass, not an `ok`.

## Finishing

The controller, after the whole-branch review and an approving pre-merge cross-review:
- sets the spec's and this plan's **Status** to
  `Implemented on fix/sandbox-git-config-plant (the dotfiles have no MR)`;
- marks this plan as not to be run again;
- pushes the branch.

Merging, `chezmoi apply` and the post-apply checks are Michael's.
