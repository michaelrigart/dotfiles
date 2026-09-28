# xreview on the Codex app-server daemon

**Status:** In progress
**Date:** 2026-09-26
**Amended:** 2026-09-28 - dispatch is turn first: xreview creates the thread over the daemon,
starts the turn, then resumes the pane onto the thread, which replays the turn from its start
(F22, §7.3). This supersedes the original pane-first ordering (§12).

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

The rollout (task 10, 2026-09-27) found the original probe of F11 wrong: Codex ALWAYS
truncates the title's `thread-id` item; a full id appears only as `thread-title`'s fallback,
for a thread that is not yet named. So the join key described in §6 is a title id prefix,
resolved through the daemon (F21), never a full id read straight off the title.

## 2. Goals

1. **Live.** Every review turn is visible live in the repository's Codex pane. Right after
   the turn starts, the pane is resumed onto its thread and replays it from its first item
   (F22). A pane that fails to attach costs the live view, never the review.
2. **Correct routing.** A review never reaches another repository's thread. The review thread
   is one xreview created for the repository over the daemon, or one the operator pinned
   explicitly.
3. **Herdr knows every thread.** `herdr pane list` shows the correct thread id for every Codex
   pane, including sessions the operator starts by hand. It never shows another pane's id,
   and a wrong id that does appear is repaired automatically.
4. **Everything on the daemon.** Every interactive Codex start attaches to the daemon, or
   refuses. The only exception is an explicit `--no-daemon`, which the operator accepted as
   the deliberate escape on 2026-09-26.
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
| F11 | `tui.terminal_title` accepts the item `thread-id`, which must come first. Codex ALWAYS truncates it to 29 characters plus `...`: the observed title is `<29-char prefix>... | <thread-title> | <cwd>`. A full id appears only as `thread-title`'s fallback, for a thread that is not yet named. |
| F12 | `herdr pane list` exposes each pane's `terminal_title`, `agent`, `agent_status` and `cwd`. `herdr pane report-agent-session <pane> --source --agent --agent-session-id` sets a pane's session from outside the pane. |
| F13 | Herdr's managed Codex hook exits immediately when `HERDR_ENV`, `HERDR_SOCKET_PATH` or `HERDR_PANE_ID` is unset. |
| F14 | A fresh TUI attached to the daemon registers its thread at launch. The thread is loaded and `idle` before any turn. The default terminal title does not show the id. |
| F15 | A second client can `turn/start` on that pre-first-turn thread without `thread/resume`, with `sandboxPolicy {type:"readOnly"}` and `approvalPolicy:"never"` set on the turn. The attached TUI renders it from the first token. |
| F16 | `thread/read` reports status `active` while a turn runs and `idle` after. `thread/turns/list` (summary view) gives each turn's status (`inProgress`, `completed`, `failed`, `interrupted`) and its `agentMessage` item with `phase: "final_answer"`. |
| F17 | A fresh connection can `thread/resume` a thread and receive `turn/completed` for a turn another connection started. For a turn that already finished, `thread/turns/list` returns it `completed`. |
| F18 | `SessionStart` fires at a thread's first turn, not at TUI launch. |
| F19 | `codex app-server daemon bootstrap` installs no launchd job. The daemon's supervisor (`daemon pid-update-loop`) and server are each their own process-group leader. `daemon.pid` and `daemon-updater.pid` under `$CODEX_HOME/app-server-daemon/` hold JSON with a `pid` field. |
| F20 | Inside the Claude sandbox, binding a unix socket is denied, so a socket-based fake daemon cannot run in the default test run. |
| F21 | `thread/loaded/list` resolves a title's id prefix to a full id: it lists every loaded thread, and the one whose id starts with the prefix is the match. Zero or several matches is an error, never a guess. |
| F22 | (Probed 2026-09-28.) A thread created with `thread/start` and given a turn at once can be opened with `codex resume <id>` while that first turn is still running. The TUI renders the whole turn from its start, prompt included, streams the rest live, and shows the final answer. |


## 4. Architecture

```
launchd ──starts──▶ Codex daemon (clean env)
                        ▲         │ SessionStart hooks
      TUIs attach ──────┤         ├──▶ herdr-agent-state.sh    (herdr-managed; exits: F13)
  (via codex launcher)  │         └──▶ herdr-codex-pane-map.py (new: reconcile titles → herdr)
                        │
 xreview ─▶ xreview-rpc ┘  thread/start, turn/start + outputSchema, wait turn/completed
    └──▶ herdr: then resume the repo's Codex pane on that thread; it replays the turn (F22)
```

| Unit | Kind | Responsibility |
|------|------|----------------|
| Daemon LaunchAgent | new, `Library/LaunchAgents/` | Start the daemon at login with a clean environment |
| `codex` launcher | new, `~/.local/bin/codex` | Make every interactive start attach to the daemon, or refuse |
| `codex-code-mode-host` shim | changed, `~/.local/bin/` | Resolve the real Codex binary the same way the launcher does |
| `codex-daemon` | new, `~/.local/bin/` | `ensure` (start through launchd and wait) and `check` (reachable, clean environment) |
| `config.toml` template | changed | Keep `daemon_auto_start = false`; pin `tui.terminal_title` |
| `herdr-codex-pane-map.py` | new, `~/.codex/` | Reconcile herdr's session id for every Codex pane from its title |
| `hooks.json` template | changed | Register the pane-map hook beside herdr's entry |
| `xreview-rpc` | new, `~/.local/bin/`, Python stdlib | Talk to the daemon: start a thread, thread status, start a turn, wait for a turn, archive |
| `xreview` | changed | Turn-first dispatch with the pane following, checkpoint threads, structured collect |
| Reviewer instructions | new, `~/.config/xreview/reviewer.md` | Reviewer role, carried inside every review packet |
| `cross-review/SKILL.md` | changed | Structured findings, automatic rotation, new refusals and exit codes |

The new files under `~/.codex` each need their own `!` entry in `.chezmoiignore`, because that
tree is an allowlist.

## 5. Daemon lifecycle

**LaunchAgent.** A chezmoi-managed LaunchAgent (`be.netronix.codex-app-server`) runs
`codex app-server daemon start` at login, because `bootstrap` installs no launchd job (F19).
The environment it hands to the daemon contains no `HERDR_*` variable and no pane's working
directory. Its `PATH` covers the mise shims, `~/.local/bin` and Homebrew, so commands the
reviewer runs still find the project toolchains that an interactive shell would activate.
`AbandonProcessGroup` keeps launchd from reaping the daemon when `start` returns.
Verification is `codex-daemon check`: no daemon process carries a `HERDR_` variable.

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
- `restart`: the fix for a contaminated daemon. Stop the daemon, stop a surviving supervisor
  only if it is still a Codex daemon process, start through launchd, then `check`. This
  disconnects every open Codex TUI.
- `real-bin`: print the real Codex binary (see below).

**The `codex` launcher** is a script at `~/.local/bin/codex`. `~/.local/bin` comes first on
`PATH`, so the launcher shadows the Homebrew binary.

**Resolving the real binary.** The launcher and the existing `codex-code-mode-host` shim both
need the real Codex binary, and both resolve it the same way: the first `codex` on `PATH`
outside `~/.local/bin`, followed through symlinks. The shim currently uses `command -v codex`.
Once the launcher exists that returns the launcher itself, so the shim would find itself as the
"sibling" host and exec itself in a loop, and Codex's tool runtime would never start. The shim
changes with the launcher, in the same commit.

| Invocation | Launcher behaviour |
|------------|--------------------|
| Interactive start: no subcommand, `resume`, `fork` | `codex-daemon ensure`, then exec. If the daemon cannot be started, refuse and name `--no-daemon` as the deliberate escape. |
| Interactive start with `-c`, `--config`, `--enable` or `--disable` | Refuse, because these would silently run the session embedded (F10). `--no-daemon` makes the choice explicit and passes through. |
| Interactive start with an explicit `--no-daemon` | Pass through untouched: the operator-approved escape. |
| Interactive start with `--remote` | Refuse. A remote server runs its own hooks, so herdr could never learn the session's thread id (goal 3). |
| Every other subcommand (`exec`, `app-server`, `features`, `update`, …) | Pass through untouched. |

If `codex-daemon check` fails on an interactive start, the launcher warns but still starts. It
does not block ordinary Codex use; dispatch refuses instead (§7.3).

Herdr's managed hook exits inside the clean daemon (F13). It is not edited.

## 6. Pane ↔ thread identity

**Join key.** The `config.toml` template pins
`tui.terminal_title = ["thread-id", "thread-title", "current-dir"]` (F11). Every TUI on the
daemon therefore shows its thread id at the start of its title, from launch onwards - but only
ever as a 29-36 character PREFIX (F11/F21): Codex ALWAYS truncates the `thread-id` item to 29
characters plus `...`. Pane titles in herdr now start with that prefix;
that is the accepted cost. The prefix is resolved to a full thread id through
`xreview-rpc thread-resolve --prefix`, which asks the daemon's `thread/loaded/list` for the one
loaded thread that starts with it (F21). A prefix is never treated as a full id, and never
guessed.

**Pane-map hook.** `herdr-codex-pane-map.py` is registered as a second `SessionStart` entry in
`hooks.json`, beside herdr's. It runs inside the daemon and **reconciles all Codex panes**,
not only the one whose session is starting:

1. List herdr panes on the default socket.
2. For every pane with `agent == "codex"` whose title begins with an id prefix, compare it with
   the pane's `agent_session`. If the session already starts with that prefix, nothing to do.
   Otherwise resolve the prefix to a full id, and run
   `herdr pane report-agent-session <pane> --source herdr:codex --agent codex --agent-session-id <full-id> --seq <ns>`.
   Every pane resolves through `xreview-rpc thread-resolve --prefix`, except the one pane (if
   exactly one) whose title prefix is a prefix of the hook's own `session_id`: that id is
   already known for free, but one matching pane does not prove the prefix names only THIS
   thread - two threads can share a 29-character prefix (item 21/F13). A UUIDv7 prefix that
   long (48-bit millisecond timestamp plus 46 random bits) is treated as *effectively* unique,
   never as *provably* unique, so the shortcut still confirms through
   `xreview-rpc thread-resolve --prefix` before trusting itself: if the resolver returns exactly
   `session_id`, report it; any other answer - a different id, a refusal as ambiguous or not
   found, or none at all because the resolver is missing, the daemon unreachable or the call
   timed out - reports nothing for that pane. The next `SessionStart` or `--reconcile` retries.
3. If the hook input's `session_id`'s prefix is not yet on any title, retry for about 5 s while
   the title catches up, then stop.
4. Never report a prefix as if it were a full id, and never report an id that did not resolve
   from a title. That rules out guessing for sub-agent threads, and for anything not visibly on
   screen; a resolver that is missing, fails or times out reports nothing for that pane, the
   own-session shortcut included.

Because every `SessionStart` reconciles everything, one contaminated report, for example from
herdr's managed hook in a daemon that carries a pane's environment, is repaired by the next
session start anywhere. `herdr-codex-pane-map.py --reconcile` runs the same pass on demand,
without hook input; the rollout (§10) uses it.

The hook always exits 0, stays well inside the 10 s hook timeout, and never blocks a session.
It resolves `herdr` by absolute path, because the daemon's `PATH` is launchd's.

## 7. xreview transport

### 7.1 `xreview-rpc`

A Python 3 client using only the standard library. It connects to the daemon socket (F1),
completes the handshake (F2), declines any server-initiated approval request, and exposes:

- `thread-start --cwd <dir>`: creates a thread on the daemon and prints its id (F22).
- `thread-status --thread <id>`: whether the thread is loaded, and whether a turn is running
  on it.
- `thread-resolve --prefix <p>` (F21): the one loaded thread id starting with `<p>`. Refuses a
  prefix shorter than 13 characters or containing anything but `[0-9a-f-]`. Zero or several
  matches is an error; never a guess.
- `turn-start --thread <id> --input <file> --schema <file> [--known <file>]`: starts a turn
  with the findings schema, a read-only sandbox policy and approval `never` set on the turn
  itself. Prints the turn id. `--known` first records the thread's existing turn ids. A
  thread with no user message yet refuses `thread/turns/list` as "not materialized"; that is
  an empty baseline, not an error.
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
- **A new thread is created by xreview**, with `xreview-rpc thread-start --cwd <repo root>`,
  and recorded as the checkpoint thread. Its id is known from the start, so nothing is read
  back from a title. Every review turn sets read-only and approval `never` on the turn itself
  (§7.1), and the pane resumes the thread with the pane command's read-only flags.
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
The pane's old TUI is quit before the turn exists; the turn starts; then the pane resumes
onto the thread and replays it (F22).

1. **Preconditions, before anything is touched:**
   - `codex-daemon ensure` and then `codex-daemon check` pass. If the daemon carries a pane's
     environment, refuse. The message names the fix (`codex-daemon restart`) and its cost:
     every open Codex TUI disconnects and must be relaunched.
   - The repository's Codex pane exists: exactly one herdr pane with `agent == "codex"` and
     `cwd` equal to the repository root. `XREVIEW_PANE` overrides the choice.
   - That pane is not mid-turn: its `agent_status` is not `working` or `blocked`, and the
     thread its title shows is not running.
   - The existing guards pass: no project `.codex/`, and the round cap.
2. **Thread.** Use the pinned or recorded checkpoint thread. With none, create one with
   `xreview-rpc thread-start` and record it. Refuse if that thread is running a turn.
3. **Free the pane, before the turn.** If the pane's title prefix is a prefix of the thread's
   id (F11) and xreview put the pane on this thread under the current daemon generation, the
   pane stays as it is. Otherwise quit its TUI now (`ctrl+c` twice) and wait (bounded) for the
   shell. No keystroke ever reaches a TUI after the turn exists: a `ctrl+c` then would
   interrupt the review itself. If the pane closes or its session will not exit, refuse; no
   turn exists yet.
4. **Turn.** Build the packet as `<cross-review-request>` containing the reviewer instructions,
   the body, and the diff inline. Run `turn-start` with the findings schema (§7.5), and record
   `$state_dir/turns/<nonce>` as `<thread> <turn>`. From here on dispatch always succeeds and
   prints the nonce: the review runs whatever happens to the pane.
5. **Resume the pane, best effort.** If step 3 quit the TUI, run the Codex pane command with
   `resume <thread>` in the pane's shell; the TUI replays the running turn (F22). Wait
   (bounded, about 20 s) for the title to show the thread's prefix, then record the pane and
   report the thread to herdr. If that fails, warn on stderr that the review is running but
   not shown, and still exit 0.
6. **Archive** the superseded review threads, if any, but only once the pane shows the new
   thread; otherwise keep them for the next successful dispatch.

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
| Interactive `codex --remote` | The launcher refuses. |
| No Codex pane, or several | Refuse, list the candidates, and suggest applying the project layout or setting `XREVIEW_PANE`. |
| Pane mid-turn | Refuse before touching anything. |
| Pane closes or its session will not exit while being freed | Refuse. No turn exists yet. |
| Resumed pane never shows the thread | Warn; the review still runs and `collect` works. Superseded threads are kept for later archiving. |
| Checkpoint thread still running a turn | Refuse; collect the running turn first. |
| Refusal after the pane was freed (turn-start refused, a local failure) | Start a fresh Codex session in the pane, then refuse; the next dispatch resumes it onto the review thread. |
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
    - a new checkpoint thread comes from `thread-start`;
    - no keystroke reaches the pane after `turn-start`; the TUI is quit before it;
    - a pane that will not free refuses with no turn started; a pane that fails to resume
      after the turn only warns: the nonce is printed and the turn recorded;
    - a refusal after the pane was freed relaunches Codex in the pane;
    - no re-point when the title already shows the id;
    - exit codes 0, 1, 3 and 4;
    - receipt fields, old and new;
    - `round --reset` yields a fresh pane session, and a new thread, on the next dispatch.
- **`codex-launcher.test.sh`**: with a stubbed `codex-daemon` and a stub Homebrew binary:
  - interactive starts call `ensure` and exec the real binary;
  - a failing `ensure` refuses;
  - `-c` on an interactive start refuses;
  - `--remote` on an interactive start refuses;
  - `--no-daemon` and every non-interactive subcommand pass through untouched;
  - installed together with the `codex-code-mode-host` shim ahead of a stub Homebrew
    directory, the shim execs the stub's host and never itself;
  - the launcher never execs itself.
- **`herdr-codex-pane-map.test.sh`**: hook-input fixtures with a stubbed `herdr`.
  - Every Codex pane whose title id prefix differs from its session is reported.
  - A matching pane is not reported.
  - Titles without a title id prefix, and non-Codex panes, are ignored.
  - `--reconcile` works without hook input.
  - The hook never exits non-zero.
- **`codex-config.test.sh`**: `tui.terminal_title` is pinned with `thread-id` first, and
  `daemon_auto_start` stays false. `hooks.json` holds both hook entries, the edit is
  idempotent, and unrelated hooks survive.
- **`live-codex-daemon.test.sh`** (`# test-requires: unsandboxed, live daemon, live herdr`):
  automates the probes. In a scratch pane:
  - start a fresh Codex and read the thread id from the title;
  - start a turn with the schema through `xreview-rpc`;
  - assert the pane renders it from the first token and the result is structured;
  - F22: create a thread with `thread-start`, start a turn, then `codex resume` it in the
    pane; assert the pane shows the turn while it runs and its final answer;
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
5. Run `herdr-codex-pane-map.py --reconcile`. `herdr pane list` then shows every Codex pane
   with its own id.
6. Run one real dispatch in this repository. Confirm it renders live from the first token and
   that collect returns JSON.

## 11. Open questions

Resolved by probe on 2026-09-27, before planning:

- Pane-first works: another client can start a turn on a TUI-created thread before its first
  turn, and the pane renders it from the first token (F14, F15). The bootstrap-turn fallback
  is not needed.
- `bootstrap` installs no launchd job, so the LaunchAgent is our own (F19).

Still open, neither a gate:

- Whether `SessionStart` fires when a TUI resumes a thread the daemon already has loaded. The
  reconcile-on-every-`SessionStart` design and xreview's own report cover both answers.
- What happens when a thread is archived while a TUI is still attached to it. §7.3 archives
  only after the pane has moved off it, so the case does not arise.

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
- **Pane first** (the 2026-09-26 design): the pane created each fresh thread, and xreview
  started the turn only after polling the title proved the pane was watching. Superseded on
  2026-09-28. The title polling produced a run of races (stale titles, missed resets, failed
  reads), and F22 shows turn first loses nothing: the resumed pane replays the turn from its
  start. The one cost is a pane that fails to attach, which now leaves a review running
  unwatched rather than refused.
- **Only warning about a daemon that carries a pane's environment.** Rejected in review: it
  keeps corrupting herdr's view of other panes.
- **Transport-only change**, keeping the pane's current thread. Rejected: rotation stays
  manual and reviews accumulate in one thread.
- **Passing `--remote` through the launcher.** Rejected in review: herdr cannot map a session
  whose hooks run on another server.
- **A Rust client.** Rejected for now: the repository has no build step, and the client is
  small glue. Revisit it if the client gains a second consumer.

## 13. Consequences

- xreview depends on the daemon, and so does every interactive Codex start through the
  launcher. With the daemon unavailable, `codex --no-daemon` is the only way to start Codex.
- Interactive starts cannot take `-c` overrides without `--no-daemon`; settings go through
  `config.toml`.
- A daemon that carries a pane's environment blocks reviews until it is restarted, which
  disconnects every open Codex TUI.
- Pane titles lead with a title id prefix.
- `~/.local/bin/codex` shadows the Homebrew binary. Anything that needs the real binary must
  resolve it past `~/.local/bin`, as the code-mode host shim now does.
- Each checkpoint's first dispatch replaces whatever session the Codex pane had open.
- The Codex app-server protocol is marked experimental. `live-codex-daemon` is the tripwire,
  and a Codex update that breaks it blocks reviews until `xreview-rpc` is adjusted.
- Review threads are created and archived automatically. The Codex resume picker shows only
  the current checkpoint's review thread.
