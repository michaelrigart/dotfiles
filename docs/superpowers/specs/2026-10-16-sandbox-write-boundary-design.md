# Sandbox write boundary

**Status:** Approved
**Date:** 2026-10-16
**Branch:** `feat/sandbox-write-boundary`

The first of two sandbox specs that follow the
[post-evaluation optimisations](2026-10-16-post-evaluation-optimisations-design.md). This
one closes the boundary: nothing a sandboxed command writes may later run outside the sandbox
without review. The second spec, later, takes the escape habits (2,262 escapes in 14 days,
3.3% of Bash calls) cluster by cluster.

## Problem

The sandbox lets Bash write to `~/Code`, `~/.local/share/chezmoi`, `~/.local/bin`,
`~/.config`, `~/Documents` and the Obsidian vault (widened on 2026-08-02 so ordinary work
stopped escaping). Several of those places hold code that something outside the sandbox runs
later, with no review in between. Probed on 2026-10-16:

| Sandbox-writable | Run outside the sandbox by |
|---|---|
| `~/.local/bin`, first on every `PATH` | every hook and the statusline (`bash`, `jq`, `git`, `python3` resolve there first); the excluded commands `docker`, `basecamp`, `herdr`, `xreview`, which run unsandboxed with no prompt; Michael's shells; the hooks' `ssh-sandbox-proxy` |
| `~/.config/zsh/*` | every shell Michael opens: `~/.zshrc` sources it. Claude Code's built-in denial protects `~/.zshrc` itself, not what it sources |
| `~/.config/git` | Michael's git and the hooks' git: aliases, `core.hooksPath`, `core.sshCommand`, `core.fsmonitor`, a promisor remote that a lazy fetch runs |
| `~/.config/mise/config.toml` | every mise shim: `[env]` directives can source scripts |
| `~/.config/herdr` | herdr's `[[keys.command]]`; the launchd job `be.netronix.herdr-phase-refresh` runs `~/.config/herdr/phase.sh` |
| `~/.config/ghostty`, `glab-cli`, … | the terminal, and glab's `editor` and `browser` |
| `~/Code/*/.git/hooks` (creatable) | Michael's own `git commit`; a hook is invisible to `git diff`, so no review sees it |
| the vault's `.obsidian` | Obsidian runs community plugins listed there, with full access |
| the chezmoi working tree, uncommitted files included | Michael's `chezmoi apply`, `run_` scripts and all |

A second route needs no planted file in those places. The hooks find `jq` through the mise
shims. In a repository whose `mise.toml` is trusted, the shim loads it, and the repository is
sandbox-writable, so a hook can run what an agent wrote into it. Separately, the push guard's
outgoing-commit listing (`git rev-list … --not --remotes=<remote>`) lazy-fetches through a
promisor remote when a remote-tracking ref points at a missing object (reproduced).

Transcripts from the last 30 days show no agent writing to `~/.config`, `~/.local/bin`,
`.git/hooks` or `.obsidian`, whether sandboxed or not. The files changed there in 14 days came
from herdr, basecamp, borg and `chezmoi apply`, all of which run outside the sandbox. Closing
these places should cost no escapes.

## Design

### 1. The write set: default deny

- `sandbox.filesystem.allowWrite` drops `~/.config` and `~/.local/bin`. It keeps `~/Code`,
  `~/.local/share/chezmoi`, `~/Documents` and the vault.
- `sandbox.filesystem.denyWrite` (or the matching `Edit(...)` deny rules, which Claude Code
  merges into the sandbox's write denials) adds the executing places inside what stays
  writable, in every remaining write root (`~/Code`, the chezmoi checkout, `~/Documents`, the
  vault):
  - in any git directory at any depth, its hooks and its configuration files: `hooks/`,
    `config`, `config.worktree` and the same files under `modules/` and `worktrees/` (a
    submodule's or a linked worktree's own). Claude Code already denies a repository's
    top-level `.git/config`; this covers the rest. Only the files that name commands are denied.
    Objects, refs and the index stay writable, so sandboxed `git add`, `commit` and `fetch` keep
    working;
  - the vault's `.obsidian`.

  The plan picks whichever form the sandbox enforces for a glob, by probe.
- **Re-allowing.** A path goes back into the write set only when a sandbox denial shows that a
  sandboxed tool needs it, and nothing outside the sandbox executes it or reads commands from
  it. A file that names an editor, a browser, a hook or a shell command fails that test.
  Each one is recorded in this spec with its evidence. None is re-allowed today. If sandboxed
  `glab` needs to write `~/.config/glab-cli/config.yml`, that file stays denied, because it
  names glab's editor and browser. That glab call then joins the escape clusters of the next
  spec.

### 2. What runs outside the sandbox resolves nothing writable

- **Hooks and statuslines.**
  - Every hook command and both statusline commands in the settings name their interpreter by
    absolute path (`/opt/homebrew/bin/bash`).
  - Every hook script and helper sets `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin`
    before it runs anything. `jq`, `git` and `python3` then come from `/usr/bin`: jq 1.7.1,
    git 2.54 and the system Python. `gitleaks` and `tagteam` come from Homebrew.
  - No hook or statusline goes through a mise shim, `~/.local/bin` or `~/.cargo/bin`. A hook
    that needs a tool from `~/.local/bin` calls it by absolute path; with §1 that directory is
    no longer sandbox-writable.
  - The suites still stub a tool (the statusline's `tagteam`, for one) through an override
    variable, `PINNED_PATH`. The script reads that variable only from its own environment. For
    a hook that environment is Claude Code's. For an excluded command it is the Bash tool's
    base environment: a command prefixed with an assignment is no longer excluded, so it runs
    sandboxed. No sandboxed command can change either environment.
- **The push guard.** Every git call it makes runs with lazy fetch off
  (`GIT_NO_LAZY_FETCH=1`, which git 2.54 supports), except the gitleaks scan. That scan may
  need blobs in a genuine partial clone, and with §1 no sandboxed command can configure a
  promisor remote any more. This closes the reproduced `rev-list` route.
- **Excluded commands.**
  - `docker`, `basecamp` and `herdr` are binaries, so §1 covers them.
  - `xreview` is a script of ours. It and the helpers it calls (`xreview-rpc`, `codex-daemon`)
    look up `jq`, `git` and the rest by name, which would reach a mise shim and so a trusted
    repository's `mise.toml`. They pin
    `PATH=$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin`, with no mise
    shims. `~/.local/bin` stays first, so the `codex` launcher still shadows Homebrew's, and §1
    makes it unwritable.
- **Launchd jobs** resolve through `~/.local/bin` and `~/.config`, which §1 closes.
- **The test override.** Every pinned script takes its `PATH` from `PINNED_PATH` when that is
  set. The suites set it to their stub directories.

### 3. `chezmoi apply` deploys only reviewed source

The source checkout cannot prove what was reviewed. A sandboxed command can do any of these:
- commit to the local `main`;
- move a remote-tracking ref;
- hide a file from `git status` through `.git/info/exclude` (chezmoi applies ignored files as
  well);
- add a replacement ref;
- write a loose object under the name of a reviewed commit.

So the deployment input comes from origin, never from the checkout's files or object store.

A zsh wrapper around `chezmoi` handles `apply` and `update`.
- **Precondition.** It refuses, naming the reason, unless the checkout is on `main`, has no
  uncommitted or untracked changes, and its `HEAD` equals origin's `main`, read with
  `git ls-remote origin refs/heads/main`. That read runs in Michael's unsandboxed shell,
  against a remote whose configuration §1 protects. `update` first fast-forwards the checkout
  with `git pull --ff-only`, then checks the same way.
- **Deployment.**
  - It clones origin's `main` afresh: `git clone --depth 1 --branch main --template=` into a new
    temporary directory. The empty template means no hooks are copied in, and the clone has
    its own object store, which `index-pack` verifies object by object.
  - It checks that the clone's `HEAD` is the commit `ls-remote` returned. Then it runs chezmoi
    with `--source` pointing at the clone. The checkout's files, ignored files, refs,
    replacements and objects play no part.
  - Templates and scripts that read `.chezmoi.sourceDir` see the clone. The plan lists each one
    and shows it still works there.
  - The temporary directory is removed afterwards, whatever the outcome.
- **Override.** `--dirty-ok`, removed before chezmoi sees it, skips both and applies the
  working tree as today, for a deliberate local change.
- `init --apply` and `edit --apply` are refused with a pointer to `apply`.
- Commits reach origin's `main` only through Michael: his merge, or a default-branch push that
  the push guard put to him. Only Michael runs `chezmoi apply`; agents never do.

## Expected effect

- No new escapes or prompts: nothing sandboxed wrote to the closed places in 30 days.
- After `chezmoi apply` and a new session, every place in the Problem table is unwritable from
  the sandbox, and no hook, statusline or excluded command can be steered by a sandboxed
  write.
- The next escape measurement (with the 2026-10-31 re-measure) shows no new cluster of escapes
  for `~/.config` or `~/.local/bin` writes. If one appears, it goes through the re-allow test
  in §1.

## Testing

- **A new live suite, `live-write-boundary`.** Its `test-requires` are sandboxed and a fresh
  session after `chezmoi apply`, like `live-credential-boundary`. It tries to create a file in
  each denied place and expects a denial, and in each place that stays writable and expects
  success. It cleans up after itself and reports `KEY=VALUE`.
- **`claude-settings`.** The exact `allowWrite` and `denyWrite` arrays (or deny rules), and
  that every hook and statusline command names an absolute interpreter.
- **The hooks.** Each hook and the statusline runs with a hostile `PATH`: a directory first on
  it holds `bash`, `jq`, `git` and `python3` stubs that write a marker. No marker may appear.
  The list of hooks comes from the settings themselves, so a new hook without the pin fails.
  `xreview`, `xreview-rpc` and `codex-daemon` get the same check, with a mise-shim directory
  holding a stub `jq`.
- **`git-forge-guard`.** The reproduced lazy fetch: a dangling remote-tracking ref plus a
  promisor remote whose `uploadpack` writes a marker. The push still gets its usual verdict,
  and no marker appears.
- **The `chezmoi` wrapper**, against a local bare "origin":
  - **Refusals.** It refuses, with the reason, each of: another branch; an uncommitted change;
    an untracked file; a local commit that origin lacks; origin ahead of the checkout.
  - **Clean `main`.** On a clean `main` equal to origin, it applies the fresh clone.
  - **Planted content.** None of these reaches the applied source, as a marker script proves:
    - a `run_` script hidden through `.git/info/exclude`;
    - a replacement ref for origin's commit;
    - a forged loose object under that commit's name;
    - a moved `refs/remotes/origin/main`.
  - **Override and refusals.** `--dirty-ok` applies the working tree and never reaches
    chezmoi as an argument. `init --apply` and `edit --apply` are refused.
- **`live-write-boundary`** also covers a repository outside `~/Code` (in `~/Documents`): its
  `hooks/` and `config` files are denied there too, while its objects and refs stay writable.

## Out of scope

- The escape habits: the next spec (cargo, Python heredocs, `.git/config` writes, kubectl,
  brakeman, glab, the manual-demo server and headless Chrome, `ps`, `mise trust`).
- Code in a repository that Michael runs himself (tests, `bin/dev`). It is the work product
  and goes through review like any change.
- Codex's own sandbox, and anything Michael's unsandboxed processes write.
- The push guard's merged-branch exemption still judges ancestry on the local object store.
  A forged loose object can make an unmerged branch look merged, and the guard then deletes
  it on the remote without asking. Its commits remain in the local objects and the local
  branch, so nothing runs and nothing is lost locally. Executing code is this spec's concern,
  so this is recorded rather than fixed.
