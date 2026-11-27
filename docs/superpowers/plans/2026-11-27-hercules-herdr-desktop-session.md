# hercules Herdr core in the desktop login — Implementation Plan

> **For agentic workers:** run with the `plan-run` skill (subagent-driven). Steps use checkbox
> (`- [ ]`) syntax for tracking.

**Goal:** a LaunchAgent that keeps each machine's Herdr core in the desktop login, so programs it
runs can use the login keychain.

**Architecture:** `be.netronix.herdr-core-desktop` runs `~/.local/bin/herdr-core-desktop` at the
desktop login and whenever `~/.local/state/herdr-core/default/core.lock` changes. The script checks,
through `herdr-core exec`, whether the core's programs can use the login keychain, and if not runs
`herdr-core server restart --fresh` from the desktop login; a move that still fails unloads the job.

**Tech Stack:** bash 3.2, launchd plist (chezmoi template), bash test suite with stubs.

**Spec:** `docs/superpowers/specs/2026-11-27-hercules-herdr-desktop-session-design.md` (Approved).
Read its Design, Behaviour and Tests sections before any task.

## Global Constraints

- The script never assigns or exports an environment variable that reaches its children: no `PATH`
  pin, no `export`. `server restart --fresh` hands the script's environment to new terminals.
- Tools by absolute path: `/usr/bin/timeout`, `/bin/sleep`, `/bin/launchctl`, `/usr/bin/id`,
  `/bin/date`, `/bin/mkdir`; the check runs `/usr/bin/security`. Suite-only seam: when `HCD_TOOLS`
  is set, `timeout`, `sleep` and `launchctl` come from that directory instead.
- Every `herdr-core` call is `<timeout> -f 60 "$HOME/.local/bin/herdr-core" …` (`-f`: a timeout
  signals herdr-core alone, never a core it started as its child; fix round 1).
- The script never calls `herdr-core server stop`, `kill` or `rm`.
- Fixed names: label `be.netronix.herdr-core-desktop`; log `$HOME/.local/state/herdr-core-desktop.log`
  (one line per event: `<UTC ISO-8601> <message>`, as `ssh-agent-run` writes); keychain
  `$HOME/Library/Keychains/login.keychain-db`; watched path
  `$HOME/.local/state/herdr-core/default/core.lock`.
- bash 3.2 (`/bin/bash`): no associative arrays, no `${x,,}`.
- Suites follow `tests/AGENTS.md`: exit 2 when a subject is missing, `  PASS:`/`  FAIL:` lines, a
  final `passed/total` line, shebang `#!/usr/bin/env bash`, mode 755, a subject-map row for every
  file a suite loads.
- Public repository: nothing private in any file. Commits: imperative mood, no attribution.

## Review Focus

1. **HOME containing a space** — every path the script builds stays one word. Pinned in Task 2
   (each scratch `HOME` has a space in it; stubs log each argument delimited).
2. **A fresh machine without `~/.local/state`** — the script creates it before logging. Pinned in
   Task 2 (every case starts without it).
3. **The job unloading itself kills the script mid-run** — the failure line must be in the log
   before `launchctl bootout` runs. Pinned in Task 2 (the `launchctl` stub records whether the log
   already holds the line when it is called).
4. **A core being stopped and started by herdr's own tooling when the job fires** — the 5-second
   wait comes before the first check. Pinned in Task 2 (call order).
5. **`core.lock` absent when the job loads (fresh machine)** — launchd's `WatchPaths` on a path that
   does not exist yet. Not testable in a suite; it is covered by Michael's undo check (spec step 3)
   on hercules, where the file exists, and named in the final report for a fresh machine.

---

### Task 1: Checklist rows and the spec's Provisioning line

**Depends on:** none. Runs first: `tests/provisioning.test.sh` is red on this branch until the
spec's Provisioning line names existing rows, and it also reads every LaunchAgent plist, so Task 2's
checks need this one done. Your check, no per-task review.

**Files:**
- Modify: `.scripts/machine-checklist.tsv` (rows `claude-login`, `filevault-on`)
- Modify: `docs/superpowers/specs/2026-11-27-hercules-herdr-desktop-session-design.md` (header and
  the Provisioning paragraph)

- [ ] **Step 1: Row `claude-login`**

Step text: `Start claude once in a terminal or Herdr pane of the desktop login and sign in (from an
SSH login Claude Code cannot write the keychain and keeps the login in plain text, in
~/.claude/.credentials.json; delete that file after signing in again)`. Verify: `claude auth status
--json | /usr/bin/jq -e .loggedIn >/dev/null && [ ! -e "$HOME/.claude/.credentials.json" ]`.

- [ ] **Step 2: Row `filevault-on`**

Append to the step, after "until a desktop login": `; on hercules that login also moves Herdr's
core into it (be.netronix.herdr-core-desktop), and Herdr panes opened before it stay in the SSH
login, so reopen them`.

- [ ] **Step 3: The spec's provisioning (ruling at planning)**

The existing `launchagents` row already fails when a `be.netronix.*` job is not loaded, including
after this job unloads itself, so no `herdr-core-desktop` row is added. In the spec: add after the
`**Sign-off:**` entry the line `**Amended:** 2026-11-27, at planning: no new checklist row; the
existing \`launchagents\` row checks that the job is loaded.`; set `**Provisioning:**
\`launchagents\`, \`filevault-on\`, \`claude-login\``; in `**Size:**` say "two edited checklist
rows"; in Design's **Provisioning.** paragraph replace the new-row sentence with "The existing
`launchagents` row checks that the job is loaded (it fails after the job unloads itself)."

- [ ] **Step 4: Check**

Run: `./tests/run.sh provisioning machine-check`
Expected: both pass. Then check the new `claude-login` verify against a fixture, the way
machine-check runs it: a scratch HOME, and a scratch bin directory holding a stub `claude` that
prints `{"loggedIn":true}`; run `env -i HOME=<scratch> PATH=<scratch bin>:/usr/bin:/bin
/usr/bin/timeout 30 /bin/zsh -f -c '<the verify>'; echo rc=$?`. Expected: `rc=0` without
`<scratch>/.claude/.credentials.json`, and `rc=1` after `touch`ing it. Record both in the ledger.

- [ ] **Step 5: Commit**

```bash
git add .scripts/machine-checklist.tsv docs/superpowers/specs/2026-11-27-hercules-herdr-desktop-session-design.md
git commit -m "Flag a plain-text Claude login and note the desktop-login move in the checklist"
```

### Task 2: The job: script, plist and suite

**Depends on:** Task 1 (the provisioning suite must be green to judge this task's run). Gets a
per-task review (it sets who reaches the login keychain).

**Files:**
- Create: `dot_local/bin/executable_herdr-core-desktop` (mode 755)
- Create: `Library/LaunchAgents/be.netronix.herdr-core-desktop.plist.tmpl`
- Create: `tests/herdr-core-desktop.test.sh` (mode 755)
- Create: `tests/subjects/herdr-core-desktop.tsv`
- Modify: `tests/subjects/load-launchagents.tsv` (add the plist's row)

**Interfaces:**
- Produces: the script `herdr-core-desktop` (no arguments; exit 0 when the core is or was moved into
  the desktop login or herdr-core is missing, 1 after a failed move) and the plist, which runs it.

- [ ] **Step 1: Write the failing suite `tests/herdr-core-desktop.test.sh`**

A scratch root from `mktemp -d`, removed on exit. A `fresh` helper gives each case its own state, as
`fresh_home` does in `tests/ssh-agent-run.test.sh`: a new scratch `HOME` whose name contains a space
and that has no `.local/state`, the herdr-core stub installed in it, and new `CALLS`, `ctx` and
`move` files. Stubs are written with unquoted heredocs so the case's paths are fixed in them at
creation (`env -i` passes none through). Each logs one line per call to `CALLS`, every argument
delimited (`printf ' [%s]' "$@"`):
- `$HOME/.local/bin/herdr-core`: logs `hc`, or `hc-direct` when `STUB_VIA_TIMEOUT` is unset, then
  its arguments. `exec …` exits 0 when `ctx` holds `ok`, else prints `security:
  SecKeychainCopySettings …: User interaction is not allowed.` to stderr and exits 36. `server
  restart --fresh` writes `env | /usr/bin/grep -v '^STUB_VIA_TIMEOUT='` to `restart.env` and, per
  `move` (`now`, `late`, `never`), sets `ctx` to `ok` at once, after the next check, or never.
- `$HCD_TOOLS/timeout`: logs `timeout` and its arguments, exports `STUB_VIA_TIMEOUT=1`, drops a
  leading `-f` and then the seconds, and execs the rest.
- `$HCD_TOOLS/sleep`: logs `sleep` and its arguments, returns at once.
- `$HCD_TOOLS/launchctl`: logs `launchctl` and its arguments, and `log-had-failure=yes|no` (whether
  the log file already holds the failure line).

Run the script as `env -i HOME="$HOME" PATH=/opt/x:/usr/bin:/bin HCD_TOOLS=… MARKER=kept
/bin/bash <script>`. Cases and assertions:
- **A. usable core:** rc 0; `CALLS` is exactly `sleep [5]`, then `timeout [-f] [60] [<hc path>] [exec]
  [/usr/bin/security] [show-keychain-info] [<HOME>/Library/Keychains/login.keychain-db]` and the
  matching `hc` line; no restart; no log file.
- **B. unusable, moves at once:** rc 0; exactly one `hc [server] [restart] [--fresh]`; the log
  exists with exactly one line, containing `moved`; no `launchctl` call.
- **C. unusable, moves only after the re-check** (`move=late`): rc 0; one restart; three checks;
  `sleep [5]` twice (before the first check, before the re-check); from the restart on, the order
  is restart, check, sleep, check; one `moved` line.
- **D. never moves:** rc 1; exactly one restart; the log's one line contains `could not move`;
  `launchctl [bootout] [gui/<uid>/be.netronix.herdr-core-desktop]` called once, with
  `log-had-failure=yes`.
- **E. herdr-core missing:** rc 0; `CALLS` empty; no log file.
- **F. environment:** in case B's `restart.env`, `PATH=/opt/x:/usr/bin:/bin` and `MARKER=kept`, and
  no variable names besides those given plus `SHLVL`, `_`, `PWD` and `OLDPWD`.
- **G. timeouts and forbidden calls, over every case:** no `hc-direct` line; every `timeout` line
  starts `timeout [-f] [60]`; no `hc [server] [stop]`, `hc [kill]` or `hc [rm]` line.
- **H. plist:** render with `sed "s|{{ .chezmoi.homeDir }}|$H|g"` as `tests/ssh-agent-run.test.sh`
  does; `plutil -lint` passes; `Label` is `be.netronix.herdr-core-desktop`; `ProgramArguments.0` is
  `$H/.local/bin/herdr-core-desktop`; `RunAtLoad` and `AbandonProcessGroup` are `true`;
  `LimitLoadToSessionType` is `Aqua`; `WatchPaths.0` is
  `$H/.local/state/herdr-core/default/core.lock`; `KeepAlive` and `EnvironmentVariables` are absent;
  `StandardOutPath` and `StandardErrorPath` are `/dev/null`. No assertion on header wording.

Missing script or plist: print the path and exit 2.

- [ ] **Step 2: Run it, expect exit 2 (missing subject)**

Run: `./tests/herdr-core-desktop.test.sh; echo rc=$?`
Expected: `rc=2` and the missing script's path.

- [ ] **Step 3: Write `dot_local/bin/executable_herdr-core-desktop`**

Header comment in the style of `executable_ssh-agent-run`: what it does, the spec path, exit codes,
"HCD_TOOLS is for the suite only", bash 3.2. Then the spec's five script steps with the Global
Constraints' values: `[ -x "$hc" ] || exit 0`; `sleep 5`; check; on failure `server restart
--fresh`, check, `sleep 5`, check; success logs `moved Herdr's core into the desktop login`; failure
logs `could not move Herdr's core into the desktop login; unloading be.netronix.herdr-core-desktop
until the next desktop login (reload: launchctl bootstrap gui/<uid>
~/Library/LaunchAgents/be.netronix.herdr-core-desktop.plist)`, then boots out its own label and
exits 1. `mkdir -p "$HOME/.local/state"` before the first log line. `set -u`.

- [ ] **Step 4: Write `Library/LaunchAgents/be.netronix.herdr-core-desktop.plist.tmpl`**

Keys exactly as case H pins, home paths spelled `{{ .chezmoi.homeDir }}`. Header comment like
`be.netronix.ssh-agent.plist.tmpl`'s: what the job does and why (an SSH-started core stays in the
SSH login; `WatchPaths` catches SSH-side restarts such as `hc machine update`), that
`.scripts/load-launchagents.sh` loads it (configure.sh and the apply hook), the hand-load and bootout
commands, that it unloads itself after a failed move until the next desktop login, and the spec path.

- [ ] **Step 5: Subject maps**

`tests/subjects/herdr-core-desktop.tsv`:
```
dot_local/bin/executable_herdr-core-desktop	bash	own,guard
Library/LaunchAgents/be.netronix.herdr-core-desktop.plist.tmpl	data	own,guard
```
`tests/subjects/load-launchagents.tsv` gains, in name order:
`Library/LaunchAgents/be.netronix.herdr-core-desktop.plist.tmpl	data	-`

- [ ] **Step 6: Stage, then run the focused suites, expect all pass**

`git add` the five files first: `missing-subject` copies only `git ls-files`, so unstaged files
escape it. Run: `./tests/run.sh herdr-core-desktop load-launchagents missing-subject provisioning`
Expected: every suite passes; `herdr-core-desktop` reports `N/N`.

- [ ] **Step 7: Revert checks**

Break the script one way at a time, run the suite, see the named assertion fail, restore: boot out
before logging (D's `log-had-failure=yes`); add `export PATH=/usr/bin:/bin` (F); check before the
first sleep (A's order); call herdr-core without the timeout (G's `hc-direct`); leave the keychain
path unquoted (A's single delimited argument).

- [ ] **Step 8: Commit**

```bash
git add dot_local/bin/executable_herdr-core-desktop Library/LaunchAgents/be.netronix.herdr-core-desktop.plist.tmpl tests/herdr-core-desktop.test.sh tests/subjects/herdr-core-desktop.tsv tests/subjects/load-launchagents.tsv
git commit -m "Keep the Herdr core in the desktop login with a LaunchAgent"
```

---

## After the tasks (controller)

1. `./tests/run.sh --changed` (full pre-merge run, quotes its `needs: heavy` lines).
2. Preview: `command chezmoi --source <checkout> cat ~/Library/LaunchAgents/be.netronix.herdr-core-desktop.plist`
   and `command chezmoi --source <checkout> apply --dry-run --verbose`, filtered to the new files;
   record both in the ledger. Never preview `~/.claude/settings.json` whole.
3. `change-facts origin/main...HEAD`; stop if non-test code passes about 135 lines (half again over
   the spec's 90).
4. Final review (`sp-architect`), then the pre-merge cross-review per Michael's Codex instruction at
   that point, then the PR (`merge-request` skill).
