# xreview on the Codex app-server daemon

**Status:** Approved
**Date:** 2026-09-26

## 1. Problem

Codex 0.157.0 (installed here on 2026-09-25) introduced a shared app-server daemon. The first
interactive `codex` spawns it, and every later TUI attaches to it. Hooks run inside the
daemon, not inside the TUI.

The daemon keeps the environment of whichever pane spawned it. On this machine that was the
VM.Portal Codex pane, so the daemon carries `HERDR_PANE_ID=wE:p2`. Herdr's Codex integration
hook (`~/.codex/herdr-agent-state.sh`, herdr-managed) reads `HERDR_PANE_ID` from its
environment, so it reported every new Codex thread, from any pane, against `wE:p2`. The last
thread started anywhere won. Every other Codex pane had no session id.

`xreview` resolves its review thread from herdr's session ids. It therefore dispatched
VM.Portal reviews into the tagteam thread, and refused to dispatch in every other repository.

Commit `c9d2d00` pinned `features.daemon_auto_start = false` as a stopgap. That keeps the
daemon from being spawned by a pane, but it gives up the daemon, and the daemon is what this
design builds on.

## 2. Goals

1. **Live.** Every review turn is visible live in the repository's Codex pane.
2. **Correct routing.** A review never reaches another repository's thread. xreview creates
   the review thread itself, or uses one the operator pinned explicitly.
3. **Herdr knows every thread.** `herdr pane list` shows the correct thread id for every Codex
   pane, including sessions the operator starts by hand. It never shows another pane's id.
   Everything runs on the daemon.
4. **Structured findings.** `xreview collect` returns schema-valid JSON, or exits non-zero.
   Nothing polls the history database.
5. **Cold per checkpoint.** The first dispatch of each checkpoint lands in a fresh thread
   without manual steps.

### Non-goals

- P1-A (binding receipts to checkpoint, artifact and verdict). This design produces the
  verdict that P1-A needs but does not bind anything to it.
- Editing herdr-managed hook scripts, or updating the herdr Claude integration (v9 → v10).
- Herdr sessions other than the default one, and Codex sessions outside herdr.
- A Rust client. Revisit it if the daemon client gains a second consumer.

## 3. Verified facts

Probed on 2026-09-26 against Codex 0.157.1 and herdr 0.9.1. The design depends on each of
these, and the live suite (§9) re-checks them.

| # | Fact |
|---|------|
| F1 | The daemon listens on `$CODEX_HOME/app-server-control/app-server-control.sock`. It speaks WebSocket (upgrade on `GET /rpc`) carrying JSON-RPC messages, with no `jsonrpc` field. `codex app-server proxy` relays raw bytes, so a client must speak WebSocket either way. |
| F2 | The handshake is `initialize {clientInfo:{name,version}}`, then an `initialized` notification. |
| F3 | `thread/start {cwd, sandbox:"read-only", approvalPolicy:"never", developerInstructions}` returns a thread id immediately. |
| F4 | A thread has no rollout until its first turn starts. `codex resume <id>` fails before that ("no rollout found"). |
| F5 | `turn/start {threadId, input, outputSchema, effort?}` returns at once. `turn/completed` carries the final `agentMessage` text, which conforms to the schema. |
| F6 | A turn started by one client renders live in a TUI attached to the same thread: the prompt, `Working…`, then the answer. This holds whether the TUI attached before the turn or mid-turn. |
| F7 | A second client can `thread/resume` a thread a TUI is attached to, and start turns on it, without disturbing the TUI. |
| F8 | `thread/loaded/list` and `thread/read` expose every loaded thread and its `cwd`. |
| F9 | With `daemon_auto_start = false`, a TUI still attaches to a daemon that is already running. |
| F10 | Any `-c` override makes a TUI run an embedded app-server instead of attaching to the daemon. |
| F11 | `tui.terminal_title` accepts the item `thread-id`. The TUI puts the full id in its title at launch, before any turn. Codex truncates long titles, so `thread-id` must come first. |
| F12 | `herdr pane list` exposes each pane's `terminal_title`, `agent`, `agent_status` and `cwd`. `herdr pane report-agent-session <pane> --source --agent --agent-session-id` sets a pane's session from outside the pane. |
| F13 | Herdr's managed Codex hook exits immediately when `HERDR_ENV`, `HERDR_SOCKET_PATH` or `HERDR_PANE_ID` is unset. |

## 4. Architecture

```
launchd ──starts──▶ Codex daemon (clean env)
                        ▲         │ SessionStart hooks
      TUIs attach ──────┤         ├──▶ herdr-agent-state.sh    (herdr-managed; exits: F13)
      (every pane)      │         └──▶ herdr-codex-pane-map.sh (new: title → pane → herdr)
                        │
 xreview ─▶ xreview-rpc ┘  thread/start, turn/start + outputSchema, wait turn/completed
    └──▶ herdr: point the repo's Codex pane at the review thread; report the id
```

| Unit | Kind | Responsibility |
|------|------|----------------|
| Daemon LaunchAgent | new, `Library/LaunchAgents/` | Start the daemon at login with a clean environment |
| `config.toml` template | changed | Keep `daemon_auto_start = false`; pin `tui.terminal_title` |
| `herdr-codex-pane-map.sh` | new, `~/.codex/` | Map a `SessionStart` thread id to the pane showing it; report it to herdr |
| `hooks.json` template | changed | Register the pane-map hook beside herdr's entry |
| `xreview-rpc` | new, `~/.local/bin/`, Python stdlib | Talk to the daemon: start a thread, start a turn, wait for a turn |
| `xreview` | changed | Checkpoint threads, pane pointing, structured collect |
| Reviewer instructions | new, `~/.config/xreview/reviewer.md` | `developerInstructions` for review threads |
| `cross-review/SKILL.md` | changed | Structured findings, automatic rotation, new refusals and exit codes |

The new files under `~/.codex` each need their own `!` entry in `.chezmoiignore`, because that
tree is an allowlist.

## 5. Daemon lifecycle

- A chezmoi-managed LaunchAgent starts the daemon at login. The environment it hands to the
  daemon contains no `HERDR_*` variable and no pane's working directory. The plan decides
  between `codex app-server daemon bootstrap`, if it installs exactly this, and our own plist.
  Either way, verification is `ps eww` on the daemon's process tree: no `HERDR_` variables.
- `features.daemon_auto_start = false` stays pinned. TUIs attach to the running daemon (F9).
  If the daemon is down, a TUI falls back to an embedded server that carries its own pane's
  environment. It never spawns a daemon that carries a pane's environment.
- Herdr's managed hook exits inside the clean daemon (F13). It is not edited.
- Nothing may pass `-c` to an interactive `codex` that should run on the daemon (F10). Every
  setting goes through `config.toml`.

## 6. Pane ↔ thread identity

**Join key.** The `config.toml` template pins
`tui.terminal_title = ["thread-id", "thread-title", "current-dir"]` (F11). Pane titles in
herdr now start with the thread UUID. That is the accepted cost.

**Pane-map hook.** `herdr-codex-pane-map.sh` is registered as a second `SessionStart` entry in
`hooks.json`, beside herdr's. It runs inside the daemon, once per session start, and does the
following:

1. Read `session_id` from the hook input. If it is missing, exit 0.
2. Poll `herdr pane list` on the default socket for a pane whose `terminal_title` contains a
   UUID equal to `session_id`. Retry for about 5 s while the title catches up.
3. On a match, run
   `herdr pane report-agent-session <pane> --source herdr:codex --agent codex --agent-session-id <id> --seq <ns>`,
   with `--session-start-source` passed through from the hook input.
4. With no match (a sub-agent thread, or a review thread whose pane has not attached yet),
   report nothing.

The hook always exits 0, stays well inside the 10 s hook timeout, and never blocks a session.
It resolves `herdr` by absolute path, because the daemon's `PATH` is launchd's.

Hand-started sessions, `/new` and resumes are reported when `SessionStart` fires: for a fresh
session, at its first turn, as today. Whether `SessionStart` fires when a TUI resumes a thread
the daemon already has loaded is unverified (§11). The review path does not depend on it,
because xreview reports its own threads (§7.3).

## 7. xreview transport

### 7.1 `xreview-rpc`

A Python 3 client using only the standard library. It connects to the daemon socket (F1),
completes the handshake (F2) and exposes:

- `thread-start --cwd <dir> --instructions <file>`: prints the thread id.
- `turn-start --thread <id> --input <file> --schema <file>`: runs `thread/resume` to
  subscribe, then `turn/start`. Prints the turn id.
- `turn-wait --thread <id> --turn <id> --budget <secs>`: subscribes first, then reads the
  turn's status (`thread/turns/list` or `thread/read`), so a turn that finished before the
  wait began is still caught. It then waits for `turn/completed` and prints the final agent
  message.
  - Exit 0: completed.
  - Exit 3: still running when the budget ends.
  - Exit 1: failed, interrupted, or unknown.
  - Exit 5: daemon unreachable.
- `health`: checks the daemon is reachable, and reports whether its environment contains
  `HERDR_PANE_ID`.

It declines any server-initiated approval request. None should arrive under
`approvalPolicy: never`.

### 7.2 Threads and checkpoints

- Precedence for the review thread: `XREVIEW_THREAD` > `xreview init <id>` pin > the
  checkpoint thread in `$state_dir/thread` > a new thread.
- A new thread is created in the repository root, read-only, with `approvalPolicy: never` and
  the reviewer instructions.
- Every round within a checkpoint goes to the same thread. `xreview round --reset` (moving to
  the next checkpoint) drops the recorded thread, so the next dispatch creates a cold one.
- The superseded review thread is archived (`thread/archive`) once the pane has moved off it.
  Archived threads stay readable, so receipts keep their meaning.
- `warn_stale_thread` and `XREVIEW_THREAD_WARN` are removed. A thread only ever holds one
  checkpoint's rounds, and the round cap bounds those.
- Resolving the thread from herdr is removed.
- Model and effort come from `config.toml` defaults when the thread starts; `/model` writes
  there. There is no gate on which model runs. `xreview tier` is unchanged.

### 7.3 Dispatch

`xreview dispatch [--diff <range>] <body-file>`. The output is unchanged: the nonce on stdout.

1. **Preconditions, before anything is created:**
   - `xreview-rpc health` passes. If the daemon's environment contains `HERDR_PANE_ID`, warn
     loudly and print the fix.
   - The repository's Codex pane exists: exactly one herdr pane with `agent == "codex"` and
     `cwd` equal to the repository root. `XREVIEW_PANE` overrides the choice.
   - That pane's `agent_status` is not `working`.
   - The existing guards pass: no project `.codex/`, and the round cap.
2. **Thread.** Resolve the review thread (§7.2), creating one if needed.
3. **Turn.** Wrap the body in `<cross-review-request>` as today, carrying the diff inline. The
   correlation line is dropped, because the turn id replaces it. Run `turn-start` with the
   findings schema (§7.5).
4. **Pane.** If the pane's title does not already contain the thread id:
   1. Quit its TUI (`ctrl+c` twice) and wait for the shell.
   2. Run the Codex pane command with `resume <id>`. The flags come from the single definition
      that `layout.sh` uses.
   3. Report the id to herdr.

   This happens after the turn has started (F4); mid-turn attach works (F6).
5. **Record** `$state_dir/turns/<nonce>` as `<thread> <turn>`.

If step 4 fails, the review is not lost. Dispatch still prints the nonce, and warns with the
manual `codex resume <id>`.

### 7.4 Collect

`xreview collect <nonce> [budget]`. The interface and default budget are unchanged.

1. Look up the thread and turn for the nonce, then run `turn-wait`.
2. Validate the result against the schema.
   - Valid: print the JSON and write the receipt.
   - Invalid: print the raw text, labelled untrusted, and exit 4.
3. Exit codes: 0 done; 3 still running; 1 failed or ambiguous (never re-dispatch); 4 output
   not schema-valid.

On a dropped connection, reconnect within the budget, because launchd restarts the daemon.
If the turn is unknown after reconnecting, exit 1.

`sq`, `assert_like_safe` and all history-database polling are removed.

### 7.5 Findings schema

```json
{
  "type": "object", "additionalProperties": false,
  "required": ["verdict", "findings"],
  "properties": {
    "verdict": {"enum": ["approve", "changes"]},
    "findings": {"type": "array", "items": {
      "type": "object", "additionalProperties": false,
      "required": ["severity", "file", "line", "summary", "failure_scenario"],
      "properties": {
        "severity": {"enum": ["P0", "P1", "P2", "P3"]},
        "file": {"type": "string"}, "line": {"type": "integer"},
        "summary": {"type": "string"}, "failure_scenario": {"type": "string"}
      }}}
  }
}
```

Text fields remain untrusted evidence. The skill's rule, verify before acting, is unchanged.

### 7.6 Receipts

`reviews.jsonl` keeps every existing field (`ts`, `branch`, `head`, `thread`, `nonce`,
`tier`). It adds `turn`, `verdict` and `findings` (a count). The guards read only the
existing fields, so they are unaffected.

## 8. Failure handling

| Condition | Behaviour |
|-----------|-----------|
| Daemon down | `dispatch` refuses and names the `launchctl kickstart` command. `collect` reconnects within its budget, then exits 1. |
| Daemon carries `HERDR_PANE_ID` | `dispatch` warns with the fix: stop the daemon and start it through launchd. The pane-map hook still reports correctly, but herdr's managed hook would report too. |
| No Codex pane, or several | Refuse, list the candidates, and suggest applying the project layout or setting `XREVIEW_PANE`. |
| Pane mid-turn | Refuse before creating anything. |
| Re-pointing fails after the turn started | Dispatch succeeds and warns with the manual `resume`. |
| Turn failed or interrupted | `collect` exits 1 with the reason. |
| Output not schema-valid | `collect` exits 4. Raw text is printed and labelled untrusted. |
| Pane-map hook: no match, or herdr unreachable | Report nothing and exit 0. |

## 9. Testing

Every suite checks that its subject exists and exits 2 if not.

- **`xreview.test.sh`**, reworked:
  - A fake daemon: a Python WebSocket JSON-RPC server on a temporary socket, with scripted
    thread and turn starts, a turn that completes before `collect` connects, a failed turn,
    schema-invalid output, and a dropped connection.
  - A stubbed `herdr` on `PATH`, the pattern `herdr-phase.test.sh` uses.
  - Asserts:
    - preconditions refuse before any `thread/start`;
    - no re-point when the title already holds the id;
    - the busy-pane refusal;
    - exit codes 0, 1, 3 and 4;
    - receipt fields, old and new;
    - `round --reset` yields a new thread on the next dispatch.
- **`herdr-codex-pane-map.test.sh`**: hook-input fixtures with a stubbed `herdr`. An exact
  id in a title is reported with the right arguments. No match reports nothing. The hook
  never exits non-zero.
- **`codex-config.test.sh`**: `tui.terminal_title` is pinned with `thread-id` first, and
  `daemon_auto_start` stays false. `hooks.json` holds both hook entries, the edit is
  idempotent, and unrelated hooks survive.
- **`live-codex-daemon.test.sh`** (`# test-requires: unsandboxed, live daemon, live herdr`):
  automates the 2026-09-26 probe.
  - Start a thread; start a turn with a schema; attach a scratch pane with `codex resume`.
  - Assert live rendering and a structured result; assert the pane-map hook reported the
    scratch pane.
  - Clean up: archive the thread and close the tab.

  This suite is the canary for protocol changes after a Codex update.
- **`xreview-skill.test.sh`**: updated for the skill text.
- `AGENTS.md`: the testing table gains `live-codex-daemon`.

## 10. Rollout

1. Apply the config, hooks and LaunchAgent changes.
2. Stop the current daemon. It carries the VM.Portal pane's environment.
3. Start the daemon through launchd. Confirm with `ps eww` that it has no `HERDR_` variables.
4. Relaunch every Codex pane. Each attaches (F9) and puts its id in its title.
5. After each pane's first turn, `herdr pane list` shows every Codex pane with its own id.
6. Run one real dispatch in this repository, and confirm it renders live and collects JSON.

## 11. Open questions for the plan

- Whether `codex app-server daemon bootstrap` installs a clean-environment launchd job, or
  whether an own plist is needed. Also whether launchd should keep the daemon's supervisor or
  the server itself alive.
- Whether `SessionStart` fires when a TUI resumes a thread the daemon already has loaded. This
  affects only hand-resumed sessions, not reviews.
- What happens when a thread is archived while a TUI is attached to it. Archive only after the
  re-point, which §7.2 already requires.

## 12. Alternatives considered

- **Keep the daemon off** (the stopgap `c9d2d00`). Rejected: no live view of turns xreview
  starts, and no structured output through `codex queue`.
- **Hand-started sessions standalone** (`--no-daemon` through a shell wrapper), with herdr's
  own hook reporting them. Rejected by the operator: everything runs on the daemon.
- **A daemon-side hook guessing the pane from the thread's `cwd`.** Rejected: sub-agent
  threads share their parent's `cwd` and would overwrite the pane's real id.
- **A herdr event subscriber** (`events.subscribe`, `pane_updated`) watching titles.
  Rejected: it needs another long-running supervised process. The `SessionStart` hook already
  runs at the right moment.
- **Transport-only change**, keeping the pane's current thread. Rejected: rotation stays
  manual and reviews accumulate in one thread.
- **A Rust client.** Rejected for now: the repository has no build step, and the client is
  small glue. Revisit it if the client gains a second consumer.

## 13. Consequences

- xreview depends on the daemon. With the daemon down there are no reviews, by design,
  because the live view requires it.
- Pane titles lead with a UUID.
- The Codex app-server protocol is marked experimental. `live-codex-daemon` is the tripwire,
  and a Codex update that breaks it blocks reviews until `xreview-rpc` is adjusted.
- Review threads are created and archived automatically. The Codex resume picker shows only
  the current checkpoint's review thread.
