# Herdr trial alongside Zellij

**Status:** Approved

**Date:** 2026-08-27

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

Run Herdr **beside** Zellij as a reversible trial. Nothing in the Zellij path is
modified, removed, or deprecated. `dev`, `wt`, `wt-rm` and `~/.config/zellij` keep
working unchanged for the duration, and reverting the trial means deleting files
that nothing else references.

This spec covers the trial. Whether to migrate is a separate decision, made against
the exit criteria below, and would get its own spec.

### Non-goals

- Migrating `dev`, `wt` or `wt-rm` to Herdr.
- Porting `wt-rm`'s session-shutdown preflight. That check is the only thing standing
  between a dirty worktree and processes writing into a deleted directory; it is
  built on `zellij list-sessions` semantics that were reasoned about carefully, and
  it does not port for free. Out of scope until the trial succeeds.
- Adopting Herdr's built-in worktree support (`[worktrees]`, `new_worktree`,
  `worktree.created`). It overlaps `wt` and would entangle the trial with the
  worktree lifecycle.
- Neovim navigation integration. See "Known limitations".
- Automating the Claude/Codex relay. Herdr can do it (`agent prompt`, `agent wait
  --until blocked`), but GLOBAL.md defines the relay as manual and deliberate:
  "One relay, one turn." That constraint is a workflow choice, not a capability gap,
  and the trial does not revisit it.

## Model mapping

Herdr's hierarchy is server → sessions → workspaces → tabs → panes. Zellij's is
sessions → tabs → panes. The trial maps a project onto a **workspace**, not a
session:

| Zellij today | Herdr in the trial |
|---|---|
| One session per repo (`netronix--curato`) | One workspace per repo, all in the default session |
| `zellij attach` / `switch-session` | `herdr` to attach the server; `workspace focus` to switch project |
| Four tabs from `dev.kdl` | Four tabs built by `layout.sh` |
| Status bar, per session | Sidebar, spanning every workspace |

The single-server choice is the point of the exercise. Session-per-repo would mirror
today's muscle memory more closely, but the sidebar would then only ever show one
project's agents — discarding the cross-project visibility that motivates the trial.

### Workspace labels carry identity

`WorkspaceInfo` exposes `workspace_id`, `label`, `number`, `focused`, `agent_status`
and `worktree` — but **not** the workspace's working directory. There is therefore
no way to ask "is there already a workspace for this repo?" by path. The label is
the only durable handle, so it must encode identity, not just read nicely.

A bare basename will not do: `Netronix/curato` and `ViuMore/curato` would collide,
and `hdev` would focus the wrong project — silently, since both look right in the
sidebar.

The label is therefore derived deterministically from the repo path:

| Repo | Label |
|---|---|
| `~/Code/Netronix/curato` | `Netronix/curato` |
| `~/Code/ViuMore/curato` | `ViuMore/curato` |
| `~/.local/share/chezmoi` | `.local/share/chezmoi` |
| `/opt/src/thing` | `/opt/src/thing` |

Under `~/Code`, the label is the path relative to it; elsewhere under `$HOME`,
relative to `$HOME`; otherwise absolute. Distinct paths always produce distinct
labels, and one path always produces the same label — which makes lookup-by-label
exactly equivalent to lookup-by-path, the property idempotency depends on.

This also happens to be what `dev`'s picker already prints (`${pool[@]#$code/}`), so
the sidebar and the picker agree on what a project is called.

`_wt_session_name` is **not** reused. It exists to satisfy Zellij's session-name
constraints — lowercasing, `/` → `--`, hashing on collision or names over 60
characters — none of which apply to a display label, and its transformation is
deliberately not invertible. `hdev` uses it nowhere.

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

### `layout.sh <repo-path>`

Idempotent by contract. Given a repo path:

1. Derive the label from the repo path (see "Workspace labels carry identity").
2. `herdr workspace list`; if a workspace with that label exists, `workspace focus`
   it and exit 0. **Do not rebuild.**
3. Otherwise create the workspace and its four tabs.

Step 2 is what makes `hdev curato` safe to run repeatedly — the same property
`dev` gets from checking `zellij list-sessions` first.

IDs are parsed from JSON responses, never predicted. Herdr's public IDs (`w1`,
`w1:t1`, `w1:p1`) are opaque stable handles, and its own agent skill file is explicit
that closed IDs are not reused and order must not be inferred. `workspace create`
returns `.result.workspace`, `.result.tab` and `.result.root_pane`; `tab create`
returns `.result.tab` and `.result.root_pane`; `pane split` returns `.result.pane`.

The construction sequence:

```
workspace create --cwd <repo> --label <name> --focus
  → w1, tab w1:t1 (rename → "agents"), root pane w1:p1
pane split --target-pane-id w1:p1 --direction right   → w1:p2
pane run w1:p1 "claude"
pane run w1:p2 "codex"

tab create --label editor   → pane run "nvim ."
tab create --label runtime  → pane split --direction down    (two shells, nothing auto-run)
tab create --label git      → pane run "lazygit"

tab focus <agents tab id>
```

**`pane run`, not `agent start`.** Herdr offers `agent start <name> --kind claude`,
which validates agent identity and returns a named handle usable by `agent prompt`
and `agent wait`. It is rejected here for two reasons. It blocks until Herdr detects
the agent is ready for interactive input, with a 30-second default timeout — two of
those serialize every workspace creation behind two agent boot sequences. And it
changes the exit semantics: `dev.kdl` runs `zsh -c "claude; exec zsh"` so that
quitting the tool leaves a live prompt to relaunch from. `pane run` in a shell pane
preserves that exactly.

Agent *detection* is unaffected by this choice. Herdr identifies agents from
foreground processes and screen manifests regardless of how they were launched, so
the sidebar populates either way. What is given up is the scripting handle — which
the trial does not use, because relay automation is a non-goal.

### `hdev` (zsh function)

Repo resolution only, then delegation. The resolution cascade is `dev`'s, unchanged:

- `.` or an existing directory → the git repo containing it
- a path relative to `~/Code`
- exact basename → case-insensitive substring → `fzf` picker

`dev`'s session-name lookup branch is dropped; workspace labels are plain basenames,
so there is nothing to round-trip.

Having resolved a repo, `hdev`:

- **outside Herdr** — starts or attaches the client (`herdr`), then applies the layout
- **inside Herdr** (`HERDR_ENV=1`) — applies the layout directly

`hdev` is added to `dot_config/zsh/functions` alongside `dev`. `dev` is not modified.

### Plugin

`~/.config/herdr/plugin/herdr-plugin.toml` registers `layout.sh` as action
`dev.layout.apply`, making the same layout reachable from Herdr's own menu and
bindable to a key — without a shell, and without a second copy of the layout logic.
Registered with `herdr plugin link` (which, unlike `plugin install`, runs no build
step).

The manifest declares no `[[startup]]` hook. Herdr already restores workspaces and
resumes agents on restart; a startup hook that re-applied layouts would fight it.

## Configuration

`~/.config/herdr/config.toml`, chezmoi-managed. Herdr ships a fully commented
default (`herdr --default-config`); the tracked file carries only deliberate
divergences, so a Herdr upgrade that changes a default is visible rather than
silently pinned.

### Theme

`tokyo-night` is built in — confirmed present in the shipped default config
alongside catppuccin, terminal, dracula, nord, gruvbox, one-dark, solarized,
kanagawa, rose-pine and vesper. No `[theme.custom]` overrides. This matches Ghostty
(`theme = "tokyo-night"`), Zellij, and everything else in the setup.

### Keybindings

The Zellij scheme is prefix-less `Alt+<letter>` with `Ctrl+h/j/k/l` for navigation,
chosen so that tab jumps are mnemonic rather than numeric — digits require Shift on
AZERTY. That intent carries over.

`ctrl+b` remains bound as prefix, as an escape hatch. Zellij needed
`clear-defaults=true` because its stock `Ctrl` leaders shadowed shell readline and
Neovim keys; Herdr's prefix model does not have that problem, so nothing needs
clearing.

Direct mappings, all native actions:

| Key | Herdr action | Was |
|---|---|---|
| `alt+z` | `zoom` | `ToggleFocusFullscreen` |
| `alt+n` | `split_vertical` | `NewPane` |
| `alt+t` | `new_tab` | `NewTab` |
| `alt+w` | `detach` | `Detach` |
| `alt+b` | `toggle_sidebar` | *(new — no Zellij equivalent)* |
| `ctrl+h/j/k/l` | `focus_pane_left/down/up/right` | vim-zellij-navigator plugin |

Three bindings have **no native equivalent** and are implemented as
`[[keys.command]]` entries:

1. **Tab jumps (`alt+a`/`e`/`r`/`g`).** `switch_tab` is a range-only binding
   (`"prefix+1..9"`); there is no `switch_tab_1`. The socket method `tab.focus` takes
   a `tab_id`, not an index. So each key runs `tab-goto.sh <n>`, which lists the
   current workspace's tabs and focuses the nth.
2. **Clear (`alt+k`).** Herdr has no clear action at all. `clear-pane.sh` clears the
   pane's screen and scrollback. Ghostty already maps `cmd+k` → `text:\x1bk`, which
   is `alt+k`, so the existing muscle memory reaches it.
3. **Scratch popup (`alt+p`).** `type = "popup"` opens a session-modal terminal
   without disturbing the tab layout — the on-demand `bin/rails console` slot. This
   is a better fit than Zellij's floating layer, which had the wart that `Alt+n`
   created *floating* panes while the layer was visible.

`alt+s` (scroll mode) is dropped. Herdr has no modal scroll; it scrolls with the
mouse and with `prefix+e` (`edit_scrollback`).

### Alt-key viability

Herdr's own config warns that `alt+…` bindings "may depend on your terminal/tmux
setup", and that the most reliable direct bindings are `ctrl+letter` and function
keys. Ghostty is configured `macos-option-as-alt = left`, so the scheme is viable —
via the **left** Option key only. Right Option will not produce Alt.

This is the single most likely thing to fail, and it fails visibly and immediately.
It is the first thing the trial should test.

## Artifacts

All chezmoi source; all new except the already-committed Brewfile line.

```
dot_config/herdr/config.toml               → ~/.config/herdr/config.toml
dot_config/herdr/executable_layout.sh      → the single layout definition
dot_config/herdr/executable_tab-goto.sh    → tab focus by index
dot_config/herdr/executable_clear-pane.sh  → alt+k
dot_config/herdr/plugin/herdr-plugin.toml  → registers dev.layout.apply
dot_config/zsh/functions                   → += hdev()   (dev/wt/wt-rm untouched)
.scripts/test-hdev.sh                      → mocked test
```

`brew "herdr"` landed in `dot_config/homebrew/Brewfile.tmpl` in commit `01bd008`.

Deliberately absent: `brew services start herdr`. A trial does not earn a login
daemon. The server exists once `hdev` or `herdr` is run and ends with
`herdr server stop`.

## Testing

`.scripts/test-hdev.sh`, following `test-wt-functions.sh`: stub `herdr` on `PATH`,
log every invocation, assert on the log. Real git repos, stubbed multiplexer — the
same split that existing suite uses, for the same reason.

What must be asserted:

- **Resolution.** Each branch of the cascade — `.`, a path under `~/Code`, exact
  basename, case-insensitive substring, the `fzf` fallback — resolves to the repo it
  should, and a non-repo argument fails without calling `herdr` at all.
- **Idempotency.** A second `hdev` on a repo whose workspace exists emits exactly one
  `workspace focus` and zero `workspace create` / `tab create` / `pane split` calls.
  This is the regression that matters most: getting it wrong silently duplicates
  workspaces, and it will not be noticed until the sidebar is cluttered.
- **Label identity.** Two repos sharing a basename in different orgs produce two
  distinct labels and two distinct workspaces. `hdev` on the second must not focus
  the first. This is the failure the label scheme exists to prevent, so it gets a
  test rather than a comment.
- **Ordering.** Panes are split before commands run in them; the workspace exists
  before its tabs. Assert on ordering, not just presence.
- **ID handling.** Given stub JSON with non-sequential IDs, the produced calls carry
  the IDs from the responses and not `w1`/`w1:p1` guesses. A stub returning `w7:p3`
  must produce `pane run w7:p3 …`.
- **Failure.** A stub failing at `tab create` reports the failure and does not leave a
  half-built workspace silently presented as success. `dev` learned this the hard
  way: every step of the old detached-session shape returned 0 while the layout
  failed, and exit status was no guard.

Assertions pin exact values. A test that cannot go red is not coverage.

## Known limitations

**Neovim navigation is regressed for the duration.** Binding `ctrl+h/j/k/l` natively
in Herdr means Herdr consumes them before Neovim sees them, so inside `nvim` those
keys move between Herdr panes instead of Neovim splits. smart-splits.nvim cannot see
across the boundary because there is no Herdr-aware counterpart to
vim-zellij-navigator installed.

Community plugins exist (`herdr-splits.nvim`, `herdr-nvim-nav`, and several ports of
vim-tmux-navigator) but none is first-party, and picking one is a Neovim config
change — excluded from a trial that promised the current system stays untouched.
Within Neovim, `<C-w>hjkl` still moves between splits. If the friction proves
intolerable before the trial concludes, adding a nav plugin is a small,
separately-approved follow-up.

**`[[keys.command]]` context injection is unverified.** Herdr documents injecting
`HERDR_WORKSPACE_ID` / `HERDR_TAB_ID` / `HERDR_PANE_ID` into managed panes and plugin
commands. Whether a `type = "shell"` keybinding command receives the same context is
not documented. `tab-goto.sh` and `clear-pane.sh` must therefore fall back to
resolving the focused workspace via `herdr workspace list` when the variables are
absent, rather than assuming them.

**Version 0.8.2.** Younger and moving faster than Zellij 0.45. The CLI surface is the
contract this design depends on, and it may shift under a `brew upgrade`. The mocked
test suite pins the expected call shapes, so a breaking change surfaces as a test
failure rather than a broken `hdev` on a Monday morning.

## Exit criteria

The trial answers one question: does agent-state visibility change how the work
actually goes, enough to justify porting `wt-rm`'s safety preflight?

Migrate if, after real use across multiple projects:

- The sidebar is genuinely consulted — Codex finishing is *noticed* rather than
  polled for.
- Restore-with-agents works well enough that `dev`'s rebuild-from-scratch is no
  longer the more reliable option.
- The Alt keybinding scheme is stable in Ghostty.
- The Neovim navigation gap is closable with a plugin that inspires confidence.

Abandon if agent status turns out to be a novelty that does not change behaviour,
if restore is unreliable, or if the CLI churns enough that the layout script needs
regular repair.

Reverting costs: delete `dot_config/herdr/`, delete `hdev` and its test, drop the
Brewfile line, `herdr server stop`, `brew uninstall herdr`. Nothing else references
any of it.
