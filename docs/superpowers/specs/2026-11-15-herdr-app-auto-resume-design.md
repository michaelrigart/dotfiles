# Herdr app: resume agents only after a real terminal loss

**Status:** In progress (branch `feat/herdr-app-auto-resume`)
**Date:** 2026-11-15
**Branch:** `feat/herdr-app-auto-resume`
**Sign-off:** Michael, 2026-11-15 (option A for a quit nobody saw); Codex spec review round 1's
two findings: one fixed (Codex ownership), one decided by Michael (option A); round 2's one finding
fixed (launch reservation)

Agents in the Herdr desktop app should come back on their own after their terminals are lost, as
they do in the herdr TUI (`resume_agents_on_restore = true` in `~/.config/herdr/config.toml`), and
never otherwise. `mods/resume` (deployed at `~/.config/herdr-app/mods/resume`) already resumes
without a click, but it decides "lost" by the wrong signal, and nothing stops it from resuming a
conversation that already runs somewhere else.

## What happens today

The mod remembers, per terminal, the command that resumes its agent's session and the core
(`hc server status`: pid and start time) it ran under. A terminal back at a bare shell under a
**different core** is resumed at once; under the **same core**, it only gets the status-bar
button (`↻ resume N agents`, or `resume.all` on `cmd-shift-r`).

The core is not what holds the terminals. `hc server status` lists a separate holder process
(`holder.pid`, `holders[]`), and each terminal's root shell (`hc get <t> --json` → `.pid`) is the
holder's child, not the core's. herdr-core's manual: `hc update` "restarts an older running core
… terminals keep running"; "Updates keep running terminals"; the app's first start after an
update moves the core the same way. A terminal is lost only when its process dies (reboot,
logout, holder crash, signal death); the core then gives it a login shell in its last folder at
the same address, after a grace delay. Measured on a scratch kept terminal (no Herdr labels,
removed after): `kill -9` of its program left `pid` null for about a second, then a new
`zsh -l` with a new `pid`; `created_ms`, the address and `keep` stayed, and nothing in `hc get`
records what was running before the loss.

| Event | Terminals | What the mod does | Right? |
|---|---|---|---|
| Core restart or update (`hc update`, app update moving the core) | kept, same processes | Running agents: record refreshed, nothing sent. **A terminal already at a shell with a record (agent quit on purpose) is resumed unasked**, since the core differs. | No |
| Machine reboot, logout | lost, recovery shells | Every remembered terminal is resumed, including ones whose agent was quit on purpose before the reboot. | Partly |
| Holder crash or one terminal's signal death, core alive | lost, recovery shells | Same core, so only the button. | Safe, incomplete |
| Window closed and reopened, core alive | kept | Same core: agents keep running; quit ones keep the button. | Yes |

No path checks whether a session already runs elsewhere (another app terminal, the TUI, a plain
terminal), and two terminals remembering the same session are both resumed.

## Goals

- A terminal whose agent was running when it was lost gets that session back without a click, once
  its recovery shell is up: after a reboot, a logout, a holder crash or a single terminal's loss.
- Nothing is resumed unasked when the terminals survived: a core restart or update, the window
  closed and reopened.
- An agent the app saw quitting is never resumed unasked, even after a later loss; it keeps the
  button. (A quit the app did not see: "Decided: a quit nobody saw" below.)
- A session is never resumed when it already runs elsewhere, and never twice; this holds for the
  button too.

## Non-goals

- Changing what is resumed (the recorded command: same flags, `--resume <id>` / `resume <id>`, or
  a fresh start when the session was never written) or the button.
- `bin/retire` and `bin/session-written`, which other lines own (they read the same records; new
  record fields are additive).
- Remote machines' terminals (the mod already handles only this computer's).

## Anti-goals

- Resuming anything after a core update or a window reopen.
- A conversation running in two places at once.
- A resume that fails and retries in a loop.

## Approaches

1. **The terminal's root process (recommended).** Record `hc get`'s `.pid` with the session. Back
   at a shell under the same pid: the agent quit inside its shell. Under a new pid: the terminal was
   lost and recovered. Exact per terminal, covers every way of losing one, and the field is already
   in the `hc get` reply the mod reads, so it costs no call (and `hc server status` goes). The only
   error is pid reuse across a reboot, which makes a lost terminal look kept: the button, the safe
   direction.
2. **The holder's identity** (`holder.instance` from `hc server status`). One signal for the whole
   machine; it cannot see one terminal's signal death, and the multi-holder model (`holders[]`) is
   undocumented.
3. **Keep the core rule, add a "was running" bit.** Fixes the core-update misfire for agents seen
   quitting, but a core update after an unseen quit (window closed) still resumes, and a loss under
   a live core still gets only the button.

## Design (approach 1)

### When a terminal counts as lost

Each record (`shared("resume.sessions")[address]`) keeps `{app, id, cwd, cmd, fresh}` as today,
drops `core`, and gains:

- `pid`: the terminal's root pid when the agent was last seen running.
- `quit`: true once the terminal was seen back at a shell under that same pid.

Per scan, for each of this computer's panes with a record:

- Agent running: refresh the record (`pid` now, `quit` cleared) when the command, the pid or `quit`
  differs.
- Shell under the recorded pid: set `quit`; the terminal joins the button's list.
- Shell under another pid, record not `quit`: **lost**. Resumed automatically once the same new pid
  has been seen for at least 3 s (replaces "3 s after the core started", which says nothing about a
  shell recovered later or by a live core). Until then, look again on the next tick.
- Shell, record without `pid` (written before this change): treated as `quit`. Safe direction.

Before sending, each lost terminal is claimed: its record's `pid` becomes the new shell's. A resume
that fails then reads as a quit on the next scan (button), never a retry.

### Never twice, never where it already runs

Before any resume, automatic or from the button, a session is skipped when:

1. another terminal in the same batch already takes that session id;
2. another of this computer's app terminals runs it now (the scan already knows each running
   agent's session id);
3. it was sent to a terminal less than 60 s ago, automatically or from the button, and no app
   terminal is seen running it yet: a launch in flight. An agent publishes its session (Claude's
   registry, Codex's loaded rollout) only once it has started, so without this a second terminal
   that settles on a later scan, or a click in between, would send the same session again. The
   reservation lives in the mod's memory, by session id, and ends when the session is seen running
   or after 60 s;
4. `bin/session-running <claude|codex> <id>` exits 0. New helper, same shape as
   `bin/session-written`:
   - Claude: a file in `~/.claude/sessions/` (Claude Code's own registry of running sessions, one
     per pid) has that `sessionId` and its pid is alive. Covers every Claude on the machine: app,
     TUI, any terminal.
   - Codex: some process holds the session's rollout file open (`lsof` on
     `~/.codex/sessions/**/rollout-*-<id>.jsonl`). Codex's rollout recorder keeps the file open
     while the conversation is loaded: measured, the Codex daemon held 22 rollouts open, one per
     loaded conversation, for clients in app terminals, TUI panes and plain terminals alike, fresh
     and resumed; a standalone `codex --no-daemon` runs the same recorder. Also running: a `codex`
     process with the id in its arguments (`codex … resume <id>`).
   - Both: the TUI's `~/.config/herdr/session.json` lists the id in a pane's `agent_session`; the
     TUI restores and resumes those itself.
   If the helper does not run at all, or cannot tell (no `lsof`), the session counts as running,
   and a warning says so once per run (fail closed).

A lost terminal whose session reads as running stays pending: it is checked again on each scan,
for up to 2 minutes from its new shell's first sighting, then claimed, so it falls to the button,
where the same checks apply. The wait is for Codex: its daemon keeps a conversation loaded about a
minute after the client dies, so after a loss that the daemon survived the session reads as
running at first. A toast counts the terminals that fell to the button this way ("1 not resumed:
already running elsewhere").

### Unchanged

Detection of what runs (Claude's registry, Codex's title, flags from the process), `fresh` versus
`cmd` via `session-written`, the button and `resume.all`, forgetting records of closed panes once
the layout has loaded, local terminals only.

## Tests

Michael's rule: only what the change needs, one or two cases. The classification moves into a pure
module, `mods/resume/decide.js`, imported by `main.js` and run in tests by macOS's own
`/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc -m` (no new
runtime). A new suite, `tests/herdr-app-resume.test.sh`, so it stays out of `herdr-app.test.sh`,
which a parallel line edits:

1. **Decision:** a core restart (same root pids) resumes nothing, and a terminal at a shell is
   marked quit; a lost terminal (new pid) whose agent was running is resumed once its pid has held
   for the settle time, a second terminal with the same session is not (in the same scan, nor when
   it settles on the next scan while the first one's launch is in flight), a quit one is not, and
   one whose session runs elsewhere waits. Revert check: the core-based rule fails the first half.
2. **Helper:** a Claude session whose registry pid is alive is running, and not once the pid is
   dead; a Codex session whose rollout the test holds open is running, and not once it is closed;
   an id listed in a scratch TUI `session.json` is running.

Subject map rows for `decide.js`, `bin/executable_session-running` and the suite.
`herdr-app check` passes on the mod.

## Acceptance (Michael, after merge and `chezmoi apply`)

The branch cannot run live before merge (chezmoi applies from main), and no agent restarts the app
or core. Checks, each on the next natural occasion:

1. **One terminal's loss, now:** in a scratch app tab, start `claude`, send it one message, then
   from another terminal `kill -9 <its shell's pid>` (`hc get <t> --json | jq .pid`). The core
   recovers the terminal; within a few seconds the session comes back with "Resumed 1 agent
   session after a restart".
2. **Core update or restart:** with one agent running and one quit (at its shell, button showing),
   at the next app or core update: the running one keeps running, the quit one keeps the button,
   no "Resumed" toast.
3. **Reboot:** after the next reboot, reopening the app resumes each agent that was running, each
   once; quit ones show the button; a session also open in the TUI is not resumed in the app.
4. **Window closed and reopened** with the core alive: nothing is resumed.

## Decided: a quit nobody saw (option A, Michael, 2026-11-15)

The mod only watches while the app runs. An agent quit while the window was closed (through
`hc attach`, another machine's Herdr, another agent's `hc send`) and then lost before the app
reopens still has a record that says running, and its recovered shell has a new pid: as designed,
it is resumed after the loss, in its own terminal and only if it runs nowhere else. Neither the
core nor the agents keep anything that says what ran at the moment of loss, so the only fully safe
rule is "resume only what the app watched until the loss", and every reboot breaks that watch.
Options:

- **A (recommended): accept it.** The case needs a deliberate quit from outside the app while the
  window is closed, then a loss before reopening; the cost is one unwanted resume of that agent's
  own session, never a duplicate.
- **B: the button after any loss the app did not watch.** Auto-resume only losses seen while the
  app runs (holder crash, one terminal); after a reboot or logout every agent waits for one click.
- **C: bound the gap.** Stamp the time the app quits (`close()`) and auto-resume after a reboot
  only when the app quit within a few minutes of boot (`kern.boottime`). Restarts resume; a
  shutdown overnight or a logout waits for the click. It depends on a write made in the app's last
  250 ms being saved, which cannot be checked before merge.

## Known limits

- A quit nobody saw, then a loss: resumed (decided above).
- Pid reuse across a reboot can make a lost terminal look kept: it gets the button.
- A launch reservation is in memory: an app restart or a mod reload in the seconds between a send
  and the agent publishing its session forgets it.
