# Herdr UI refresh: Tokyo Night, live signals

**Status:** In progress
**Date:** 2026-11-05
**Branch:** `herdr-ui-refresh` (dotfiles: the pushed branch is the end, no MR)
**Sign-off:** Michael, 2026-11-05, after Codex's spec review approved it in round 3
(`xr-1793916843-3f988b5e`).

## Intent

Michael finds his herdr (TUI, 0.9.5) "too basic" next to setups he has seen, and wants it more
modern without losing function: every decorative element must carry information. The theme
stays Tokyo Night. He stays in the terminal herdr; the herdr.dev gallery's desktop-app looks
(rounded floating panels, translucency, animated creatures) are out of reach and out of scope.

Three mockups were compared in the brainstorm (A refined, B live signals, C cockpit). He chose
**B**: A's visual craft plus the signals he now goes and checks by hand. C was "too loud"; A
"not there yet". He expects to judge the result only by working with it, so the plan ends with a
live tuning pass rather than treating the first render as final.

## Goals

1. Exact Tokyo Night everywhere herdr paints, with visible structure (hairlines between the
   spaces list, the agents list and the panes).
2. Know which pane holds which agent. The agents tab holds several agent panes (Claude and
   Codex today, possibly more), so each pane's border names its agent.
3. See at a glance which agents are busy (motion), which need Michael (words, not only a glyph),
   whether an open MR's pipeline passed, and how much Claude and Codex usage is left.
4. Zero cost when nothing is happening: no polling loop while no agent works.

## Non-goals

- The herdr desktop app, or any look only it can draw.
- Anything from mockup C: project-type icons, client tags, ports, diff size, commit age,
  system stats (CPU, memory, battery, hostname), three-line agent cards.
- Changing tab names or putting icons in them: `tab-goto.sh` resolves tabs by exact label, so
  Alt-a/e/r would break.
- New keybindings, sidebar width changes, toast behaviour changes.

## Anti-goals (a failure even if it works)

- New code that reads login tokens (keychain, `~/.claude/.credentials.json`,
  `~/.codex/auth.json`) or calls vendor usage APIs. tagteam's existing, already-accepted usage
  fetch is reused instead (§5).
- A spinner that freezes on screen after its agent stops or its process dies.
- A badge that lies: a stale usage figure shown as current, a pipeline badge on the wrong MR.
- Anything that runs unsandboxed yet resolves a path a sandboxed command can write.

## Current state

- `dot_config/herdr/config.toml`: built-in `tokyo-night` theme plus six `[theme.custom]`
  overrides (`sidebar_bg`, `active_row_bg`, `selection_bg`, `accent`, `red`, `green`); two-row
  space entries (state, name, git status / phase badge, branch); agent rows (state, name / title;
  Codex one row); `status_indicators = "symbols"`; in-app toasts.
- `dot_config/herdr/executable_phase.sh` and the `dev.phase` plugin (`plugin-phase/`) report the
  `$active` / `$review` / `$merged` workspace tokens from `glab mr list`, cached with a TTL, kept
  fresh by the `be.netronix.herdr-phase-refresh` LaunchAgent (every 3 min) and plugin events.
- `layout.sh` builds each space's agents tab as Claude with a Codex split beside it.
- `dot_claude/executable_statusline.sh` shows tagteam's segment for the live Claude account
  (`<alias> · 5h —% · 7d 69%`), from `tagteam --no-color statusline`.
- Codex writes `rate_limits` on `token_count` events in
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (`primary` / `secondary`, each with
  `used_percent`, `window_minutes`, `resets_at`). On Michael's plan today only `primary` is set,
  with `window_minutes = 10080` (weekly).

## Design

### 1. Palette and chrome (config only)

Pin all 19 `[theme.custom]` tokens herdr 0.9.5 accepts (`accent`, `panel_bg`, `sidebar_bg`,
`active_row_bg`, `selection_bg`, `surface0`, `surface1`, `surface_dim`, `overlay0`, `overlay1`,
`text`, `subtext0`, `mauve`, `green`, `yellow`, `red`, `blue`, `teal`, `peach`) to Tokyo Night
(night) values, keeping the six existing ones. Starting values (builder's call to adjust each
against what herdr actually paints with it, which herdr does not document):

| Token | Value | Tokyo Night name |
|---|---|---|
| `panel_bg` | `reset` | Ghostty paints `#1a1b26` |
| `sidebar_bg` | `#16161e` | bg_dark (kept) |
| `active_row_bg` | `#292e42` | bg_highlight (kept) |
| `selection_bg` | `#283457` | bg_visual (kept) |
| `surface0` / `surface1` | `#292e42` / `#3b4261` | bg_highlight / fg_gutter |
| `surface_dim` | `#3b4261` | fg_gutter: the hairline; herdr's default equals the sidebar bg and hides it |
| `overlay0` / `overlay1` | `#565f89` / `#737aa2` | comment / dark5 |
| `text` / `subtext0` | `#c0caf5` / `#a9b1d6` | fg / fg_dark |
| `accent`, `blue` | `#7aa2f7` | blue (accent kept) |
| `mauve` | `#bb9af7` | magenta |
| `green`, `yellow`, `red` | `#9ece6a`, `#e0af68`, `#f7768e` | (green, red kept) |
| `teal`, `peach` | `#73daca`, `#ff9e64` | green1, orange |

Rule for adjustments: hairlines visible but quiet; nothing brighter than `text` except accents;
colour is reserved for state.

`[ui]`: `show_agent_labels_on_pane_borders = true`; `window_title = "{workspace} · {tab}"`.
Pane borders, outer borders and gaps stay at herdr's defaults (`auto`, on, on).

### 2. Tab bar right

```toml
tab_bar_right = [ <usage command, §5>, { type = "zoom" }, { type = "datetime", format = "%H:%M" } ]
tab_bar_right_separator = "  │  "
```

The zoom entry should show only while a pane is zoomed (Alt-z). If herdr renders it
unconditionally, the builder drops it and says so. Herdr strips ANSI from command output, so the
tab bar is one colour.

### 3. Agent rows: spinner and wording (new plugin)

Rows (both `[ui.sidebar.agents]` and the Codex `rows_by_agent` override):

```
<state_icon> <agent, mauve, bold> <$spin, yellow, bold> <state_text>
             <terminal_title_stripped, dim>        (Claude only; Codex keeps one row)
```

The spinner sits between the name and the state text, so the agent name never shifts when it
starts or stops; the state text moves only when its word changes anyway. `state_text` keeps
herdr's contextual style unless that style is uncoloured, in which case it is dim.

A new plugin, `dot_config/herdr/plugin-agent-rows/` (id `dev.agent-rows`, its own plugin so it
can be unlinked alone, like `dev.phase`), runs one long-lived worker. Herdr's manifest has no
supervised process, so `herdr plugin unlink` stops future starts only: the running worker and its
labels go at the next server start. That is accepted for a rollback path.

- **Spinner.** While at least one agent pane is `working`, report a `$spin` pane token (one-cell
  braille frame, about 7 fps) to each working pane with `ttl_ms` of about 1500, through the herdr
  socket (`pane.report_metadata`), not a CLI process per frame. Clear the token (`null`) when a
  pane leaves `working`, and for every shown pane on SIGTERM/SIGINT. If the worker dies, the TTL
  removes the frame on its own.
- **Event-driven.** Learn state from the socket's event subscription: `pane.agent_status_changed`,
  plus every event that changes which agent panes exist or what they are called
  (`pane.agent_detected`, `pane.closed`, `pane.moved`). A pane moved into another workspace gets a
  new pane ID (`herdr --skill`: "A pane moved into another workspace receives a new
  workspace-qualified pane ID"), so a move remaps the worker's state to the new ID, or resyncs,
  and re-reports that pane's label; frames only ever go to IDs the worker currently knows to be
  live. It resyncs from `session.snapshot` at start and on `events_lost`. A `pane_agent_detected`
  that carries a release (`agent` null and/or `released`) removes the pane's state. With no
  working pane it does no periodic work at all.
- **Wording.** Report a state label for every agent pane so `blocked` reads `needs you`; other
  states keep herdr's labels. Labels carry no TTL, are reported under their own source
  (`dev.agent-rows.labels`, the frames use `dev.agent-rows`), and are re-reported at start and when
  an agent pane appears (pane metadata does not survive a server restart).
- **Lifecycle.** Started by a `[[startup]]` hook, which herdr runs once per server start; the
  hook detaches the worker and returns. One instance (lock in `HERDR_PLUGIN_STATE_DIR`). A plain
  close of the event subscription means the server shut down: the worker clears what it can and
  exits at once, and the next server start launches a new one with the code then on disk (a worker
  that reconnected would attach to the restarted server and keep the old code). Only the very first
  connect retries, for about 10 s. Bounded log in the state dir.
- Works for any number of agent panes and any agent kind.

### 4. Pipeline on the MR badge (`phase.sh`)

For a space whose phase comes from an open MR (`review`, or `active` with the draft icon), add the
head pipeline status after the phase badge on row 2:

| GitLab status | Token | Glyph | Colour |
|---|---|---|---|
| `success` | `$ci_ok` | U+EAB2 cod-check | `#9ece6a` |
| `failed` | `$ci_fail` | U+EA76 cod-close | `#f7768e` |
| `running`, `pending`, `created`, `preparing`, `waiting_for_resource`, `scheduled` | `$ci_run` | U+EA77 cod-sync | `#e0af68` |
| anything else, no pipeline, merged or no MR | none | | |

Exactly one of the three is set, the others cleared, in the same report as the phase tokens (the
existing one-token-per-colour pattern). Row 2 order: phase tokens, ci tokens, `branch`.

The status comes from GitLab via `glab`. The list endpoint does not carry `head_pipeline`
(measured on VM.Portal, 2026-11-05), so it costs one call per open MR, e.g.
`glab api projects/<slug>/merge_requests/<iid>` → `.head_pipeline.status`.

Measured on VM.Portal, whose MR pipelines end in `when: manual, allow_failure: true` build jobs:
those pipelines settle at `success` (detailed status "Warning"), so they get the green badge, which
is the truth for "quality passed, builds not started"; of its last 23 MR pipelines, 20 were
`success`, 1 `failed`, 2 `canceled`. Its `workflow:` rules skip pipelines for Draft MRs, so a draft
there has no pipeline and no badge; the draft rule costs nothing where it does not apply.

The status is cached in the existing cache directory with the existing TTL, keyed by repository
and MR iid (the slug's `/` encoded as `%2F`, so no two repositories share a file), so a branch
reused after a merge never shows the old MR's pipeline. A failed lookup keeps showing a cached
status only while that file is under 30 minutes old; after that the pipeline tokens are cleared.
Every hardening rule `phase.sh` already follows applies unchanged (no fetch, pinned `PATH`, no
config-driven git execution, never reading back reported state), and it now starts from `/`, since
`glab` reads the current directory's repository.

### 5. Usage in the tab bar

This section adds no network calls of its own and reads no login tokens. That describes
`usage.sh`: `tagteam status` may itself fetch usage and refresh the live account's token on
demand, which is tagteam's existing, accepted behaviour. For that reason `usage.sh` ends a
`tagteam` that outlives its timeout with SIGTERM, never SIGKILL (tagteam's handler releases its
locks and keeps a rotated refresh token), and does not wait for it.

- **Claude: from tagteam** (Michael's ruling, 2026-11-05). Michael switches between three Claude
  accounts, each with a short tagteam alias, and his Claude status line already shows tagteam's
  figure for the live account. The tab bar reads the same source, so the two never disagree and
  an account switch shows at once: `tagteam status --json` → `.active` (the contract is
  tagteam's spec `2026-09-26-tagteam-core-cli-design.md` §13.2, in `~/Code/tagteam`):
  - `active: null` → no Claude figure.
  - `usage` non-null (decision-grade) → its `fiveHour` / `sevenDay` windows (each `{pct,
    resetsAt?}`, and either may be null: on 2026-11-05 `fiveHour` was null), aged by
    `usageAgeSeconds`.
  - `usage` null and `lastGoodUsage` non-null → those windows, aged by `lastGoodAgeSeconds`, and
    always carrying the age mark whatever the age, because tagteam itself no longer treats the
    reading as current.
  - both null (any `usageStatus` other than `ok`, e.g. `token_expired`) → `—`.

  The figure is labelled with `.active.alias` (`<alias> 38% 5h`), falling back to `claude`.
  tagteam is Claude-only (`-p codex` is an unknown provider). It needs the
  sandbox off to open its store, which the tab bar command has (it runs on the herdr server). The
  cost of one `tagteam status` a minute is measured while building; if it is too slow for
  `timeout_seconds`, the builder reports rather than caching around it.
- **Codex.** The newest valid usage observation, by the event's own timestamp, not the file's.
  Candidates are the rollout files under both `~/.codex/sessions/**/rollout-*.jsonl` and
  `~/.codex/archived_sessions/`, modified within the last 7 days (the longest window; an older
  reading has reset anyway). Walk them newest mtime first. In each, the last `token_count` event
  with a non-null `rate_limits` is found by reading backwards from the end until one turns up or
  the file is exhausted, so no fixed tail size can hide it. Keep the newest event timestamp `T`
  seen so far, and stop as soon as the next file's mtime is older than `T`: an event is written
  no later than its file's mtime, so no remaining file can hold a newer reading. There is no
  fixed candidate count. A new thread writes its opening records before its first `token_count`,
  and any non-usage append makes a file newest by mtime without making its reading newest; both
  only lengthen the walk. `window_minutes` 300 labels `5h`, 10080 labels `wk`; other values get a generic
  label. Both directories, because Codex moves finished threads to `archived_sessions/`: on
  2026-11-04 an archived rollout was about 7 hours newer than the newest file under `sessions/`.
- **Script** `dot_config/herdr/executable_usage.sh`, a `command` entry with
  `interval_seconds = 60` and a short `timeout_seconds`, prints one plain line, e.g.
  `<alias> 38% 5h · codex 81% wk ⚠`:
  - **% used**, matching Claude's `/usage` and Codex's `/status`.
  - Per agent, the window with the highest used percentage among windows whose `resets_at` is
    still in the future. If every known window has reset, `—`.
  - `⚠` after any figure at 80% or more (colour is not available in the tab bar).
  - **Age.** Within a window usage only grows until `resets_at`, so an old figure is a floor, not
    a lie, as long as it says it is old: a figure whose source is more than 30 minutes old carries
    its age (`codex 81% wk ·3h`). For Claude the age is tagteam's `usageAgeSeconds` (or
    `lastGoodAgeSeconds`, always marked, above); for Codex, the rollout event's timestamp. Usage from claude.ai, the phone or another Mac never reaches
    these sources; the age mark is what keeps that honest.
  - An agent with no data source at all is left out; with neither, the line is empty.
  - Inputs are parsed as data (numbers and timestamps only); malformed input yields `—` or
    nothing, never an error message in the tab bar.

### Constraints

- Every new or changed script runs unsandboxed (herdr hooks, plugin, tab bar command, LaunchAgent)
  and follows spec 2026-10-16 (sandbox write boundary): absolute shebang (`/bin/bash`, `/bin/zsh`,
  `/usr/bin/python3 -I`), pinned `PATH` (which resolves `tagteam`, `glab` and `jq` from
  `/opt/homebrew/bin`), stdlib only for Python, nothing read or executed from a path a sandboxed
  command can write. `~/.codex` and `~/.config/herdr` are outside the sandbox's write set; what
  the scripts read there is parsed as data only.
- Herdr-managed files (`herdr-agent-state.sh` in `dot_claude/hooks/` and `dot_codex/`) are not
  edited; herdr's integration installer overwrites them.
- Socket limits: at most 16 token keys per report, 32 per pane or workspace.
- Inside a herdr pane, any herdr CLI call threads `--session` (AGENTS.md); the socket path comes
  from `HERDR_SOCKET_PATH`.
- `herdr config check` passes on the rendered config with no diagnostics.

## Testing

One suite per script under test, in `tests/`:

- `herdr-phase.test.sh` (extended): each GitLab status maps to the right token, one-of reporting,
  cache keyed by MR, no badge for merged or MR-less spaces, glab failures leave the phase intact.
- `herdr-usage.test.sh` (new), with `tagteam` stubbed on `PATH`: window selection, reset windows
  to `—`, the 80% marker, the age mark, the alias label; tagteam's real shapes (`active: null`,
  `usage` with a null `fiveHour`, `usage: null` with `lastGoodUsage`, both null with a non-`ok`
  `usageStatus`), tagteam missing or failing; for Codex, the newest observation by event
  timestamp across both directories, more newer files without a `token_count` than any small
  batch, a file whose last `token_count` sits far before its end, the mtime stopping rule (an
  older file is not read once a newer reading is in hand), the 7-day horizon, malformed lines;
  no network.
- `herdr-agent-rows.test.sh` (new), against a fake herdr socket: no reports while idle, frames
  only for working panes with a TTL, clear on state change and on SIGTERM, single instance,
  resync on `events_lost`, `blocked` label reported for new agent panes, a working pane moved to
  another workspace keeps spinning under its new ID and nothing is sent to the old one, exit when
  the socket closes.
- A check that `herdr config check` accepts the source config, if it can run without a server.

Before the pre-merge review: `./tests/run.sh` and the heavy trio, per AGENTS.md.

## Activation and live tuning

Tuning happens after the merge (Michael's ruling, 2026-11-05). He merges, runs `chezmoi apply`
as usual, links the plugin once (`herdr plugin link ~/.config/herdr/plugin-agent-rows`) and
restarts the herdr server so the plugin starts (`herdr server reload-config` covers config-only
changes). Then a live tuning pass (`live-feedback`): he works with it while colours, wording and
spacing are adjusted. The tuning changes go on a follow-up branch, which he asked for, sized as a
small change (cold diff review plus Codex's pre-merge review), and he merges it.

## Calls made in the brainstorm (Claude's, open to Michael)

- Usage shows % used, the binding window per agent, `—` after a reset, `⚠` at 80%.
- Codex usage from its rollout logs (tagteam has no Codex provider).
- Draft MRs get the pipeline badge too.
- Spinner placed after the agent name (the mockup showed it before), so names never shift.
- Only `blocked` gets new wording (`needs you`).
- Clock as `%H:%M`.
- `panel_bg = "reset"` so Ghostty owns the background.
- Usage older than 30 minutes carries its age.
- Unlinking the plugin takes effect at the next server start.

## Dropped

- Greying the branch of merged spaces (shown in the mockup): a sidebar token has one fixed style,
  so it would mean replacing herdr's live `branch` with a phase.sh copy up to 3 minutes stale.
- Auto-named tabs, from the gallery: conflicts with label-based tab jumps.
- Third-party quota plugins (`herdr-plugin-agent-quota`): they read OAuth tokens and call vendor
  APIs.
- Caching Claude Code's status-line `rate_limits` to a file: the last session to draw wins, so
  after an account switch it shows the old account and disagrees with tagteam's figure.

## Left to the builder

Exact palette mapping after seeing herdr render it; glyph spacing and the usage line's exact
format within §5; the socket method and parameter names for event subscription and state labels
(`herdr --skill`, the socket-api docs); the worker's frame interval and TTL within the stated
ranges; the `glab` call used for pipeline status.
