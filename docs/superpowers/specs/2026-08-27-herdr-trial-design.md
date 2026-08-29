# Herdr trial alongside Zellij

**Status:** In progress

**Date:** 2026-08-27

**Amended:** 2026-08-27, three times, after peer review against the installed binary.
The passes corrected, in order: the worktree hazard, bootstrap and path identity; the
interrupted-build contradiction, the CLI sequence (which would not have run), the
plugin's no-op failure mode and the integration contract; then the managed baseline,
lock ordering, and the unowned `hooks.json`.

**Amended 2026-08-29, during execution.** Two decisions in this document were reversed
by what the build learned, and the text below now describes what exists rather than
what was originally approved:

- **Worktrees are supported, not refused.** The original design confined the trial to
  primary checkouts because `wt-rm` could not see Herdr. Execution ported that preflight
  instead, and added a Git ownership lock that makes `wt-rm` the only *supported
  lifecycle* path — a guardrail, not an enforcement boundary. See "The worktree
  lifecycle", which replaces the former "worktree guard".
- **Neovim navigation is no longer regressed.** smart-splits.nvim ships a Herdr plugin;
  `ctrl+h/j/k/l` are bound to its actions and covered by a live assertion.

Both were previously listed as non-goals or known limitations. Reversing a
safety-critical invariant without amending the record is precisely what this section
exists to prevent, and it went unrecorded for a day.

## Problem

The Zellij `dev` layout is, in practice, an agent harness wearing a dev-layout
costume. Tab 1 is `claude | codex` side by side, and the cross-model workflow in
`~/.config/agents/GLOBAL.md` is a manual relay between those two panes. Zellij has
no idea any of that is happening: it sees four tabs of undifferentiated terminal.

Two consequences follow.

The first is polling. Finding out whether Codex has finished means switching to the
`agents` tab and looking. With one project open that is a minor tax; with three
sessions detached it means visiting each one.

The second is that session persistence was actively turned off. `config.kdl` sets
`session_serialization false`, because resurrection restored tabs full of dead
"Waiting to run" banners rather than working agents — `dev` rebuilds the layout
faster and more reliably than Zellij restores it.

Herdr addresses both: it identifies coding agents inside panes, tracks a
`working` / `blocked` / `idle` / `done` lifecycle per agent, aggregates that into a
sidebar spanning every workspace, and restores sessions with agents resumed.

## Decision

Run Herdr **beside** Zellij as a reversible trial. Zellij, `dev` and
`~/.config/zellij` keep working unchanged for the duration. `wt` and `wt-rm` are
**extended** — they carry the worktree lifecycle described below — so they are the one
part of the existing setup this trial modifies.

This spec covers the trial. Whether to migrate is a separate decision, made against
the exit criteria below, and would get its own spec.

### The trial is not purely additive

An early draft claimed it touched only new files. Four exceptions are in scope:

- Agent integrations modify `~/.claude` and `~/.codex` (see "Integrations").
- `wt-rm` is extended with Herdr-aware teardown across running and stopped sessions,
  and `hdev`'s adoption path applies the Git ownership lock (see "The worktree
  lifecycle"). Plain `wt` is refactored to share creation and preparation with `hwt`
  via `_wt_create_or_prepare`, but its **behaviour is unchanged**: a `wt` worktree
  stays Zellij-only and unlocked.
- Neovim gains a Herdr-aware navigation binding — `dot_config/nvim/lua/plugins/
  smart-splits.lua`, dispatching `ctrl+h/j/k/l` through smart-splits.nvim's Herdr
  plugin (see "Keybindings").
- `hdev` routes a linked checkout to the worktree path rather than refusing it, which
  is what makes the `wt-rm` extension load-bearing rather than optional.

### Non-goals

- Migrating `dev`, `wt` or `wt-rm` to Herdr.
- ~~Porting `wt-rm`'s session-shutdown preflight~~ — **done during execution.** It is
  no longer a non-goal; see "The worktree lifecycle".
- ~~Adopting Herdr's built-in worktree support~~ — **partially adopted.** `herdr
  worktree open` provides provenance and sidebar grouping; Git creation, project
  preparation and teardown stay in the `wt` lifecycle. Herdr's own `new_worktree`
  shortcut is unbound, because it cannot run `.worktreeinclude` / `.worktreehook` or
  apply the ownership lock.
- Automating the Claude/Codex relay. Herdr can (`agent prompt`, `agent wait`), but
  GLOBAL.md defines the relay as manual: "One relay, one turn." That is a workflow
  choice, not a capability gap.
- ~~Neovim navigation integration~~ — **done during execution**, via smart-splits.nvim's
  own Herdr plugin. See "Keybindings".

## The worktree lifecycle

*Replaces "The worktree guard". The original design refused linked worktrees outright;
execution ported the safety property instead.*

`wt-rm` maintains a hard invariant at `dot_config/zsh/functions`: stop the session
**before** removing the worktree, because "a live process holding the directory open is
what leaves an empty `tmp/` husk behind." Originally that step knew exactly one
multiplexer, so a Herdr workspace on a `wt` worktree was invisible to it and the trial
simply refused to open one.

Three mechanisms now make worktrees safe rather than forbidden.

**1. Native adoption, not plain creation.** `hwt` creates the checkout through the
normal `wt` lifecycle (branch, `.worktreeinclude`, `.worktreehook`), then hands off to
`layout.sh --worktree <primary> <checkout>`, which calls `herdr worktree open` so the
workspace carries real worktree provenance and groups under its primary in the sidebar.
`hl_adopt_worktree` converts the resulting one-tab workspace into the managed baseline;
it re-reads the live topology first and refuses to adopt anything that is not blank, so
a stale or reshaped response cannot rename a user's tab.

`hdev` on a linked checkout routes to this path rather than refusing. Herdr's own
`new_worktree` binding is cleared and replaced by a popup calling `hwt-prompt`, because
the native creator cannot run the project hooks or apply the lock below.

**2. A Git ownership lock.** On adoption — in `hdev`, via `_wt_prepare_for_herdr`, not
in plain `wt` — `git worktree lock --reason "hwt-managed; remove with command wt-rm"`
is applied. A worktree created with `wt` and never opened in Herdr is never locked. Git then refuses `worktree remove` and
`remove --force`, so **`wt-rm` is the only supported lifecycle path**, and it crosses
the lock with `remove --force --force` *after* its three cleanliness checks. The lock is
a guardrail, not an enforcement boundary: anyone can run `remove --force --force`
themselves and bypass teardown entirely. What it buys is that doing so is deliberate
rather than accidental. The lock is deliberately
never released while Herdr owns the checkout: unlocking before removal would open an
interrupt window in which a checkout meant to be protected is exposed. If a worktree is
already locked for a different reason, adoption refuses rather than taking ownership of
a user-managed lock.

**3. Herdr-aware teardown.** `wt-rm` enumerates every Herdr session, matching a checkout
on both `workspace.worktree.checkout_path` and pane `cwd`, and closes matching
workspaces through the public API before removal. It is fail-closed at every step:
malformed or unexpected JSON refuses rather than proceeding, `server_not_running` is
distinguished from a genuine error, and a **stopped** session is inspected via its
persisted `session.json` — because a stopped session can still restore panes into the
checkout later. That inspection pins the persisted schema at `version == 3` and refuses
anything else rather than guessing at an unknown shape.

The net effect is the original invariant, preserved: no process may outlive the checkout
it is writing into.

## Model mapping

| Zellij today | Herdr in the trial |
|---|---|
| One session per repo (`netronix--curato`) | One workspace per repo, all in the default session |
| `zellij attach` / `switch-session` | `herdr` to attach the client; `workspace focus` to switch project |
| Four tabs from `dev.kdl` | Four tabs built by `layout.sh` |
| Status bar, per session | Sidebar, spanning every workspace |

Session-per-repo would mirror today's muscle memory more closely, but the sidebar
would then only ever show one project's agents — discarding the cross-project
visibility that motivates the trial.

## Architecture

```
   hdev curato ─────▶ layout.sh <repo>                       (build-or-focus, from a shell)
   hdev <worktree> ─┐
   hwt <branch> ────┴▶ layout.sh --worktree <primary> <co>   (native open + adopt)
   dev.layout.apply ─▶ layout.sh --current                   (repair-in-place, in a workspace)
```

`layout.sh` owns the topology definition. Its three modes differ in *entry condition*,
not in what a finished workspace looks like: all of them end at the same managed
baseline of `agents` / `editor` / `runtime` / `git`.

### Bootstrap

An earlier draft said `hdev` outside Herdr "starts or attaches the client (`herdr`),
then applies the layout". Not implementable: `herdr` is a blocking TUI returning only
on detach, and socket commands fail with no server:

```
$ herdr workspace list
{"error":{"code":"server_not_running",
          "message":"no herdr server is running at …/herdr.sock; run `herdr` to start or attach it"}}
```

Two further corrections, both verified:

- `herdr server` runs in the **foreground**. It must be explicitly backgrounded and
  detached from the calling shell, and concurrent starters tolerated — a second
  `hdev` racing the first must not fail, and must not start a second server.
- **`herdr status server` exits 0 while reporting `not running`.** Exit status is
  not a readiness signal. There is also no CLI `ping`; `ping` is a raw socket method.

The readiness probe is therefore an explicit failing CLI call — `herdr workspace
list` — testing for the `server_not_running` error code, retried with a bounded
timeout and a clear message on exhaustion. Never a fixed sleep.

Outside Herdr: probe → background a server if absent → wait for readiness → build or
focus → `exec herdr`. Inside Herdr (`HERDR_ENV=1`), only the middle step runs.

First-run behaviour is proven against the real binary, not asserted.

### Workspace identity

`WorkspaceInfo` exposes `workspace_id`, `label`, `number`, `focused`, `agent_status`
and `worktree`, but **no working directory**. An earlier draft concluded path
identity was unavailable and made the label the key. Wrong: `PaneInfo` carries both
**`cwd`** and **`foreground_cwd`**.

The label-only scheme was also not injective — `~/Code/Netronix/curato` and
`~/Netronix/curato` both rendered `Netronix/curato` — and labels are mutable, so a
rename would misroute `hdev`.

Identity is the **canonical repo path**, verified through panes:

1. Resolve the repo to a canonical absolute path.
2. **Acquire the per-path lock** (see "Lock ordering") — before any scan.
3. `herdr workspace list`, then `herdr pane list` for candidates; match on pane `cwd`.
4. Exactly one match → classify it (see "The managed baseline") and focus or repair.
5. Zero matches → build.
6. More than one match → **fail loudly**. Ambiguity is a bug, not something to guess
   through.

A workspace whose *label* looks right but whose panes sit elsewhere is simply **not a
match**, and the repo builds its own workspace. An earlier revision called for failing
loudly there too; that was vestigial label-thinking. Once identity is the path, the
label carries no authority, and treating a cosmetic string collision as an error would
make renaming a workspace break `hdev`.

Labels remain human-readable display strings (`Netronix/curato`), matching what
`dev`'s picker prints. They are no longer load-bearing.

`_wt_session_name` is not reused: it exists for Zellij's session-name constraints
and its transformation is not invertible.

### Completeness, and recovering from an interrupted build

The previous amendment introduced a provisional `(building)` label but kept
path-based identity, which contradicted itself: a half-built workspace still has
panes with the right `cwd`, so the scan matches it and the focus step lands on the
husk — the exact failure the provisional label was meant to prevent.

#### The managed baseline

"Four tabs named `agents`, `editor`, `runtime`, `git`" is the wrong test in both
directions. `alt+t` exists, so adding a fifth tab is ordinary use — and would demote
a perfectly healthy workspace to provisional, triggering repair on something that
needs none. Meanwhile a dead build can carry all four names while missing the runtime
split or an agent pane, and would certify as complete.

Completeness is therefore defined over a **managed baseline**, not over the workspace
as a whole:

- For each managed label (`agents`, `editor`, `runtime`, `git`) there must be
  **exactly one** tab, with its expected pane geometry — `agents` split right into
  two panes, `runtime` split down into two, `editor` and `git` single-pane.
- **Unmanaged tabs are ignored.** Extra tabs the user added are none of this
  script's business, and it must never close or renumber them.
- A workspace is **complete** when every managed label is present and well-formed,
  and carries the final label.
- **Provisional** means no malformed condition holds, but the final label is missing,
  or one or more managed tabs are, or both. The label matters independently of the
  tabs: a build killed after the last `tab create` but before the rename leaves
  correct topology under a `(building)` label. That state is complete in every
  respect except the one that marks it finished, and an earlier definition keyed only
  on missing tabs classified it as neither complete nor provisional. Repair creates
  whatever managed tabs are missing — possibly none — and renames.
- **Malformed** means a managed label appears more than once, or its geometry is
  wrong. This **fails non-destructively** — reported, never silently "fixed".
  Repairing a duplicate means choosing which one to destroy, and nothing here knows
  enough to make that choice safely.

`layout.sh` then handles:

- **Complete** → focus, exit 0.
- **Provisional** → repair: create only the missing managed tabs, then rename to the
  final label. Repair beats close-and-rebuild because the workspace may hold a
  running agent the user cares about.
- **Malformed** → fail with what was found and what was expected.

Belt and braces: the build runs under a trap that closes the workspace it created if
it fails partway. The trap covers the common case (a command errors); baseline
detection covers what the trap cannot reach (SIGKILL, a lost server). Both are
needed — neither alone is sufficient.

#### Repair cannot reorder, so nothing may depend on order

`herdr tab` offers `list`, `create`, `get`, `focus`, `rename` and `close` — there is
**no move**. A repaired tab is therefore appended, and a repaired workspace can have
its managed tabs in any order.

Any position-based tab jump is consequently unsound: after one repair, `alt+e` could
land on `git`. Tab jumps resolve by **unique label**, never by index. See
"Keybindings".

#### Lock ordering

The lock must be acquired **before any classification**, and the scan repeated
underneath it.

Classifying first and locking second permits a delayed duplicate: caller B scans and
sees no workspace, waits while A builds and releases, then acquires the lock and acts
on its stale observation — creating a second workspace for the same repo. Scanning
under the lock is what makes the decision and the action atomic.

The lock is per canonical repo path, in the style of `_wt_lock`, released on every
exit path.

### Construction sequence

IDs are parsed from JSON responses, never predicted, and passed explicitly to
**every** operation — not only tab creation. Herdr's public IDs (`w1`, `w1:t1`,
`w1:p1`) are opaque, and its agent skill file is explicit that closed IDs are not
reused and order must not be inferred.

Flags below are as the installed 0.8.2 accepts them. An earlier draft used
`--workspace-id` and `--target-pane-id`; **neither exists**, and the sequence would
have failed at the first tab.

```
workspace create --cwd <repo> --label "<label> (building)" --no-focus
  → ws = .result.workspace.workspace_id
    t1 = .result.tab.tab_id          (rename → "agents")
    p1 = .result.root_pane.pane_id

pane split --pane <p1> --direction right --cwd <repo>   → p2 = .result.pane.pane_id
pane run <p1> "claude"
pane run <p2> "codex"

tab create --workspace <ws> --label editor  --cwd <repo> → root pane pe → pane run <pe> "nvim ."
tab create --workspace <ws> --label runtime --cwd <repo> → root pane pr
pane split --pane <pr> --direction down --cwd <repo>      (two shells, nothing auto-run)
tab create --workspace <ws> --label git     --cwd <repo> → root pane pg → pane run <pg> "lazygit"

workspace rename <ws> "<label>"
workspace focus <ws>
tab focus <t1>
```

`--cwd <repo>` is passed explicitly at every creation rather than relying on
`new_cwd = "follow"`, whose inheritance depends on the source pane — which, during a
scripted build with focus deliberately withheld, is not a well-defined thing to
inherit from.

Construction runs `--no-focus` and focuses only once the workspace is complete. A
half-built workspace should never be the thing the user is looking at, and on a
repair the user is by definition already somewhere they chose to be.

Capturing each tab's `root_pane` is load-bearing. `tab create` does not focus new
tabs by default, so a bare `pane split --direction down` has no defined target and
could split the agents pane instead of the runtime tab's.

**`pane run`, not `agent start`.** `agent start` blocks until Herdr detects the agent
is ready, with a 30-second default — two of those serialize every workspace creation
behind two agent boot sequences. It also changes exit semantics: `dev.kdl` runs
`zsh -c "claude; exec zsh"` so quitting the tool leaves a live prompt. `pane run` in
a shell pane preserves that exactly.

### `hdev` (zsh function)

Repo resolution only, then delegation. The cascade is `dev`'s, unchanged: `.` or a
directory → its git repo; a path relative to `~/Code`; exact basename →
case-insensitive substring → `fzf`. `dev`'s session-name lookup branch is dropped.

Added to `dot_config/zsh/functions` alongside `dev`. `dev` is not modified.

### Plugin

`herdr-plugin.toml` registers `layout.sh --current` as action `dev.layout.apply`.

A previous amendment claimed the plugin was "a second caller carrying no new failure
mode". **That was wrong.** A plugin action runs from inside an existing workspace,
so plain `layout.sh` would match that workspace by `cwd`, focus it, exit 0, and
apply nothing — a silent no-op, and the most confusing possible outcome.

`--current` is therefore a distinct mode, not a shortcut:

- Target the workspace from `HERDR_WORKSPACE_ID` / `HERDR_PLUGIN_CONTEXT_JSON`, not
  a path lookup.
- Inspect its topology and create only what is missing, reusing the repair path
  above.
- Report the outcome — repaired, already complete, or malformed — through
  `herdr notification show`, not only the plugin log. A key-invoked action whose
  result is buried in a log file is indistinguishable from a broken keybinding.

This makes the action genuinely useful — repairing a workspace whose tabs were
closed — rather than decorative.

Registered with `herdr plugin link` (no build step). Registration is **global across
named sessions**, not per-session, which matters for both the live tests and
rollback: `herdr plugin unlink <plugin-id>`.

No `[[startup]]` hook — Herdr restores workspaces on restart, and a hook re-applying
layouts would fight it.

## Integrations

An earlier draft claimed integrations provide authoritative lifecycle state. **They
do not, for these two agents.** Herdr's matrix has two tiers, and Claude Code and
Codex are both in the lower one:

> **Lifecycle Authority** — Pi, OMP, Kimi, OpenCode, Kilo, MastraCode: report
> semantic `idle` / `working` / `blocked`.
> **Session Identity Only** — **Claude Code, Codex**, Copilot, Devin, Droid, Qoder,
> Qwen, Cursor, Hermes, Antigravity, Grok: native session references for restore,
> with state sourced from Herdr's screen detection.

Sidebar status is therefore identical with or without them. What they buy is cold
restore: agents resumed by native session reference across a server restart. That
is the sole justification, and the exit criteria reflect it.

Touchpoints, to be confirmed by install-and-diff before anything is committed:

| Agent | Install writes | Uninstall |
|---|---|---|
| Claude | `~/.claude/hooks/herdr-agent-state.sh`, hook entries in `settings.json` | removes both |
| Codex | `~/.codex/herdr-agent-state.sh`, entries in `hooks.json`, `[features] hooks = true` in `config.toml` | removes hook + `hooks.json` entries; **deliberately leaves `config.toml` unchanged** |

Four mechanics follow, all of which must be solved in chezmoi rather than left to the
installer. **Every touchpoint needs an owner**: `.chezmoiignore` allowlists both
`.claude/*` (lines 57-66) and `.codex/*` (lines 73-78), so anything without one is
silently dropped on the next provision.

- **Both hook scripts need explicit `!` re-inclusions** or they will never deploy.
- **`settings.json` is already rewritten in place** by
  `dot_claude/modify_private_settings.json`, which owns the `hooks` block. Herdr's
  hook registration must merge into that script; leaving it to the installer means
  the two fight on every `chezmoi apply`.
- **`config.toml` is already managed** by `dot_codex/modify_private_config.toml`,
  which pins `features.*` via `setValueAtPath`. `features.hooks` must be pinned
  there. Because Herdr's uninstall deliberately leaves the flag set, rollback has to
  restore its prior value explicitly — nothing else will.
- **`~/.codex/hooks.json` has no owner at all**, and that is the dangerous one. The
  re-inclusion list is `AGENTS.md`, `config.toml` and `themes/` — `hooks.json` is
  not among them. Reprovisioning a machine would therefore deploy Codex's hook
  script *and* set `features.hooks = true`, while never writing the registration
  that connects them: Codex cold restore would silently stop working, with every
  visible artifact present and correct.

  It needs a merge-preserving `dot_codex/modify_private_hooks.json` that adds only
  Herdr's entries and leaves any other hook registration intact, plus its own
  `.chezmoiignore` re-inclusion. Rollback removes Herdr's entries, not the file.

Sandbox note: `~/.claude/hooks` and `~/.claude/settings.json` are write-denied, so
installation and the subsequent `chezmoi apply` need an unsandboxed shell.

## Configuration

`~/.config/herdr/config.toml`, chezmoi-managed, carrying only deliberate divergences
from `herdr --default-config` so upstream default changes stay visible.

Two settings are pinned rather than left to defaults:

- `onboarding = false`. Left unset, first run shows onboarding and may write back to
  the config file — which chezmoi manages, so the write would surface as drift and be
  reverted on the next apply.
- `session.resume_agents_on_restore = true`. It is the shipped default but arrives
  commented out, and it is the single setting the integrations exist to serve. The
  default config notes it "requires official integrations that report session refs",
  which is exactly what installing Claude and Codex provides. Pinning it makes the
  dependency legible in one place.

### Theme

`tokyo-night` is built in — confirmed in the shipped default config alongside
catppuccin, terminal, dracula, nord, gruvbox, one-dark, solarized, kanagawa,
rose-pine and vesper. No `[theme.custom]` overrides. Matches Ghostty and Zellij.

### Keybindings

Prefix-less `Alt+<letter>`, `Ctrl+h/j/k/l` for navigation — mnemonic rather than
numeric, because digits require Shift on AZERTY. `ctrl+b` stays bound as prefix, an
escape hatch. Zellij needed `clear-defaults=true` because its stock `Ctrl` leaders
shadowed shell and Neovim keys; Herdr's prefix model has no such problem.

| Key | Herdr action | Was |
|---|---|---|
| `alt+z` | `zoom` | `ToggleFocusFullscreen` |
| `alt+n` | `split_vertical` | `NewPane` |
| `alt+t` | `new_tab` | `NewTab` |
| `alt+w` | `detach` | `Detach` |
| `alt+b` | `toggle_sidebar` | *(new)* |
| `ctrl+h/j/k/l` | `plugin_action` → `smart-splits.nvim.{left,down,up,right}` | vim-zellij-navigator |

Two bindings have no native equivalent:

- **Tab jumps (`alt+a`/`e`/`r`/`g`).** `switch_tab` is range-only (`"prefix+1..9"`);
  there is no `switch_tab_1`, and `tab.focus` takes a `tab_id`, not an index. Each
  key runs `tab-goto.sh <label>` via `[[keys.command]]`, resolving the **label** —
  `agents`, `editor`, `runtime`, `git` — to its `tab_id` in the active workspace.
  Never an index: repair appends, `herdr tab` has no move, and a user's own `alt+t`
  tab shifts every position after it. A label that is missing or ambiguous produces a
  message, not a jump to the wrong tab.
- **Scratch popup (`alt+p`).** `type = "popup"` — session-modal, does not disturb the
  tab layout. The on-demand `bin/rails console` slot, and a better fit than Zellij's
  floating layer, where `Alt+n` created *floating* panes while the layer was visible.

**`alt+k` (clear) is dropped.** An earlier draft specified a helper without
confirming a mechanism existed. There is none: the `pane.*` API has no clear or reset
method, only `send_text` / `send_keys`. Clearing could only inject control sequences
into whatever occupies the pane — corrupting state in Neovim, or sending input to a
live agent. Not worth it for a convenience binding.

`alt+s` is **`edit_scrollback`**, not Zellij's modal scroll — Herdr has no scroll mode;
it opens the scrollback in an editor. The mnemonic is kept because the finger habit is
"alt+s to look back", even though the mechanism differs.

### Helper context

`tab-goto.sh` must target the workspace the keypress came from. Resolving via the
globally-focused workspace is racy: persistence is a shared session view, so another
attached client can change focus between keypress and query.

Herdr documents active-context variables for `[[keys.command]]`:
`HERDR_ACTIVE_WORKSPACE_ID`, `HERDR_ACTIVE_TAB_ID`, `HERDR_ACTIVE_PANE_ID`,
`HERDR_ACTIVE_PANE_CWD`. They do not appear in `herdr --default-config`, so the
implementation verifies them at runtime as a compatibility check — dumping the
environment from a bound key — and the helper fails with a clear message rather than
falling back to global focus if they are absent.

### Alt-key viability

Herdr's config warns `alt+…` bindings "may depend on your terminal/tmux setup" and
that `ctrl+letter` and function keys are most reliable. Ghostty is configured
`macos-option-as-alt = left`, so the scheme is viable via the **left** Option key
only. This is the most likely thing to fail, and it fails visibly. Test it first.

## Artifacts

```
dot_config/herdr/config.toml               → ~/.config/herdr/config.toml
dot_config/herdr/executable_layout.sh      → topology definition, all three modes
dot_config/herdr/executable_tab-goto.sh    → tab focus by unique label
dot_config/herdr/plugin/herdr-plugin.toml  → registers dev.layout.apply
dot_config/zsh/functions                   → += hdev(), hwt(), hwt-prompt();
                                             wt/wt-rm EXTENDED for the worktree
                                             lifecycle (no longer untouched)
dot_config/nvim/lua/plugins/smart-splits.lua → herdr-aware ctrl+h/j/k/l
.chezmoiignore                             → re-include both hook scripts + hooks.json
dot_claude/modify_private_settings.json    → merge Herdr hook registration
dot_codex/modify_private_config.toml       → pin features.hooks
dot_codex/modify_private_hooks.json        → merge Herdr entries into hooks.json (new owner)
dot_claude/…, dot_codex/…                  → the two hook scripts
.scripts/test-hdev.sh                      → mocked test
.scripts/test-wt-functions.sh              → EXTENDED: worktree lifecycle + teardown
.scripts/test-hdev-topology.sh             → live, isolated session
.scripts/test-hdev-integrations.sh         → live, controlled install/restore/uninstall
```

`brew "herdr"` landed in `Brewfile.tmpl` in commit `01bd008`.

No `brew services start herdr`. A trial does not earn a login daemon.

## Testing

### Mocked — `.scripts/test-hdev.sh`

Stub `herdr` on `PATH`, log every invocation, assert on the log. Real git repos,
stubbed multiplexer, following `test-wt-functions.sh`.

- **Resolution.** Every branch of the cascade; a non-repo argument fails without
  calling `herdr` at all.
- **Worktree routing.** A linked checkout is *accepted* and opened through the primary
  repo's Herdr worktree group, and a subdirectory of one resolves to the worktree root
  rather than being treated as its own repo. A native worktree workspace adopts,
  reopens and repairs; a linked-worktree workspace that is **not** registered as a
  native worktree is refused, since it carries no provenance for `wt-rm` to find.
- **Identity.** Path matching focuses the right workspace; two repos sharing a
  basename across orgs resolve to two workspaces; a label match whose pane `cwd`
  disagrees fails rather than focusing; two matches fail rather than guessing.
- **Idempotency.** A second `hdev` emits exactly one `workspace focus` and zero
  `create` calls.
- **Completeness.** A workspace at the right path with three managed tabs is treated
  as provisional, not focused as complete. One with four managed tabs plus two the
  user added is treated as complete, and neither extra tab is touched.
- **The rename window.** A workspace with correct topology but still carrying the
  `(building)` label — the state a SIGKILL between the last `tab create` and the
  rename produces — is classified provisional and repaired by renaming alone, with
  **zero** `tab create` calls. This is the narrowest interrupted state and the one a
  tab-count-only check misses entirely.
- **Malformed fails without mutating.** A workspace with two tabs labelled `agents`,
  and separately one whose `runtime` tab has a single pane, each fail with a report —
  and the invocation log shows no `create`, `close`, `split` or `rename` at all.
  Asserting the absence of mutation is the point of the test; a "safe" failure that
  still touched the workspace would pass a weaker assertion.
- **Interrupted build, both paths.** A stub failing at the third `tab create`
  triggers the trap and closes the workspace. A pre-seeded stale provisional
  workspace is *repaired* — missing tabs created, then renamed — not duplicated and
  not focused as-is.
- **Ordering.** Panes split before commands run in them; workspace before tabs.
- **Explicit IDs.** Stub JSON returning `w7:p3` must produce `pane run w7:p3 …`, and
  `pane split --pane w7:p3 …`, never a guessed `w1:p1` and never an untargeted split.
- **Failure reporting.** A mid-sequence failure is reported, never silently
  presented as success. `dev` learned this the hard way: every step of the old
  detached-session shape returned 0 while the layout silently failed.

Assertions pin exact values. A test that cannot go red is not coverage.

### Live, isolated — `.scripts/test-hdev-topology.sh`

An earlier draft claimed the mocked suite would catch Herdr CLI churn. **It cannot** —
a stub defines its own acceptance and keeps passing after the real binary changes its
flags or JSON shapes. That claim is withdrawn; this script replaces it.

Against `herdr --session hdev-test`, never the live session:

- Cold bootstrap with no server running, including the backgrounding and the
  readiness probe.
- **Concurrency, on the schedule that actually breaks it.** Launching two `hdev`
  calls at once mostly proves nothing — the interesting interleaving is B scanning,
  A building and releasing, *then* B acquiring. Force that order explicitly; a race
  test that only ever passes by luck is not a test.
- Actual resulting topology: managed labels present, correct pane counts and split
  directions.
- Extra unmanaged tabs are tolerated, not "repaired" away.
- A duplicated managed label fails non-destructively.
- Interrupted-build repair, and label-resolved tab jumps landing correctly *after* a
  repair has appended a tab out of order.
- Key-command context: what is actually injected.

A named session isolates the socket and runtime state. It does **not** isolate plugin
registration, which is global — so this test links under a **distinct plugin id**
(`dev.layout.test`). Reusing the real id would let teardown unlink the plugin the
live setup depends on.

### Live, uncontained — `.scripts/test-hdev-integrations.sh`

Integrations touch real `~/.claude` and `~/.codex`; no named session isolates them.
The test is therefore split in two, so that only the part which *must* touch real
config does.

**Against temporary fixtures** — `CLAUDE_CONFIG_DIR` and `CODEX_HOME` pointed at
scratch directories (both to be confirmed as honoured by the installer before the
plan relies on them):

- Install, and diff what actually changed against the table above.
- Uninstall, confirming `features.hooks` is left set and that removal touches only
  Herdr's entries in `hooks.json`.

**Against the real config, once** — after the chezmoi sources are in place and
applied normally, cold restore is exercised in a dedicated named session. It does
**not** reinstall the integrations; it verifies the ones chezmoi deployed.

Every test runs under a cleanup trap that restores prior registry and config state on
any exit path, including interruption. Diffs report *which keys* changed — never a
dump of `settings.json`, `hooks.json` or `config.toml`, which carry credentials and
machine state.

## Known limitations

**~~Neovim navigation is regressed~~ — resolved during execution.** smart-splits.nvim
ships its own Herdr plugin, so no third-party port was needed. `ctrl+h/j/k/l` are bound
as `plugin_action` entries dispatching to `smart-splits.nvim.{left,down,up,right}`:
inside Neovim they move between editor splits and call Herdr at the edge; outside, they
move pane focus while preserving shell `Ctrl-h`/`Ctrl-l` where no neighbour exists.
Linking that plugin is part of the live activation gate, and the topology gate asserts
focus actually crosses Herdr panes.

**Shared session view.** Per the 0.8.2 CHANGELOG: "The current persistence model is a
shared session view across attached clients. It is not yet full tmux-style per-client
independent navigation." Two attached clients move together.

**Agent status is screen-detected**, not agent-reported, for both Claude and Codex.
Whatever the sidebar shows is inference from the terminal buffer. The exit criteria
must judge that inference, not assume it.

**Version 0.8.2** is younger and moving faster than Zellij 0.45, and the CLI surface
is the contract this design depends on. The live gates are the only churn detector.

## Exit criteria

Fixed window: **four weeks** of ordinary use across at least three projects.

Migrate if all of:

- **Restore:** ≥90% success over **at least ten** cold-restoration attempts —
  workspaces and agents usable without manual repair. Fewer than ten attempts means
  the criterion is unmet, not passed by default.
- **Correctness:** zero wrong-workspace events, zero husk incidents, zero manual
  repairs of a half-built workspace after the first week.
- **Keybindings:** the Alt scheme survives four weeks in Ghostty without remapping.
- **The actual question:** agent state was *noticed* rather than polled for — at
  least weekly, a Herdr status display prompted action on a blocked or finished agent
  before it would otherwise have been checked. Since that state is screen-detected,
  this also tests whether the inference is trustworthy. If it fails, nothing else
  matters: it is the entire reason to move.

Abandon if restore is unreliable, if the CLI churns enough to need regular repair, or
if agent status proves a novelty that does not change behaviour.

## Rollback

**0. Retire the Git ownership locks — before reverting anything.** This step is first
because it is the only one the later steps can strand. Adoption applies
`git worktree lock`, and there is deliberately no unlock path while Herdr owns a
checkout: `wt-rm` crosses the lock with `remove --force --force`. Once `wt-rm` is
reverted to its pre-trial form, plain `worktree remove` and single `--force` both fail
(exit 128, "cannot remove a locked working tree"), so every worktree Herdr ever opened
becomes unremovable by your own tooling.

Git's error does name the reason and the escape hatch, so this is recoverable rather
than fatal — but it is avoidable entirely by doing it in the right order:

The ownership marker is the exact string `hwt-managed; remove with command wt-rm` —
note it contains no "herdr", so a substring search for that word silently matches
nothing and reports a clean inventory when worktrees are in fact locked. Match it
exactly, and parse porcelain records so the *path* is what comes out:

```bash
MARKER='hwt-managed; remove with command wt-rm'
for gd in ~/Code/*/*/.git ~/Code/*/.git; do
  # Directory => primary checkout. A linked worktree's .git is a FILE, and querying one
  # lists the same worktrees again, so every hit would repeat once per checkout.
  [ -d "$gd" ] || continue
  git -C "${gd%/.git}" worktree list --porcelain -z 2>/dev/null | tr '\0' '\n' | awk -v m="$MARKER" '
    /^worktree /      { p = substr($0, 10) }
    $0 == "locked " m { print p }
  '
done | sort -u
```

For each path listed:

- **Finished with it** → retire now with the **current** `command wt-rm <branch>`, while
  it can still cross the lock.
- **Keeping it** → close **every** Herdr reference to it first, not just the one
  workspace you can see: the same checkout may be open in several sessions, and a
  *stopped* session can restore panes into it later. Either close each matching
  workspace across every session, or stop all Herdr sessions. Then
  `git worktree unlock <path>`.

Re-run the inventory afterwards and confirm it prints nothing.

*(Verified 2026-08-29: no locked worktrees exist under `~/Code`, so nothing is stranded
today. This step is preventive.)*

1. `herdr integration uninstall claude`, then `herdr integration uninstall codex` —
   the CLI takes exactly one target per invocation. Restore `features.hooks` to
   its prior value in `dot_codex/modify_private_config.toml` — Herdr's uninstall
   deliberately will not. Revert the `modify_private_settings.json` merge, remove
   `dot_codex/modify_private_hooks.json`, and revert the `.chezmoiignore`
   re-inclusions.
2. `herdr plugin unlink <plugin-id>` — registration is global, so this is required
   even if the trial session is gone.
3. **Enumerate sessions and stop each**, default and named alike. Each named session
   has its own socket and survives independently; stopping the default one leaves the
   others running. Before each: confirm no pane processes are worth keeping —
   **`herdr server stop` terminates every process in every pane.**
4. Delete `dot_config/herdr/`, `hdev`, all three test scripts, then `chezmoi apply`
   so the reverted sources actually reach `$HOME` — deleting a chezmoi source alone
   changes nothing on disk. Reload open shells, which still hold the old `hdev`.
5. Drop the Brewfile line; `brew uninstall herdr`.
6. `~/.config/herdr/` holds logs, stopped-session state and the plugin registry, so
   it is **archived, not deleted** — moved aside, with removal left as an explicit
   separate decision once nothing is needed from it. Same for `~/.herdr/` if present.
   The exact `$XDG_STATE_HOME/herdr-trial/restore-fixture` directory is synthetic
   test state and can be removed after every Herdr session is stopped. Codex records
   that fixture's absolute path as trusted; the current CLI and official documentation
   expose no supported command to remove one trust entry, so deleting the fixture may
   leave an inert path in `config.toml`. Do not hand-edit the deployed dotfile to hide
   that limitation.

Zellij and `dev` are untouched throughout. `wt` and `wt-rm` are **not** — they carry
the worktree lifecycle, so their changes must be reverted in `dot_config/zsh/functions`
and re-applied, and step 0 must precede that revert. An earlier revision of this
sentence claimed all four were untouched; that was true only before worktree support
existed.
