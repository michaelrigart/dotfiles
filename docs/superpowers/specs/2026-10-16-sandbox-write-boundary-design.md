# Sandbox write boundary

**Status:** In progress
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
  - in any `.git` directory at any depth, its `hooks/`, and a submodule's under `modules/`. No
    agent wrote there in 30 days, so this costs no escapes. Objects, refs, the index and the
    configuration files stay writable, so sandboxed `git add`, `commit`, `fetch`,
    `branch -u`, `clone` and `git config` keep working;
  - the vault's `.obsidian`.
- **Git, decided 2026-10-17 (Michael).** The configuration files stay writable; denying them
  would add escapes for real agent work. Over 30 days, sandboxed outside temporary
  directories, that work counted `git branch -u` 4 times, `clone` 6, `submodule` 7,
  `remote add` 3, plus `git config` writes. A path rule also cannot reach a git directory
  that a worktree's or submodule's `.git` file points at under any other name. So agent-touched
  repositories remain a place where agent-written git configuration runs when Michael uses git
  there. This is the same trust as their code, and it is recorded under Out of scope.

  The plan picks whichever form the sandbox enforces for a glob, by probe.
- **Other repositories' agent configuration (Michael, 2026-10-18).** `denyWrite` also names,
  in every work root, at depth 0, 1 and 2: `<root>/<p>`, `<root>/*/<p>` and `<root>/*/*/<p>`
  (work root, organisation directory or top-level repository, repository or `wt` sibling:
  where sessions start) for `.claude/settings.json`, `.claude/settings.local.json`,
  `.mcp.json`, `.codex` and `.codex/**`. Claude Code's built-in denial covers only the
  session's working directory. An agent in one repository could otherwise plant hooks,
  environment variables or MCP servers that a later Claude Code session, or Codex, loads in
  another repository, a `wt` sibling included.
  - **Why bounded.** Not at any depth: npm packages ship such files. `resolve@1.22.12`
    contains `.claude/settings.local.json`, and `~/Code/ViuMore/VM.Website/node_modules/resolve`
    has it, so an any-depth deny makes a sandboxed `npm ci`, a re-extracting `npm install` or
    `rm -rf node_modules` fail with EPERM: new escapes, against this spec's own rule that no
    change adds a prompt or an escape. The live suite probes a `node_modules` package at depth
    4 and expects it writable.
  - **Cost.** None of the 55 repositories under `~/Code` tracked one of these files at depth 2
    or less on 2026-10-18. A sandboxed clone or pull of a repository that does track one would
    fail, and needs Michael's own git.
  - **Out of scope here.** A session started deeper than two levels below a root (a
    subproject directory, for one) has an unprotected project configuration.
  - `.claude/skills`, `commands` and `agents` stay writable; skill and agent frontmatter
    hooks are under Out of scope.
- **Re-allowing.** A path goes back into the write set only when a sandbox denial shows that a
  sandboxed tool needs it, and nothing outside the sandbox executes it or reads commands from
  it. A file that names an editor, a browser, a hook or a shell command fails that test.
  Each one is recorded in this spec with its evidence. None is re-allowed today. If sandboxed
  `glab` needs to write `~/.config/glab-cli/config.yml`, that file stays denied, because it
  names glab's editor and browser. That glab call then joins the escape clusters of the next
  spec.

### 2. What runs outside the sandbox resolves nothing writable

- **Hooks and statuslines.**
  - Every hook command and the one statusline command in the settings name their interpreter
    by absolute path (`/opt/homebrew/bin/bash`). The Brewfile declares `bash`, so dropping
    `direnv` cannot remove it and fail every guard open.
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
  (`GIT_NO_LAZY_FETCH=1`, which git 2.54 supports), its shell entry, the patch listing and
  gitleaks included. A repository's configuration stays agent-writable (§1, "Git"), so the
  guard can never trust a promisor remote. A push from a genuine blob-filtered partial clone
  is therefore denied with the existing "push by hand" message; this machine has none. This
  closes the reproduced `rev-list` route and its patch-listing variant.
- **Excluded commands.**
  - `docker`, `basecamp` and `herdr` are binaries, so §1 covers them.
  - `xreview` is a script of ours. It and the helpers it calls (`xreview-rpc`, `codex-daemon`)
    look up `jq`, `git` and the rest by name, which would reach a mise shim and so a trusted
    repository's `mise.toml`. They pin
    `PATH=$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin`, with no mise
    shims. `~/.local/bin` stays first, so the `codex` launcher still shadows Homebrew's, and §1
    makes it unwritable.
- **Launchd jobs** resolve through `~/.local/bin` and `~/.config`, which §1 closes.
- **mise (Michael, 2026-10-18).** The global mise config sets `paranoid = true`. mise then
  trusts a project config by its content hash, so a `mise.toml`, `.tool-versions` or
  `mise.local.toml` edited since it was trusted is untrusted again until Michael re-trusts it.
  That covers every consumer: his shell, Claude Code's own `PATH` (the language servers it
  starts) and the Codex daemon, which reads `~/.config/mise` through `XDG_CONFIG_HOME`. This
  replaces the earlier plan of setting `MISE_PARANOID` in the `codex-app-server` launchd job
  only; one global setting is the single source of truth. Cost: re-trust with `mise trust`
  after every `mise.toml` change; existing directory trusts are not honoured and need one
  re-trust after `chezmoi apply`; `mise run` and `mise exec` no longer trust automatically.
  Probed 2026-10-18: the global config and an idiomatic `.ruby-version` still load untrusted.
- **Git that our unsandboxed code runs.** A repository's configuration is agent-writable
  (§1, "Git"), so unsandboxed code runs only git forms that execute nothing from it, or
  neutralises the rest.
  - Forms that execute nothing: `rev-parse`, `symbolic-ref`, `branch --show-current`,
    `worktree list`, `rev-list`, `diff` between commits with `--no-ext-diff --no-textconv`,
    `ls-tree`, `hash-object --no-filters`, `cat-file`, `merge-base` and
    config reads.
  - Neutralised: the push guard's and the pre-merge gate's `ls-remote` run with a protocol
    allowlist (no `ext`), no credential helper or askpass, `--upload-pack=git-upload-pack` and
    `GIT_TERMINAL_PROMPT=0`, and fail closed when `core.sshCommand`, `core.gitProxy` or
    `remote.origin.vcs` is set or origin's URL is not a plain transport. `xreview apply` runs
    its diffs with `core.fsmonitor=false`, `core.hooksPath=/dev/null` (a diff that refreshes
    the index would otherwise run `post-index-change` from the configured hooks path) and every
    configured filter emptied. The ledger's patch diff runs with `--submodule=short`:
    under `diff.submodule=diff` the diff of a submodule would otherwise recurse into a child
    diff that runs that submodule's `diff.external` and textconv.
  - Not used: a diff against the index or the work tree, `status`, `ls-files` and `pull`
    fire configured commands (fsmonitor, filters, hooks), except the chezmoi wrapper's own
    `status` and `pull` (Out of scope).
  - `hook-path`'s fixture repositories carry fsmonitor, filter, `sshCommand`, `hooksPath` and
    `ext`/`insteadOf` markers, and those config markers enforce the git rule; the pin
    assertions enforce `PATH`.
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

A zsh wrapper around `chezmoi` handles `apply`, `update` and the previews below.
- **Precondition.** It refuses, naming the reason, unless the checkout is on `main`, has no
  uncommitted or untracked changes, and its `HEAD` equals origin's `main`.
  - Origin is the dotfiles' published URL, pinned in the wrapper. The checkout's own remote
    configuration is agent-writable (§1, "Git"), so it does not choose what is deployed.
  - The wrapper reads `main` with `git ls-remote <pinned URL> refs/heads/main`, in Michael's
    unsandboxed shell. Its git reads of the checkout run with `core.fsmonitor` off.
  - `update` checks the branch and the tree first, then fast-forwards with
    `git pull --ff-only <pinned URL> main`, then compares the same way.
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
- Every command that would apply the working tree is refused with a pointer to `apply`:
  `init --apply`, `init --one-shot`, `edit --apply` and `edit --watch`, in any spelling.
  Every `init` is refused too, `init <url>` included (Michael, 2026-10-17; ruling 2026-10-17:
  a missed value-taking option would otherwise let a bare `init` through): `init` renders the
  checkout's `.chezmoi.toml.tmpl` into the config that every later apply trusts.
  `command chezmoi init` stays available. `chezmoi apply --init` renders the config from the
  verified clone instead.
- **Previews (Michael, 2026-10-18).** `diff`, `status`, `cat`, `verify`, `dump`, `archive` and
  `execute-template` evaluate templates, which can run `modify_` scripts and `output` calls.
  They get the same gate as `apply`: against the verified clone when the checkout is a clean
  `main` equal to origin, otherwise refused with a pointer to `--dirty-ok`. `merge` and
  `merge-all` write the source, which a temporary clone would lose, so they are refused
  without `--dirty-ok`.
- **Help.** Help is detected only as an exact `-h` or `--help` token, or a short-option group
  containing `h` with no `=`, before `--`. The wrapper then runs `chezmoi help <subcommand>`
  itself and never forwards the arguments, so a help flag cannot carry the working tree
  through to a real `apply`. Every `=` form (`--help=false`, `-h=false`) and every `h` after
  a value-taking option goes through the normal checks (fail closed).
- **Smaller points.** A `--mode` other than `file` is
  refused for runs against the clone. `update`'s pull also updates `refs/remotes/origin/main`,
  so the checkout does not look ahead afterwards. `.scripts/provision.sh` skips
  `chezmoi init` and `apply` when the checkout already existed, and points to
  `chezmoi apply --init`.
- Commits reach origin's `main` only through Michael: his merge, or a default-branch push that
  the push guard put to him. Only Michael runs `chezmoi apply`; agents never do.

## Expected effect

- No new escapes or prompts: nothing sandboxed wrote to the closed places in 30 days.
- After `chezmoi apply` and a new session, every place in the Problem table is unwritable from
  the sandbox, and no hook, statusline or excluded command can be steered by a sandboxed
  write, except the routes recorded under Out of scope. Other repositories' agent
  configuration (`.claude/settings*.json`, `.mcp.json`, `.codex`) is unwritable too, at depth 0 to 2 under each work root.
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
  holding a stub `jq`. The fixture repository carries fsmonitor, filter, `sshCommand` and
  `ext`/`insteadOf` markers, none of which may fire, and the suite asserts each pinned
  script's exact pin line.
- **`xreview-guard`, `xreview apply` and the ledger.** The pre-merge `ls-remote` fails closed on
  `core.sshCommand`, `core.gitProxy`, `remote.origin.vcs` and a non-plain origin URL, and runs
  with the protocol allowlist. `xreview apply`'s diffs fire no fsmonitor, no filter and no hook (the `hooksPath`
  marker never fires), and the ledger's patch diff runs no `diff.external` or textconv from a
  submodule (the submodule case).
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
    chezmoi as an argument. `init --apply` and `edit --apply` are refused, and so is every
    `init`.
  - **Previews and the rest.** Each preview command runs against the clone on a clean `main`
    and is refused off it; `merge` and `merge-all` are refused without `--dirty-ok`; the help
    shapes (`-h`, `--help`, a short group with `h`) print `chezmoi help <subcommand>` without
    forwarding arguments, and the `=` forms and `h` after a value-taking option take the normal
    checks; `--mode` other than `file` is refused for clone runs; `update` moves
    `refs/remotes/origin/main`.
- **`live-write-boundary`** also covers a repository outside `~/Code` (in `~/Documents`). Its
  `hooks/` is denied there too, while its objects, refs, index and configuration files stay
  writable. The suite checks that last part, so the change adds no escapes.
  - It probes the denial of `.claude/settings.json`, `.claude/settings.local.json`,
    `.mcp.json` and the `.codex` directory in a repository at depth 2 in each root, and of
    `.claude/settings.json` directly under `~/Code` and `~/Documents`. A `node_modules/<pkg>`
    probe at depth 4 (`.claude/settings.local.json`) must stay writable, which proves npm
    keeps working. `.codex/**` is not measurable live, because `.codex` itself is denied.
    `.claude/skills`, `commands` and `agents` stay writable. Its rename probe (a parent directory moved to reach the same
    result as `core.hooksPath`) is reported as information and not counted.
  - Claude Code's own built-in rule keeps `.git/config` and `.git/hooks` denied under the
    session's working directory (unless `sandbox.filesystem.allowGitConfig`, which stays
    unset). This spec leaves that rule as it is, so the suite skips the config probe under
    the working directory it runs in.

## Out of scope

- The escape habits: the next spec (cargo, Python heredocs, `.git/config` writes, kubectl,
  brakeman, glab, the manual-demo server and headless Chrome, `ps`, `mise trust`).
- Code in a repository that Michael runs himself (tests, `bin/dev`). It is the work product
  and goes through review like any change.
- Source-editing and listing commands (`add`, `re-add`, `edit`, `forget`, `chattr`, `managed`,
  `unmanaged`, `ignored`, `data`) still evaluate the working tree's `.chezmoiignore` and
  templates. They are Michael's own deliberate source edits (ruling 2026-10-18); gating them
  would make every source edit need `--dirty-ok`. This replaces the 2026-10-17 acceptance of
  `chezmoi diff`, `status` and `cat` rendering the working tree: §3 now gates those.
- The hooks denial stops only direct writes. Renaming a parent directory reaches the same
  result as `core.hooksPath`, which is already accepted; the live suite reports its rename
  probe as information.
- The pre-merge gate takes the forge project from the raw `remote.origin.url`, while
  `ls-remote` follows `url.*.insteadOf`. A sandbox-written rewrite to a local mirror can feed
  the gate a fake head. That is review-gate integrity, not code execution, and it predates
  this spec; it belongs with the xreview follow-ups.
- The wrapper's own `git status` and `pull` in the checkout honour its configuration
  (filters, `insteadOf`, credential helpers). That is the class of "Michael's own git in an
  agent-touched repository".
- Hooks in skill or agent frontmatter under a repository's committed `.claude/skills` or
  `.claude/agents` (Michael, 2026-10-18; the next spec).
- Language servers execute project code by design (Gemfile, `build.rs`, procedural macros).
  That is the same trust as running the repository's code. The `mise.toml` route into them
  is closed by paranoid mode (§2).
- Bare repositories (`x.git/hooks`, with no `/.git/` component), which the hooks denial does
  not name.
- A repository's git configuration (`config`, `config.worktree`, `core.hooksPath`,
  `core.fsmonitor` and the like), and any git directory reached through a `.git` file. Both
  stay agent-writable (see §1, "Git"). The justification is the git rule in §2, "Git that
  our unsandboxed code runs", not `PATH`. Michael's own git in an agent-touched repository
  trusts that repository's metadata as it trusts its code.
- Codex's own sandbox, and anything Michael's unsandboxed processes write.
- The push guard's merged-branch exemption still judges ancestry on the local object store.
  A forged loose object can make an unmerged branch look merged, and the guard then deletes
  it on the remote without asking. Its commits remain in the local objects and the local
  branch, so nothing runs and nothing is lost locally. Executing code is this spec's concern,
  so this is recorded rather than fixed.
