# wt carries mise trust into new worktrees

**Status:** Approved
**Date:** 2026-10-19
**Branch:** `feat/wt-mise-trust`

A follow-up to the [sandbox write boundary](2026-10-16-sandbox-write-boundary-design.md),
which turned on mise's paranoid mode globally (merged to main at ab0346a).

## Problem

In paranoid mode, mise loads a project config only once it is trusted, and that trust is tied
to the file's contents. Paranoid mode also turns off the two conveniences that used to cover
a new worktree: trust no longer carries from a repository's main checkout to the same path in
its git worktrees, and `mise exec`, `mise run` and `mise install` no longer trust their config
automatically.

So every checkout `wt` creates starts with untrusted configs:

- **VM.Portal's `.worktreehook`** ends in `exec mise exec -- env NO_COVERAGE=1 bin/rails
  runner -e test …` inside the new worktree. Measured 2026-10-19 with no terminal: `mise exec`
  in a directory whose `mise.toml` is untrusted exits 1 with "Config files in … are not
  trusted". With a terminal, mise may instead ask whether to trust the file. That is a trust
  decision made mid-command, without seeing the file.
- **Every shell in the new Herdr workspace** loads no project environment (database names,
  tool versions) until Michael runs `mise trust` there by hand.
- **From the Herdr popup** (`prefix+shift+g`, a 7-row `wt-prompt`), a refusal scrolls past
  before the popup closes. Rerunning `wt <branch>` then reopens the worktree, which does no
  preparation, so the workspace opens with configs mise will not load.

The fix must not undo what paranoid mode is for. The sandbox can write anywhere under
`~/Code`, so an agent can change a branch's committed `mise.toml`, or the main checkout's
`mise.local.toml`, which `wt` copies into the worktree. Trusting whatever lands in a new
worktree would reopen exactly that route.

## Goals

- A new worktree whose mise configs are byte-identical to configs Michael already trusts in
  the main checkout is ready at once: its setup hook and its shells load them.
- A config that is new, differs, or whose main-checkout copy is not trusted is never trusted
  automatically. Michael sees which file it is, how to review it, and how to carry on, from
  the popup too.
- Reopening a worktree whose configs are untrusted says so, instead of opening silently.

## Non-goals

- Claude Code's own harness worktrees (`.claude/worktrees/*`). The sandbox cannot write mise's
  trust store, by design, so `mise exec` there fails until Michael trusts the config himself.
- Re-trusting after `git pull`, a rebase or an edit changes a config in any checkout. That is
  paranoid mode's documented cost (sandbox write boundary spec, §2).
- Preparing a reopened worktree. `wt <branch>` on an existing checkout does no preparation
  today and keeps it that way; it only gains the warning below.
- **curato.** Its setup hook (`bin/worktree-db setup`, from the worktree's own tree) rewrites
  the worktree's `mise.local.toml` with that worktree's database names, then runs `mise exec`.
  The rewritten file is content nobody has trusted, so the trust this step carried is lost and
  mise asks mid-hook (or fails without a terminal). curato gets its own change in its own
  repository (Michael's ruling, 2026-10-19), deriving the names in its tracked `mise.toml` the
  way VM.Portal does, so the worktree's configs stay identical to the main checkout's. Until
  then, `wt` in curato behaves as it does today under paranoid mode.
- Env files and scripts a config reads (`env._.file`, `env._.source`, the `env_file` setting),
  which paranoid mode trusts separately. No repository uses them today (checked 2026-10-19:
  VM.Portal and curato use plain `[env]` tables).

## Anti-goals

- `wt` never trusts content Michael has not already trusted.
- `wt` never runs `mise trust` without a file path, or with `--all`: both widen trust beyond
  the one file (without a path, paranoid mode also trusts the env files and scripts it reads).
- `wt` never changes the main checkout's trust.
- When creating a worktree, `wt` never reaches the setup hook, or opens the workspace, while a
  worktree config it could not carry stays untrusted. Otherwise mise's own question would come
  up in the hook, inviting a yes without review. (Reopening still opens, with a warning: it
  runs no hook.)

## Design

### Where it runs

A new helper, `_wt_mise_trust <main> <dest>`, runs inside `_wt_do_prepare`: after the
`.worktreeinclude` copy (so a carried `mise.local.toml` is covered) and before
`_wt_hook_run … setup`. It therefore runs under the lock `wt` and `wt-prepare` already hold,
and `wt-prepare` re-runs it on the recovery path.

If no `mise` binary is on `PATH` (`$+commands[mise]`, since `mise activate` also defines a
`mise` shell function), the step does nothing: nothing in the worktree can load a mise config
either. `wt` calls it as `command mise`, never through a shell function or alias.

### Which files

`command mise -C <dest> trust --show` lists the config files mise would load in `<dest>` and
its parents, one per line on stdout as `<path>: trusted` or `<path>: untrusted`, and exits 0;
with none it prints "No trusted config files found" on stderr. There is no third state (a file
marked `--ignore` shows as `untrusted`). The `-C` directory is printed canonicalised (`/tmp`
becomes `/private/tmp`) and the rest of the path as found; a path under `$HOME` is printed as
`~/…`. Format measured 2026-10-19 with mise 2026.10.15.

Only entries inside `<dest>` matter; the step ignores parent and global configs. Membership is
decided lexically: the step canonicalises `<dest>` itself (as mise does with the `-C`
directory, and because `~/Code` may sit behind a symlink), maps a leading `~/` back to
`$HOME`, and takes each entry whose printed path begins with `<canonical dest>/`. It never
resolves the entry itself: a `mise.toml` that is a symlink to a file outside the worktree would
then fall outside `<dest>` and be skipped, where rule 1 below must refuse it. The main
checkout's counterpart is `<canonical main>/<rel>`, matched the same way in its `--show`
output.

An entry already `trusted` needs nothing. Each `untrusted` entry `<dest>/<rel>` is carried
only when all of these hold:

1. No component of `<dest>/<rel>` below `<dest>`, and none of `<main>/<rel>` below `<main>`,
   is a symlink (checked per component, as `_wt_manifest` does), and both are regular files.
2. `command mise -C <main> trust --show` lists `<main>/<rel>` as `trusted`.
3. `cmp -s <main>/<rel> <dest>/<rel>` reports them identical.

Then `command mise trust <dest>/<rel>`.

### Closing the check-then-trust window

Between the comparison and `mise trust`, a sandboxed process could rewrite `<dest>/<rel>`, and
mise would hash the rewritten content. So after trusting each file, the step checks again:
`cmp -s` must still report it identical to `<main>/<rel>`, `mise -C <dest> trust --show` must
list it as `trusted` (which, in paranoid mode, means the stored hash matches the current
content), and `mise -C <main> trust --show` must still list `<main>/<rel>` as `trusted` (so
the main checkout and the worktree were not rewritten together). If any check fails, it runs
`command mise trust --untrust <dest>/<rel>` and treats the file as one it could not carry.

A residual remains: a writer that changes the file, lets `mise trust` hash the change, and
restores it before the re-check leaves a stored hash for content Michael never saw; writing
that content back later would load it. That takes a process racing a path that exists for a
few milliseconds, at the moment Michael runs `wt`. Accepted.

### When a file cannot be carried

The step names each such file, with the reason, and what to do:

```
wt: ~/Code/ViuMore/VM.Portal-feature-x/mise.toml is not trusted: it differs from the main checkout's.
    review: diff ~/Code/ViuMore/VM.Portal/mise.toml ~/Code/ViuMore/VM.Portal-feature-x/mise.toml
    then:   mise trust ~/Code/ViuMore/VM.Portal-feature-x/mise.toml
```

The reasons are: it differs from the main checkout's; the main checkout has no such file
(`review` then shows the file itself); the main checkout's is not trusted; it or its
counterpart is a symlink or not a regular file. After listing every file, the step returns 1,
and `_wt_do_prepare` stops before the setup hook with its existing recovery line ("The
worktree exists — fix it, then: wt-prepare <branch> && wt <branch>"). After Michael trusts
the files, `wt-prepare` finds nothing left to carry and goes on to the hook.

### Failing closed

If `mise trust --show` fails or prints a line the step cannot read, the step trusts nothing,
says so, and returns 1. A failed `mise trust` or `--untrust` does the same.

### Output

On success, one line per carried file (`wt: mise trust carried to <dest>/<rel>`), so Michael
can see what was trusted for him. Nothing when there was nothing to carry.

### Reopening warns

When `wt <branch>` reopens an existing worktree (the branch in `_wt_create_or_prepare` that
prints "wt: reopening …"), it runs the same `trust --show` read. If any entry inside the
worktree is `untrusted`, it prints one line naming the files and pointing at
`wt-prepare <branch>`, which carries what it can and explains the rest. It then opens the
workspace as before. The warning never trusts anything and never stops the reopen; a failed
read prints that the status could not be read, and also goes on.

### The popup waits when there is something to read

`wt-prompt` keeps the popup open when `wt` fails, and when `wt` succeeds but printed the
reopen warning: it prints a line asking for Enter and waits for it, so the refusal or warning
stays readable. The warning is signalled separately from the exit status (a reopen that warns
still succeeds), for example through a variable `wt` sets. Otherwise it returns at once, as
today. The popup's size does not change.

## Testing

`tests/wt-functions.test.sh` gets a section for the new step. `mise` is stubbed on `PATH`: the
stub keeps a fake trust store keyed by path and content hash, answers `-C <dir> trust --show`,
`trust <file>` and `trust --untrust <file>`, and logs every call. Cases:

- Identical to a trusted main-checkout file: trusted, and the setup hook runs.
- A tracked `mise.toml` that differs: no `mise trust` call, the step stops before the hook,
  and the message names the file, the `diff` and the recovery line.
- A carried `mise.local.toml` whose main-checkout copy is untrusted: not trusted.
- A file with no counterpart in the main checkout: not trusted; `review` shows the file.
- A symlink in either checkout: refused. That includes a worktree `mise.toml` that is a
  symlink to a file outside the worktree, and a symlinked directory on the way to a config:
  both are refused, never skipped as outside the worktree.
- No `mise` on `PATH`: the step does nothing and the hook runs.
- `trust --show` failing or printing an unreadable line: nothing trusted, stop.
- The stub rewrites the file during `mise trust`: `--untrust` follows, and the step stops.
- A config in a parent directory of the worktree: ignored.
- Paths printed as `~/…`, and paths with spaces.
- Recovery: after the stub's store trusts the file, `wt-prepare` reaches the hook.
- `mise trust` is never called without a path, or with `--all`.
- The main checkout's file loses its trust during the step: `--untrust` follows, and the step
  stops.
- Reopen: an untrusted config prints the warning and the workspace still opens; a trusted one,
  or no `mise`, prints nothing; reopen never calls `mise trust`.
- `wt-prompt`: a failing `wt` waits for Enter; so does a reopen that printed the warning;
  a clean success does not.

The stub replaces `mise` for the whole suite, so no case touches the real trust store.

After `chezmoi apply`, Michael's first `wt` in VM.Portal is the live check: the worktree opens
with its test database prepared, and no trust question comes up.

## Calls made in writing this spec

Settled by Claude, not by Michael; each can be overruled at sign-off:

- Symlinks are checked per path component, as `_wt_manifest` does.
- The post-trust re-check also re-reads the main checkout's trust.
- `mise` is detected with `$+commands[mise]`.
- The reopen warning points at `wt-prepare` rather than at `mise trust`, so the same rules
  decide what is carried.

## Left to the builder

- The helper's internal structure and the parsing of `--show` output, within the rules above.
- The exact wording of messages, keeping the shape above.
- Whether the post-trust re-check runs per file or once for all carried files.
