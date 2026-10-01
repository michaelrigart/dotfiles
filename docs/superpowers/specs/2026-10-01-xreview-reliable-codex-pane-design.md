# xreview: a reliable Codex pane

**Status:** Approved
**Date:** 2026-10-01
**Builds on:** [`2026-09-26-xreview-codex-daemon-design.md`](2026-09-26-xreview-codex-daemon-design.md)
(§7.3 dispatch, §8 failure handling). This design replaces that spec's pane record and its
two-keystroke quit; everything else there stands.

## 1. Problem

Cross-reviews keep a live Codex view: the review turn plays in the repository's own Codex
pane while it runs. That view must stay. It must also stop costing Michael interventions:
pane handling, "the pane is ready" handshakes, and refused dispatches.

Measured from the Claude transcripts and Codex's log database (`~/.codex/logs_2.sqlite`):

- **The handshakes are history.** Every "fresh Codex session is ready" turn from Michael
  predates turn-first dispatch (2026-09-28). Since then no dispatch has needed one.
- **The remaining failures are one mechanism.** Since 2026-09-26, 140 real dispatches
  produced 11 "the review is running but not shown in pane" warnings and 6 "did not exit its
  session within 20s" refusals. 15 of the 17 fell in one 65-minute VM.Portal run on
  2026-09-29, alternating: a warning, then a refusal, then a warning.
- **Cause.** All nine TUIs that xreview resumed in that run stopped on an interactive screen
  that Codex shows before it loads a session. Codex's log shows each one fetch its startup
  tip, then wait 41 s to 19 min before connecting to the daemon. Six of them connected
  within three seconds of the *next* dispatch's two `ctrl+c`: those six dispatches are the
  six refusals. The keystrokes dismissed the screen and let the session start, rather than
  quitting it. The retry's `ctrl+c` then quit the now-running TUI and resumed it, and the new
  TUI stopped on the same screen. The other three were released some other way, most likely
  by hand. The Codex 0.159 binary holds two such screens: the "Update available" prompt
  and a resume directory chooser ("Use session directory" / "Use current directory"). The
  logs do not show which one it was. The update prompt is the likelier one: the daemon
  updates itself (0.157.0 to 0.159.3 in six days), while the Homebrew TUI lags until
  `brew upgrade`, so the prompt shows often.
- **The pane record is a secondary defect.** xreview writes `$state_dir/pane` only once a
  resume confirms. That is why a "not shown" is always followed by a full quit. Writing the
  record earlier would not help, because the stuck pane's title never shows the thread
  either.
- **Not the cause: the launcher PATH bug** fixed on 2026-10-01. Every Codex TUI is attached
  to the daemon today, including panes started straight from the Homebrew binary (checked
  with `lsof`): a TUI attaches to a daemon that is already running (F9). The launcher
  matters only when the daemon is down or `-c` is passed.

Three smaller defects sit on the same path:

- **Restored panes lose the reviewer flags.** herdr restores every Codex pane as a bare
  `codex resume <id>` (`resume_agents_on_restore = true`). The pane command's
  `--sandbox read-only --ask-for-approval never` is lost. All 13 Codex panes restored on
  2026-10-01 run that way, and turns typed into such a pane run `workspace-write` (thread
  `01a0e1d2…`). xreview's own turns stay read-only, because each sets its sandbox itself.
- **Harness worktrees have no pane.** `find_pane` matches a pane whose `cwd` equals the
  repository root, and a harness worktree (`.claude/worktrees/<name>`) never has one. Two
  dispatches were refused this way (tagteam 2026-09-28, chezmoi 2026-09-30).
- **The round counter reads the branch at run time.** `bump_round` and `current_round` read
  `HEAD` when they run, not the branch `dispatch` recorded. In this shared checkout, a branch
  switch mid-dispatch moves another branch's counter (safe-autonomy residual).

## 2. Goals

1. **No pre-session screen in a pane xreview resumes.** Known screens are prevented by
   configuration. An unknown one is reported by name, never guessed at.
2. **The pane frees reliably.** A dispatch refuses only when the pane truly will not give
   way. It never refuses because the TUI happened to be on a screen.
3. **No re-launch of a pane that is already right.** A pane that shows the review thread on
   the current daemon stays as it is, whether or not xreview saw it confirm.
4. **A harness worktree reviews in its repository's Codex pane.** Dispatches that share a
   pane never interleave.
5. **A resumed reviewer thread stays read-only**, including after a herdr restore.
6. **Rounds are counted against the branch the dispatch recorded.**
7. **Nothing new to approve.** No new prompts, no settings changes. `xreview` is invoked
   exactly as today, and its existing stderr lines keep their exact text.

### Non-goals

- Headless review (`codex exec`), and any extra Codex tab or pane for a review. Both were
  rejected by Michael (2026-09-30).
- Killing the pane's Codex process. See §8.
- Answering a pre-session screen with keystrokes once the turn exists. See §8.
- Changes to the receipts, the guards, the push guard, or what the safe-autonomy evaluation
  measures.

## 3. Verified facts

Probed on 2026-10-01 against Codex 0.159.3 and herdr 0.9.3.

| # | Fact |
|---|------|
| G1 | `herdr pane process-info --pane <id>` returns the pane's `shell_pid`, `foreground_process_group_id`, and each foreground process's `pid`, `argv` and `cwd`. A pane at its shell prompt has `foreground_process_group_id == shell_pid`. |
| G2 | `herdr pane read <id> --source visible --lines <n> --format text` returns the pane's rendered screen as plain text. |
| G3 | `daemon.pid` (JSON) carries the daemon server's `pid`. With `lsof -a -U -p <pid>`, an attached TUI holds a unix socket whose peer (`->0x…` in the NAME column) is one of the daemon's own sockets (the DEVICE column of `lsof -a -U -p <daemon pid>`). All four TUIs checked had exactly one such peer. |
| G4 | herdr's restore runs `codex resume <id>` through the pane's shell. The process's `argv[0]` is the real binary's resolved path, which only the launcher's `exec "$real" "$@"` produces. So the restore goes through `~/.local/bin/codex`. |
| G5 | A Codex thread's rollout (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl`) holds one `turn_context` per turn, whose `payload.sandbox_policy.type` and `payload.approval_policy` record that turn's sandbox and approval policy. |
| G6 | A TUI started with no sandbox flags runs its turns `workspace-write` (thread `01a0e1d2…`: TUI turns `workspace-write`, then xreview's turns `read-only`). |
| G7 | Codex 0.159 reads `check_for_update_on_startup` from `config.toml`. |
| G8 | On a Codex pre-session screen, one `ctrl+c` pair lets the session start. Once the session runs, a second pair quits it (2026-09-29: 6 refusals, 6 successful retries). |
| G9 | On macOS, a `/usr/bin/python3` child that takes `fcntl.flock(fd, LOCK_EX)` on a descriptor inherited from bash leaves the lock held after the child exits. A second locker gets `EWOULDBLOCK` until bash closes the descriptor, and then succeeds. |

Probed by the plan's first task, before anything relies on them:

| # | To verify | If it fails |
|---|-----------|-------------|
| V1 | `codex -C <root> resume <id>`, run from a shell in another directory, opens the thread with no directory chooser. | Drop `-C` and amend §4.1. Detection (§4.5) still reports the chooser. |
| V2 | A TUI held at the directory chooser (a resume from another directory, without `-C`) is quit by the ladder (§4.4) within its bound, and the shell then runs a `herdr pane run` command. | Stop and amend §4.4. |

## 4. Design

### 4.1 Prevent the known screens

- **The update prompt.** The managed `config.toml` template pins
  `check_for_update_on_startup = false`. Homebrew owns Codex upgrades, through the Brewfile.
  The setting goes in `config.toml` rather than on the pane command, because any `-c`
  override makes a TUI leave the shared daemon (F10). That makes it global: no Codex
  session shows the prompt any more.
- **The directory chooser.** xreview resumes with
  `<pane command> -C <review root> resume <thread>`. The review thread is created with
  `--cwd <review root>`, so the session's directory and the current one always agree,
  wherever the pane's shell happens to be.

### 4.2 Find the repository's pane

The review root is `git rev-parse --show-toplevel`, as today. The **pane root** is the
directory whose Codex pane serves it:

- For a harness worktree, it is the registered worktree that holds it: the worktree `W` in
  `git worktree list --porcelain`, other than the review root itself, whose
  `W/.claude/worktrees/` contains the review root. If several qualify, the longest `W`
  wins. This covers a harness worktree of the main checkout and one created inside a `wt`
  sibling (`/repo-feature/.claude/worktrees/x`, whose common git dir is still
  `/repo/.git`).
- For anything else, including a `wt` sibling (which has its own workspace and pane), it is
  the review root.

`find_pane` selects the Codex panes whose `cwd` is the pane root, or lies under
`<pane root>/.claude/worktrees/`. The second form keeps the owner's pane findable if a TUI
started with `-C <harness worktree>` reports that directory as its cwd. `XREVIEW_PANE`
still picks among valid candidates only. Zero or several candidates refuse, as today.

A harness worktree and its owner share one pane, and their reviews take turns in it. The
pane lock (§4.9) serialises their dispatches. A dispatch that gets the lock while the other
review's turn is still running refuses as "mid-turn", which is the existing refusal and its
existing remedy.

### 4.3 Keep a pane that is already right: an observation, not a record

`$state_dir/pane` and `daemon_gen` are removed. The fast path is taken when both hold:

1. the pane's title prefix is a prefix of the review thread's id (F11/F21), as today;
2. the pane's foreground Codex process (G1) holds a connection to the running daemon (G3).

The second condition is the observation the record stood in for. A TUI left over from
before a daemon restart has no connection to the new daemon. A TUI running its own
embedded server (`-c`, `--no-daemon`, the real binary run directly) never has one. Any
read that fails (`process-info`, `daemon.pid`, `lsof`) counts as "not observed", and the
slow path runs. A resume that confirmed after xreview stopped waiting is now kept by the
next dispatch, rather than quit and relaunched.

### 4.4 Free the pane: a bounded `ctrl+c` ladder

This runs only before the turn exists, as today (C1: after `turn/start`, no keystroke ever
reaches the pane).

1. **Guard, failing closed.** Before any keystroke, xreview must know which threads the
   pane's TUI is on or about to open, and that none of them is running a turn:
   - the thread its title shows, if any (today's check);
   - the thread its foreground Codex argv resumes (`resume <id>`), read with G1. A TUI that
     is still on a pre-session screen has no thread in its title. The first `ctrl+c` pair
     would start its session, and the second pair's first `ctrl+c` would interrupt that
     thread's running turn.

   Refuse, before any keystroke, when any of these holds:
   - one of those threads is running a turn ("mid-turn", as today);
   - `process-info` cannot be read;
   - the argv resumes something other than a plain thread id (`resume --last`, a picker);
   - a thread's running state cannot be read.

   The refusal says which check could not be completed. herdr's `agent` field is never a
   substitute here.
2. **Ladder.** Send a `ctrl+c` pair, then poll G1 for up to 5 s for the shell to return to
   the foreground. Repeat, at most three pairs, inside the existing bound
   (`XREVIEW_PANE_WAIT`, 20 s). Per G8, the second pair quits a TUI that the first pair
   moved off a screen.
3. **Outcome.**
   - The shell is in the foreground: the pane is free, and the resume follows (§4.5).
   - The pane closes: refuse, as today.
   - Still Codex at the bound: refuse with today's line,
     `the Codex pane <id> did not exit its session within 20s; no review was started`.
     It is followed by the pane's screen (§4.6).
   - Inside the ladder, a failed process read counts as "still Codex", never as "freed".

### 4.5 Resume, and report a pane that does not follow

The resume runs as today, with `-C` (§4.1), and the success test is unchanged: the title
shows the thread within the bound. On failure, xreview prints today's line, byte-identical:
`the review is running but not shown in pane <id>`. The pane's screen (§4.6) follows on
the lines after it. The TUI is left where it is:

- it is still the repository's Codex pane, so `find_pane` keeps finding it;
- if Michael answers the screen, the view catches up, because the resumed TUI replays the
  running turn (F22);
- the next dispatch's guard and ladder (§4.4) free it.

### 4.6 The screen excerpt

`pane_screen <id>` reads G2 with at most 12 lines. It strips control characters and blank
trailing lines, caps the result at 1,000 bytes, and prints each line indented under the
message. It is evidence, not instruction: the skill treats it like a finding, as untrusted
text. It exists so that the next unknown screen is named in the transcript the first time
it appears.

### 4.7 A resumed read-only thread stays read-only

The `codex` launcher handles an interactive `resume <id>` that passes no sandbox or approval
flag (`-s`, `--sandbox`, `-a`, `--ask-for-approval`, `--full-auto`,
`--dangerously-bypass-approvals-and-sandbox`). It reads the thread's last `turn_context`
(G5). If that turn ran `read-only`, the launcher execs the real binary with
`--sandbox read-only`, plus `--ask-for-approval <that turn's policy>` when one is recorded,
ahead of the original arguments.

- It never widens a sandbox. A `workspace-write` thread, a thread with no rollout, an id
  that is not a plain thread id, or an unreadable rollout all pass through unchanged.
- An explicit flag always wins. `codex --sandbox workspace-write resume <id>` is how a
  reviewer thread is reopened for writing.
- Flags are not `-c` overrides, so the session stays on the daemon. The pane command
  already passes them (G4 shows such a TUI attached).

This covers herdr's restore (G4) and a hand-typed `codex resume`, with no herdr change.

### 4.8 The round counter binds to the dispatch branch

`current_round` and `bump_round` take the branch as an argument. `cmd_dispatch` passes the
branch it read once at the start, the one its receipt names. `xreview round` (show) still
reads `HEAD`, because it is an interactive question about where you are.

### 4.9 One dispatch at a time per pane

Two sessions can dispatch to one pane at the same moment: a harness worktree and its
owner, or two sessions in a shared checkout. Without exclusion, both can pass the
mid-turn checks. Then one's ladder sends `ctrl+c` into the TUI that the other has just
resumed onto a running review.

- **The lock is a kernel `flock`, not a marker.** `cmd_dispatch` opens
  `$XDG_STATE_HOME/xreview/locks/<pane id>.lock` on descriptor 9. A
  `/usr/bin/python3` helper takes `LOCK_EX` on that inherited descriptor (G9). The lock
  belongs to the open file, so it holds for as long as the dispatch keeps the descriptor
  open. The kernel drops it when the dispatch closes the descriptor or exits, crashes
  included. There is no pid, no stale state and no reclamation step. Two dispatches can
  never both hold it. The lock file is never deleted: deleting a `flock` file lets a
  waiter lock an unlinked inode while a newcomer locks a new one.
- **Scope.** The lock is taken right after `find_pane`, before any pane check. It is
  released once the resume step ends (confirmed or warned) by closing the descriptor, and
  by process exit on every other path. Every pane check in §4.4 runs inside it, so the
  checks see the state left by the previous holder. Nothing started inside the scope
  outlives the dispatch: herdr, `xreview-rpc`, `ps` and `lsof` all exit. The daemon is
  started earlier (`codex-daemon ensure`), by launchd, and inherits nothing. Every child
  the scope does start runs with the descriptor closed anyway (`9>&-`), so a future
  long-lived child cannot pin the lock.
- **Waiting.** The helper polls `LOCK_EX | LOCK_NB` until it succeeds or
  `XREVIEW_LOCK_WAIT` runs out. The default, 90 s, is above one holder's worst case: a
  20 s ladder, the turn start and a 20 s resume. At the bound, refuse:
  `another dispatch is using the Codex pane <id>; no review was started`.
- **Not locked.** `collect` and the other subcommands never touch the pane, so they take no
  lock. Pane ids are unique within one herdr server, and xreview talks to one server.

## 5. Failure handling

| Condition | Behaviour |
|-----------|-----------|
| Pane on a pre-session screen, before the turn | The ladder: pair one moves it off the screen, pair two quits it. The dispatch proceeds. |
| Pane on a pre-session screen, resuming a thread with a running turn | Refuse as mid-turn, before any keystroke. |
| Pane will not quit within the bound | Refuse as today, plus the pane's screen. No turn exists. |
| Resumed TUI does not show the thread | Warn as today, plus the pane's screen. The review runs, `collect` works, and the TUI is left in place. |
| Pane already on the thread, TUI connected to the daemon | No keystroke and no resume. |
| Pane on the thread, TUI not connected (daemon restarted, embedded server) | Ladder, then resume. |
| Process, `daemon.pid` or `lsof` read fails on the fast path | Not observed: the slow path runs. |
| Pane's process or a thread's running state unreadable before the ladder | Refuse before any keystroke, naming the check. |
| Pane's argv resumes no plain thread id | Refuse before any keystroke. |
| Process read fails inside the ladder | Counts as "still Codex". |
| Another dispatch holds the pane | Wait up to 90 s, then refuse. A crashed holder's lock is already gone (the kernel released it). |
| Harness worktree | Uses the pane of the registered worktree that holds it. Zero or several candidates refuse as today. |
| `codex resume <id>` of a read-only thread, no flags | Launcher adds the thread's sandbox and approval. |
| Rollout missing or unreadable at resume | Launcher passes through unchanged. |

## 6. Testing

Every suite keeps its existence check (exit 2 when its subject is missing).

- **`xreview.test.sh`.** The `herdr` stub gains `pane process-info` and `pane read`, and an
  `lsof` stub reports socket peers. New cases:
  - a TUI that ignores the first `ctrl+c` pair and quits on the second: the dispatch
    succeeds without refusing;
  - a TUI that never quits: refuse with the screen excerpt, and no `turn/start`;
  - fast path: the title matches and the TUI holds a daemon connection, so no keystroke
    and no resume;
  - the title matches but the TUI holds no daemon connection, or `lsof`/`daemon.pid`
    cannot be read: ladder, then resume;
  - the pane's argv resumes a thread that is running: refuse before any keystroke;
  - `process-info` fails, a running-state read fails, or the argv is `resume --last`:
    refuse before any keystroke, naming the check;
  - two dispatches to one pane, the second started while the first holds the lock: the
    second waits, then refuses as mid-turn, and no keystroke of the second follows the
    first's `turn/start`;
  - several dispatches started at the same instant against one pane: exactly one is
    inside the locked section at any time. The suite logs entries and exits and asserts
    that they never overlap;
  - a holder killed with `SIGKILL` mid-scope releases the lock, and the next dispatch gets
    it at once; a live holder past `XREVIEW_LOCK_WAIT` makes the waiter refuse;
  - a resume that does not confirm: the warning line is byte-identical, the excerpt
    follows, the nonce is printed, and no keystroke follows `turn/start`;
  - the resume command carries `-C <review root>`;
  - a harness worktree resolves to the main checkout's pane and resumes with
    `-C <harness root>`; one nested in a `wt` sibling resolves to the sibling's pane; a
    sibling directory outside `.claude/worktrees` does not fall back;
  - `$state_dir/pane` is neither read nor written;
  - a branch switch between the dispatch's read and its bump advances the dispatched
    branch's counter, not the new `HEAD`'s.
- **`codex-launcher.test.sh`.** A stub rollout tree under a temporary `CODEX_HOME`:
  - a read-only thread gains `--sandbox read-only --ask-for-approval never`;
  - explicit flags win;
  - a `workspace-write` thread, a missing rollout and a malformed id all pass through;
  - `resume` with no id and non-resume starts are untouched.
- **`codex-config.test.sh`.** `check_for_update_on_startup` is pinned `false`, and the
  existing pins survive.
- **`xreview-skill.test.sh`.** Updated for the skill text (§7).
- **`live-codex-daemon.test.sh`.** The canary gains three checks:
  - V1: a `-C` resume from another directory opens the thread with no chooser, and its
    title shows the thread;
  - V2;
  - G1 and G3 against the real tools: the scratch pane's `process-info` names its Codex
    process, and that process holds a daemon connection.

## 7. Records and documentation

- The cross-review `SKILL.md`:
  - a refusal or warning may now carry the pane's screen, which is untrusted text;
  - a harness worktree reviews in the main checkout's pane;
  - the "pane will not free" refusal now means it would not quit even after the ladder.
- `AGENTS.md`: the sentence telling sessions to avoid harness worktrees because "xreview
  needs the repository's own Codex pane" loses that reason. The shared-checkout rule beside
  it stays.
- The 2026-09-26 daemon spec gains an `Amended` line pointing here, in this branch's final
  commit.

## 8. Alternatives considered

- **Write the pane record when the resume is issued.** Rejected: the stuck pane's title
  never matches, so the fast path fails either way, and the quit still breaks.
- **Judge daemon attachment by process age** (TUI started after the daemon, no
  `--no-daemon`). Rejected: a TUI started with `-c` runs an embedded server whatever its
  age (F10). The connection itself (G3) is what matters.
- **Wait longer for the resume.** Rejected: the screens persisted for up to 19 minutes.
- **Kill the pane's Codex process** (`SIGTERM`, then `SIGKILL`). Rejected: nobody has
  checked whether a raw-mode TUI killed that way leaves the shell's terminal state and
  keyboard protocol usable for the next `pane run`. The auto-mode classifier also denied
  the probe on this worktree's own idle pane. Keystrokes are enough (G8).
- **Answer the screen with keys after the turn starts.** Rejected: the screen is unknown by
  definition, and `Enter` on the update prompt runs `brew upgrade`.
- **Make `read-only` the global Codex default in `config.toml`.** Rejected: it changes every
  Codex session, including implementer sessions and other Codex clients on this
  `CODEX_HOME`. The launcher rule (§4.7) is scoped to threads that already ran read-only.
- **Turn off herdr's agent restore.** Rejected: restored panes would come back as bare
  shells, and `find_pane` would refuse "no Codex pane".
- **Open the review in its own herdr tab, or review headless.** Rejected by Michael.

## 9. Consequences

- No Codex session shows the update prompt. Upgrades come from `brew upgrade`.
- `$state_dir/pane` is no longer used. Old files are left in place and ignored.
- A harness worktree's reviews and its owner's reviews share one pane and take turns in it.
  A dispatch can wait up to 90 s for another to finish with the pane.
- Reopening a read-only thread for writing needs an explicit `--sandbox` flag.
- xreview depends on `herdr pane process-info` and `herdr pane read` (herdr 0.9.3), and on
  `lsof`. The stubbed suite pins their shapes, and the live canary re-checks them. Without
  `process-info`, every dispatch that needs the slow path refuses, by design (§4.4).

## 10. Rollout

Michael merges and runs `chezmoi apply`. The launcher and xreview take effect immediately.
The config pin takes effect at each TUI's next start. No daemon restart is needed. The first
dispatch afterwards in each repository takes the slow path once, because no pane record
exists to trust. That is expected, not a regression.
