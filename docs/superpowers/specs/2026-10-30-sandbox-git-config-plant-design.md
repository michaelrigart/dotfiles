# Sandboxed sessions cannot plant git configuration

**Status:** Approved
Signed off 2026-10-30 under Michael's delegation while he was away.
**Date:** 2026-10-30
**Branch:** `fix/sandbox-git-config-plant`

This spec closes the open finding of 2026-10-29: a sandboxed session wrote another
repository's git configuration, and git outside the sandbox ran it. It supersedes one decision
of the [sandbox write boundary](2026-10-16-sandbox-write-boundary-design.md): §1 "Git", under
which configuration files stay writable, and the matching Out-of-scope entry. That spec's
hooks denial, `PATH` pins and git neutralisation stay as they are. Its record keeps its text;
the plan adds a one-line pointer to this spec beside the superseded decision.

All measurements here were taken on 2026-10-30, sandboxed, in a session started in a Claude
Code harness worktree of the chezmoi checkout. Versions: Claude Code 2.1.314, git 2.56.0
(Homebrew) and 2.54.0 (Apple), Starship 1.27.0, herdr 0.9.5. Probes ran in `$TMPDIR` and in
uniquely named directories under `~/Code` and the worktree. They used harmless keys and marker
files, and everything they made was removed. "Read from the binary" marks a claim taken from
reading Claude Code's code rather than from a probe.

## Problem

- **The plant.** On 2026-10-29 a session rooted in the chezmoi checkout ran
  `git init ~/Code/<x>` and `git config core.fsmonitor <script>`. An unsandboxed `git status`
  in that repository then ran the script. Re-measured on 2.1.314: `git init` and `git config`
  in a new repository under `~/Code` still succeed sandboxed.
- **Claude Code protects only the session's own repository** (read from the binary).
  - **What it protects.** Its built-in write denials cover `config`, `config.lock`,
    `config.worktree`, `commondir`, `hooks`, alternates, each linked worktree's
    `config.worktree` and `commondir`, the `.git` file, and a planted `HEAD`, `objects` or
    `refs`.
  - **Where.** They apply to the session's working directory, its git common directory, and
    directories granted at runtime. Its `**/.git/config` and `**/.git/hooks` globs are
    anchored at the working directory.
  - **What is left out.** A repository reached only through `sandbox.filesystem.allowWrite`
    gets none of this.
  - **Measured from this harness worktree.** The chezmoi checkout's `.git/config`, the
    worktree's own `.git` file and its `commondir` are denied, and its `gitdir` is writable.
- **Nothing has to be typed.** Starship draws git status on every prompt, with gitoxide.
  Measured: in a repository whose configuration names a clean filter, Starship ran that filter
  while drawing the prompt. A file's stat data had changed, and no git command was typed. A
  `core.fsmonitor` hook set in that same repository did not run, so the filter ran inside
  Starship itself, not in a git it called.
- **Why the 2026-10-17 decision no longer holds.** That decision kept configuration writable
  for two reasons. Agent-touched repositories were to trust their metadata as they trust their
  code, and a deny would add escapes. Neither still holds:
  - the plant reaches any repository under a work root, and new ones;
  - drawing a prompt runs it, with no git command typed;
  - the escapes it adds are few (Costs).

## Threat model and scope

**Attacker.** A sandboxed agent session, possibly steered by what it reads: a repository, an
issue, a web page.
- It runs any shell command the sandbox allows, as Michael's uid.
- It writes under the four work roots (`~/Code`, `~/.local/share/chezmoi`, `~/Documents`,
  the Obsidian vault) and under `$TMPDIR`.
- The auto-mode classifier sees every sandboxed command (spec 2026-10-28, §2).
- Its aim is to run code as Michael outside the sandbox.

**Route in scope.** Git metadata that git executes and no diff shows: configuration, and the
files that decide which configuration git reads. Everything that reads it runs outside the
sandbox:
- Starship, on every prompt;
- Michael's git, lazygit and Neovim's git integration;
- herdr;
- `phase.sh` and `xreview`, which turn off fsmonitor, hooks and filters (spec 2026-10-16, §2);
- the Codex daemon;
- Claude Code's own git, which turns off fsmonitor and hooks but not filters (read from the
  binary);
- the basecamp plugin hook.

**Trust stance.**
- Tracked content keeps the trust it had: diffs show it for review, and Michael runs it when
  he runs the project.
- Untracked git metadata that git executes must not be writable from the sandbox. The
  2026-10-16 spec closed hooks; this spec closes configuration.

**Goals.**
1. Under every work root and in every repository, no sandboxed command can write, without the
   escape:
   - a git configuration file;
   - a configuration redirect (`commondir`);
   - a `.git` entry where no repository may be.
2. Git outside the sandbox does not treat a directory that only looks like a git directory as
   a repository.
3. No new prompts. Every escape the change adds is named and measured.

**Non-goals.**
- Renaming a git directory, or writing a `.git` file inside a repository's work tree. Path
  rules cannot see either (Residuals).
- Sessions started in `~`. Their write scope is all of `$HOME`, a gap wider than git
  (Residuals).
- Codex's own sandbox, and anything written outside the sandbox.

## Vectors

| # | Vector | Measured today | Disposition |
|---|---|---|---|
| V1 | Another repository's `.git/config` | writable: `git init` and `git config` succeed under `~/Code` | in scope, §1 |
| V2 | `.git/config.worktree` | writable | in scope, §1 |
| V3 | `.git/commondir` in an ordinary `.git` | writable. Git then reads the `config` of the directory it names; one in `$TMPDIR` was read | in scope, §1 |
| V4 | `.git/worktrees/<id>/config.worktree` and `commondir` | writable | in scope, §1 |
| V5 | `.git/worktrees/<id>/gitdir` | writable. Claude Code leaves it writable for the session's own worktree too | out: git reads it only to list, prune and repair worktrees, never for configuration. A bad value can lose a worktree record; it runs nothing |
| V6 | `.git/modules/**/config`, `config.worktree` and `commondir` | writable | in scope, §1 |
| V7 | A `.git` file whose `gitdir:` names a directory the sandbox writes, such as one in `$TMPDIR` | writable. Git in that directory and below read the `$TMPDIR` configuration | in part: §2 covers the roots' top level, the vault and harness worktrees. Elsewhere a residual |
| V8 | `.git/hooks` outside the start directory | denied since 2026-10-16 (measured again). `mkdir .git/HOOKS` is denied as well | no change |
| V9 | `include.path`, `includeIf` | Adding one needs a configuration write (V1). The global configuration includes nothing. Of 86 repository configurations under the work roots, none includes a file. One names a work-tree file: in `presence`, Rails set `diff.rails_credentials.textconv = bin/rails credentials:diff` | reduces to V1. `bin/rails` is tracked code (Trust stance) |
| V10 | A fake git directory: `HEAD`, `objects/`, `refs/` and `config` in a plain directory | git uses it, even with `core.bare = false` and `core.worktree` set | for git, in scope (§3). Starship ignores `safe.bareRepository` (residual) |
| V11 | Global and system configuration | denied: `~/.config/git/config`, `/opt/homebrew/etc/gitconfig`, and the Command Line Tools' and Xcode's `gitconfig`. `~/.gitconfig` and `/etc/gitconfig` do not exist, and `$HOME` is not in the write set | no change, except in a session started in `~` (Residuals) |
| V12 | `.gitattributes` and `.git/info/attributes`: filter, diff and merge drivers | An attribute only names a driver, which runs only if configuration defines it. The global and system configurations define none, and git-lfs is not installed | reduces to V1 |
| V13 | mise | trusts a configuration by its content hash (`paranoid = true`, spec 2026-10-16 §2) | no change |
| V14 | direnv | allows an `.envrc` by content hash. Its allow list is outside every work root. The one `.envrc` under `~/Code` has only `export` lines | no change |
| V15 | bundler's `.bundle/config` | read only when Michael runs the project's Ruby, which runs the agent-writable `Gemfile` anyway | out: the project's code, same trust |
| V16 | What Starship reads per directory | no project configuration (only `~/.config/starship`). The language-version modules go through mise shims (V13). Git: V1 to V12 | covered by this spec |
| V17 | What herdr reads per directory | git metadata files, plus the git CLI: `rev-parse`, `symbolic-ref`, `worktree list --porcelain`. Its configuration lives in `~/.config/herdr` | covered by this spec |
| V18 | Renaming a `.git` directory away and back, or moving in one built in `$TMPDIR` | writable: `mv .git .gx`, write `.gx/config`, `mv .gx .git` | residual |
| V19 | Alternates, legacy `.git/remotes`, in-progress operation state (`rebase-merge/git-rebase-todo`) | writable | out. Alternates and remotes run no code: git refuses `ext::` URLs by default, and a `<helper>::` URL runs a `git-remote-<helper>` from `PATH`, where the sandbox cannot write. A todo's `exec` line runs only when Michael continues an operation he did not start, which the prompt shows (`REBASING`) |

## Design

### 1. Deny git configuration in every work root

`sandbox.filesystem.denyWrite` gains these six forms for each work root `<root>` (24 entries):

```
<root>/**/.git/config*                <root>/**/.git/commondir
<root>/**/.git/worktrees/*/config*    <root>/**/.git/worktrees/*/commondir
<root>/**/.git/modules/**/config*     <root>/**/.git/modules/**/commondir
```

- **How these compile** (read from the binary).
  - A glob becomes the Seatbelt regex `^<glob>(/.*)?$`, so each entry also covers everything
    below it.
  - `**/` becomes `(.*/)?`, so depth 0 is included: `~/.local/share/chezmoi/**/.git/config`
    covers the checkout's own `.git/config`.
  - `*` becomes `[^/]*`.
  - A deny wins over `allowWrite`.
  - A glob also stops anything from unlinking or creating its anchor (the text before the
    first wildcard) and the anchor's parents.
- **`config*` rather than four names.** One entry covers `config`, `config.lock`,
  `config.worktree` and `config.worktree.lock`.
  - Git writes configuration through its lock file. Denying the lock makes git fail before it
    writes anything. Measured under Claude Code's own rule: "could not lock config file …
    Operation not permitted", with no lock file left behind.
  - Nothing else in a git directory has a name starting with `config`. The exception is
    `.git/modules/**`, where `**` also reaches a submodule's refs, so a submodule branch whose
    name starts with `config` cannot be created sandboxed. Only one repository here keeps
    submodule git directories: `Netronix/ansible-data`, untouched since 2023, with none of its
    submodules checked out.
- **`commondir`** decides where git reads `config` from, in an ordinary `.git` (V3) as well as
  in a linked worktree's directory.
- **What stays writable:**
  - objects, refs, the index, `HEAD`, logs, `info/` and `gitdir`. That includes a branch named
    `config` or `hooks`, because `refs/heads/config` is not `.git/config`;
  - everything outside the work roots, `$TMPDIR` included, where the suites build their
    repositories.
- **Letter case.** The volume here is case-insensitive, and Seatbelt matched regardless of
  case:
  - appending to an existing `.git/config` as `.git/CONFIG` or `.GIT/config` was denied by
    the `.git/config` rule;
  - creating `.git/HOOKS` where no `hooks` existed was denied by the `.git/hooks` rule.
- **Anchored per root, not at `~/**`.** Every deny entry still starts with a work root, the
  invariant `claude-settings` pins. A `~`-anchored set would only add repositories outside
  the work roots. Those matter only to a session started in `~`, and that session can already
  write the code itself (Residuals).

### 2. Deny `.git` where no repository may be

`denyWrite` also gains 15 entries.

- **`~/Code/.git` and `~/Documents/.git`.** Neither root is a repository. A `.git` file there
  would pull into a repository, whose configuration the sandbox wrote, every directory below it
  that has no closer `.git`: the organisation directories, `ansible-roles`, `juggler_cms_v1`.
- **`~/Library/Mobile Documents/iCloud~md~obsidian/**/.git`.** The vault holds no repository
  (checked), so a `.git` at any depth there is denied.
- **Every Claude Code harness worktree's `.git` file**, at the three fixed depths the agent
  configuration entries already use:
  - `<root>/.claude/worktrees/*/.git`
  - `<root>/*/.claude/worktrees/*/.git`
  - `<root>/*/*/.claude/worktrees/*/.git`

  That entry is always a file, and Claude Code writes it itself, not through sandboxed Bash.
  Without the entry, a sandboxed session in one harness worktree could repoint another
  worktree's `.git` file at a directory it wrote. For the session's own worktree, Claude Code
  already denies it (measured).
- **Not at the organisation level.** Repositories sit at depths 1, 2 and 3 under `~/Code`
  (`~/Code/tagteam`, `~/Code/Netronix/curato`, `~/Code/Netronix/ansible-roles/<role>`).
  - So `~/Code/*/.git` would deny real repositories' `.git` directories, and every write in
    them: a deny on a path covers everything below it.
  - Claude Code's settings cannot deny creating a `.git` file while allowing a `.git`
    directory.
  - A `wt` sibling's `.git` file sits at the same depth as a main checkout's `.git`
    directory, so it gets no entry (Residuals).

### 3. Git refuses fake git directories

`dot_config/git/config` gains:

```
[safe]
	bareRepository = explicit
```

- **Measured with both gits.**
  - **Refused:** a plain directory holding `HEAD`, `objects/`, `refs/` and `config`,
    including one with `core.bare = false` and `core.worktree` set. Git reports "cannot use
    bare repository … (safe.bareRepository is 'explicit')". `git config` there reads no
    repository configuration.
  - **Still working:**
    - `--git-dir` and `GIT_DIR`;
    - a `.git` directory, and running git inside it;
    - linked worktrees;
    - clone, fetch, push and `ls-remote` against a bare repository named by path or by
      `file://`.
- **What relied on implicit bare discovery.** Checked; nothing current:
  - **The suites.** Three (`hook-path`, `xreview-guard`, `chezmoi-wrapper`) run git inside a
    bare repository with `-C`. Each sets `GIT_CONFIG_GLOBAL` to its own file, so a global
    setting never reaches them.
  - **SwiftPM and uv.** Both resolved a git dependency through their bare mirrors with the
    setting on (measured). SwiftPM keeps them in `.build/repositories` and
    `~/Library/Caches/org.swift.swiftpm`.
  - **bundler.** Versions from 4.0.21 name their bare cache with `--git-dir`; older ones do
    not. The only project with a `git:` source, `Enperas/quadrant`, is locked to bundler
    2.4.20 (with Ruby 3.2.2, which is not installed). Its next `bundle install` needs a newer
    bundler.
  - **The rest.** Cargo, npm and Go hold no bare repositories here. Homebrew taps, mise
    plugins and Neovim plugins are ordinary clones.
- **Starship does not honour it** (measured). It found a fake git directory with gitoxide and
  ran its filter, whether or not the setting was on. With `git_status.use_git_executable` on,
  the filter still ran. The likely reason, read from Starship's binary rather than measured:
  its git call names the directory it found with `--git-dir`, and git counts that as
  explicit. The setting closes V10 for git and everything that runs git; for the prompt,
  V10 stays a residual.

### 4. The instructions say so

Michael's CLAUDE.md already says a write to a repository's `.git/config` needs the escape. It
now holds for every repository. The escape line in the Claude-only fragment
(`.chezmoitemplates/agents/claude-code.md`) names what needs it:
- `git init`, `clone`, `remote add`, `config` and `branch -u`;
- `switch --track`, or any new branch started from a remote-tracking ref;
- `submodule` and `worktree add`.

The fragment stays within its 50-line cap.

### Not taken

1. **Deny whole `.git` directories under the roots.** This would close V7 and V18. But every
   commit, fetch and `git add` in every repository, the session's own included, would then
   need the escape.
2. **Per-repository literal denies, rendered at apply.** A literal deny also stops its parents
   from being renamed, which closes V18 for the repositories it lists. But the list goes stale
   with every `wt`, and it grows with every checkout.
3. **Neutralise the executing keys for Michael's git** (`GIT_CONFIG_*` in his shell or in
   Starship's environment). The executing keys are open-ended (`filter.*`, `alias.*`,
   `hook.*`, `diff.*.textconv`), and the overrides would change his own git.
4. **Starship's `git_status.use_git_executable`.** Measured: it does not stop Starship
   (§3).
5. **Turn off Starship's `git_status`.** herdr's status, Neovim's git integration and Claude
   Code's own status would still read the repository, and the prompt would lose its status.
6. **A periodic audit for `.git` files and fake git directories.** It detects rather than
   prevents, and adds a component to maintain.
7. **`Edit(…)` deny rules instead of `denyWrite`.** They have the same effect on sandboxed
   Bash. `denyWrite` is what the 2026-10-16 entries use. The Edit and Write tools never
   auto-edit inside `.git` anyway: it is on their list of dangerous directories (read from
   the binary).

## Costs

Each command below already fails the same way in the session's own repository today, under
Claude Code's built-in rule. The change is that it now fails in every repository under a work
root. Measured under that built-in rule, on a scratch repository with a bare remote:

| Command | Result when sandboxed |
|---|---|
| `git commit`, `fetch`, `pull --ff-only`, `stash`, `rebase`; `push` to an existing upstream; `switch -c <b>` from a local start point | unchanged |
| `git push -u`; a plain `git push` of a branch with no upstream (`push.autoSetupRemote = true`) | pushes and exits 0, printing "unable to write upstream branch configuration". No upstream is recorded, so the next plain push prints it again |
| `git branch -d` | deletes and exits 0, printing "update of config-file failed". A `branch.<name>` section, if there was one, stays |
| `git switch -c <b> --track origin/x`, `git switch -c <b> origin/x`, `git switch <remote-only branch>` | exits 1 and stays on the current branch. The first two leave the new branch created; `--no-track` avoids the failure |
| `git branch -u`, `remote add`, `config`, `clone`, `init`, `submodule add` or `update`, `worktree add` | fails; needs the escape |
| `rm -rf` of a repository under a root | removes everything except the repository's configuration (and hooks, if it has any), then fails; needs the escape |

- **Frequency.** Across the 4,148 transcript files of the last 30 days, the only sandboxed
  configuration writes aimed at a repository other than the session's own were three
  cross-repository `git push -u`. All three still push. Every other match was either the
  session's own repository (already denied) or a false positive.
- **Prompts: none added.**
  - A sandbox denial is a silent `Operation not permitted`.
  - An escape goes to the auto-mode classifier, not to Michael.
  - `safe.bareRepository` and the instructions add no prompt either.
- **Not affected:**
  - `wt`, `wt-rm`, `xreview` and herdr, which run unsandboxed;
  - harness worktrees, which Claude Code creates itself, outside the Bash sandbox;
  - the suites, whose repositories live in `$TMPDIR`;
  - the escape itself.
- **Michael's own git.** A `git -C <bare repository>` now needs `--git-dir` instead (§3).

## Testing

### Focused suites

- **`claude-settings`.**
  - `denyWrite` equals the expected array exactly: the 2026-10-16 entries, plus §1's 24 and
    §2's 15.
  - Every entry starts with a work root and a slash, so `$TMPDIR` stays writable.
  - Each root has all six §1 forms.
  - No entry reaches objects, refs or the index.
  - No entry has the shape `.git/**/config`, so a branch named `config` stays writable. Only
    `.git/modules/**/config*` reaches refs, and only a submodule's.
  - The old assertion "no deny glob reaches a git configuration file" is replaced by these.
- **The global git configuration**, in `git-signing-config` or a new suite.
  - The rendered file sets `safe.bareRepository = explicit`.
  - With `GIT_CONFIG_GLOBAL` pointing at the rendered file, in `$TMPDIR`:
    - `-C` refuses a fake git directory, and `--git-dir` accepts it;
    - a repository, a linked worktree and a local bare remote (clone, fetch, push) work.
- **`agent-instructions`.** The fragment stays within 50 lines.

### `live-write-boundary`

The suite runs sandboxed, in a fresh session after `chezmoi apply`.

- **Fixture repositories, in the three roots that may hold one** (`~/Code`, the chezmoi
  checkout, `~/Documents`). In each of these roots' fixtures (a `mkdir`'d `.git`), these are
  denied:
  - `config`, `config.lock`, `config.worktree`, `commondir`;
  - `worktrees/wt/config.worktree`, `worktrees/wt/commondir`;
  - `modules/sub/config`, `modules/sub/commondir`,
    `modules/sub/worktrees/swt/config.worktree`.

  They replace today's `*_writable` probes. The main `config` probe no longer skips the
  session's base directory. Objects, the index, `refs/heads/config`, `refs/heads/hooks` and
  `worktrees/wt/gitdir` stay writable.
- **The vault gets no git fixture.** §2 denies `.git` at any depth there, so the suite's
  `mkdir -p` of a fixture `.git` would fail. The vault's fixture has no `.git`. Its git probes
  are the `.git` denials below, and its agent-configuration probes run unchanged without one.
- **`.git` where no repository may be.** Creating `.git` is denied in these places:
  - directly under `~/Code`, as a file;
  - directly under `~/Documents`, as a file;
  - two levels down in the vault, as a directory and as a file;
  - at `<root>/<stamp>/arepo/.claude/worktrees/wt1/.git`, as a file, in every root.
- **Case.** In the repository of the behaviour probe below, appending to its existing
  `config` as `.git/CONFIG` is denied, and so is creating the absent `commondir` as
  `.git/COMMONDIR`.
- **Informational, like the rename probe.** A `.git` file in a plain directory two levels
  down, outside the vault, reads WRITABLE (Residuals).
- **Behaviour.** A repository is built in `$TMPDIR`, with a bare remote there, then moved
  under `~/Code/<stamp>/`. There:
  - `git commit` succeeds;
  - `git config` fails;
  - `git push -u` exits 0 and records no upstream;
  - `git worktree add` fails.

  The suite then moves the repository back to `$TMPDIR` to delete it, because `rm -rf`
  cannot remove its `.git/config` in place.
- **The chezmoi checkout's own `.git/config`** is denied. The probe opens it for append and
  writes nothing.
- **`$TMPDIR`.** A `.git/config` there stays writable (an existing probe).

### After Michael's apply

1. In a fresh session started in a `~/Code` repository, `./tests/run.sh live-write-boundary`
   passes. It passes again from a session started in a `wt` sibling.
2. In his shell, `git -C <some bare repository> log` is refused, and the `--git-dir` form works.
3. Over the following week, `~/.local/state/agent-audit/prompts.jsonl` shows no prompt that
   names a path these entries cover.

## Residuals

- **Renames (V18).** A rename is checked only at its two ends.
  - A git directory moved aside, edited and moved back keeps what was written into it. So does
    one built in `$TMPDIR` and moved into a root.
  - An agent that avoids the clone escape by cloning into `$TMPDIR` and moving the clone in
    keeps git's own configuration. Only keys it added on purpose would matter, and the
    instructions name `clone` as needing the escape.
  - This is the class of the hooks rename that the 2026-10-16 spec accepted. The classifier
    sees each command.
- **`.git` files elsewhere (V7).** A `.git` file can point git at a directory the sandbox
  wrote:
  - a new one inside a repository's work tree;
  - a new one in a non-repository directory below a root's top level;
  - an existing one rewritten: a `wt` sibling's, or a submodule's.

  Path rules cannot tell a `.git` file from a `.git` directory. Claude Code could close this,
  by denying regular files named `.git` or by extending its own `.git` protection to the
  `allowWrite` roots, but its settings offer neither today.
- **Starship and fake git directories (V10).** Starship reads a fake git directory and runs
  its filters despite `safe.bareRepository`. The prompt has to be drawn inside that directory.
- **Configuration that names tracked files**, such as `presence`'s textconv `bin/rails`: that
  is tracked code, reviewed like any change.
- **Sessions started in `~`.** Their write scope is all of `$HOME`.
  - Claude Code's own list protects `~/.gitconfig` and the shell rc files. It does not cover
    `~/.config/git`, `~/.config/zsh`, `~/.local/bin` or `~/Library/LaunchAgents` (read from
    the binary).
  - Michael's transcripts hold 21 sessions started in `~`.
  - A git-only deny there would close one door of many. This needs its own spec.
- **Not code execution:** a worktree's `gitdir` (V5), and the alternates, legacy remotes and
  operation state of V19.

## Calls made in writing this spec

1. Anchor per work root, not at `~/**` (§1).
2. Use `config*` rather than enumerating names. Its cost is submodule branches whose names
   start with `config` (§1).
3. Deny `.git` at `~/Code/.git`, at `~/Documents/.git` and anywhere in the vault, not at the
   organisation level (§2).
4. Deny harness worktrees' `.git` files, not `wt` siblings' (§2).
5. Adopt `safe.bareRepository = explicit` although Starship bypasses it. Its cost is
   `quadrant`'s bundler (§3).
6. Keep Starship's `git_status` (Not taken, 5).
7. Leave `.git/worktrees/*/gitdir` writable (V5).
8. Use `denyWrite`, not `Edit(…)` rules (Not taken, 7).
9. Leave sessions started in `~` to their own spec (Residuals).
