# Worktree teardown helper

**Status:** Approved
**Date:** 2026-09-11

Consumes the `teardown` verb defined by
[2026-07-30 Worktree hook protocol](./2026-07-30-worktree-hook-protocol-design.md) and
invoked by [2026-08-24 Worktree lifecycle invocation surface](./2026-08-24-worktree-lifecycle-invocation-surface-design.md).
Both remain accurate and Implemented. This record adds the first consumer of that
verb; it changes no protocol semantics and no `wt-rm` code.

## 1. Problem

`wt-rm issue-94` refused on 2026-09-11:

```
wt-rm: /Users/michael/Code/Netronix/curato-issue-94 is still in use by a running
process — removal aborted. Resources may already be reclaimed.
    73733 ruby
    Herdr's workspaces for this checkout are closed already; these are still in it.
    Stop them — from .worktreehook teardown if the project starts them — then retry
```

That refusal is check 4 (`_wt_live_processes`, `dot_config/zsh/functions:1035`) doing
exactly its job. PID 73733 was a `rails server`:

- cwd `/Users/michael/Code/Netronix/curato-issue-94`
- listening on `localhost:3010`, IPv4 and IPv6
- stdout and stderr redirected to `/private/tmp/claude-501/server.log`
- `tmp/pids/server.pid` in the worktree containing `73733`

The redirection target names the cause. The process was not started by a Herdr pane,
so closing the workspace never signalled it; it was started in the background by a
Claude Code session and reparented, invisible to both Git and Herdr. Its port was not
the project's configured `PORT=3002` either — the session chose 3010 — so port
identity is not a usable signal.

Check 4 converts this into a refusal rather than a husk, which is the behaviour the
2026-08-24 record was written to produce. But a refusal is where the sequence stops.
The step that is supposed to prevent the refusal — `_wt_hook_run … teardown`
(`dot_config/zsh/functions:1271`) — is a no-op for every repository on this machine,
because **no repository has a `.worktreehook` at all**. The protocol has been
specified and implemented for six weeks and never used.

The gap is therefore not in the protocol or in `wt-rm`. It is that nothing exists for
a project hook to call, so writing one means writing process-signalling and
`lsof`-parsing logic per repository — which is how it stays unwritten.

## 2. Scope

**In scope.** A machine-level helper on `PATH` that a project `.worktreehook` calls to
stop processes rooted in the worktree being retired, and the first `.worktreehook`
that calls it, in `netronix/curato`.

**Explicitly out of scope: dropping a per-worktree database.** This was considered and
cut. `GLOBAL.md` states that `wt` worktrees share one DB/Redis/storage, and curato
confirms it in practice — `mise.local.toml` is carried verbatim into every worktree by
`.worktreeinclude`, so every sibling resolves to `localhost:5433/curato_development`.
A drop path would be a guard for a condition this setup is designed never to produce,
exercised only by its own tests. The "declare → guard → act" shape below accommodates
it whenever a project contradicts that arrangement; see §9.

**Also out of scope.** Reclaiming Redis keyspaces, object storage, or containers, for
the same reason and by the same route.

## 3. Architecture

Two artifacts in two repositories, split so that neither holds the other's knowledge.

**`~/.local/bin/wt-teardown`** (source: `dot_local/bin/executable_wt-teardown`) owns
mechanics and safety. How to signal a pid without hitting the wrong one; how to scan
`lsof` without misreading a failed scan as an empty one; how to refuse. It knows
nothing about Rails, Postgres, foreman, or Ruby.

**`netronix/curato:.worktreehook`** owns declaration, and nothing else:

```sh
#!/bin/sh
set -eu
command -v wt-teardown >/dev/null 2>&1 || exit 0
exec wt-teardown --pidfile tmp/pids/server.pid --sweep ruby "$@"
```

The split follows the protocol's own division: the project owns its resources, the
machine owns the lifecycle. It also survives the second consumer — a Python or Rust
project declares different flags rather than teaching `wt-teardown` a second stack's
conventions.

### 3.1 The `command -v` guard is deliberate and it cuts both ways

`.worktreehook` must be tracked and indexed `100755` to be valid
(`_wt_hook_check`, `dot_config/zsh/functions:429`). It therefore ships to every
Netronix developer and to CI — people who have no `wt-teardown`, never run `wt`, and
would otherwise find a broken executable in their clone.

The cost is real and is accepted knowingly: a `PATH` problem on this machine makes
teardown skip silently instead of failing loudly. The guard is scoped as narrowly as
possible — it tests only for the binary's absence, which is exactly the "not
installed" case. Any other failure inside `wt-teardown` still exits nonzero and still
preserves the worktree.

## 4. Interface

```
wt-teardown [--pidfile REL]... [--sweep COMMAND]... setup|teardown
```

`--pidfile REL`
: Repo-root-relative path to a pidfile. Repeatable.

`--sweep COMMAND`
: Exact command name to sweep by cwd. Repeatable. Empty by default: a repository
  opts in per command, and a repository that declares none gets no sweep.

`setup`
: Accepted no-op, so a project with nothing to prepare can `exec` for both verbs.

`teardown`
: The work described in §5.

Unknown verb exits 64, matching the protocol record's §5.2 example. All other state
comes from the protocol environment — `WT_MAIN`, `WT_WORKTREE`, `WT_BRANCH`,
`WT_SLUG`. The helper takes no path from any source it was not handed.

## 5. Teardown sequence

Five steps. Each is idempotent, each fails closed, and a nonzero exit at any point
leaves `wt-rm` holding the worktree with its Herdr workspaces already closed — which
is precisely the state a retry re-enters.

**1. Resolve and validate.** `WT_WORKTREE` must be set and absolute. Each `--pidfile`
is resolved against it and checked for containment both lexically and through the
filesystem, the same asymmetric rule `_wt_manifest` applies
(`dot_config/zsh/functions:518`). The reason is identical: the worktree's tree comes
from the feature branch, so a branch that commits `tmp` as a symlink redirects the
pidfile read outside the checkout, and a path with no `..` in it still escapes.

**2. Stop declared pidfiles.** Read the pid; it must be a plain integer greater than 1.
Then the check this step exists for: **verify the pid's cwd is inside `WT_WORKTREE`
before signalling it.** A pidfile outlives its process and macOS recycles pids, so an
unverified pidfile is an instruction to signal an arbitrary process. No ownership
proof, no signal. The pidfile is removed only after the process is confirmed gone, so
a failed stop leaves its evidence in place for the retry.

**3. Sweep declared commands.** `lsof -w -d cwd -F0pcn`, parsed with the discipline
`_wt_live_processes` already establishes and for the same reasons: NUL framing rather
than newline, strict per-record cycle validation by value, and refusal on empty or
misaligned output rather than reading a failed scan as "nothing is running". Matching
is anchored (`$dest` or `$dest/*`) — sibling worktrees of one repo differ by a suffix
on a shared path, so `curato-issue-9` must never match `curato-issue-94`. Command
names match by exact equality, never substring.

**4. Signal discipline, shared by steps 2 and 3.** `TERM`, poll for exit, then `KILL`,
poll again. A final re-scan confirms the worktree is clear. Anything still alive is an
error, not a shrug: the helper exits nonzero and `wt-rm` keeps the worktree. A second
refusal is a better outcome than a husk.

**5. Report.** Name what was stopped, on stdout, so the `wt-rm` transcript records it.

### 5.1 Self-exclusion is unconditional

`wt-rm` runs the hook with cwd inside the worktree
(`_wt_hook_run`, `dot_config/zsh/functions:480`), so the helper and its shell appear in
their own `lsof` results. The helper's own pid and every ancestor of it are excluded
before the allowlist is consulted — not merely saved by `ruby` failing to match `sh`.
A repository that declares `--sweep sh` must not kill the process interpreting its own
hook.

## 6. Invariants

These are the properties the test suite exists to hold, stated once:

1. A pid is signalled only after its cwd is proved to be inside `WT_WORKTREE`.
2. A path prefix match is anchored at a directory boundary.
3. A failed or unparseable `lsof` scan is a refusal, never an empty result.
4. The helper never signals itself or an ancestor.
5. Every step run twice leaves the same state as running it once.
6. Any failure exits nonzero, leaving the worktree for `wt-rm` to preserve.

## 7. Testing

`tests/wt-teardown.test.sh`, one suite per script under test per repo policy, bash,
executed rather than interpreter-prefixed.

`lsof` is stubbed on `PATH` to feed the parser its fixtures, including every case that
must refuse rather than read as "nothing running": empty output, a record count not
divisible by four, a misaligned cycle, a bare `n` field. Signal handling runs against
real `sleep` processes, so `TERM` → poll → `KILL` is measured rather than mocked.

The cases that carry the most weight are the refusals and the near-misses — a stale
pidfile whose pid now belongs to a process outside the worktree; `curato-issue-9`
against `curato-issue-94`; the helper surviving its own `--sweep sh`. Idempotency is
tested by running every step twice.

No `# test-requires:` line. The suite stubs everything it needs and runs in the
default `./tests/run.sh`.

## 8. Rollout

Cross-repo, so per `GLOBAL.md`: this document is canonical and lives here. Curato's MR
references it by repo and path plus a GitLab link, never a bare path — a bare path
looks local to curato and does not resolve there.

Both MRs open before either merges. **Dotfiles merges first**: curato's hook is inert
without `wt-teardown` on `PATH`, and the `command -v` guard makes that inertness
silent rather than a failure, so the reverse order would land a hook that does nothing
and says nothing.

## 9. Alternatives considered

**A Rails-aware helper.** `wt-teardown-rails` detecting `tmp/pids/server.pid` and
`config/database.yml` itself, reducing the hook to two lines. Rejected: it puts one
stack's conventions in a machine-level tool on a machine that also runs Python, Rust
and .NET, and the boilerplate it saves is three flags.

**A declarative `.worktreeteardown` file.** Rejected: a second project-level file and a
format to maintain, buying nothing over flags on the `exec` line.

**Pidfiles only, no sweep.** Rejected: it would have caught PID 73733, which wrote a
pidfile, but not a `bin/dev` started the same way — foreman, `tailwindcss:watch` and
`bin/jobs` write nothing. Ad-hoc agent launches are the recurring shape, and the
sweep is what covers them.

**Sweep only, no pidfiles.** Rejected, though closer than it looks: `--sweep ruby`
alone would stop the rails server, foreman, `bin/jobs` and a stray rake. Pidfiles are
kept for exactness and ordering — stop the named supervisor first, by proved identity,
then sweep for what it left behind.

**Killing everything with cwd in the worktree.** Rejected outright: `nvim`, `zsh`,
`claude` and `codex` all sit in these checkouts. The allowlist is what makes the sweep
safe, and it is empty by default.

**Dropping a per-worktree database.** Cut; see §2. The reintroduction path is
`--db-from-env VAR --drop-db-command CMD`, where the helper resolves `VAR` in both
`WT_WORKTREE` and `WT_MAIN` (via `mise env --json`, with tool auto-install disabled),
compares, and runs the project's command only when they differ — the helper deciding
*whether*, the project saying *how*. It is recorded here so the shape is not
re-derived, not because it is planned.

## 10. Consequences

- A `rails console` or test run left open in a worktree is killed by `wt-rm`, not
  reported. This is accepted: the command's purpose is deleting that worktree, and it
  has already passed three cleanliness checks by the time teardown runs.
- Curato's `.worktreehook` is visible to the whole team while being useful only to
  `wt` users. §3.1 is the mitigation.
- Check 4 remains the backstop and keeps its current behaviour. Teardown reduces how
  often it fires; it does not replace it, and processes that escaped their cwd remain
  invisible to both.
