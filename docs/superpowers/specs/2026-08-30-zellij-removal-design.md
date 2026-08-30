# Zellij removal

**Status:** Approved

**Date:** 2026-08-30

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

### The lock marker — the only behaviour change

Plain `wt` never applied the Git ownership lock; `hwt` did, via `hdev` →
`_wt_prepare_for_herdr`. After the merge there is one creation path, so **every `wt`
worktree is locked and `wt-rm` is the only supported removal path.** That is the state
the trial design already called supported; this change removes the way to sidestep it,
rather than introducing a new constraint.

The marker string changes from `hwt-managed; remove with command wt-rm` to
`wt-managed; remove with command wt-rm`.

Changing a lock marker is normally hazardous: `wt-rm` classifies any lock reason that
is not its exact string as a foreign lock — an explicit preservation request by
another owner — and refuses. A worktree locked under the old string would become
unremovable by its own tooling.

**Verified before adopting the clean rename:** `git worktree list` across every repo
under `~/Code` reports no linked worktrees at all. There is nothing to strand, on the
only machine this configuration is deployed to. A back-compatible arm accepting both
strings was considered and rejected as dead code from the moment it was written.

This is the one part of this change that would need care if it were ever applied to a
machine with live worktrees. Anyone doing so should check for the old marker first.

### Comment-only, no behaviour change

`dot_config/ghostty/config` (×2), `dot_zshrc`, `dot_config/zsh/config`,
`dot_config/nvim/lua/plugins/smart-splits.lua`, `dot_config/herdr/config.toml`,
`dot_config/herdr/executable_layout.sh`.

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
  `.chezmoiremove` entry removes the tree, including the WASM plugin beneath it.
  `.chezmoiremove` is then itself deleted in a follow-up commit on the same branch:
  a fresh provision never creates `~/.config/zellij`, so leaving the entry in place
  would be permanently stale instruction.
- **`brew uninstall zellij`** (0.45.1 installed), after the Brewfile edit.
- **`~/.config/agents/GLOBAL.md`**, which lives in 1Password
  (`op://Private/Agent instructions/notes`) and is the source of truth for
  `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`. Three passages become false on
  merge: "`wt <branch>` — a sibling checkout … in its own Zellij dev session"; "Raw
  removal skips the Zellij session shutdown and the project teardown hook"; and
  "`wt` attaches to a Zellij session". Edited via `op-edit`, which needs an
  unsandboxed shell and a 1Password approval.

Machine state confirmed before planning: no running sessions, and no
`/tmp/zellij-$UID`, `~/.local/share/zellij` or `~/.cache/zellij`. Nothing is holding
state that removal could interrupt.

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
the point, and Zellij was merely the observable proxy for it. Each becomes an
assertion that teardown and removal were not reached.

One test is added, the inverse of one deleted: `wt` acquires the ownership lock.

`.scripts/test-dev.sh` is the rename of `test-hdev.sh`, with `hdev` → `dev`
throughout.

Live gates: `test-dev-topology.sh` is re-run, because it exercises `wt` creation, the
lock marker and label-resolved tab jumps against the real binary — all three of which
this change touches. `test-dev-integrations.sh` is **not** re-run: it covers the
Claude and Codex hook wiring, which this change does not touch.

Then `chezmoi apply --dry-run --verbose`, a real apply, and a live `dev <repo>` /
`wt <branch>` / `wt-rm <branch>` round trip. Final check: `grep -ri zellij` over the
repo returns hits only in the historical design records under `docs/`.

## Rollback

Rolling this change back is `git revert` plus `brew install zellij` — with one
ordering constraint inherited from the trial design.

The trial's rollback §0 warns that reverting `wt-rm` to a pre-trial form strands every
Herdr-locked worktree, because Git then refuses both `worktree remove` and single
`--force`. That hazard is unchanged and still applies, with one amendment: after this
change the marker is `wt-managed; …`, so a rollback must retire locks bearing **that**
string, not the `hwt-managed; …` one the trial spec names.

There are currently no locked worktrees, so a rollback performed today has nothing to
retire. That will not stay true once `wt` is used.

Rollback does not restore the four-week trial. Zellij's configuration would come back
from git intact, but a reverted setup is a fresh decision to run Zellij, not a
resumption of a measurement window that this document closes.
