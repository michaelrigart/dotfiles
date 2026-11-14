# xreview reliability: an MCP barrier that can settle

**Status:** In progress (branch `fix/xreview-reliability`; no MR, a dotfiles line)
**Date:** 2026-11-14
**Sign-off:** the driver session, on Michael's delegation, 2026-11-14: D1 yes, D2 B (no change to
the pane step; the signal fallback is kept as the structural option), D3 not built (§9). Codex
spec review: approve in round 2 (`xr-1794648428-d416cc11`; round 1 `xr-1794648330-6c1c72a4`,
one P2, fixed).
**Branch:** `fix/xreview-reliability`, in the `wt` checkout `~/.local/share/chezmoi-fix-xreview-reliability`,
from `main` at `4c76ec4`
**Source:** item 24 of the 2026-11-11 agent setup review: "the MCP barrier waits only on `starting`
or `notStarted` (17 failures); quit the pane with SIGTERM instead of the ctrl+c ladder (28
failures, cause inferred); escalate after a second identical refusal." Approved by Michael on
2026-11-12, to run after `fix/xreview-trust`.
**Related:** `2026-10-01-xreview-reliable-codex-pane-design.md` (§4.4 the ladder and its
2026-10-15 barrier amendment, §8 the rejected kill), `2026-11-12-xreview-trust-design.md`,
`2026-11-13-instruction-weight-design.md` (part C: every refusal ends with its next step).

## 1. Why

Item 24 names three fixes. This spec counts each failure first, and builds only for those that
still occur or can come back.

## 2. What failed (measured)

Every Bash call whose first command was `xreview`, in the Claude Code transcripts on this Mac
from 2026-09-19 to 2026-11-14: 5,292 calls, 2,117 of them `dispatch`. "Incident" means one
episode in one session; its refusals are the retries within it.

| Failure | Refusals | Incidents | Dates | How each incident ended | Still live? |
|---|---|---|---|---|---|
| Pane did not exit its session within 20 s | 43 | 15 | 10-13 to 11-04 | Michael quit Codex and started a new pane, every time. The longest ran 8 h overnight: the agent re-dispatched hourly. | Not seen since 11-04 (§2.1) |
| MCP barrier: a server's `runtimeStatus` stays null for 30 s | 20 | 8 | 11-01 to 11-11 | `round --reset` onto a fresh thread (5), or a later round (3) | Not on today's daemon, but can come back (§2.2) |
| No Codex pane for the repository | 21 | 18 | 10-12 to 11-08 | Michael opened the session in its Herdr workspace. 3 followed a pane that failed to exit. | Correct refusal, not a defect |
| Daemon carries a pane's environment | 7 | 2 | 11-12 | Michael restarted the daemon | Removed: 0 since the daemon started clean on 11-12 |
| Thread archived when cold-loaded | 3 | 3 | 10-13 to 10-21 | A new round | 0 since 10-21 |
| Background `collect` exited 1 | 15 of 1,966 | 15 | 09-27 to 11-06 | Varied | Outputs gone; not classifiable |
| `collect`: "ambiguous: no turn on record" | 2 | 1 | 11-04 | Reported | Too few to design for |

Other refusals counted (the size cap, 24; usage errors) are not reliability failures.

**Repeated identical refusals.** Streaks of the same refusal in one session: pane exit up to 17,
MCP up to 4, daemon environment 3 and 4. All of them predate part C of the instruction weight
line (merged 2026-11-14). Since part C, each of those refusals ends either with
"Michael's call: report this and stop" (pane exit, daemon environment, no pane) or, for the MCP
one, goes away under §3.1.

### 2.1 The pane that will not exit

- Every one of the 43 refusals showed the same screen: the idle composer ("Ask Codex to do
  anything"), not the stale "turn running" footer that the 2026-10-15 amendment diagnosed. The
  cause is unknown: the daemon's logs keep about two days, and none of the incidents is in them.
- They fell on Codex 0.162.1, 0.164.0 and 0.166.0, and clustered by day (six days carry all
  15 incidents; on 11-04, five repositories within three hours).
- Since 11-05 (Codex 0.167.0 onward), 283 dispatches started a fresh thread, and each of them
  quit the pane's TUI first. None failed. So a Codex upgrade most likely removed it (inferred),
  but nothing explains it, so it can come back.
- Each incident cost a line until Michael restarted the pane by hand. Part C now makes the agent
  stop at the first refusal instead of retrying, but the line still waits for Michael.

### 2.2 The barrier that cannot settle

- The 2026-10-15 barrier holds `turn/start` until every MCP server's `runtimeStatus` is
  `connected`, `authenticationRequired`, `failed`, `cancelled` or `disabled`; anything else, null
  included, holds for up to 30 s, then refuses.
- The app-server schema (Codex 0.169.0, `ListMcpServerStatusResponse`) defines `runtimeStatus` as
  `notStarted | starting | connected | authenticationRequired | failed | cancelled | disabled`,
  or null "when unavailable or the configuration changed". In all 20 refusals the null held for
  the full 30 s.
- The incidents named only servers disabled in Codex's configuration (`node_repl`, `cua_repl`,
  `codex_app`).
- A probe on today's daemon (up since 2026-11-12) read every disabled server as `disabled`, on a
  fresh thread and on the same thread cold-loaded (archive, unarchive, resume). The one enabled
  server, `codex_apps`, read `starting` from the first poll and `connected` about 1 s later. So
  a starting server reports `starting`, never null.
- Inferred: null comes from a configuration change applied under a running daemon, and lasts
  until the daemon restarts. That restart disconnects every TUI and is Michael's.

## 3. Design

### 3.1 The barrier holds only on a server that is starting (D1)

`mcp_barrier` in `xreview-rpc` holds while some server's `runtimeStatus` is `starting` or
`notStarted`, and no longer. Null, a missing field and any other value let the turn start.

- The refusal after 30 s keeps its text, and names only the servers still `starting` or
  `notStarted`.
- An empty list, a list error, an unreadable answer and the 30 s bound behave as today.
- What it keeps: the race the barrier exists for (a turn started while a server is `starting`)
  is still held, and that is the only state measured on a cold load.
- What it gives up: a server that reports null while it is in fact starting would no longer be
  waited for. No such status has been seen.

### 3.2 The pane step stays as it is; a signal fallback is the option (D2)

**Ruled B: not built.** The pane step, the ladder and its refusal are unchanged. The reasons:
- No incident in 283 fresh-thread dispatches since 11-05.
- The kill's effect on the live view is unmeasured. The 2026-10-01 spec rejected it for that
  reason, and the probe was refused to an agent.

**When to revisit.** A pane-quit refusal ("did not exit its session") recurs, in particular
after a Codex upgrade. Before building the option:
1. Read the evidence while the daemon's logs still hold it, within about two days: the screen
   the refusal printed, the Codex version, and the daemon's log rows for the pane's thread
   (`~/.codex/logs_2.sqlite`).
2. Michael runs the hand check: on an idle Codex pane, `kill -TERM -- -<foreground group>` (the
   group from `herdr pane process-info --pane <id>`), then the next dispatch. Does the shell
   come back usable, and does the resume show the review? That measures what this spec could
   not.

**The option, as reviewed by Codex.** When the ladder ends with Codex still in the foreground,
`pane_quit` signals the TUI before it refuses:

1. **The TUI's identity** is its leader's pid together with that process's start time
   (`ps -o lstart=`), read once from the observation the guard judged, before the first
   `ctrl+c`. A pid alone is not an identity: a replacement process can reuse it.
2. Re-read `process-info` and the leader's start time. Go on only if the foreground process
   group is still led by the same pid, that process is Codex with the same start time, and the
   group is not the shell's. A start time that cannot be read counts as a mismatch.
3. Send `SIGTERM` to that process group. Poll for the shell to return, for up to
   `XREVIEW_RUNG_WAIT` (5 s).
4. Still not free: re-check as in step 2, send `SIGKILL`, and poll the same way.
5. Still not free, or a check in step 2 or 4 fails: refuse with today's message, which part C
   left as it is ("…did not exit its session within 20s; no review was started. Michael's call:
   report this and stop."). The screen follows, as today.

**Rules that do not change:**
- Signals, like keystrokes, are sent only in `pane_quit`, and only before the turn exists
  (C1 of the 2026-10-01 spec, extended to signals).
- The guard has already confirmed that no thread the TUI is on or about to open is running a
  turn, so the signal ends a client and never a review.
- The ladder stays first, unchanged. It succeeds in every measured case but the 43, and it exits
  through Codex's own quit, which restores the terminal.

**Bound.** At most 30 s in the pane step (today 20 s), within dispatch's 300 s tool timeout.

**Accepted limit.** The start time has one-second resolution. A replacement passes only if it
reuses the pid and starts in the same second the original started, so the original would have
to start, be observed, exit and have its pid come back within one second.

**The terminal after a signal (not measured).** `SIGKILL`, and possibly `SIGTERM`, ends the TUI
without restoring the terminal: raw mode, the alternate screen and the keyboard protocol may be
left as Codex set them. The 2026-10-01 spec rejected the kill for exactly that reason, unmeasured,
and the auto-mode classifier refused the probe to an agent on this checkout's own idle pane,
then and again on 2026-11-14. What bounds the risk:
- The pane resume is already best effort (§4.5 of the 2026-10-01 spec). If the shell cannot run
  `codex … resume`, dispatch warns "the review is running but not shown", and the review and
  `collect` go on.
- The new TUI sets its own modes when it starts.
- Worst case, Michael resets the pane by hand, as he restarts it by hand today, but the review
  itself is no longer lost.

**How the signal is sent.** Through `env kill`, so that the suite's stub on `PINNED_PATH`
receives it. In production `PATH` is pinned and resolves the system `kill`. The suite's panes
are fake, and a real signal to a stub's process-group number could reach an unrelated process.

**Measured for the option (2026-11-14, outside the sandbox, where `xreview` runs).**
`ps -o lstart= -p <pid>` prints the same start time on every read of a live process, to the
second, and exits 1 for a pid that does not exist. Inside the sandbox `ps` is not permitted at
all, so the suite would stub it on `PINNED_PATH`, like `kill`.

**The option's tests.**
- K1: a TUI that ignores `ctrl+c` and exits on `SIGTERM`. Dispatch succeeds, with one TERM to
  the foreground group and no KILL, and the pane resumes.
- K2: a TUI that also ignores TERM and dies on KILL: TERM, then KILL, then success.
- K3: a TUI that quits on `ctrl+c` gets no signal at all.
- K4: before TERM and again before KILL, each of these sends no signal and ends in the refusal:
  another group, the shell's group, the same pid with another start time, an unreadable start
  time.
- K5: when nothing frees it, today's refusal, unchanged, after TERM and KILL.
- K6: no signal once the turn exists (a failed resume).
- The existing `STUCK_TUI` rows keep a stub that ignores signals too.

### 3.3 No tool-side counter for repeated refusals (D3)

Not built. Since part C, every refusal that streaked ends with Michael's call, and §3.1 removes
the MCP one. The refusals left with an action clause are waits ("another dispatch is using the
Codex pane", "mid-turn"), where a repeat is the expected path while a long review holds the
pane. A counter would either repeat what those messages say, or stop a legitimate wait.

## 4. Non-goals and anti-goals

- No change to refusal texts, the skill or its three refusal rules, the review loop, guards or
  prompts.
- No change to the pane step (D2).
- No headless review, no second pane, no daemon restart by an agent.
- Not item 39 (slicing, delta packets, thread housekeeping).
- Anti-goal: anything that changes the working path. The ladder and the barrier's wait on
  `starting` stay as they are.

## 5. Alternatives

| Alternative | Status |
|---|---|
| Signal the TUI instead of the ladder (item 24's wording) | Rejected |
| Type `/quit` and Enter as a fourth rung | Rejected |
| Leave the pane step as it is, since it has not failed since 11-04 | Adopted (D2 B) |
| A signal fallback after the ladder | The option, if pane-quit refusals return (§3.2) |
| Treat a null status as settled only for servers disabled in `config.toml` | Rejected |
| Restart the daemon when the barrier sees null | Rejected |
| A counter that adds Michael's call on a second identical refusal | Rejected (D3) |

## 6. Tests

Table-driven, one row per rule. Each row passes the revert check.

| Suite | Row | Catches |
|---|---|---|
| `xreview-rpc` | MB2 rewritten: `starting` and `notStarted` hold, then refuse at the bound; null, a missing field and an unknown value start the turn at once | A barrier that waits on a status that cannot settle |
| | MB (the mixed list): the refusal names `node_repl=starting` and not the null server | A refusal naming servers it does not wait for |

## 7. Records

- The 2026-10-01 spec gets a dated amendment under §4.4, after its 2026-10-15 note: the barrier
  now holds only on `starting` and `notStarted` (this spec, §3.1). No point-in-time text is
  rewritten.
- The pane step's option and its revisit condition live here (§3.2), not in the 10-01 spec.

## 8. Rollout

- About 3 lines of non-test code, in `xreview-rpc`. That is a small change, but the brief asked
  for a spec and Codex reviews, so it gets a plan too.
- Deploys at `chezmoi apply`. No state, receipt, packet or schema changes, so in-flight reviews
  are unaffected.
- Pre-merge: `./tests/run.sh --changed` (the heavy `xreview` suite is selected) and a full-range
  Codex pre-merge review.
- Rollback: revert the line and apply.

## 9. Decisions

Ruled by the driver session on Michael's delegation, 2026-11-14.

- **D1, the barrier (§3.1): yes.** Hold only on `starting` and `notStarted`. It removes a
  refusal that can never resolve on its own, with no measured cost.
- **D2, the pane step (§3.2): B, no change.** The options were:
  - A (the line's recommendation): a signal fallback after the ladder, TERM then KILL. At
    worst it turns the measured failure into a review without the live view. About 35 lines.
  - B (ruled): no change. The failure has not occurred in 283 fresh-thread dispatches since
    11-05, the kill's effect on the live view is unmeasured, and the probe was refused to an
    agent. A stays the structural option, with the revisit condition in §3.2.
- **D3, the counter (§3.3): not built.**
