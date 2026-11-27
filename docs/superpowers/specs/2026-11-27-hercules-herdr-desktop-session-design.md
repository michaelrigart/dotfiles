# hercules: Herdr's core runs in the desktop login

**Status:** Approved
**Date:** 2026-11-27
**Sign-off:** Michael, 2026-11-27, in the line's own pane: "D1. yes / D2. ok I guess / D3. ok I
guess", and Q1 answered: `~/.claude/.credentials.json` exists on hercules (700 bytes, mode 600,
written 2026-11-27 06:28).
**Amended:** 2026-11-27, at planning: no new checklist row; the existing `launchagents` row checks
that the job is loaded.
**Branch:** `feat/hercules-herdr-desktop-session`, in the `wt` checkout
`~/.local/share/chezmoi-feat-hercules-herdr-desktop-session`
**Source:** Michael, 2026-11-27, relayed by line `chore/hercules-filevault-on` and briefed by the
driver (chezmoi-9f): agent sessions in Herdr panes on hercules, managed from fenrir over SSH, have
their logins (the login keychain) without Michael stepping in, except the one desktop login (Screen
Sharing) after a restart.
**Review:** Codex's spec review was refused (usage limit until 2026-11-28 09:29); Michael,
2026-11-27: "skip codex for now". A cold Claude review (sp-architect) ran instead. After Michael
asked whether this was overcomplex, the spec was cut to one job: its fenrir-side gate, hercules-only
role key and failure counter are gone (Rulings).
**Size:** about 90 lines of non-test code: the LaunchAgent plist about 50 (mostly its header
comment, like the other `be.netronix.*` plists), `dot_local/bin/executable_herdr-core-desktop` about
35, two edited checklist rows. Comparable: `be.netronix.ssh-agent` (plist plus script, PR #40).
No increments.
**Provisioning:** `launchagents`, `filevault-on`, `claude-login`

## Why

Measured on hercules on 2026-11-27 (macOS 27.2.1, herdr-core 0.1.21), from fenrir over SSH, with a
scratch core (`HC_SESSION=probe`) so Michael's own core was never touched:

- **M1. A desktop login does not move an SSH-started core.** hercules' core started on 2026-11-26 at
  22:18 from fenrir's ssh (`herdr-core connect` starts one when none runs; from SSH it is a direct
  process in the SSH login, with `SSH_CONNECTION` in its environment). The desktop login followed at
  22:48; 13 hours later the core is unchanged. Herdr.app, running on hercules since 22:49, attached
  to it without replacing it.
- **M2. Its programs cannot use the login keychain.** In a terminal of an SSH-started core,
  `launchctl managername` prints `Background`, `security show-keychain-info` on the login keychain
  fails with "User interaction is not allowed", and `gh auth status` cannot read its keyring token.
- **M3. A restart from the desktop login moves the core.** A launchd job in `gui/501` running
  `herdr-core server restart --fresh` moved the core into a launchd job and retired the SSH holder.
  New terminals, including ones opened by an SSH client as fenrir's Herdr opens them, print `Aqua`,
  `security show-keychain-info` answers `no-timeout`, and `gh auth status` is logged in.
  `herdr-core exec` gave the same answers as a terminal in both cases.
- **M4. An SSH-side restart moves it back** (`herdr-core server restart` from SSH, which is what
  `hc machine update hercules` does): new terminals are `Background` again.
- **M5. A `WatchPaths` job on the core's `core.lock`** (rewritten at every core start) fired on that
  SSH-side restart and moved the core back within about a second; its own restart did not make it
  loop. After `herdr-core server stop` it fired too, and its check started a new desktop core.
- **M6. Claude Code answered in both sessions.** `claude -p` (haiku, one call each) worked in a plain
  SSH shell and in a terminal of the moved core, so Claude Code's login on hercules does not depend
  on the session: Q1 found it in plain text, in `~/.claude/.credentials.json`, written that morning,
  which is where Claude Code keeps a login it cannot write to the keychain (fenrir has no such
  file). The live suites that failed on 2026-11-26 at
  22:28 ran before the desktop login, when the native ssh-agent (a LaunchAgent) was not running
  either.
- **M7.** fenrir's own core, started by Herdr.app, has launchd's default environment
  (`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, launchd's `SSH_AUTH_SOCK`, no `XDG_*`).

herdr-core's manual (`herdr-core --skill`) documents this: desktop starts use a launchd job, "SSH
starts stay direct"; "An explicit `hc server restart` from a healthy login also retires holders from
another login without ending their programs. Viewing a healthy SSH core does not replace it";
`--fresh` takes the restarting shell's environment for new terminals.

## Design

**The job.** `Library/LaunchAgents/be.netronix.herdr-core-desktop.plist.tmpl` runs
`~/.local/bin/herdr-core-desktop` in the `gui` domain with `LimitLoadToSessionType` `Aqua`,
`RunAtLoad` (the desktop login, and each load by the loader), `WatchPaths` on
`~/.local/state/herdr-core/default/core.lock` (every core start), `AbandonProcessGroup` (herdr-core
falls back to a direct child when its launchd start fails), no `KeepAlive` and no
`EnvironmentVariables`: its environment is launchd's, the one fenrir's core has (M7). It deploys on
every machine and is loaded by `.scripts/load-launchagents.sh` like the others; on fenrir the core is
already in the desktop login, so the job finds nothing to do.

**The script**, bash 3.2. It never changes its environment, because `--fresh` hands it to new
terminals; it calls tools by absolute path and every `herdr-core` call under `/usr/bin/timeout`.

1. If `~/.local/bin/herdr-core` is missing, exit 0.
2. Wait 5 seconds, so a stop and start by herdr's own tooling (an update) finishes first.
3. Check: `herdr-core exec /usr/bin/security show-keychain-info <login keychain>`. It succeeds when
   the core's programs can use the login keychain (M3) and fails in an SSH-started core (M2); it
   reads keychain settings, never an item. When no core runs, it starts one from the desktop login.
   Success: exit 0.
4. `herdr-core server restart --fresh`, then check again, and once more after 5 seconds if needed.
   Success: log one dated line in `~/.local/state/herdr-core-desktop.log`.
5. Still failing: log it, then unload the job (`launchctl bootout` of its own label) so a herdr-core
   that no longer moves cannot restart the core over and over; the next desktop login loads it
   again.

It never stops a core or ends a terminal.

**Provisioning.** configure.sh loads the job with the other LaunchAgents. The existing
`launchagents` row checks that the job is loaded (it fails after the job unloads itself). Row
`filevault-on` gains: the desktop login also moves Herdr's core on hercules; panes opened before it
stay in the SSH login, so reopen them. Row `claude-login`: sign in from a desktop-login terminal or
pane, and its verify also requires that `~/.claude/.credentials.json` does not exist, so a
plain-text login (Q1) shows up as a step to do on any machine.

## Behaviour

| Event | Result |
|---|---|
| Desktop login, core started earlier over SSH | moved; new panes in the desktop login; panes from before keep the SSH login (D2) |
| Desktop login, no core running | started in the desktop login; fenrir attaches to it |
| `hc machine update hercules`, or any SSH-side restart | moved back within seconds (M5) |
| `hc server stop` | a new desktop core within seconds (D3) |
| A move that fails | logged; the job unloads itself until the next desktop login |

## What changes for an attacker or a runaway agent

Every program hercules' core runs, agents in its panes (inside their Claude Code sandbox, as today)
and `hc run`/`exec` calls with `--on hercules` from fenrir, gains the unlocked login keychain (Claude
Code's, gh's and glab's stored logins), the desktop pasteboard, Apple Events and Herdr Core's
privacy grants. That is fenrir's posture, where the keychain exposure is accepted (Michael,
2026-10-13). It is not new for a process running as Michael: an SSH login can already put a job into
the desktop login with `launchctl bootstrap gui/501` (how M3 was measured). New: the job restarts the
core by itself; the manual and M3 to M5 say programs keep running through a restart.

## Decisions for Michael

- **D1.** Every program hercules' core runs reaches the login keychain and desktop session, as on
  fenrir. Recommended: yes.
- **D2.** After a hercules restart, fenrir's Herdr usually reconnects before the desktop login, so
  the panes it recovers then stay in the SSH login; reopen them. Claude Code works there today only
  through the plain-text login (M6, Q1); once step 4 removes it, Claude Code is logged out there too,
  as is gh's keyring, and a `/login` there would write the plain-text file again (which `claude-login`
  then flags). Recommended: accept. A fenrir-side gate (`hc machine add --via`) could keep
  hercules unreached until the desktop login; it is left out until reopening panes proves annoying.
- **D3.** `hc server stop` on hercules is followed by a new desktop core within seconds; to keep it
  stopped, boot the job out first. Recommended: accept.
- **Q1.** In a hercules terminal: `ls -la ~/.claude/.credentials.json`. Answered: it exists, so
  Claude Code on hercules runs on a plain-text login, which the brief rejects. It is readable by any
  process running as Michael, sandboxed agents included (no deny rule covers it), and Borg backs it
  up. Step 4 below moves the login to the keychain and deletes the file; copies in older backups stay.

## Michael's steps after merge

1. On hercules, in a desktop terminal: `git -C ~/.local/share/chezmoi pull --ff-only`, then
   `chezmoi apply`. The job loads and moves the running core (its panes keep running);
   `~/.local/state/herdr-core-desktop.log` shows the move. On fenrir, `chezmoi apply` loads the job,
   which does nothing.
2. From fenrir, open a new hercules pane: `launchctl managername` prints `Aqua` and `gh auth status`
   is logged in. Reopen the hercules panes from before step 1 when convenient.
3. Undo check: `~/.local/bin/herdr-core server restart` in an SSH shell on hercules (or `hc machine
   update hercules` from fenrir), wait 15 seconds, repeat step 2 in a new pane.
4. Right after step 2: in a new hercules pane, `claude`, then `/login`; check `claude -p "say ok"`
   there; then `rm ~/.claude/.credentials.json` and check `claude -p "say ok"` once more. Reopen the
   panes from before step 1 now rather than later: a Claude session in one still needs the file.
   `dotfiles-run machine-check` then shows `claude-login` done.
5. Acceptance: in a fresh Claude Code session in a new hercules pane, sandboxed:
   `./tests/run.sh live-agent-signing live-credential-boundary live-agent-auth`.

Rollback: `launchctl bootout gui/$(id -u)/be.netronix.herdr-core-desktop` on each machine, revert
the PR, `chezmoi apply`, and `rm ~/Library/LaunchAgents/be.netronix.herdr-core-desktop.plist`.

## Tests

`tests/herdr-core-desktop.test.sh` with stub `herdr-core` and `launchctl` in a scratch `HOME`, and a
seam for `sleep` and `timeout`. Pins: a usable core gets no restart; an unusable one gets exactly
one `server restart --fresh` and a log line; a move that still fails logs and boots the job out,
with no second restart; a missing herdr-core exits 0; `--fresh` receives the job's environment
unchanged; every `herdr-core` call goes through `timeout`; no run calls `server stop`, `kill` or
`rm`. It also renders the plist, runs `plutil -lint` and pins its keys. Subject maps:
`tests/subjects/herdr-core-desktop.tsv`, and the plist's `data -` row in
`tests/subjects/load-launchagents.tsv`.

## Rulings

From the cold review (sp-architect, 2026-11-27): fixed, `--fresh` passing the script's environment
(no `PATH` pin), the race with herdr's own stop and start (the 5-second wait), a hung call wedging
the job (`timeout`), a stale core from an earlier login (the keychain check rather than
`managername`), the fuller attacker list, the subject-map row. Cut for simplicity after Michael's
question: the fenrir-side `--via` gate (D2), a hercules-only role key and ignore rule (the job is
harmless where the core is already in the desktop login), and a failure counter (the job unloads
itself instead).
