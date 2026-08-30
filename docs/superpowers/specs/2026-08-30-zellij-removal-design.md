# Zellij removal

**Status:** Approved

**Date:** 2026-08-30

**Amended:** 2026-08-30, after peer review, before any implementation. Five corrections:
the `.chezmoiremove` lifecycle (which as drafted would have shipped no removal
instruction at all); the old-marker check promoted from a design-time observation to a
pre-apply gate; a rollback procedure that actually restores deployed files and the
1Password-backed instructions; a second behaviour change and a fourth stale
global-instruction statement that the first draft missed; and two verification steps
that were wrong rather than merely thin — `test-dev-integrations.sh` is touched, and
`grep -ri zellij` can never come back clean.

**Amended again:** 2026-08-30, second review round, still before implementation. Four
further corrections, three of them to checks that could not have caught what they were
written to catch: the marker gate's `~/Code/*/*` glob saw 37 of 84 Git entries and had
to become recursive, and must run a second time immediately before the apply; the
zero-hit sweep still could not pass, because `.chezmoiremove` necessarily names
`.config/zellij`; the failure-evidence description claimed an invocation-log observation
this harness cannot make. Added an explicit activation order, because `op-edit`
re-applies its targets and would otherwise publish instructions ahead of the behaviour.

**Amended a third time:** 2026-08-30, third review round, still before implementation.
The marker gate — twice rewritten by then — was **wired backwards**: an explicit `if`
now sets its exit status, verified against a fixture holding a genuinely locked
worktree, and the scan roots gained the dotfiles repository, which lives outside
`~/Code`. The status lifecycle was circular, citing a PR reference before the PR
existed; `In progress` → reference → review → `Implemented` is now spelled out. That
three consecutive drafts of a safety gate were each broken in a different way is the
argument for the plan's rule that a check must be run before it is trusted.

Retires Zellij from the dotfiles. Herdr becomes the only multiplexer, and `hdev` /
`hwt` reclaim the `dev` / `wt` names the Zellij functions held.

Follows [Herdr trial alongside Zellij](./2026-08-27-herdr-trial-design.md), which
ran Herdr beside Zellij as a reversible trial and said explicitly that migrating
"is a separate decision, made against the exit criteria below, and would get its
own spec." This is that spec.

## Decision

Migrate. Delete Zellij's configuration, its layout, its WASM navigator plugin, its
socket-directory workaround, its Homebrew package, and every branch of the worktree
lifecycle that spoke to it. Rename the Herdr entry points onto the names the Zellij
ones occupied.

### The window was cut short, and by judgement rather than measurement

The trial specified a fixed four-week window and numeric exit criteria: ≥90% cold
restore over at least ten attempts, zero wrong-workspace or husk incidents, the Alt
scheme surviving four weeks in Ghostty, and — the criterion that mattered — agent
state being *noticed* rather than polled for.

This decision comes on **day three**. None of those criteria were formally measured,
and the honest characterisation is that daily use settled the question before the
instrumented window could. Recording it as "exit criteria met" would be false; the
record should say what actually happened.

The trial's own framing anticipated this asymmetry. Its criteria were written to
justify *migrating* — to stop a novelty from winning on first impressions. They are
not the only evidence that can settle the question, and a user who has decided is not
obliged to keep operating a parallel setup to satisfy a schedule. The cost of being
wrong is also low and known: the trial spec carries a full rollback procedure, and
§"Rollback" below records what this change does and does not preserve of it.

### Why removal rather than leaving Zellij installed

Two live costs, not tidiness.

**A dual-path lifecycle is the actual hazard.** `wt` created an unlocked, Zellij-only
worktree; `hwt` created a locked, Herdr-owned one; `wt-rm` had to handle both, and its
Zellij shutdown step ran unconditionally against a multiplexer that no longer holds
anything. Every additional branch through the teardown sequence is a branch that can
strand a checkout, and the hook-protocol design is explicit that the invariant it
protects — no process outliving the checkout it writes into — is what husk directories
cost when it fails.

**The `wt` / `hwt` split is a hand-loaded gun.** `wt-rm` is the only supported removal
path for a Herdr-owned worktree, but `wt` — the shorter, older, more reflexive name —
was the one that produced worktrees it did not lock and did not open in Herdr.

## Scope

### Deleted

| Artifact | Why it can go |
|---|---|
| `dot_config/zellij/config.kdl.tmpl`, `dot_config/zellij/layouts/dev.kdl` | the entire Zellij configuration |
| `.chezmoiexternal.toml` | its only entry is the `vim-zellij-navigator` WASM; the file goes, not just the stanza |
| `dev()` (Zellij) in `dot_config/zsh/functions` | superseded by the rename below |
| `wt()` (Zellij) in `dot_config/zsh/functions` | superseded by the rename below |
| `_wt_session_name()` | Zellij session-name construction; no caller survives |
| the Zellij shutdown block in `wt-rm()` | `_wt_stop_herdr_workspaces` already runs ahead of it |
| the zellij-unreachable preflight in `dot_local/bin/executable_wt-rm` | see below — the property moves, it is not dropped |
| `ZELLIJ_SOCKET_DIR` in `dot_config/zsh/zshenv` | worked around Zellij's 104-byte IPC socket limit; Herdr has no equivalent constraint |
| `brew "zellij"` in `dot_config/homebrew/Brewfile.tmpl` | plus `brew uninstall zellij` on this machine |

**The wrapper preflight is the one deletion that removes a safety check**, so it is
worth being precise about why that is safe. It guarded a specific discrepancy: live
session sockets on disk that `zellij list-sessions` cannot see, because a sandboxed
process cannot reach them — which `wt-rm` would otherwise read as "no session", i.e.
"successfully stopped", and proceed to remove a worktree whose processes are still
writing into it.

That property is already reimplemented, in-function, for Herdr. `_wt_herdr_runtime_matches`
returns a distinct status for an API-level `server_not_running` response, and
`_wt_stop_herdr_workspaces` fails closed on it with the reasoning stated inline:
"`session list` just called this server running. An API-level `server_not_running`
response may instead mean the process cannot reach the socket (the exact Zellij sandbox
failure this lifecycle already guards). Persisted state cannot prove that no live
process exists, so fail closed." It also refuses stopped sessions whose persisted state
still references the checkout. The guard is not lost; the Zellij-shaped copy of it is.

### Renamed

| Was | Becomes |
|---|---|
| `hdev()` | `dev()` |
| `hwt()` | `wt()` |
| `hwt-prompt()` | `wt-prompt()` |
| `HDEV_LAYOUT` | `DEV_LAYOUT` |
| `HDEV_NO_ATTACH` | `DEV_NO_ATTACH` |
| `.scripts/test-hdev.sh` | `.scripts/test-dev.sh` |
| `.scripts/test-hdev-topology.sh` | `.scripts/test-dev-topology.sh` |
| `.scripts/test-hdev-integrations.sh` | `.scripts/test-dev-integrations.sh` |

No aliases. `hdev` and `hwt` were trial names; keeping them alive would preserve the
two-name ambiguity this change exists to remove.

Follow-through: the `prefix+shift+g` popup in `dot_config/herdr/config.toml` invokes
`hwt-prompt` and must be renamed with it, or the binding breaks silently — the popup
would open a shell that fails to find the command.

`wt-prepare` and `wt-rm` are unchanged in name. They were already unprefixed and
already covered both paths; that is what makes `dev` / `wt` the correct names to
reclaim rather than a matter of taste.

### Behaviour changes

Two, both intentional. Everything else in this document is deletion, renaming, or
comment text.

#### 1. Every `wt` worktree is now locked

Plain `wt` never applied the Git ownership lock; `hwt` did, via `hdev` →
`_wt_prepare_for_herdr`. After the merge there is one creation path, so **every `wt`
worktree is locked and `wt-rm` is the only supported removal path.** That is the state
the trial design already called supported; this change removes the way to sidestep it,
rather than introducing a new constraint.

The marker string changes from `hwt-managed; remove with command wt-rm` to
`wt-managed; remove with command wt-rm`.

Changing a lock marker is hazardous: `wt-rm` classifies any lock reason that is not
its exact string as a foreign lock — an explicit preservation request by another owner
— and refuses. A worktree locked under the old string becomes unremovable by its own
tooling. A back-compatible arm accepting both strings was considered and rejected as
dead code from the moment it was written. The alternative is a gate.

**Gate, required, and run twice.** Scan every repository under `~/Code` for the old
marker, matching the reason **exactly** and reading `git worktree list --porcelain -z`
NUL-delimited so a path or reason containing whitespace cannot split a record. Track
the worktree path across records so a hit names **the worktree to retire**, not merely
the repository containing it:

```zsh
# wt_marker_gate <exact lock reason> — 0 clean, 1 stale worktrees found.
wt_marker_gate() {
  emulate -L zsh
  setopt local_options null_glob extended_glob
  local want="$1" common cur rec g
  local -A seen
  local -a hits roots
  roots=( ~/Code ~/.local/share/chezmoi )
  for g in ${^roots}/**/.git(N/) ${^roots}/**/.git(N.); do
    common="$(git -C "${g:h}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || continue
    [[ -n "${seen[$common]:-}" ]] && continue
    seen[$common]=1
    cur=""
    while IFS= read -r -d '' rec; do
      case "$rec" in
        "worktree "*)   cur="${rec#worktree }" ;;
        "locked $want") hits+=( "$cur" ) ;;
      esac
    done < <(git -C "${g:h}" worktree list --porcelain -z 2>/dev/null)
  done
  if (( ${#hits} )); then
    print -ru2 -- "STALE MARKER — retire these with \`command wt-rm\` before proceeding:"
    print -rl -u2 -- ${(u)hits}
    return 1
  fi
  print -r -- "clean: no worktree carries ${(q-)want}"
  return 0
}
```

**The exit status must come from an explicit `if`.** A trailing
`(( ${#hits} )) && { …; return 1 }` — as two earlier drafts of this section had —
returns 1 on a *clean* tree too, because the arithmetic is false and it is the last
statement; a `&&` without the `return` inverts the gate outright, exiting 0 on a stale
tree. A gate wired backwards aborts on a clean tree and waves through the one case it
exists to catch. Verified against a fixture holding a genuinely locked worktree: clean
→ 0, unlocked worktree → 0, foreign lock reason → 0, exact old marker → 1 naming the
worktree path.

**The glob must recurse.** An earlier draft used `~/Code/*/*/.git`, on the strength of
the documented `~/Code/<Org>/<repo>` convention. That convention is not universal:
the tree actually holds 84 Git entries, of which the depth-two glob sees 37. A safety
gate blind to more than half the repositories it guards is worse than none, because it
reports "clean" with authority. Enumerate by unique **common directory**, so linked
worktrees are not mistaken for separate repositories.

**The roots include the dotfiles repository**, which lives outside `~/Code` and holds
worktrees of its own — this change is being developed in one. It is clean now, which is
why it belongs in the scan before the second run rather than after.

Any hit aborts. Retire that worktree through the **current** `command wt-rm`, which
still understands the old marker, and only then proceed.

Run it **twice**: once immediately before the marker change, and again immediately
before the canonical `chezmoi apply`. The second run is not ceremony. Between those
two moments the deployed `~/.config/zsh/functions` still contains the old code, so
ordinary use — in another session, during PR review — can create a fresh worktree
carrying the old marker. Applying over it strands exactly the checkout the gate exists
to protect.

Both runs returned clean on 2026-08-30, but that is context, not authorisation. The
gate is what authorises.

#### 2. `dev <session-name>` resolution disappears

The Zellij `dev` accepted a session name as typed — `dev netronix--curato`, "exactly as
`zellij list-sessions` prints it" — resolving it by generating each repo's name and
comparing, because `_wt_session_name` is deliberately not invertible. `hdev` dropped
that branch, since the name it resolves is a Zellij session name and its transformation
exists only for Zellij's constraints.

Inheriting `hdev`'s cascade therefore retires that input form. This is **intentional**:
after this change no Zellij session name exists to paste back. `dev Netronix/curato`,
`dev curato` and `dev .` all still work, and `dev netronix--curato` falls through to
the case-insensitive substring arm — which will not match — so it lands in the `fzf`
picker rather than failing silently.

### Comment-only, no behaviour change

`dot_config/ghostty/config` (×2), `dot_zshrc`, `dot_config/zsh/config`,
`dot_config/nvim/lua/plugins/smart-splits.lua`, `dot_config/herdr/config.toml`,
`dot_config/herdr/executable_layout.sh`.

Also `dot_config/homebrew/Brewfile.tmpl`, whose surviving `brew "herdr"` line reads
"the hdev() function in zsh/functions + ~/.config/herdr. On trial alongside zellij" —
stale on both counts once `hdev` is renamed and the trial is over.

**`dot_claude/executable_worktree-guard.sh` needs no change, and that was checked
rather than assumed.** It enforces the "retire with `wt-rm`, never raw `git worktree
remove`" rule from GLOBAL.md, so it is exactly the kind of file a rename could break
silently. It references `wt`, `wt-rm` and the sibling convention — all of which keep
their names — and mentions no multiplexer at all.

One of these describes a behaviour that must be confirmed rather than assumed.
Ghostty maps `cmd+k` to `text:\x1bk` because its built-in `clear_screen` is a no-op in
the alternate screen, and the existing comment says "Zellij binds Alt-k to Clear".
Herdr deliberately binds **no** `alt+k` — the trial design dropped it, because Herdr
0.8.2's `pane.*` API has no clear method and the only implementation would inject
control sequences into whatever occupies the pane. The chord therefore falls through
to zsh's `bindkey '\ek' clear-screen` from `dot_zshrc`. That should mean `cmd+k` still
clears inside a Herdr shell pane, but it is a live assertion, not a rewording: verify
it before editing the comment to claim it.

## Out of repo

- **`~/.config/zellij`** is deployed on disk and would survive as an orphan once the
  source is deleted — chezmoi does not remove targets whose source disappeared. A
  `.chezmoiremove` entry of `.config/zellij` removes the tree, including the nested
  WASM plugin; verified empirically against a throwaway source/destination pair rather
  than assumed from the documentation.

  **`.chezmoiremove` stays in the source permanently.** An earlier draft had it added,
  applied, then deleted in a follow-up commit, on the reasoning that a fresh provision
  never creates `~/.config/zellij` so the entry would be stale. That is wrong, and in a
  way that defeats the purpose: chezmoi acts on the entry only while the file exists,
  so deleting it means the merged branch carries no removal instruction at all — the
  real apply, and any *already-provisioned* machine that pulls this branch later, would
  find the source gone and the deployed tree untouched. A removal entry is a
  declarative tombstone, not stale configuration. It costs nothing: removing an absent
  path is a no-op.
- **`brew uninstall zellij`** (0.45.1 installed), after the Brewfile edit.
- **`~/.config/agents/GLOBAL.md`**, which lives in 1Password
  (`op://Private/Agent instructions/notes`) and renders to **three** files, all from
  that one item: `~/.config/agents/GLOBAL.md`, `~/.claude/CLAUDE.md` and
  `~/.codex/AGENTS.md`. Editing the item and re-applying updates all three. Uses
  `op-edit`, which needs an unsandboxed shell and a 1Password approval.

  **Four** statements go stale, not three:

  1. "`wt <branch>` — a sibling checkout … in its own Zellij dev session"
  2. "Raw removal skips the Zellij session shutdown and the project teardown hook"
  3. "for `wt-rm` that also bypasses the zellij safety preflight, which lives only in
     that wrapper" — the subtlest, and the one an earlier draft missed. This change
     **deletes that preflight**, so the sentence describes a guard that no longer
     exists. The surrounding rule — invoke as `command wt-rm`, because a shell function
     shadows the `$PATH` wrapper — remains correct and must survive the edit.
  4. "Agents do not create `wt`-managed sibling worktrees — that stays an interactive
     command, because `wt` attaches to a Zellij session"

  **The rule in (4) is preserved; only its rationale changes** — `wt` attaches a Herdr
  client instead. The failure mode to avoid here is deleting the rule along with the
  word "Zellij", which would silently license agents to create interactive worktrees.
  The same paragraph's carve-out for native and harness worktrees is unaffected.

Machine state confirmed before planning: no running sessions, and no
`/tmp/zellij-$UID`, `~/.local/share/zellij` or `~/.cache/zellij`. Nothing is holding
state that removal could interrupt — **re-confirm immediately before the apply**, since
that observation is days old by then and nothing maintains it.

### Activation order

Publication, merge and activation are separable, and getting them out of order
publishes instructions for behaviour that is not yet deployed. `op-edit` re-applies its
chezmoi targets as part of editing, so updating GLOBAL.md *before* the apply would push
Herdr-only instructions — including "agents do not create these worktrees because `wt`
attaches a Herdr client" — to all three rendered files while the deployed `wt` is still
the Zellij one.

The order is therefore:

1. `**Status:** In progress` on this spec and its plan, set when implementation begins.
2. Open the PR; add its reference to both records **while still `In progress`**. The
   reference cannot be cited before the PR exists, and review has not happened yet.
3. Complete review and any fixes.
4. Final pre-merge commit setting `**Status:** Implemented` — **before** merging, per
   the design-records lifecycle, not after.
5. Explicit merge approval.
6. Wait until the canonical checkout at `~/.local/share/chezmoi` actually contains the
   merge. Merging a PR does not update a local checkout, and that checkout is presently
   on another branch with unrelated uncommitted work belonging to a different session.
   This step is the owner's, not an automated one.
7. Re-run the marker gate and the Zellij-session check.
8. `chezmoi apply --dry-run --verbose`, then the real apply.
9. Live verification.
10. `brew uninstall zellij`.
11. Publish GLOBAL.md through `op-edit` — **last**, once the behaviour it describes is
   the behaviour that is running.

## Design records

The two earlier lifecycle specs — [worktree hook
protocol](./2026-07-30-worktree-hook-protocol-design.md) and [worktree lifecycle
invocation surface](./2026-08-24-worktree-lifecycle-invocation-surface-design.md) —
are **not edited.** They are dated records of point-in-time facts, and the policy in
`GLOBAL.md` is explicit that a completed document's body is not rewritten. In
particular `dot_local/bin/executable_wt-rm` cites §4.3 of the invocation-surface
design; that citation remains accurate as history even though the preflight it
describes is removed here.

The [Herdr trial spec](./2026-08-27-herdr-trial-design.md) keeps `**Status:**
Implemented` — it was implemented — and gains an outcome note pointing forward to this
document, recording that the four-week window was ended early by decision.

## Testing

`.scripts/test-wt-functions.sh` loses: the `zellij` stub and `ZLOG`; the `ZELLIJ` /
`MOCK_ZJ_SWITCH_RC` session-creation and switch-failure cases; the wrapper-preflight
block; and the test asserting `wt` stays unlocked.

Several assertions there read `unlogged "delete-session" "Zellij is not disrupted
after a Herdr close failure"` and similar. **These lose their subject and must be
replaced, not deleted.** What they actually prove is that a failure at the Herdr
boundary halts the sequence before anything destructive — the ordering guarantee is
the point, and Zellij was merely the observable proxy for it.

Each becomes two assertions. Asserting only that the checkout directory still exists is
vacuous — a surviving directory is equally consistent with teardown having run and
removal having failed for an unrelated reason.

1. **Teardown never ran**, observed on the hook's own touch-file. Removal is strictly
   after teardown in `wt-rm`'s sequence, so this also proves removal was never reached.
2. **The checkout is still a registered worktree**, observed on `git worktree list
   --porcelain`. This is the direct, non-vacuous replacement for the bare `-d` check:
   a directory can survive a *failed* removal, but a surviving registration proves
   `git worktree remove` did not succeed.

There is deliberately no assertion that `git worktree remove` was not *invoked*. The
harness stubs `zellij`, `herdr`, `wtcp` and `layout.sh`, but runs **real git** — that
is what makes its worktree assertions meaningful — so there is no git invocation log to
observe, and (1) carries the ordering proof instead. An earlier draft of this section
claimed both absences were read off an invocation log; that observation does not exist
in this harness.

One test is added, the inverse of one deleted: `wt` acquires the ownership lock, with
the new marker string.

`.scripts/test-dev.sh` is the rename of `test-hdev.sh`, with `hdev` → `dev` throughout.

**`test-dev-integrations.sh` is touched after all.** An earlier draft said it was not,
reasoning that it covers only the Claude and Codex hook wiring. That reasoning is
sound but the conclusion was wrong: line 64 passes `HDEV_NO_ATTACH=1` to `layout.sh`,
so the environment-variable rename lands in it. It gets the rename, a syntax check,
and a run far enough to prove the renamed no-attach control still suppresses the
blocking TUI. A full cold-restore rerun is optional if `test-dev-topology.sh` — which
uses the same control in seven places — already demonstrates it.

`test-dev-topology.sh` is re-run in full: it exercises `wt` creation, the lock marker
and label-resolved tab jumps against the real binary, all three of which change here.

The live `dev` / `wt` / `wt-rm` round trip runs **inside that script's existing
isolated fixture** — its named `hdev-test` session and scratch repos — not against a
real project under `~/Code`. The round trip is the last thing that should be proving
itself on a checkout that matters.

Then `chezmoi apply --dry-run --verbose` and a real apply. **A full apply renders
`op`-backed templates** (`private_dot_ssh/`, `dot_config/bundler/config.tmpl`), so it
needs an unsandboxed shell with `op` signed in and the 1Password desktop app approved.
Re-run the marker gate and re-check that no Zellij session or socket state has appeared
immediately before it — both facts were established days earlier and neither is
self-maintaining.

Final check, two commands rather than one:

```bash
git grep -i zellij -- ':!docs' ':!.chezmoiremove'   # expected: no output
grep -c '^\.config/zellij$' .chezmoiremove          # expected: 1
```

The exclusion is not a convenience. `.chezmoiremove`'s entire purpose is to name
`.config/zellij`, so a zero-hit sweep including it can never pass — the same defect as
the `grep -ri zellij` an earlier draft specified, which walks `.git` and matches ref and
reflog metadata including this change's own branch name. Both would report a failure
that is not one. The tombstone therefore gets a **positive** assertion of its exact
entry instead: the sweep proves absence everywhere else, and this proves presence where
it is required.

## Rollback

An earlier draft said rollback was "`git revert` plus `brew install zellij`". That is
insufficient in three ways, each of which leaves a half-reverted machine: reverting
source does not restore *deployed* files, does not touch 1Password, and — done in the
wrong order — strands worktrees.

Ordered procedure:

**1. Retire every `wt-managed` worktree first.** Inherited from the trial's rollback
§0, which warns that reverting `wt-rm` to a form that does not cross the ownership
lock leaves Git refusing both `worktree remove` and single `--force`. The amendment
this change forces: the marker is now `wt-managed; remove with command wt-rm`, so a
rollback must scan for **that** string, not the `hwt-managed; …` one the trial spec
names. Use the §"Behaviour changes" scan with `want` swapped — including its recursive
glob, since the depth-two shorthand misses more than half the tree. Retire each hit
through the current `command wt-rm` while it still understands the marker.

**2. Revert the source and reinstall Zellij.** `git revert`, then `brew install
zellij`. This restores `dot_config/zellij/`, `.chezmoiexternal.toml`, both zsh
functions, the wrapper preflight, `ZELLIJ_SOCKET_DIR` and the Brewfile entry — in the
source only.

**3. `chezmoi apply`.** Without this, `~/.config/zellij` does not come back: revert
restores the source tree, and only an apply deploys it. Needs an unsandboxed shell with
`op` signed in, since a full apply renders the `op`-backed templates. The reverted
`.chezmoiexternal.toml` also has to re-download the WASM navigator, which is a network
fetch Little Snitch will prompt on.

**4. Restore GLOBAL.md in 1Password**, under a fresh owner approval — `op-edit`
cannot be replayed from git, because the item is not in git. All four statements from
§"Out of repo" revert together, and re-applying propagates to all three rendered
copies.

**5. Verify source/deployed parity.** The steps above can each half-succeed —
particularly (3), where an apply that prompts about a modified target can skip it
silently. Confirm `~/.config/zellij` exists with both the config and the plugin, that
`zellij` is on `$PATH`, that `dev`/`wt` resolve to the reverted functions, and that
the three rendered instruction files match the 1Password item.

There are currently no locked worktrees, so a rollback performed today skips step 1
entirely. That stops being true the first time `wt` is used.

Rollback does not restore the four-week trial. Zellij's configuration would come back
from git intact, but a reverted setup is a fresh decision to run Zellij, not a
resumption of a measurement window that this document closes.
