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

Commit `c9d2d00` pinned `features.daemon_auto_start = false` as a stopgap, so no pane can
spawn the daemon. This design keeps that pin, and brings the daemon back under launchd with a
clean environment, because the daemon is what the live review view builds on.

## 2. Goals

1. **Live.** Every review turn is visible live in the repository's Codex pane, from its
   first token. No review turn is started unless the pane is already watching its thread.
2. **Correct routing.** A review never reaches another repository's thread. The review thread
   is one xreview had the repository's own pane create, or one the operator pinned
   explicitly.
3. **Herdr knows every thread.** `herdr pane list` shows the correct thread id for every Codex
   pane, including sessions the operator starts by hand. It never shows another pane's id,
   and a wrong id that does appear is repaired automatically.
4. **Everything on the daemon.** Every interactive Codex start attaches to the daemon, or
   refuses. The only exception is an explicit `--no-daemon`.
5. **Structured findings.** `xreview collect` returns schema-valid JSON, or exits non-zero.
   Nothing polls the history database.
6. **Cold per checkpoint.** The first dispatch of each checkpoint lands in a fresh thread
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
  (via codex launcher)  │         └──▶ herdr-codex-pane-map.sh (new: reconcile titles → herdr)
                        │
 xreview ─▶ xreview-rpc ┘  turn/start + outputSchema on the pane's thread, wait turn/completed
    └──▶ herdr: prepare the repo's Codex pane on the review thread BEFORE the turn starts
```

| Unit | Kind | Responsibility |
|------|------|----------------|
| Daemon LaunchAgent | new, `Library/LaunchAgents/` | Start the daemon at login with a clean environment |
| `codex` launcher | new, `~/.local/bin/codex` | Make every interactive start attach to the daemon, or refuse |
| `codex-daemon` | new, `~/.local/bin/` | `ensure` (start through launchd and wait) and `check` (reachable, clean environment) |
| `config.toml` template | changed | Keep `daemon_auto_start = false`; pin `tui.terminal_title` |
| `herdr-codex-pane-map.sh` | new, `~/.codex/` | Reconcile herdr's session id for every Codex pane from its title |
| `hooks.json` template | changed | Register the pane-map hook beside herdr's entry |
| `xreview-rpc` | new, `~/.local/bin/`, Python stdlib | Talk to the daemon: thread status, start a turn, wait for a turn, archive |
| `xreview` | changed | Pane-first dispatch, checkpoint threads, structured collect |
| Reviewer instructions | new, `~/.config/xreview/reviewer.md` | Reviewer role, carried inside every review packet |
| `cross-review/SKILL.md` | changed | Structured findings, automatic rotation, new refusals and exit codes |

The new files under `~/.codex` each need their own `!` entry in `.chezmoiignore`, because that
tree is an allowlist.

## 5. Daemon lifecycle

**LaunchAgent.** A chezmoi-managed LaunchAgent starts the daemon at login. The environment
it hands to the daemon contains no `HERDR_*` variable and no pane's working directory. The plan
decides between `codex app-server daemon bootstrap`, if it installs exactly this, and our own
plist. Verification either way is `ps eww` on the daemon's process tree: no `HERDR_` variables.

**No fallback.** `features.daemon_auto_start = false` stays pinned, so no TUI ever spawns a
daemon that carries its pane's environment. A TUI attaches to a running daemon (F9). Nothing
may pass `-c` to an interactive `codex` that should run on the daemon (F10); every setting goes
through `config.toml`.

**`codex-daemon`** is a small helper with two commands:

- `ensure`: if the daemon socket does not accept a connection, run
  `launchctl kickstart gui/$UID/<label>` and wait up to about 10 s for the socket. Exit 0 when
  it is up, and non-zero when it is not.
- `check`: exit 0 only when the daemon is reachable and its process environment carries no
  `HERDR_*` variable. Otherwise, print which condition failed and the fix.

**The `codex` launcher** is a script at `~/.local/bin/codex`. `~/.local/bin` comes first on
`PATH`, so the launcher shadows the Homebrew binary; it execs that binary by absolute path,
skipping itself.

| Invocation | Launcher behaviour |
|------------|--------------------|
| Interactive start: no subcommand, `resume`, `fork` | `codex-daemon ensure`, then exec. If the daemon cannot be started, refuse and name `--no-daemon` as the deliberate escape. |
| Interactive start with `-c`, `--config`, `--enable` or `--disable` | Refuse, because these would silently run the session embedded (F10). `--no-daemon` makes the choice explicit and passes through. |
| Any explicit `--no-daemon` or `--remote` | Pass through untouched. |
| Every other subcommand (`exec`, `app-server`, `features`, `update`, …) | Pass through untouched. |

If `codex-daemon check` fails on an interactive start, the launcher warns but still starts. It
does not block ordinary Codex use; dispatch refuses instead (§7.3).

Herdr's managed hook exits inside the clean daemon (F13). It is not edited.

## 6. Pane ↔ thread identity

**Join key.** The `config.toml` template pins
`tui.terminal_title = ["thread-id", "thread-title", "current-dir"]` (F11). Every TUI on the
daemon therefore shows its thread UUID at the start of its title, from launch onwards. Pane
titles in herdr now start with the UUID; that is the accepted cost.

**Pane-map hook.** `herdr-codex-pane-map.sh` is registered as a second `SessionStart` entry in
`hooks.json`, beside herdr's. It runs inside the daemon and **reconciles all Codex panes**,
not only the one whose session is starting:

1. List herdr panes on the default socket.
2. For every pane with `agent == "codex"` whose title begins with a UUID, compare that UUID
   with the pane's `agent_session`. On a mismatch or no session, run
   `herdr pane report-agent-session <pane> --source herdr:codex --agent codex --agent-session-id <uuid> --seq <ns>`.
3. If the hook input's `session_id` is not yet in any title, retry for about 5 s while the
   title catches up, then stop.
4. Never report an id that is not in a title. That rules out guessing for sub-agent threads,
   and for anything not visibly on screen.

Because every `SessionStart` reconciles everything, one contaminated report, for example from
herdr's managed hook in a daemon that carries a pane's environment, is repaired by the next
session start anywhere. `herdr-codex-pane-map.sh --reconcile` runs the same pass on demand,
without hook input; the rollout (§10) uses it.

The hook always exits 0, stays well inside the 10 s hook timeout, and never blocks a session.
It resolves `herdr` by absolute path, because the daemon's `PATH` is launchd's.

## 7. xreview transport

### 7.1 `xreview-rpc`

A Python 3 client using only the standard library. It connects to the daemon socket (F1),
completes the handshake (F2), declines any server-initiated approval request, and exposes:

- `thread-status --thread <id>`: whether the thread is loaded, and whether a turn is running
  on it.
- `turn-start --thread <id> --input <file> --schema <file>`: starts a turn with the findings
  schema, a read-only sandbox policy and approval `never` set on the turn itself. Prints the
  turn id.
- `turn-wait --thread <id> --turn <id> --budget <secs>`: subscribes first, then reads the
  turn's status, so a turn that finished before the wait began is still caught. It then waits
  for `turn/completed` and prints the final agent message.
  - Exit 0: completed.
  - Exit 3: still running when the budget ends.
  - Exit 1: failed, interrupted, or unknown.
  - Exit 5: daemon unreachable.
- `thread-archive --thread <id>`.

### 7.2 Threads and checkpoints

- Precedence for the review thread: `XREVIEW_THREAD` > `xreview init <id>` pin > the
  checkpoint thread in `$state_dir/thread` > a new thread.
- **A new thread is created by the pane, not by xreview.** xreview launches a fresh Codex in
  the pane. The TUI creates the thread on the daemon and shows its id in its title (F11), and
  xreview records that id as the checkpoint thread. The session starts with the pane
  command's read-only flags, and every review turn sets read-only and approval `never` again
  on the turn (§7.1).
- Every round within a checkpoint goes to the same thread. `xreview round --reset` (moving to
  the next checkpoint) drops the recorded thread, so the next dispatch starts a cold one.
- The superseded review thread is archived once the pane has moved off it. Archived threads
  stay readable, so receipts keep their meaning.
- `warn_stale_thread` and `XREVIEW_THREAD_WARN` are removed. A thread only ever holds one
  checkpoint's rounds, and the round cap bounds those.
- Resolving the thread from herdr's session ids is removed.
- Model and effort come from `config.toml` defaults when the thread starts; `/model` writes
  there. There is no gate on which model runs. `xreview tier` is unchanged.

### 7.3 Dispatch

`xreview dispatch [--diff <range>] <body-file>`. The output is unchanged: the nonce on stdout.
Nothing is sent to the reviewer until the pane is watching the thread.

1. **Preconditions, before anything is touched:**
   - `codex-daemon ensure` and then `codex-daemon check` pass. If the daemon carries a pane's
     environment, refuse. The message names the fix (restart the daemon through launchd) and
     its cost: every open Codex TUI disconnects and must be relaunched.
   - The repository's Codex pane exists: exactly one herdr pane with `agent == "codex"` and
     `cwd` equal to the repository root. `XREVIEW_PANE` overrides the choice.
   - That pane's `agent_status` is not `working`.
   - The existing guards pass: no project `.codex/`, and the round cap.
2. **Pane first.** Make the pane show the review thread:
   - If the recorded thread's id is already at the start of the pane's title, nothing to do.
   - If a thread is recorded (or pinned) but the pane shows something else, quit its TUI
     (`ctrl+c` twice), wait for the shell, and run the Codex pane command with `resume <id>`.
     The pane command's flags come from the single definition that `layout.sh` uses.
   - If no thread is recorded, quit the TUI and run the Codex pane command without `resume`.
     Record the UUID that appears at the start of the title as the checkpoint thread.

   In every case, wait (bounded, about 20 s) until the title shows the expected id and the
   daemon reports the thread as loaded, then report the id to herdr. If that does not happen,
   refuse. No turn has been started, so nothing is lost or unseen.
3. **Turn.** Build the packet as `<cross-review-request>` containing the reviewer instructions,
   the body, and the diff inline. The correlation line is dropped, because the turn id
   replaces it. Run `turn-start` with the findings schema (§7.5).
4. **Record** `$state_dir/turns/<nonce>` as `<thread> <turn>`. Archive the superseded review
   thread, if there is one.

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
| Daemon down at an interactive `codex` | The launcher starts it through launchd and waits. If it is still down, refuse and name `--no-daemon`. |
| Daemon down at dispatch | `codex-daemon ensure`; if it is still down, refuse and name the `launchctl` command. |
| Daemon down during collect | Reconnect within the budget, then exit 1. |
| Daemon carries a pane's environment | Dispatch refuses, naming the fix and that it disconnects every open Codex TUI. The launcher warns. The pane-map hook repairs herdr's view on every session start. |
| Interactive `codex` with `-c` and friends | The launcher refuses unless `--no-daemon` is explicit. |
| No Codex pane, or several | Refuse, list the candidates, and suggest applying the project layout or setting `XREVIEW_PANE`. |
| Pane mid-turn | Refuse before touching anything. |
| Pane cannot be prepared (no title id, thread not loaded, timeout) | Refuse. No turn exists. |
| Turn failed or interrupted | `collect` exits 1 with the reason. |
| Output not schema-valid | `collect` exits 4. Raw text is printed and labelled untrusted. |
| Pane-map hook: herdr unreachable, or no title match | Report nothing and exit 0. |

## 9. Testing

Every suite checks that its subject exists and exits 2 if not.

- **`xreview.test.sh`**, reworked:
  - A fake daemon: a Python WebSocket JSON-RPC server on a temporary socket, with scripted
    thread status, turn starts, a turn that completes before `collect` connects, a failed
    turn, schema-invalid output, and a dropped connection.
  - A stubbed `herdr` and a stubbed `codex-daemon` on `PATH`, the pattern `herdr-phase.test.sh`
    uses.
  - Asserts:
    - a contaminated daemon, a missing or ambiguous pane and a busy pane each refuse before
      any pane keystroke or `turn/start`;
    - no `turn/start` until the stub pane's title shows the thread id, and none at all when
      preparation times out;
    - no re-point when the title already shows the id;
    - exit codes 0, 1, 3 and 4;
    - receipt fields, old and new;
    - `round --reset` yields a fresh pane session, and a new thread, on the next dispatch.
- **`codex-launcher.test.sh`**: with a stubbed `codex-daemon` and a stub Homebrew binary:
  - interactive starts call `ensure` and exec the real binary;
  - a failing `ensure` refuses;
  - `-c` on an interactive start refuses;
  - `--no-daemon`, `--remote` and other subcommands pass through untouched;
  - the launcher never execs itself.
- **`herdr-codex-pane-map.test.sh`**: hook-input fixtures with a stubbed `herdr`.
  - Every Codex pane whose title UUID differs from its session is reported.
  - A matching pane is not reported.
  - Titles without a UUID, and non-Codex panes, are ignored.
  - `--reconcile` works without hook input.
  - The hook never exits non-zero.
- **`codex-config.test.sh`**: `tui.terminal_title` is pinned with `thread-id` first, and
  `daemon_auto_start` stays false. `hooks.json` holds both hook entries, the edit is
  idempotent, and unrelated hooks survive.
- **`live-codex-daemon.test.sh`** (`# test-requires: unsandboxed, live daemon, live herdr`):
  automates the 2026-09-26 probe in the pane-first order. In a scratch pane:
  - start a fresh Codex and read the thread id from the title;
  - start a turn with the schema through `xreview-rpc`;
  - assert the pane renders it from the first token and the result is structured;
  - assert the pane-map hook reported the scratch pane;
  - clean up: archive the thread and close the tab.

  This suite is the canary for protocol changes after a Codex update.
- **`xreview-skill.test.sh`**: updated for the skill text.
- `AGENTS.md`: the testing table gains `live-codex-daemon`.

## 10. Rollout

1. Apply the config, hooks, launcher, helper and LaunchAgent changes.
2. Stop the current daemon. It carries the VM.Portal pane's environment.
3. Start the daemon through launchd. `codex-daemon check` passes.
4. Relaunch every Codex pane through the launcher. Each attaches (F9) and shows its id in its
   title.
5. Run `herdr-codex-pane-map.sh --reconcile`. `herdr pane list` then shows every Codex pane
   with its own id.
6. Run one real dispatch in this repository. Confirm it renders live from the first token and
   that collect returns JSON.

## 11. Open questions for the plan

- **Pane-first depends on this, so the plan probes it first:** can another client start a turn
  on a thread that a TUI created but has not yet run a turn on? If not, the fallback is a
  bootstrap turn: xreview spends one minimal turn to make a new thread resumable, attaches the
  pane, and only then submits the review.
- Whether `codex app-server daemon bootstrap` installs a clean-environment launchd job, or an
  own plist is needed. Also whether launchd should keep the daemon's supervisor or the server
  itself alive.
- What happens when a thread is archived while a TUI is still attached to it. Archive only
  after the pane has moved off it, which §7.3 already requires.

## 12. Alternatives considered

- **Keep the daemon off** (the stopgap `c9d2d00`). Rejected: no live view of turns xreview
  starts, and no structured output through `codex queue`.
- **Hand-started sessions standalone** (`--no-daemon` through a shell wrapper), with herdr's
  own hook reporting them. Rejected by the operator: everything runs on the daemon.
- **An embedded fallback when the daemon is down.** Rejected in review: sessions would
  silently leave the daemon.
- **A daemon-side hook guessing the pane from the thread's `cwd`.** Rejected: sub-agent
  threads share their parent's `cwd` and would overwrite the pane's real id.
- **A herdr event subscriber** (`events.subscribe`, `pane_updated`) watching titles.
  Rejected: it needs another long-running supervised process. The `SessionStart` hook already
  runs often enough to reconcile.
- **Starting the turn before attaching the pane.** Rejected in review: a fast turn, or a pane
  that fails to attach, leaves the review unwatched.
- **Only warning about a daemon that carries a pane's environment.** Rejected in review: it
  keeps corrupting herdr's view of other panes.
- **Transport-only change**, keeping the pane's current thread. Rejected: rotation stays
  manual and reviews accumulate in one thread.
- **A Rust client.** Rejected for now: the repository has no build step, and the client is
  small glue. Revisit it if the client gains a second consumer.

## 13. Consequences

- xreview depends on the daemon, and so does every interactive Codex start through the
  launcher. With the daemon unavailable, `codex --no-daemon` is the only way to start Codex.
- Interactive starts cannot take `-c` overrides without `--no-daemon`; settings go through
  `config.toml`.
- A daemon that carries a pane's environment blocks reviews until it is restarted, which
  disconnects every open Codex TUI.
- Pane titles lead with a UUID.
- Each checkpoint's first dispatch replaces whatever session the Codex pane had open.
- The Codex app-server protocol is marked experimental. `live-codex-daemon` is the tripwire,
  and a Codex update that breaks it blocks reviews until `xreview-rpc` is adjusted.
- Review threads are created and archived automatically. The Codex resume picker shows only
  the current checkpoint's review thread.
