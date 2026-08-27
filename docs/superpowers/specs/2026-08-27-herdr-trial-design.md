# Herdr trial alongside Zellij

**Status:** Approved

**Date:** 2026-08-27

**Amended:** 2026-08-27, after peer review against the installed binary. Corrections
are recorded inline; the sections most changed are Bootstrap, Workspace identity,
Integrations, and Testing.

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

Herdr addresses both directly: it identifies coding agents inside panes, tracks a
`working` / `blocked` / `idle` / `done` lifecycle per agent, aggregates that into a
sidebar spanning every workspace, and restores sessions with agents resumed.

## Decision

Run Herdr **beside** Zellij as a reversible trial. `dev`, `wt`, `wt-rm` and
`~/.config/zellij` keep working unchanged for the duration.

This spec covers the trial. Whether to migrate is a separate decision, made against
the exit criteria below, and would get its own spec.

### Scope correction: the trial is not purely additive

The original draft claimed the trial touched only new files. That was wrong in two
ways, both now in scope:

- Agent integrations modify `~/.claude` and `~/.codex` (see "Integrations").
- `hdev` must actively refuse a class of directory to avoid weakening `wt-rm`
  (see "The worktree guard").

### Non-goals

- Migrating `dev`, `wt` or `wt-rm` to Herdr.
- Porting `wt-rm`'s session-shutdown preflight to also stop Herdr workspaces. The
  trial sidesteps the need by refusing to open workspaces in linked worktrees at
  all.
- Adopting Herdr's built-in worktree support (`[worktrees]`, `new_worktree`,
  `worktree.created`). It overlaps `wt`.
- Automating the Claude/Codex relay. Herdr can do it (`agent prompt`, `agent wait
  --until blocked`), but GLOBAL.md defines the relay as manual and deliberate:
  "One relay, one turn." That constraint is a workflow choice, not a capability gap.
- Neovim navigation integration. See "Known limitations".

## The worktree guard

`wt-rm` maintains a hard invariant, stated at `dot_config/zsh/functions:781-789`:
stop the session **before** removing the worktree, because "a live process holding
the directory open is what leaves an empty `tmp/` husk behind." Its shutdown step
knows exactly one multiplexer:

```zsh
if zellij list-sessions -s 2>/dev/null | grep -Fqx -- "$name"; then
  zellij delete-session --force "$name" ...
```

A Herdr workspace opened on a `wt`-managed worktree is invisible to that check.
`wt-rm` would report a clean shutdown, remove the checkout, and leave Herdr panes
writing into a deleted directory — reproducing precisely the husk the preflight was
built to prevent.

**Therefore `hdev` refuses linked worktrees.** A repo whose `--git-common-dir`
resolves outside its own `.git` is a linked worktree; `hdev` reports that and points
at `dev`. The plugin action inherits the same guard, since both call `layout.sh`.

This keeps the trial confined to primary checkouts, where no teardown lifecycle
competes with it. Extending Herdr to worktrees requires porting the preflight first,
and that belongs to a migration decision, not a trial.

## Model mapping

| Zellij today | Herdr in the trial |
|---|---|
| One session per repo (`netronix--curato`) | One workspace per repo, all in the default session |
| `zellij attach` / `switch-session` | `herdr` to attach the client; `workspace focus` to switch project |
| Four tabs from `dev.kdl` | Four tabs built by `layout.sh` |
| Status bar, per session | Sidebar, spanning every workspace |

The single-server choice is the point of the exercise. Session-per-repo would mirror
today's muscle memory more closely, but the sidebar would then only ever show one
project's agents — discarding the cross-project visibility that motivates the trial.

## Architecture

One layout definition, two entry points.

```
                    ┌─────────────────────────┐
   hdev curato ────▶│                         │
   (zsh function)   │  ~/.config/herdr/       │──▶ herdr workspace create
                    │      layout.sh          │    herdr tab create
   plugin action ──▶│                         │    herdr pane split / run
   dev.layout.apply └─────────────────────────┘
```

`layout.sh` is the single source of truth for what a project workspace looks like.
Neither entry point duplicates any part of it.

### Bootstrap

The original draft said `hdev` outside Herdr "starts or attaches the client
(`herdr`), then applies the layout". That is not implementable: `herdr` is a
blocking TUI that returns only on detach, and socket commands fail without a server.
Verified:

```
$ herdr workspace list
{"error":{"code":"server_not_running",
          "message":"no herdr server is running at …/herdr.sock; run `herdr` to start or attach it"}}
```

The correct sequence, outside Herdr:

1. If no server is running (`herdr status`), start one headlessly: `herdr server`.
2. Wait for socket readiness by polling a cheap read (`ping`), with a bounded
   timeout and a clear failure message. Do not sleep a fixed interval and hope.
3. Build or focus the workspace over the socket.
4. `exec herdr` to attach the client.

Inside Herdr (`HERDR_ENV=1`), steps 1, 2 and 4 are skipped.

First-run behaviour is proven against the real binary, not asserted — see "Testing".

### Workspace identity

`WorkspaceInfo` exposes `workspace_id`, `label`, `number`, `focused`, `agent_status`
and `worktree`, but **no working directory**. The original draft concluded that path
identity was therefore unavailable and made the label the key. That was wrong:
`PaneInfo` carries both **`cwd`** and **`foreground_cwd`**.

The label-only scheme was also not injective — `~/Code/Netronix/curato` and
`~/Netronix/curato` both rendered as `Netronix/curato` — and labels are mutable and
non-unique, so a rename or a duplicate would silently misroute `hdev`.

Identity is therefore the **canonical repo path**, verified through panes:

1. Resolve the repo to a canonical absolute path.
2. `herdr workspace list`; for candidates, inspect their panes' `cwd` via
   `herdr pane list`.
3. Exactly one workspace whose panes match the canonical path → `workspace focus`,
   exit 0.
4. Zero matches → build.
5. More than one match, or a label match whose path disagrees → **fail loudly**.
   Ambiguity is a bug, not something to guess through.

Labels remain human-readable display strings (`Netronix/curato`), matching what
`dev`'s picker prints (`${pool[@]#$code/}`). They are no longer load-bearing.

`_wt_session_name` is not reused. It exists to satisfy Zellij's session-name
constraints — lowercasing, `/` → `--`, hashing on collision or names over 60
characters — and its transformation is deliberately not invertible.

### Building safely

Three failure modes get explicit handling:

- **Interrupted builds.** A workspace is created under a provisional label
  (`…  (building)`) and renamed to its final label only once all four tabs exist.
  Without this, an interrupted build leaves something the next `hdev` finds, focuses,
  and reports success on — a half-built workspace presented as ready.
- **Implicit targeting.** Every `tab create` passes the captured `workspace_id`
  explicitly. Relying on the focused workspace races against the user and any other
  attached client.
- **Concurrency.** `hdev` takes a per-repo lock for the build, in the style of
  `_wt_lock`, so two invocations cannot both decide to create.

### Construction sequence

IDs are parsed from JSON responses, never predicted. Herdr's public IDs (`w1`,
`w1:t1`, `w1:p1`) are opaque; its agent skill file is explicit that closed IDs are
not reused and order must not be inferred.

```
workspace create --cwd <repo> --label "<label> (building)" --focus
  → w1, tab w1:t1 (rename → "agents"), root pane w1:p1
pane split --target-pane-id w1:p1 --direction right   → w1:p2
pane run w1:p1 "claude"
pane run w1:p2 "codex"

tab create --workspace-id w1 --label editor   → pane run "nvim ."
tab create --workspace-id w1 --label runtime  → pane split --direction down
tab create --workspace-id w1 --label git      → pane run "lazygit"

workspace rename w1 "<label>"
tab focus <agents tab id>
```

**`pane run`, not `agent start`.** `agent start` blocks until Herdr detects the agent
is ready, with a 30-second default timeout — two of those serialize every workspace
creation behind two agent boot sequences. It also changes exit semantics: `dev.kdl`
runs `zsh -c "claude; exec zsh"` so quitting the tool leaves a live prompt. `pane
run` in a shell pane preserves that exactly.

### `hdev` (zsh function)

Repo resolution only, then delegation. The cascade is `dev`'s, unchanged: `.` or a
directory → its git repo; a path relative to `~/Code`; exact basename →
case-insensitive substring → `fzf`. `dev`'s session-name lookup branch is dropped.

`hdev` is added to `dot_config/zsh/functions` alongside `dev`. `dev` is not modified.

### Plugin

`~/.config/herdr/plugin/herdr-plugin.toml` registers `layout.sh` as action
`dev.layout.apply`, making the same layout reachable from Herdr's menu and bindable
to a key, without a shell and without a second copy of the layout logic. Registered
with `herdr plugin link`, which runs no build step.

Peer review suggested dropping this for simplicity. It is retained deliberately: it
is a second caller of an already-tested script, carrying no new failure mode, and
the two-entry-point shape was the approved design.

No `[[startup]]` hook is declared — Herdr already restores workspaces on restart, and
a hook that re-applied layouts would fight it.

## Integrations

Herdr detects agents from foreground processes and screen manifests, so the sidebar
populates without integrations. What integrations add is *authoritative* lifecycle
state (`idle` / `working` / `blocked` reported by the agent rather than inferred from
the terminal buffer) and native session identity for cold restore.

All 18 are currently uninstalled:

```
$ herdr integration status
claude: not installed (/Users/michael/.claude/hooks/herdr-agent-state.sh)
codex:  not installed (/Users/michael/.codex/herdr-agent-state.sh)
```

The trial installs `claude` and `codex`, and brings the result under chezmoi rather
than leaving drift in generated directories. Two mechanics must be solved, and both
are verified by installing and diffing before anything is committed:

- **`.chezmoiignore` is an allowlist for `.claude`.** Lines 57-66 ignore `.claude/*`
  and re-include named entries individually. A hook at `.claude/hooks/…` is ignored
  by default and will not deploy without an explicit `!` re-inclusion.
- **`settings.json` is already rewritten in place.** `dot_claude/modify_private_settings.json`
  is a chezmoi `modify_` script. If the integration also edits `settings.json` to
  register its hook, the two will fight on every `chezmoi apply`. If it does, hook
  registration must move into the `modify_` script and not be left to the installer.

Sandbox note: `~/.claude/hooks` and `~/.claude/settings.json` are both write-denied,
so installation and the subsequent `chezmoi apply` require an unsandboxed shell.

## Configuration

`~/.config/herdr/config.toml`, chezmoi-managed, carrying only deliberate divergences
from `herdr --default-config` so that upstream default changes stay visible.

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
| `ctrl+h/j/k/l` | `focus_pane_left/down/up/right` | vim-zellij-navigator |

Two bindings have no native equivalent:

- **Tab jumps (`alt+a`/`e`/`r`/`g`).** `switch_tab` is range-only (`"prefix+1..9"`);
  there is no `switch_tab_1`, and `tab.focus` takes a `tab_id`, not an index. Each key
  runs `tab-goto.sh <n>` via `[[keys.command]]`.
- **Scratch popup (`alt+p`).** `type = "popup"` — a session-modal terminal that does
  not disturb the tab layout. This is the on-demand `bin/rails console` slot, and a
  better fit than Zellij's floating layer, where `Alt+n` created *floating* panes
  while the layer was visible.

**`alt+k` (clear) is dropped.** The original draft specified a `clear-pane.sh`
helper without confirming a mechanism existed. There is none: the `pane.*` API
surface has no clear or reset method, only `send_text` / `send_keys`. Clearing could
only be done by injecting control sequences into whatever occupies the pane, which
in Neovim or an agent TUI risks corrupting state or sending input to an agent. Not
worth it for a convenience binding.

`alt+s` (scroll mode) is also dropped — Herdr has no modal scroll; it uses the mouse
and `prefix+e` (`edit_scrollback`).

### Helper context

`tab-goto.sh` must target the workspace the keypress came from. Resolving via the
globally-focused workspace is racy: the persistence model is a shared session view,
so another attached client can change focus between the keypress and the query.

Herdr is reported to expose active-context variables to `[[keys.command]]`
(`HERDR_ACTIVE_WORKSPACE_ID`, `HERDR_ACTIVE_TAB_ID`, `HERDR_ACTIVE_PANE_ID`,
`HERDR_ACTIVE_PANE_CWD`). These do **not** appear in `herdr --default-config` and are
unverified. The implementation plan's first task is to dump the environment from a
bound key and use whatever is actually injected; the helper fails with a clear
message rather than falling back to global focus if nothing is.

### Alt-key viability

Herdr's own config warns `alt+…` bindings "may depend on your terminal/tmux setup"
and that `ctrl+letter` and function keys are the most reliable. Ghostty is configured
`macos-option-as-alt = left`, so the scheme is viable via the **left** Option key
only. This is the most likely thing to fail, and it fails visibly. Test it first.

## Artifacts

```
dot_config/herdr/config.toml               → ~/.config/herdr/config.toml
dot_config/herdr/executable_layout.sh      → the single layout definition
dot_config/herdr/executable_tab-goto.sh    → tab focus by index
dot_config/herdr/plugin/herdr-plugin.toml  → registers dev.layout.apply
dot_config/zsh/functions                   → += hdev()   (dev/wt/wt-rm untouched)
.chezmoiignore                             → re-include the herdr agent hooks
dot_claude/…, dot_codex/…                  → integration hooks, exact paths TBD by install-and-diff
.scripts/test-hdev.sh                      → mocked test
.scripts/test-hdev-live.sh                 → real-binary gate, run manually
```

`brew "herdr"` landed in `dot_config/homebrew/Brewfile.tmpl` in commit `01bd008`.

No `brew services start herdr`. A trial does not earn a login daemon.

## Testing

### Mocked — `.scripts/test-hdev.sh`

Stub `herdr` on `PATH`, log every invocation, assert on the log. Real git repos,
stubbed multiplexer, following `test-wt-functions.sh`.

- **Resolution.** Every branch of the cascade; a non-repo argument fails without
  calling `herdr` at all.
- **The worktree guard.** A linked worktree is refused, with zero `herdr` calls.
- **Identity.** Path-based matching focuses the right workspace; two repos sharing a
  basename in different orgs resolve to two workspaces; a label match whose pane
  `cwd` disagrees fails rather than focusing; two matches fail rather than guessing.
- **Idempotency.** A second `hdev` emits exactly one `workspace focus` and zero
  `create` calls.
- **Interrupted build.** A stub failing at the third `tab create` leaves no workspace
  under the final label, and the next run rebuilds rather than focusing a husk.
- **Ordering.** Panes split before commands run in them; workspace before tabs.
- **ID handling.** Stub JSON returning `w7:p3` must produce `pane run w7:p3 …`, not a
  guessed `w1:p1`.
- **Failure reporting.** A mid-sequence failure is reported, never silently
  presented as success. `dev` learned this the hard way: every step of the old
  detached-session shape returned 0 while the layout silently failed.

Assertions pin exact values. A test that cannot go red is not coverage.

### Live — `.scripts/test-hdev-live.sh`

The original draft claimed the mocked suite would catch Herdr CLI churn. **It cannot**
— a stub defines its own acceptance and keeps passing after the real binary changes
its flags or JSON shapes. That claim is withdrawn.

Churn detection needs the real binary, against an isolated named session
(`herdr --session hdev-test`), never the live one:

- Cold bootstrap with no server running.
- The actual resulting topology: four tabs, correct pane counts and split directions.
- Duplicate-path and concurrent invocation.
- Interrupted-build recovery.
- `plugin link` succeeding and the action being invocable.
- Key-command context: what is actually injected.
- Claude/Codex detection and cold restore across a server restart.

Run manually and unsandboxed; not part of the mocked suite.

## Known limitations

**Neovim navigation is regressed.** Binding `ctrl+h/j/k/l` natively means Herdr
consumes them before Neovim, so inside `nvim` they move between Herdr panes rather
than splits. smart-splits.nvim cannot see across the boundary without a Herdr-aware
counterpart to vim-zellij-navigator. Community options exist (`herdr-splits.nvim`,
`herdr-nvim-nav`, ports of vim-tmux-navigator); none is first-party, and adopting one
is a Neovim config change deliberately excluded here. `<C-w>hjkl` still works inside
Neovim. Closing this is a small, separately-approved follow-up.

**Shared session view.** Per the 0.8.2 CHANGELOG: "The current persistence model is a
shared session view across attached clients. It is not yet full tmux-style per-client
independent navigation." Two attached clients move together.

**Version 0.8.2** is younger and moving faster than Zellij 0.45, and the CLI surface
is the contract this design depends on. The live gate above is the only thing that
detects churn.

## Exit criteria

Fixed window: **four weeks** of ordinary use across at least three projects.

Migrate if all of:

- **Restore:** ≥90% of server restarts come back with workspaces and agents usable
  without manual repair.
- **Correctness:** zero wrong-workspace events, zero husk incidents, zero manual
  repairs of a half-built workspace after the first week.
- **Keybindings:** the Alt scheme survives four weeks in Ghostty without remapping.
- **The actual question:** agent state was *noticed* rather than polled for — at
  least weekly, a Herdr status display prompted action on a blocked or finished agent
  before it would otherwise have been checked. If this fails, nothing else matters:
  it is the entire reason to move.

Abandon if restore is unreliable, if the CLI churns enough to need regular repair, or
if agent status proves to be a novelty that does not change behaviour.

## Rollback

1. `herdr integration uninstall claude` and `… codex`; revert the `.chezmoiignore`
   re-inclusions and any `modify_private_settings.json` change.
2. `herdr plugin unlink`.
3. Confirm no pane processes are worth keeping — **`herdr server stop` terminates
   every process in every pane** — then stop the server.
4. Delete `dot_config/herdr/`, `hdev`, both test scripts.
5. Drop the Brewfile line; `brew uninstall herdr`.
6. Remove leftover unmanaged state: `~/.config/herdr/` (logs, session state, plugin
   registry) and `~/.herdr/` if present.

Zellij, `dev`, `wt` and `wt-rm` are untouched throughout, so rollback is deletion
plus an uninstall, never a restoration.
