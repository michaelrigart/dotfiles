# Herdr UI Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented on `herdr-ui-refresh` (no MR). Completed 2026-11-06: do not run this plan again; its execution notes bind that run only.
**Goal:** Direction B of the herdr refresh: pinned Tokyo Night palette and chrome, a spinner and
"needs you" wording on agent rows, pipeline status on MR badges, and Claude/Codex usage in the tab
bar.

**Architecture:** Four disjoint pieces. `config.toml` carries every visual setting and names the
tokens the other three report. `phase.sh` gains a pipeline lookup and three `$ci_*` workspace
tokens. A new tab bar command, `usage.sh`, prints one plain line from tagteam and Codex's rollout
logs. A new herdr plugin, `dev.agent-rows`, runs one event-driven worker that reports `$spin`
frames and state labels to agent panes over the herdr socket.

**Tech Stack:** herdr 0.9.5 (TUI), bash 3.2 (`/bin/bash`), `/usr/bin/python3 -I` (stdlib only),
`glab`, `tagteam`, chezmoi source layout.

**Spec:** `docs/superpowers/specs/2026-11-05-herdr-ui-refresh-design.md` (Approved, `af2a3d5`).
Read it before any task; section numbers below (§1–§5) are the spec's.

## Global Constraints

- Every script added or changed runs unsandboxed and follows
  `docs/superpowers/specs/2026-10-16-sandbox-write-boundary-design.md`: absolute shebang
  (`/bin/bash`, `/bin/zsh`, `/usr/bin/python3 -I`), `PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}`,
  stdlib-only Python, nothing read or executed from a path a sandboxed command can write.
- The repository is public: no account aliases, emails or tokens in tracked files or fixtures.
- Never edit `dot_claude/hooks/executable_herdr-agent-state.sh` or `dot_codex/executable_herdr-agent-state.sh`
  (herdr-managed).
- Tab labels stay `agents`, `editor`, `runtime` (`tab-goto.sh` matches them exactly).
- Socket limits: at most 16 token keys per report, 32 per pane or workspace; token names match
  `^[A-Za-z0-9_-]{1,32}$`.
- `/usr/bin/python3` is 3.9.6: no `match`, no `X | None` evaluated at runtime (use
  `from __future__ import annotations` or `Optional`), no `tomllib`.
- Nerd Font glyphs are written as `printf` byte escapes (bash) or `\u` escapes (Python), never as
  literals.
- One suite per script under test in `tests/`, mode 755, correct shebang, executed (never prefixed
  with an interpreter); a suite whose subject is missing exits 2.
- Commit messages: imperative mood, no agent attribution.

### Measured facts the tasks rely on (2026-11-05)

- The herdr socket answers **one request per connection** and then closes it.
- `events.subscribe` holds its connection open: the server answers
  `{"id":…,"result":{"type":"subscription_started"}}` and then streams events, one JSON object per
  line; a second request on that connection closes it. Changing the subscription set therefore
  means opening a new subscription connection.
- `pane.agent_status_changed` subscriptions **require `pane_id`**: one entry per pane.
- Lifecycle event lines carry `data.type` in underscore form (`pane_moved`, `pane_closed`,
  `pane_agent_detected`, `pane_created`); the subscription request uses the dotted form
  (`pane.moved`). Normalise an incoming event's kind as `(data.get("type") or line["event"]).replace(".", "_")`.
- `pane_moved` data: `previous_pane_id`, `pane` (PaneInfo, new `pane_id`). `pane_closed`:
  `pane_id`. `pane_agent_detected`: `pane_id`, `agent`; it also announces a release, as `agent:
  null` and/or `released: true` with a `final_status`. `pane_agent_status_changed`: `pane_id`,
  `agent_status` (`idle|working|blocked|done|unknown`).
- `session.snapshot` → `result.snapshot.panes[]`, each with `pane_id`, `agent` (null for non-agent
  panes), `agent_status`, `state_labels`, `tokens`. The live session had 39 agent panes.
- `pane.report_metadata` params: `pane_id`, `source`, optional `tokens` (string or null per key),
  `state_labels` (object), `ttl_ms` (1–86400000).
- The sandbox denies binding or connecting unix sockets, so suites drive socket code through an
  injected transport or `socket.socketpair()` (the `xreview-rpc` suite's pattern).
- `HERDR_CONFIG_PATH=<file> herdr config check` validates any config file without a server; it
  prints `config: ok` and exits 0, or `config: issues found` and exits 1 (unknown keys included).
- GitLab's MR list carries no `head_pipeline`; `glab api projects/<url-encoded slug>/merge_requests/<iid>`
  does, as `.head_pipeline.status`.
- `tagteam status --json` (sandbox off): `.active` is null or an object with `alias`, `usage`
  (null, or `{fiveHour, sevenDay}`, each null or `{pct, resetsAt}` with `resetsAt` ISO 8601),
  `usageAgeSeconds`, `lastGoodUsage`, `lastGoodAgeSeconds`, `usageStatus`. Contract:
  `~/Code/tagteam/docs/superpowers/specs/2026-09-26-tagteam-core-cli-design.md` §13.2.
- A Codex rollout line: `{"timestamp": "<ISO 8601>", "type": "event_msg", "payload": {"type":
  "token_count", "rate_limits": {"primary": {"used_percent": 82.0, "window_minutes": 10080,
  "resets_at": <epoch s>}, "secondary": null, …}}}`. Rollouts run to ~1 MB.

## Review Focus

1. **Many agent panes.** The live session has 39; the worker must subscribe to all of them in one
   request and keep spinning only the working ones. Pinned in Task 4 (`many panes` case).
2. **Server restart under a running worker.** The subscription hits EOF, whether or not a
   reconnect would succeed; the worker must clear what it can, release its lock and exit, so the
   next server start's hook can launch a fresh one. Pinned in Task 4 (`server gone` case).
3. **A hung tagteam.** The tab bar entry has a timeout; a stuck `tagteam` must not take the Codex
   figure down with it. Pinned in Task 3 (`tagteam hangs` case).
4. **A large rollout.** A ~1 MB file whose last `token_count` is near its start must be read in
   bounded backward chunks, not loaded whole. Pinned in Task 3 (`far token_count` case).
5. **A width-hungry tab bar.** The usage line must stay short (≤ 40 cells with both agents, ⚠
   and age marks) so the tab bar does not crowd out tab names at a 98-column pane. Pinned in
   Task 3 (`width` case).

---

### Task 1: Palette, chrome and row layout (`config.toml`)

**Depends on:** none

**Files:**
- Modify: `dot_config/herdr/config.toml` (`[theme.custom]`, `[ui]`, `[ui.sidebar.spaces]`,
  `[ui.sidebar.agents]`, `[ui.sidebar.agents.rows_by_agent]`)
- Create: `tests/herdr-config.test.sh`

**Interfaces:**
- Produces (names the other tasks report into):
  - workspace tokens `$ci_ok`, `$ci_fail`, `$ci_run` (Task 2) on space row 2, between the phase
    tokens and `branch`, styled `fg = "#9ece6a"`, `"#f7768e"`, `"#e0af68"`, all `bold = true`;
  - pane token `$spin` (Task 4) on agent row 1, after `agent`, `fg = "#e0af68", bold = true`;
  - tab bar command `~/.config/herdr/usage.sh` (Task 3), `interval_seconds = 60`,
    `timeout_seconds = 5`.

- [ ] **Step 1: Write the failing suite `tests/herdr-config.test.sh`** (bash, `#!/usr/bin/env bash`,
  prose `PASS:`/`FAIL:` output like `herdr-phase.test.sh`, exit status = failure count). It exits 2
  when `herdr` is not on `PATH` or the config is missing. Cases:
  - `HERDR_CONFIG_PATH="$SRC/dot_config/herdr/config.toml" herdr config check` exits 0 and prints
    `config: ok`;
  - each of the 19 tokens (`accent panel_bg sidebar_bg active_row_bg selection_bg surface0
    surface1 surface_dim overlay0 overlay1 text subtext0 mauve green yellow red blue teal peach`)
    is set under `[theme.custom]` (section-scoped `awk`/`grep` on the exact lines this task
    writes; there is no TOML parser in the stdlib of `/usr/bin/python3`);
  - `[theme.custom]` values equal the spec §1 table (`panel_bg = "reset"`, `surface_dim =
    "#3b4261"`, `overlay1 = "#737aa2"`, `subtext0 = "#a9b1d6"`, `mauve = "#bb9af7"`, …);
  - `[ui]` has `show_agent_labels_on_pane_borders = true`, `window_title = "{workspace} · {tab}"`,
    `tab_bar_right_separator = "  │  "`, and `tab_bar_right` lists, in order, a `command` entry
    whose command is `~/.config/herdr/usage.sh`, `{ type = "zoom" }`, and `{ type = "datetime",
    format = "%H:%M" }`;
  - the agents rows and the `codex` override both contain `$spin` after `agent` and contain
    `state_text`; the spaces row 2 contains `$ci_ok`, `$ci_fail`, `$ci_run` after the three phase
    tokens and before `branch`;
  - a broken copy (an unknown `[ui]` key appended) makes `herdr config check` exit 1, proving the
    check bites.

- [ ] **Step 2: Run it and watch it fail**
  Run: `./tests/run.sh herdr-config`
  Expected: FAIL rows for the missing tokens and settings; the `config check` case passes.

- [ ] **Step 3: Edit `config.toml`** per spec §1–§3: the 13 new `[theme.custom]` tokens with the
  §1 values (keep the six existing ones), the `[ui]` keys above, the space row 2 with the `$ci_*`
  tokens, and agent rows `["state_icon", { token = "agent", fg = "#bb9af7", bold = true },
  { token = "$spin", fg = "#e0af68", bold = true }, "state_text"]` plus the dim title row (the
  `codex` override keeps only row 1). Keep the file's comment style: one short comment per block
  saying what it shows and why. Update the comment that says "Nothing else is coloured" so it no
  longer contradicts the new tokens.

- [ ] **Step 4: Run it and watch it pass**
  Run: `./tests/run.sh herdr-config`
  Expected: `PASS` on every case, exit 0.

- [ ] **Step 5: Commit** (controller)
  `git add dot_config/herdr/config.toml tests/herdr-config.test.sh`
  `git commit -m "Pin herdr's Tokyo Night palette and lay out the live-signal rows"`

---

### Task 2: Pipeline status on the MR badge (`phase.sh`)

**Depends on:** none (the `$ci_*` names are fixed by Task 1's Interfaces)

**Files:**
- Modify: `dot_config/herdr/executable_phase.sh` (`mr_table`, `derive`, `report`, `cmd_refresh`;
  new helpers)
- Modify: `tests/herdr-phase.test.sh`

**Interfaces:**
- Produces: workspace tokens `ci_ok=$'\xee\xaa\xb2'` (U+EAB2), `ci_fail=$'\xee\xa9\xb6'` (U+EA76),
  `ci_run=$'\xee\xa9\xb7'` (U+EA77), exactly one set per report and the other two cleared, in the
  same `herdr workspace report-metadata` call as the phase tokens (six token keys per call).
- Internal:
  - `repo_slug <repo_root>` → prints the GitLab slug or fails; `mr_table` uses it instead of its
    inline parsing.
  - `derive` keeps printing `<phase> <value>` on line 1, and prints `open <iid>` on line 2 when
    the branch's MR is open (draft or not). `cmd_refresh` reads both lines.
  - `pipeline_class <slug> <iid> <force>` → prints `ok`, `fail`, `run` or nothing.
  - `report <ws> <phase> <value> <ci>` with `<ci>` one of `ok|fail|run|""`.

- [ ] **Step 1: Write the failing cases in `tests/herdr-phase.test.sh`.** Extend the `glab` stub to
  answer `glab api projects/test%2Fproj/merge_requests/<iid>` from a fixture file `$PIPES`
  (`iid<TAB>status` lines; an iid absent from it answers `{"iid":N,"head_pipeline":null}`), and log
  the call. Change `glab_calls` to count only `^glab mr list` lines and add `glab_api_calls`
  (`^glab api `), so the existing per-repo caching assertions keep their meaning. New cases, under
  a new heading:
  - w4 (review, iid 10) with `success` → its report has `--token ci_ok=<U+EAB2 bytes>` and
    `--clear-token ci_fail --clear-token ci_run`;
  - `failed` → `ci_fail`; each of `running pending created preparing waiting_for_resource
    scheduled` → `ci_run`; `canceled`, `skipped`, `manual` and `head_pipeline: null` → all three
    cleared;
  - w5 (draft, iid 11) gets a pipeline badge too;
  - w6 (merged) and w7 (no MR) make no `glab api` call and clear all three;
  - caching: a second refresh inside the TTL makes 0 `glab api` calls; `--force` refetches; the
    cache key holds the iid, so changing w4's MR iid from 10 to 17 in `$MROPEN` refetches at once
    and never shows iid 10's status;
  - a failing `glab api` with a warm cache keeps the cached class; with a cold cache it clears
    the three tokens and leaves the phase token intact;
  - every report line carries at most 16 token keys.

- [ ] **Step 2: Run and watch the new cases fail**
  Run: `./tests/run.sh herdr-phase`
  Expected: the new cases FAIL; every pre-existing case still passes.

- [ ] **Step 3: Implement.** `pipeline_class` URL-encodes `/` in the slug as `%2F`, caches the
  status string at `"$CACHE_DIR/<slug with / as _>.mr<iid>.pipeline"` with the existing `TTL`
  (stat-mtime age, like `mr_table`), falls back to the stale cache on a failed call, parses with
  `"$PY" -I`, and maps statuses per spec §4's table. `cmd_refresh` calls it only when `derive`
  printed `open <iid>`. Glyph constants go beside `ICON_*` as byte escapes. Update the header
  comments (the "Three things drive it" block and `report`'s comment) to describe the six tokens.

- [ ] **Step 4: Run and watch everything pass**
  Run: `./tests/run.sh herdr-phase`
  Expected: all PASS, exit 0.

- [ ] **Step 5: Commit** (controller)
  `git add dot_config/herdr/executable_phase.sh tests/herdr-phase.test.sh`
  `git commit -m "Show the head pipeline's status beside an open MR's badge"`

---

### Task 3: Usage line for the tab bar (`usage.sh`)

**Depends on:** none

**Files:**
- Create: `dot_config/herdr/executable_usage.sh`
- Create: `tests/herdr-usage.test.sh`

**Interfaces:**
- Produces: `~/.config/herdr/usage.sh` → one line on stdout, exit 0 always.
- Environment: `PINNED_PATH` (suite only, for the `tagteam` stub), `CODEX_HOME` (default
  `$HOME/.codex`), `HERDR_USAGE_NOW` (suite only: epoch seconds standing in for now),
  `HERDR_USAGE_TRACE` (suite only: when set, the path of each rollout file opened is appended to
  that file, one per line, before it is read, and a `read <bytes>` line follows for each chunk
  read from it).
- Shape: `/bin/bash` with the pinned `PATH`, then `exec /usr/bin/python3 -I - <<'PY'` (the
  `herdr-agent-state.sh` pattern), so all logic is stdlib Python.

Output rules (spec §5, exact):
- Segments joined by ` · `: Claude first, then Codex; an agent with no source at all is omitted;
  nothing at all prints an empty line.
- A segment is `<label> <pct>% <win>`, plus ` ⚠` when the raw percentage is ≥ 80, plus ` ·<age>`
  when the figure's age exceeds 1800 s (or always, for tagteam's `lastGoodUsage`). `<pct>` is
  `int(pct + 0.5)`. `<age>` is `<n>m` under 1 h, `<n>h` under 48 h, else `<n>d` (floored).
- Unknown or fully reset → `<label> —`.
- Window choice: among the agent's windows whose reset time is in the future, the one with the
  highest percentage; `<win>` is `5h` (Claude `fiveHour`, Codex `window_minutes` 300), `wk`
  (Claude `sevenDay`, Codex 10080), otherwise `<n>d`, `<n>h` or `<n>m` from `window_minutes`.
- Claude: `tagteam status --json` run with a 3 s timeout; label `.active.alias`, else `claude`.
  tagteam missing, failing, timing out or printing invalid JSON, or `active: null` → no Claude
  segment. Otherwise spec §5's cases: `usage` non-null → its windows, aged by `usageAgeSeconds`;
  `usage` null and `lastGoodUsage` non-null → its windows, always with the age mark from
  `lastGoodAgeSeconds`; both null → `<label> —`.
- Codex: label `codex`; candidates are `rollout-*.jsonl` under `$CODEX_HOME/sessions/**` and
  `$CODEX_HOME/archived_sessions/` with mtime within 7 days of now, walked newest mtime first;
  each is read backwards in 64 KiB chunks until its last line with `payload.type == "token_count"`
  and a non-null `payload.rate_limits` is found; the walk stops when the next file's mtime is
  older than the newest event timestamp found. Malformed lines are skipped.

- [ ] **Step 1: Write the failing suite `tests/herdr-usage.test.sh`** (bash; a `tagteam` stub on
  `PINNED_PATH` that prints a fixture file or sleeps; a temp `CODEX_HOME`; fixed
  `HERDR_USAGE_NOW`; file mtimes set with `touch -t`). Fixtures use the alias `acct`. Cases:
  - `usage` with `fiveHour {pct: 38.4}` and `sevenDay {pct: 69}`, both resetting later, age 0 →
    `acct 69% wk`;
  - `fiveHour` null → falls to `sevenDay`; both windows reset → `acct —`;
  - `pct` 80 → `acct 80% wk ⚠`; `pct` 79.6 → `acct 80% wk` (the ⚠ follows the raw value, which
    is under 80);
  - `usageAgeSeconds` 2400 → ` ·40m`; 7200 → ` ·2h`;
  - `usage: null` + `lastGoodUsage` with `lastGoodAgeSeconds` 120 → age mark ` ·2m` anyway;
  - `usage: null`, `lastGoodUsage: null`, `usageStatus: "token_expired"` → `acct —`;
  - `active: null` → no Claude segment; no alias → label `claude`;
  - tagteam absent from `PINNED_PATH`, exiting 1, printing garbage → no Claude segment, exit 0;
  - **tagteam hangs** (stub sleeps 10) → the script returns within 4 s with the Codex segment;
  - Codex: newest-by-mtime file holds no `token_count` while an older one does → the older
    reading shows; five newer empty files → still found; an archived file with a newer event than
    anything under `sessions/` wins; a file whose mtime is older than the newest event found is
    never opened (the `HERDR_USAGE_TRACE` log lists the files read and does not list it); files
    older than 7 days are never opened either (same proof);
  - **far token_count**: a ~1 MB file whose only `token_count` is in its first KiB → found;
  - `window_minutes` 10080 → `wk`, 300 → `5h`, 1440 → `1d`; Codex age from the event timestamp;
  - both agents → `acct 69% wk · codex 82% wk ⚠`; **width**: with both agents, ⚠ and age marks
    (`acct 69% wk ·40m · codex 82% wk ⚠ ·3h`, 37 cells) the line is ≤ 40 characters;
  - malformed tagteam JSON fields (string `pct`, missing `resetsAt`) never print a traceback and
    never print anything but the documented shapes.

- [ ] **Step 2: Run and watch it fail**
  Run: `./tests/run.sh herdr-usage`
  Expected: the suite exits 2 or reports FAIL rows because `usage.sh` does not exist yet.

- [ ] **Step 3: Implement `executable_usage.sh`** per the rules above. One function per concern:
  `claude_segment(now) -> str | None`, `codex_segment(now) -> str | None`,
  `pick_window(windows, now) -> (pct, label) | None`, `fmt_age(seconds) -> str`,
  `last_token_count(path) -> (ts, rate_limits) | None`.

- [ ] **Step 4: Run and watch it pass**
  Run: `./tests/run.sh herdr-usage`
  Expected: all PASS, exit 0.

- [ ] **Step 5: Commit** (controller)
  `git add dot_config/herdr/executable_usage.sh tests/herdr-usage.test.sh`
  `git commit -m "Print Claude and Codex usage for herdr's tab bar"`

---

### Task 4: The `dev.agent-rows` plugin (spinner and wording)

**Depends on:** none (the `$spin` name is fixed by Task 1's Interfaces)

**Files:**
- Create: `dot_config/herdr/plugin-agent-rows/herdr-plugin.toml`
- Create: `dot_config/herdr/plugin-agent-rows/executable_agent-rows.py`
- Create: `tests/herdr-agent-rows.test.sh`

**Interfaces:**
- Manifest: `id = "dev.agent-rows"`, `name = "Agent rows"`, `version = "0.1.0"`,
  `min_herdr_version = "0.9.0"`, `platforms = ["macos"]`, one `[[startup]]` with
  `command = ["/bin/zsh", "-c", "exec /usr/bin/python3 -I \"$HOME/.config/herdr/plugin-agent-rows/agent-rows.py\" start"]`.
  A header comment says it is linked with `herdr plugin link ~/.config/herdr/plugin-agent-rows`
  and that unlinking takes effect at the next server start (spec §3).
- `agent-rows.py start` detaches `agent-rows.py worker` (`start_new_session=True`, stdio to
  `/dev/null`) and exits 0. `worker` runs the loop.
- Constants: `SOURCE = "dev.agent-rows"` (frames), `LABEL_SOURCE = "dev.agent-rows.labels"`
  (state labels, so a TTL on frames can never reach them), `TOKEN = "spin"`, `FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"` (as `\u`
  escapes), `FRAME_S = 0.14`, `TTL_MS = 1500`, `LABELS = {"blocked": "needs you"}`.
- Importable seams (the suite imports the file with `importlib` and never opens a real socket):
  - `class Transport`: `request(method: str, params: dict) -> dict` (one connection per call,
    returns the parsed response line) and `subscribe(subscriptions: list) -> Subscription`, whose
    `fileno()`, `read_events() -> list[dict]` (complete lines available now; raises `SubscriptionClosed` (an
    `EOFError`) on the subscription's own close and `EventsLost` on an error line such as `events_lost`) and `close()` the loop uses.
  - `class Rows`: pure state. `apply_snapshot(snapshot: dict) -> Effects`,
    `apply_event(event: dict) -> Effects`, `frame_effects(frame: str) -> Effects`; `Effects` holds
    `reports: list[dict]` (ready `pane.report_metadata` params) and `resubscribe: bool`.
    `subscriptions() -> list` builds the request list: `pane.agent_detected`, `pane.closed`,
    `pane.moved`, plus one `{"type": "pane.agent_status_changed", "pane_id": p}` per agent pane.
  - `run(transport, clock, sleep, stop) -> int`: the loop; returns the exit code.
- State rules: an agent pane is one whose snapshot `agent` is non-null or that a
  `pane_agent_detected` event named. Frames go only to panes currently `working`. A pane leaving
  `working`, closing or moving gets `{"spin": null}` (no TTL) on its last known live ID (not after
  close). Every agent pane gets `state_labels = LABELS` once per (re)appearance: at snapshot,
  detection and move. `pane_moved` remaps all state from `previous_pane_id` to `pane.pane_id`.
  `Rows` remembers which agent panes the live subscription covers, and **any** `apply_snapshot`
  or `apply_event` that leaves the agent-pane set different from that covered set sets
  `resubscribe` (a snapshot that discovers panes, a detection, a move, a close).
- Loop rules: bootstrap by subscribing to the lifecycle events alone, then taking a snapshot (so
  no event between them is lost); that first snapshot discovers the existing agent panes and so
  sets `resubscribe`. On `resubscribe`: open the new subscription built from `subscriptions()`,
  snapshot again, mark the new set as covered, then close the old subscription; repeat while a
  snapshot still changes the set. Wait with `select` on the
  subscription for `FRAME_S` while any pane works, with no timeout otherwise; only the first
  connect retries (for 10 s, then clear and return 0); a plain subscription close (`SubscriptionClosed`; any other `EOFError`, such as a one-shot request cut off, takes the bootstrap path below) is
  the server shutting down, so clear shown frames best-effort and return 0 at once, leaving the
  next server start's hook to launch a fresh worker; any other exception in the loop (an error
  line, a resync that times out or is refused, a malformed event line) is logged and answered with
  one new bootstrap and no wait, and if that bootstrap fails too, clear best-effort and return 0
  (a socket that is really gone fails it at once, so the worker never attaches to a restarted
  server); on SIGTERM/SIGINT clear shown frames and return 0. One instance: `fcntl.flock(LOCK_EX |
  LOCK_NB)` on `<state dir>/agent-rows.lock` (`$HERDR_PLUGIN_STATE_DIR`, else
  `~/.local/state/herdr/plugins/dev.agent-rows`); a second worker exits 0 at once. Log to
  `<state dir>/agent-rows.log`, truncated when it passes 256 KiB. Socket path from
  `HERDR_SOCKET_PATH`.

- [ ] **Step 1: Write the failing suite `tests/herdr-agent-rows.test.sh`** (bash wrapping
  `/usr/bin/python3 -I` test code; a `FakeTransport` records every `request` and serves scripted
  snapshots and event batches; a fake clock). Cases:
  - idle snapshot (agents, none working) → only the label reports, then zero requests over 50
    fake seconds of waiting and the loop's wait has no timeout;
  - one working pane → a frame report every tick with `ttl_ms` 1500 and a `FRAMES` character, to
    that pane only;
  - status `working → done` → `{"spin": null}` without `ttl_ms`, then no more frames;
  - every agent pane in the snapshot gets `state_labels == {"blocked": "needs you"}`;
    a `pane_agent_detected` for a new pane gets it too and sets `resubscribe`;
  - `pane_moved` of a working pane `w1:p1 → w2:p1` → later frames go to `w2:p1`, none to `w1:p1`,
    `w2:p1` gets its label again, and the next subscription list names `w2:p1`, not `w1:p1`;
  - `pane_closed` of a working pane → no clear sent to it, no frames after;
  - `events_lost` → resubscribe and a fresh snapshot, state rebuilt from it;
  - **bootstrap**: starting against a snapshot with two idle agent panes, the first subscription
    holds only the 3 lifecycle entries and the one after the first snapshot holds 5; a
    `pane_agent_status_changed` (`working`) delivered on that second subscription starts frames
    for its pane, and the first subscription is closed;
  - **many panes**: a snapshot with 39 agent panes, 3 working → after bootstrap the live
    subscription has 42 entries, frames go to exactly the 3, and no further resubscribe happens
    while the set is unchanged;
  - **server gone**: EOF, whether or not a reconnect would succeed → shown frames cleared
    best-effort and `run` returns 0 at once, without a second bootstrap; the first connect alone
    retries, within the 10 s budget on the fake clock;
  - **transient failures**: a resync whose snapshot times out once, and a malformed event line,
    each cost one bootstrap with no wait and the worker keeps spinning; `events_lost` followed by
    a failing bootstrap clears and returns 0;
  - SIGTERM while 2 panes spin → both cleared, return 0;
  - a second worker against a held lock exits 0 without making a request;
  - `Transport` framing through `socket.socketpair()`: one request line out, one response line
    parsed; a subscription yielding `subscription_started` then two events split across reads;
  - the file has no third-party imports (`ast` scan: only stdlib modules).

- [ ] **Step 2: Run and watch it fail**
  Run: `./tests/run.sh herdr-agent-rows`
  Expected: exit 2 or FAIL rows, because the plugin does not exist yet.

- [ ] **Step 3: Implement the manifest and `executable_agent-rows.py`** per the Interfaces.

- [ ] **Step 4: Run and watch it pass**
  Run: `./tests/run.sh herdr-agent-rows`
  Expected: all PASS, exit 0.

- [ ] **Step 5: Commit** (controller)
  `git add dot_config/herdr/plugin-agent-rows tests/herdr-agent-rows.test.sh`
  `git commit -m "Add the dev.agent-rows plugin: a spinner and 'needs you' on agent rows"`

---

## Batches

One batch: Tasks 1–4 have no dependencies, disjoint files, and no shared test resource. The
controller dispatches all four implementers together in this checkout, commits each task on its
own in the order 1, 2, 3, 4, reviews each on exactly its commit, and runs `./tests/run.sh` once
after the batch.

## Finish

- [ ] `./tests/run.sh` and `./tests/run.sh xreview git-forge-guard wt-functions` (AGENTS.md's
  heavy trio), totals reported as passed/total.
- [ ] `command chezmoi apply --dry-run --verbose` lists the new targets
  (`~/.config/herdr/usage.sh`, `~/.config/herdr/plugin-agent-rows/…`) with mode 755 for the
  executables.
- [ ] Pre-merge cross-review (`xreview dispatch --checkpoint pre-merge --diff main...herdr-ui-refresh`).
- [ ] Set the spec's and this plan's Status to `Implemented` in the final pre-merge commit, push
  `herdr-ui-refresh`, and report the activation steps from spec "Activation and live tuning".
- [ ] List, in the report, the checks only a live herdr can answer, for the tuning pass: the zoom
  entry shows only while zoomed (else drop it, spec §2); `state_text`'s default style is coloured
  (else make it dim, spec §3); the palette mapping per spec §1; the tab bar command runs with
  `~` expanded.
- [ ] Live checks of the agent-rows worker's lifecycle and wording, also for that list:
  (a) edit `agent-rows.py`, `chezmoi apply`, restart the herdr server, and see the change (a
  restart must start a worker with the new code, never keep the old one);
  (b) unlink the plugin, restart the server, and `pgrep -f agent-rows.py` finds nothing;
  (c) an agent works, then hits an approval prompt, and its row reads "needs you".
