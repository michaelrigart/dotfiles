# Herdr trial alongside Zellij

**Status:** Approved

**Date:** 2026-08-27

**Amended:** 2026-08-27, twice, after peer review against the installed binary.
The second pass corrected the interrupted-build contradiction, the bootstrap and
construction sequences (which would not have run), the plugin's no-op failure mode,
and the integration contract.

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

Run Herdr **beside** Zellij as a reversible trial. `dev`, `wt`, `wt-rm` and
`~/.config/zellij` keep working unchanged for the duration.

This spec covers the trial. Whether to migrate is a separate decision, made against
the exit criteria below, and would get its own spec.

### The trial is not purely additive

An early draft claimed it touched only new files. Two exceptions are in scope:

- Agent integrations modify `~/.claude` and `~/.codex` (see "Integrations").
- `hdev` must actively refuse a class of directory to avoid weakening `wt-rm`
  (see "The worktree guard").

### Non-goals

- Migrating `dev`, `wt` or `wt-rm` to Herdr.
- Porting `wt-rm`'s session-shutdown preflight to also stop Herdr workspaces. The
  trial sidesteps the need by refusing to open workspaces in linked worktrees.
- Adopting Herdr's built-in worktree support. It overlaps `wt`.
- Automating the Claude/Codex relay. Herdr can (`agent prompt`, `agent wait`), but
  GLOBAL.md defines the relay as manual: "One relay, one turn." That is a workflow
  choice, not a capability gap.
- Neovim navigation integration. See "Known limitations".

## The worktree guard

`wt-rm` maintains a hard invariant at `dot_config/zsh/functions:781-789`: stop the
session **before** removing the worktree, because "a live process holding the
directory open is what leaves an empty `tmp/` husk behind." Its shutdown step knows
exactly one multiplexer:

```zsh
if zellij list-sessions -s 2>/dev/null | grep -Fqx -- "$name"; then
  zellij delete-session --force "$name" ...
```

A Herdr workspace on a `wt`-managed worktree is invisible to that check. `wt-rm`
would report clean shutdown, remove the checkout, and leave Herdr panes writing into
a deleted directory — reproducing the husk the preflight exists to prevent.

**`hdev` therefore refuses linked worktrees.** A repo whose `--git-common-dir`
resolves outside its own `.git` is a linked worktree; `hdev` says so and points at
`dev`. The plugin path inherits the guard, since both go through `layout.sh`.

Extending Herdr to worktrees requires porting the preflight first, which belongs to
a migration decision, not a trial.

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
   hdev curato ───▶ layout.sh <repo>       (build-or-focus, from a shell)
   dev.layout.apply ─▶ layout.sh --current (repair-in-place, from inside a workspace)
```

`layout.sh` owns the topology definition. Its two modes differ in *entry condition*,
not in what a finished workspace looks like.

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
2. `herdr workspace list`, then `herdr pane list` for candidates; match on pane `cwd`.
3. Exactly one **complete** match → `workspace focus`, exit 0.
4. Zero matches → build.
5. More than one match, or a label match whose path disagrees → **fail loudly**.
   Ambiguity is a bug, not something to guess through.

Labels remain human-readable display strings (`Netronix/curato`), matching what
`dev`'s picker prints. They are no longer load-bearing.

`_wt_session_name` is not reused: it exists for Zellij's session-name constraints
and its transformation is not invertible.

### Completeness, and recovering from an interrupted build

The previous amendment introduced a provisional `(building)` label but kept
path-based identity, which contradicted itself: a half-built workspace still has
panes with the right `cwd`, so step 2 matches it and step 3 focuses the husk — the
exact failure the provisional label was meant to prevent.

Completeness is therefore an explicit, checked property, not an inference:

- A workspace is **complete** when it carries the final label *and* its topology
  matches the definition — four tabs, named `agents`, `editor`, `runtime`, `git`.
- Anything else found at the target path is **provisional**: a build that died, or
  one racing in another shell.

`layout.sh` handles the three cases distinctly:

- **Complete** → focus, exit 0.
- **Provisional, not locked** → stale. Repair it by creating the missing tabs, then
  rename to the final label. Repair is preferred over close-and-rebuild because the
  workspace may contain a running agent the user cares about.
- **Provisional, lock held** → another build is in flight. Fail with a message
  saying so; do not race it.

Belt and braces: the build runs under a trap that closes the workspace it created if
it fails partway. The trap handles the common case (a command errors); stale
detection handles the case the trap cannot (SIGKILL, a lost server). Both are
needed — neither alone is sufficient.

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
workspace create --cwd <repo> --label "<label> (building)" --focus
  → ws = .result.workspace.workspace_id
    t1 = .result.tab.tab_id          (rename → "agents")
    p1 = .result.root_pane.pane_id

pane split --pane <p1> --direction right      → p2 = .result.pane.pane_id
pane run <p1> "claude"
pane run <p2> "codex"

tab create --workspace <ws> --label editor    → root pane pe  → pane run <pe> "nvim ."
tab create --workspace <ws> --label runtime   → root pane pr
pane split --pane <pr> --direction down                        (two shells, nothing auto-run)
tab create --workspace <ws> --label git       → root pane pg  → pane run <pg> "lazygit"

workspace rename <ws> "<label>"
tab focus <t1>
```

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
- No-op with an explicit message when the topology is already complete, rather than
  silently.

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

Three mechanics follow, all of which must be solved in chezmoi rather than left to
the installer:

- **`.chezmoiignore` is an allowlist for `.claude`.** Lines 57-66 ignore `.claude/*`
  and re-include named entries individually. Both hook scripts need explicit `!`
  re-inclusions or they will never deploy.
- **`settings.json` is already rewritten in place** by
  `dot_claude/modify_private_settings.json`, which owns the `hooks` block. Herdr's
  hook registration must merge into that script; leaving it to the installer means
  the two fight on every `chezmoi apply`.
- **`config.toml` is already managed** by `dot_codex/modify_private_config.toml`,
  which pins `features.*` via `setValueAtPath`. `features.hooks` must be pinned
  there. Because Herdr's uninstall deliberately leaves the flag set, rollback has to
  restore its prior value explicitly — nothing else will.

Sandbox note: `~/.claude/hooks` and `~/.claude/settings.json` are write-denied, so
installation and the subsequent `chezmoi apply` need an unsandboxed shell.

## Configuration

`~/.config/herdr/config.toml`, chezmoi-managed, carrying only deliberate divergences
from `herdr --default-config` so upstream default changes stay visible.

`onboarding = false` is pinned. Left unset, first run shows onboarding and may write
back to the config file — which chezmoi manages, so the write would show up as drift
and be reverted on the next apply.

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
  there is no `switch_tab_1`, and `tab.focus` takes a `tab_id`, not an index. Each
  key runs `tab-goto.sh <n>` via `[[keys.command]]`.
- **Scratch popup (`alt+p`).** `type = "popup"` — session-modal, does not disturb the
  tab layout. The on-demand `bin/rails console` slot, and a better fit than Zellij's
  floating layer, where `Alt+n` created *floating* panes while the layer was visible.

**`alt+k` (clear) is dropped.** An earlier draft specified a helper without
confirming a mechanism existed. There is none: the `pane.*` API has no clear or reset
method, only `send_text` / `send_keys`. Clearing could only inject control sequences
into whatever occupies the pane — corrupting state in Neovim, or sending input to a
live agent. Not worth it for a convenience binding.

`alt+s` (scroll mode) is also dropped — Herdr has no modal scroll; it uses the mouse
and `prefix+e` (`edit_scrollback`).

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
dot_config/herdr/executable_layout.sh      → topology definition, both modes
dot_config/herdr/executable_tab-goto.sh    → tab focus by index
dot_config/herdr/plugin/herdr-plugin.toml  → registers dev.layout.apply
dot_config/zsh/functions                   → += hdev()   (dev/wt/wt-rm untouched)
.chezmoiignore                             → re-include both agent hook scripts
dot_claude/modify_private_settings.json    → merge Herdr hook registration
dot_codex/modify_private_config.toml       → pin features.hooks
dot_claude/…, dot_codex/…                  → the two hook scripts
.scripts/test-hdev.sh                      → mocked test
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
- **The worktree guard.** A linked worktree is refused, with zero `herdr` calls.
- **Identity.** Path matching focuses the right workspace; two repos sharing a
  basename across orgs resolve to two workspaces; a label match whose pane `cwd`
  disagrees fails rather than focusing; two matches fail rather than guessing.
- **Idempotency.** A second `hdev` emits exactly one `workspace focus` and zero
  `create` calls.
- **Completeness.** A workspace at the right path with three tabs is treated as
  provisional, not focused as complete.
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
- Concurrent `hdev` invocations: one server, one workspace.
- Actual resulting topology: four tabs, correct pane counts and split directions.
- Duplicate-path handling and interrupted-build repair.
- Key-command context: what is actually injected.

A named session isolates the socket and runtime state. It does **not** isolate plugin
registration, which is global — so `plugin link` / `unlink` is exercised here with
that understood, and torn down explicitly.

### Live, uncontained — `.scripts/test-hdev-integrations.sh`

Integrations touch real `~/.claude` and `~/.codex`; no named session isolates them.
Run deliberately, unsandboxed, with the files backed up first:

- Install, and diff what actually changed against the table above.
- Cold restore across a full server restart: agents resumed by session reference.
- Uninstall, confirming `features.hooks` is left set and rollback restores it.

## Known limitations

**Neovim navigation is regressed.** Binding `ctrl+h/j/k/l` natively means Herdr
consumes them before Neovim, so inside `nvim` they move between Herdr panes rather
than splits. smart-splits.nvim cannot see across the boundary without a Herdr-aware
counterpart to vim-zellij-navigator. Community options exist (`herdr-splits.nvim`,
`herdr-nvim-nav`, ports of vim-tmux-navigator); none is first-party, and adopting one
is a Neovim config change deliberately excluded. `<C-w>hjkl` still works inside
Neovim. A small, separately-approved follow-up.

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

1. `herdr integration uninstall claude` and `… codex`. Restore `features.hooks` to
   its prior value in `dot_codex/modify_private_config.toml` — Herdr's uninstall
   deliberately will not. Revert the `modify_private_settings.json` merge and the
   `.chezmoiignore` re-inclusions.
2. `herdr plugin unlink <plugin-id>` — registration is global, so this is required
   even if the trial session is gone.
3. Confirm no pane processes are worth keeping — **`herdr server stop` terminates
   every process in every pane** — then stop the server.
4. Delete `dot_config/herdr/`, `hdev`, all three test scripts.
5. Drop the Brewfile line; `brew uninstall herdr`.
6. Remove leftover unmanaged state: `~/.config/herdr/` (logs, session state, plugin
   registry) and `~/.herdr/` if present.

Zellij, `dev`, `wt` and `wt-rm` are untouched throughout, so rollback is deletion
plus an uninstall, never a restoration.
