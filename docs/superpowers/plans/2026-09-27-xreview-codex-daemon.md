# xreview on the Codex daemon — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Approved

**Goal:** Run every Codex session on a daemon started cleanly by launchd, keep herdr's pane→thread ids correct from the pane titles, and move xreview onto the daemon with pane-first dispatch and schema-checked findings.

**Architecture:** launchd starts `codex app-server daemon start` with no `HERDR_*` in its environment, and a `~/.local/bin/codex` launcher makes every interactive start attach to it. Each TUI puts its thread id at the start of its terminal title. A `SessionStart` hook inside the daemon reconciles herdr's session ids from those titles. xreview prepares the repo's Codex pane on the review thread first. Only then does it start the turn through `xreview-rpc` (a stdlib Python JSON-RPC client), with an `outputSchema`, and wait for `turn/completed`.

**Tech Stack:** POSIX sh (`codex`, `codex-daemon`, host shim), bash (`xreview`, tests), Python 3 stdlib (`xreview-rpc`, pane-map hook), chezmoi templates, launchd, herdr 0.9.1 CLI, Codex 0.157.1 app-server protocol.

**Spec:** `docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md` (read it with this plan; section numbers below refer to it).

## Global Constraints

- macOS only. Codex 0.157.1, herdr 0.9.1. Public repository: no secrets anywhere.
- Python code uses the standard library only. `xreview-rpc` and the pane-map hook run under `/usr/bin/env python3`.
- Never edit herdr-managed hook scripts (`~/.codex/herdr-agent-state.sh`, `dot_claude/hooks/executable_herdr-agent-state.sh`).
- `features.daemon_auto_start` stays `false`. Nothing passes `-c` to an interactive `codex` that should run on the daemon (F10).
- The LaunchAgent label is exactly `be.netronix.codex-app-server`.
- `~/.local/bin/codex` shadows Homebrew's binary. Anything that needs the real binary calls `codex-daemon real-bin`, never `command -v codex`.
- Every new file under `~/.codex` needs its own `!.codex/<name>` line in `.chezmoiignore`; that tree is an allowlist.
- xreview's external contract:
  - `dispatch` prints a nonce.
  - `collect` exits 0 (done), 1 (failed or ambiguous; never re-dispatch), 3 (still running) and 4 (not schema-valid).
  - `reviews.jsonl` keeps `ts, branch, head, thread, nonce, tier` and adds `turn, verdict, findings`.
- Test suites:
  - One `tests/<subject>.test.sh` per script, mode 755 (`git add --chmod=+x`), with a correct shebang.
  - A missing subject exits 2.
  - Run through `./tests/run.sh <filter>`, never `bash tests/x.test.sh` for zsh suites. Report totals as passed/total.
- `tests/run.sh` filters are substrings, and a filtered run executes `test-requires` suites instead of skipping them. `./tests/run.sh dev` also runs `dev-topology` and the interactive `dev-integrations`, and `codex-daemon` matches `live-codex-daemon`. To run one suite whose name another suite contains, execute it directly (`./tests/dev.test.sh`).
- The Claude sandbox denies binding unix sockets (F20). Sandboxed tests reach `xreview-rpc` through `XREVIEW_RPC_STDIO`, never a socket.
- `xreview` is in `sandbox.excludedCommands` only when it is the whole command. Never chain it after another command in one Bash call.
- Writes under `~/.codex`, and `launchctl`, `ps`, `herdr` and the daemon socket, need the unsandboxed retry. `chezmoi apply` is targeted (named paths), never a full apply without `op`.
- Commits: small, imperative mood, no agent attribution. Re-check `git branch --show-current` is `feat/xreview-codex-daemon` right before each commit, because other sessions switch branches in this checkout.

## Review Focus

1. **A Codex pane whose TUI started before `tui.terminal_title` was applied**: its title has no UUID. Dispatch must still restart it and adopt the new thread (Task 6, test D5).
2. **A repository path containing a space**: pane lookup, the state directory and dispatch still work (Task 6, test I).
3. **The reviewer wraps its JSON in a markdown fence**: `collect` must exit 4 with the raw text, never crash and never pass it as valid (Task 5, test I3).
4. **The operator presses f12 in the pane during a review**: the turn ends `interrupted`, and `collect` must exit 1 naming it (Task 5, test H2).
5. **A caller still uses the old `xreview collect <thread> <nonce>` form**: it must be refused with the usage line, not reported as an ambiguous lost turn (Task 6, test F7).

---

## File Structure

| Path (chezmoi source) | Deployed | Responsibility | Task |
|---|---|---|---|
| `dot_local/bin/executable_codex-daemon` | `~/.local/bin/codex-daemon` | `real-bin`, `ensure`, `check`, `restart` | 1 |
| `Library/LaunchAgents/be.netronix.codex-app-server.plist.tmpl` | `~/Library/LaunchAgents/…plist` | Start the daemon at login, clean env | 1 |
| `tests/codex-daemon.test.sh` | — | Tests for both of the above | 1 |
| `dot_local/bin/executable_codex` | `~/.local/bin/codex` | Interactive starts attach to the daemon, or refuse | 2 |
| `dot_local/bin/executable_codex-code-mode-host` | `~/.local/bin/codex-code-mode-host` | Resolve the real binary through `codex-daemon real-bin` | 2 |
| `tests/codex-launcher.test.sh`, `tests/codex-code-mode-host.test.sh` | — | Launcher tests; shim tests incl. installed beside the launcher | 2 |
| `dot_codex/executable_herdr-codex-pane-map.py` | `~/.codex/herdr-codex-pane-map.py` | Reconcile herdr session ids from pane titles | 3 |
| `tests/herdr-codex-pane-map.test.sh` | — | Pane-map tests | 3 |
| `dot_codex/modify_private_config.toml`, `dot_codex/modify_private_hooks.json`, `.chezmoiignore` | `~/.codex/…` | Title pin, hook registration, allowlist | 4 |
| `tests/codex-config.test.sh` | — | Config and hooks template tests | 4 |
| `dot_local/bin/executable_xreview-rpc` | `~/.local/bin/xreview-rpc` | Daemon JSON-RPC client | 5 |
| `dot_config/xreview/findings.schema.json` | `~/.config/xreview/…` | The findings `outputSchema` | 5 |
| `tests/xreview-rpc.test.sh` | — | Client tests over a stdio fake daemon | 5 |
| `dot_local/bin/executable_xreview` | `~/.local/bin/xreview` | Pane-first dispatch, collect, checkpoints | 6 |
| `dot_config/xreview/reviewer.md` | `~/.config/xreview/reviewer.md` | Reviewer instructions carried in every packet | 6 |
| `dot_config/herdr/codex-pane-command`, `dot_config/herdr/executable_layout.sh` | `~/.config/herdr/…` | The single Codex pane command | 6 |
| `tests/xreview.test.sh` | — | Rewritten xreview tests | 6 |
| `dot_claude/skills/cross-review/SKILL.md`, `tests/xreview-skill.test.sh` | `~/.claude/skills/…` | Skill text and its drift test | 7 |
| `tests/live-codex-daemon.test.sh`, `AGENTS.md` | — | Live canary; testing table | 8 |

---

### Task 1: `codex-daemon` helper and the LaunchAgent

**Files:**
- Create: `dot_local/bin/executable_codex-daemon`
- Create: `Library/LaunchAgents/be.netronix.codex-app-server.plist.tmpl`
- Create: `tests/codex-daemon.test.sh`
- Modify: `docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md` (status line only)

**Interfaces:**
- Produces:
  - `codex-daemon real-bin`: prints an absolute path; exit 1 if there is none.
  - `codex-daemon ensure`: exit 0 when the daemon answers, 1 otherwise, with the fix on stderr.
  - `codex-daemon check`: exit 0 only when the daemon answers AND every live daemon process was inspected and carries no `HERDR_*`. An unreadable environment or a missing server pid file fails closed. Exit 1 with the reason and the fix (`codex-daemon restart`) on stderr.
  - `codex-daemon restart`: exit 0 when the daemon ends up clean.
  - Test knobs: `CODEX_HOME`, `CODEX_DAEMON_LABEL`, `CODEX_DAEMON_WAIT` (seconds, default 10), `XDG_BIN_HOME`.

- [ ] **Step 0: Mark the spec in progress**

In `docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md`, change `**Status:** Approved` to `**Status:** In progress`.

```bash
git -C ~/.local/share/chezmoi branch --show-current   # must print feat/xreview-codex-daemon
git -C ~/.local/share/chezmoi add docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md
git -C ~/.local/share/chezmoi commit -m "Start implementing the Codex daemon design"
```

- [ ] **Step 1: Write the failing test** — `tests/codex-daemon.test.sh`

```bash
#!/usr/bin/env bash
# Tests dot_local/bin/executable_codex-daemon and the LaunchAgent that starts the daemon.
#
# The daemon must be started by launchd, never by a TUI: a TUI-spawned daemon keeps that
# pane's HERDR_* environment, and herdr's hook then reports every thread against that one
# pane (spec section 1). `check` is what detects that state, and `restart` is its fix.
# Every external command is stubbed: the real codex, launchctl and ps.
#
# Run: ./tests/run.sh codex-daemon   (sandboxed is fine)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CD="$ROOT/dot_local/bin/executable_codex-daemon"
PLIST="$ROOT/Library/LaunchAgents/be.netronix.codex-app-server.plist.tmpl"
for f in "$CD" "$PLIST"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/codex-daemon.XXXXXX")"
trap 'kill $A_PID $B_PID $C_PID 2>/dev/null; rm -rf "$T"' EXIT
A_PID=""; B_PID=""; C_PID=""
mkdir -p "$T/localbin" "$T/brew" "$T/cask/bin" "$T/stub" "$T/codexhome/app-server-daemon"
export CALLS="$T/calls" STATE="$T/state" CODEX_HOME="$T/codexhome" CODEX_DAEMON_WAIT=2

# The launcher's directory: real-bin must never answer with anything in here.
printf '#!/bin/sh\necho LAUNCHER\n' > "$T/localbin/codex"
# The real binary lives in a versioned cask directory and is linked from brew/, as Homebrew does.
cat > "$T/cask/bin/codex" <<'C'
#!/bin/sh
case "$*" in
  "app-server daemon version") printf '{"status":"%s"}\n' "$(cat "$STATE" 2>/dev/null || echo notRunning)" ;;
  "app-server daemon stop") echo "codex stop" >> "$CALLS"; echo notRunning > "$STATE" ;;
  *) echo "REAL $*" ;;
esac
C
ln -s "$T/cask/bin/codex" "$T/brew/codex"
cat > "$T/stub/launchctl" <<'L'
#!/bin/sh
echo "launchctl $*" >> "$CALLS"
[ "${KICK_STARTS:-1}" = 1 ] && echo running > "$STATE"
# A restarted daemon writes a fresh pid file.
[ -n "${NEW_SERVER_PID:-}" ] && printf '{"pid":%s}' "$NEW_SERVER_PID" > "$CODEX_HOME/app-server-daemon/daemon.pid"
exit 0
L
cat > "$T/stub/ps" <<'P'
#!/bin/sh
# `ps eww -o command= -p PID` shows the environment; `ps -o command= -p PID` does not.
[ -n "${PS_FAIL:-}" ] && exit 1
pid=""; for a in "$@"; do pid="$a"; done
cmd="/x/codex app-server --listen unix://"
[ "$pid" = "${FOREIGN_PID:-none}" ] && cmd="/usr/bin/some-other-program"
if [ "$1" = eww ]; then
  case " ${DIRTY_PIDS:-} " in
    *" $pid "*) cmd="$cmd HOME=/h HERDR_PANE_ID=wE:p2" ;;
    *) cmd="$cmd HOME=/h" ;;
  esac
fi
echo "$cmd"
P
chmod +x "$T/localbin/codex" "$T/cask/bin/codex" "$T/stub/launchctl" "$T/stub/ps"

run() { PATH="$T/stub:$T/localbin:$T/brew:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$CD" "$@"; }
real_path="$(cd "$T/cask/bin" && pwd -P)/codex"

echo "A. real-bin"
is "it skips ~/.local/bin and follows the Homebrew symlink" "$(run real-bin)" "$real_path"
ln -s "$T/localbin" "$T/lb-link"
is "a symlinked alias of ~/.local/bin is skipped too" \
   "$(PATH="$T/lb-link:$T/brew:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$CD" real-bin)" "$real_path"
out="$(PATH="$T/localbin:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$CD" real-bin 2>&1)"; rc=$?
is "no real codex is an error" "$rc" 1
is "and it says so" "$(printf '%s' "$out" | grep -c 'no codex on PATH outside')" 1

echo "B. ensure"
echo running > "$STATE"; : > "$CALLS"
run ensure; is "a running daemon needs nothing" "$?" 0
is "and launchd is not touched" "$(grep -c launchctl "$CALLS")" 0
echo notRunning > "$STATE"; : > "$CALLS"
run ensure; is "a stopped daemon is started through launchd" "$?" 0
is "by kickstarting the agent" \
   "$(grep -c "launchctl kickstart gui/$(id -u)/be.netronix.codex-app-server" "$CALLS")" 1
echo notRunning > "$STATE"
out="$(KICK_STARTS=0 run ensure 2>&1)"; rc=$?
is "a daemon that will not start is an error" "$rc" 1
is "and names the deliberate escape" "$(printf '%s' "$out" | grep -c -- '--no-daemon')" 1
is "and how to load the agent" "$(printf '%s' "$out" | grep -c 'launchctl bootstrap')" 1

echo "C. check"
# Live processes stand in for the daemon: check only trusts a pid it can see running.
sleep 60 & A_PID=$!
sleep 60 & B_PID=$!
echo running > "$STATE"
printf '{"pid":%s,"processStartTime":"x"}' "$A_PID" > "$CODEX_HOME/app-server-daemon/daemon.pid"
printf '{"pid":%s,"processStartTime":"x"}' "$B_PID" > "$CODEX_HOME/app-server-daemon/daemon-updater.pid"
run check; is "a clean running daemon passes" "$?" 0
out="$(DIRTY_PIDS=$B_PID run check 2>&1)"; rc=$?
is "a daemon process carrying HERDR_* fails" "$rc" 1
is "the fix is named" "$(printf '%s' "$out" | grep -c 'codex-daemon restart')" 1
is "and its cost" "$(printf '%s' "$out" | grep -c 'disconnects every open Codex TUI')" 1
# An environment that cannot be read is not known to be clean, and `ps` is exactly what a
# sandbox denies. Inspection failure must fail the check, never pass it.
out="$(PS_FAIL=1 run check 2>&1)"; rc=$?
is "an environment that cannot be read fails" "$rc" 1
is "and says it could not inspect" "$(printf '%s' "$out" | grep -c 'cannot inspect')" 1
mv "$CODEX_HOME/app-server-daemon/daemon.pid" "$T/daemon.pid.bak"
out="$(run check 2>&1)"; rc=$?
is "a missing server pid file fails" "$rc" 1
is "and names the file" "$(printf '%s' "$out" | grep -c 'daemon.pid')" 1
mv "$T/daemon.pid.bak" "$CODEX_HOME/app-server-daemon/daemon.pid"
kill "$B_PID" 2>/dev/null; sleep 0.5
run check; is "a supervisor pid whose process is gone is skipped, not a failure" "$?" 0
echo notRunning > "$STATE"
out="$(run check 2>&1)"; rc=$?
is "a daemon that does not answer fails" "$rc" 1
is "and says so" "$(printf '%s' "$out" | grep -c 'not answering')" 1

echo "D. restart"
kill "$A_PID" 2>/dev/null
sleep 60 & A_PID=$!
sleep 60 & B_PID=$!
sleep 60 & C_PID=$!   # the server the restarted daemon reports
printf '{"pid":%s}' "$A_PID" > "$CODEX_HOME/app-server-daemon/daemon.pid"
printf '{"pid":%s}' "$B_PID" > "$CODEX_HOME/app-server-daemon/daemon-updater.pid"
echo running > "$STATE"; : > "$CALLS"
FOREIGN_PID="$B_PID" NEW_SERVER_PID="$C_PID" run restart; rc=$?
is "restart ends with a clean running daemon" "$rc" 0
is "it stops the daemon first" "$(grep -c 'codex stop' "$CALLS")" 1
sleep 0.5   # let bash reap the signalled child, or kill -0 still sees a zombie
is "a surviving Codex daemon process is signalled" "$(kill -0 "$A_PID" 2>/dev/null && echo alive || echo gone)" gone
is "a recycled pid belonging to something else is not" "$(kill -0 "$B_PID" 2>/dev/null && echo alive || echo gone)" alive
is "and the daemon is started again through launchd" "$(grep -c 'launchctl kickstart' "$CALLS")" 1

echo "E. the LaunchAgent"
rendered="$T/agent.plist"
chezmoi execute-template --file "$PLIST" > "$rendered" 2>"$T/tpl.err" \
  || { _fail "the plist template renders" "$(head -c 200 "$T/tpl.err")"; }
if plutil -lint "$rendered" >/dev/null 2>&1; then _pass "the rendered plist is valid"; else _fail "the rendered plist is valid" "$(plutil -lint "$rendered" 2>&1)"; fi
x() { plutil -extract "$1" raw -o - "$rendered" 2>/dev/null; }
is "the label is the one codex-daemon kickstarts" "$(x Label)" "be.netronix.codex-app-server"
is "it runs codex app-server daemon start" "$(x ProgramArguments.1) $(x ProgramArguments.2) $(x ProgramArguments.3)" "app-server daemon start"
is "the program is the real Homebrew binary, not the launcher" \
   "$(x ProgramArguments.0 | grep -c '/\.local/bin/')" 0
is "it runs at load" "$(x RunAtLoad)" true
is "launchd does not reap the daemon when start returns" "$(x AbandonProcessGroup)" true
is "it is not kept alive by launchd (the daemon supervises itself)" "$(x KeepAlive >/dev/null 2>&1 && echo set || echo unset)" unset
is "no HERDR_ variable is handed to the daemon" \
   "$(plutil -extract EnvironmentVariables json -o - "$rendered" 2>/dev/null | grep -c 'HERDR_')" 0
is "the PATH covers the mise shims" "$(x EnvironmentVariables.PATH | grep -c '/.local/share/mise/shims')" 1

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
chmod 755 tests/codex-daemon.test.sh
./tests/run.sh codex-daemon
```
Expected: the suite exits 2 with `missing file under test: …/executable_codex-daemon`.
(Here `./tests/run.sh codex-daemon` is still exact; once Task 8 adds `live-codex-daemon` the filter matches that too, so later steps execute `./tests/codex-daemon.test.sh` directly.)

- [ ] **Step 3: Write `dot_local/bin/executable_codex-daemon`**

```sh
#!/bin/sh
# codex-daemon - keep Codex's shared app-server daemon under launchd, with a clean environment.
#
# Managed by chezmoi (source: dot_local/bin/executable_codex-daemon).
# Design: docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md, section 5.
#
# Codex 0.157 runs every TUI against one shared daemon and runs hooks inside it. Spawned by
# a TUI, the daemon keeps that pane's HERDR_* environment, and herdr's hook then reports
# every thread against that one pane. So launchd starts it (be.netronix.codex-app-server)
# and features.daemon_auto_start stays false.
#
#   codex-daemon real-bin   the real Codex binary: the first `codex` on PATH outside
#                           $XDG_BIN_HOME (~/.local/bin), symlinks followed
#   codex-daemon ensure     start the daemon through launchd unless it already answers
#   codex-daemon check      exit 0 only if it answers AND carries no HERDR_* variable
#   codex-daemon restart    fix a contaminated daemon; disconnects every open Codex TUI
set -eu

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
LABEL="${CODEX_DAEMON_LABEL:-be.netronix.codex-app-server}"
PIDS="$CODEX_HOME_DIR/app-server-daemon"

die() { printf 'codex-daemon: %s\n' "$1" >&2; exit 1; }

# A subshell body, so the IFS and noglob changes cannot leak into the caller.
real_bin() (
  skip="${XDG_BIN_HOME:-$HOME/.local/bin}"
  skip="$(cd "$skip" 2>/dev/null && pwd -P || printf '%s' "$skip")"
  IFS=:
  set -f
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    canon="$(cd "$dir" 2>/dev/null && pwd -P || printf '%s' "$dir")"
    [ "$canon" = "$skip" ] && continue
    if [ -f "$dir/codex" ] && [ -x "$dir/codex" ]; then
      readlink -f "$dir/codex" 2>/dev/null || printf '%s\n' "$dir/codex"
      exit 0
    fi
  done
  exit 1
)

answering() {
  "$REAL" app-server daemon version 2>/dev/null | grep -q '"status":"running"'
}

pid_of() { # pid_of <pid-file>: the JSON "pid" field
  [ -r "$1" ] || return 1
  sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$1" | head -1
}

# inspect <pid>: print the process's command line with its environment (`ps eww` appends
# it). Exit 2 if the process is gone, 1 if it is alive but cannot be read. A read failure
# must never pass as clean: `ps` is exactly what a sandbox denies.
inspect() {
  kill -0 "$1" 2>/dev/null || return 2
  words="$(ps eww -o command= -p "$1" 2>/dev/null)" || return 1
  [ -n "$words" ] || return 1
  printf '%s\n' "$words"
}

cmd_ensure() {
  answering && return 0
  launchctl kickstart "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  wait="${CODEX_DAEMON_WAIT:-10}"
  i=0
  while [ "$i" -lt "$wait" ]; do
    sleep 1
    i=$((i + 1))
    answering && return 0
  done
  die "the Codex daemon is not running and did not start within ${wait}s.
  Is the agent loaded?  launchctl print gui/$(id -u)/$LABEL
  Load it:              launchctl bootstrap gui/$(id -u) $HOME/Library/LaunchAgents/$LABEL.plist
  Or deliberately without the daemon:  codex --no-daemon"
}

cmd_check() {
  answering || die "the Codex daemon is not answering - run: codex-daemon ensure"
  server="$(pid_of "$PIDS/daemon.pid" || true)"
  [ -n "$server" ] || die "cannot find the daemon's pid in $PIDS/daemon.pid; its environment cannot be verified"
  dirty=""
  for f in "$PIDS/daemon.pid" "$PIDS/daemon-updater.pid"; do
    pid="$(pid_of "$f" || true)"
    [ -n "$pid" ] || continue
    rc=0
    words="$(inspect "$pid")" || rc=$?
    if [ "$rc" = 2 ]; then
      # A supervisor that has exited carries nothing; the server itself must be there.
      [ "$pid" != "$server" ] || die "the daemon answers but its pid $pid (from $f) is gone; its environment cannot be verified"
      continue
    fi
    [ "$rc" = 0 ] || die "cannot inspect the daemon process $pid (is ps denied here?); its environment cannot be verified"
    if printf '%s\n' "$words" | tr ' ' '\n' | grep -q '^HERDR_'; then dirty="$dirty $pid"; fi
  done
  [ -z "$dirty" ] && return 0
  die "the Codex daemon (pid$dirty) carries a herdr pane's environment, so herdr's own hook
  reports every new thread against that one pane.
  Fix: codex-daemon restart
  This disconnects every open Codex TUI; relaunch them afterwards."
}

cmd_restart() {
  "$REAL" app-server daemon stop >/dev/null 2>&1 || true
  # A supervisor that survives `stop` would restart the server with its old environment.
  # Only a pid that is still a Codex daemon process is signalled: pid files outlive their
  # processes, and a recycled pid belongs to someone else.
  for f in "$PIDS/daemon.pid" "$PIDS/daemon-updater.pid"; do
    pid="$(pid_of "$f")" || continue
    [ -n "$pid" ] || continue
    case "$(ps -o command= -p "$pid" 2>/dev/null)" in
      *codex*app-server*) kill "$pid" 2>/dev/null || true ;;
    esac
  done
  sleep 1
  cmd_ensure
  cmd_check
}

case "${1:-}" in
  real-bin)
    real_bin || die "no codex on PATH outside ${XDG_BIN_HOME:-$HOME/.local/bin}" ;;
  ensure|check|restart)
    REAL="$(real_bin)" || die "no codex on PATH outside ${XDG_BIN_HOME:-$HOME/.local/bin}"
    "cmd_$1" ;;
  *) die "usage: codex-daemon real-bin | ensure | check | restart" ;;
esac
```

- [ ] **Step 4: Write `Library/LaunchAgents/be.netronix.codex-app-server.plist.tmpl`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Start Codex's shared app-server daemon at login, with a clean environment.

  Managed by chezmoi (source: Library/LaunchAgents/be.netronix.codex-app-server.plist.tmpl).
  Loaded by .scripts/configure.sh; load by hand with:
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/be.netronix.codex-app-server.plist

  Why launchd and not the first TUI: a daemon spawned by a TUI keeps that pane's HERDR_*
  environment, and herdr's hook, which runs inside the daemon, then reports every Codex thread
  against that one pane. features.daemon_auto_start is pinned false so no TUI spawns one;
  `codex-daemon ensure` kickstarts this agent when an interactive start finds none running.

  `daemon start` returns once the daemon's own supervisor is up, so there is no KeepAlive;
  AbandonProcessGroup keeps launchd from reaping what it started. PATH mirrors what an
  interactive shell would activate, so commands the reviewer runs find the same toolchains.
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>be.netronix.codex-app-server</string>

    <key>ProgramArguments</key>
    <array>
        <string>{{ if .is_arm }}/opt/homebrew{{ else }}/usr/local{{ end }}/bin/codex</string>
        <string>app-server</string>
        <string>daemon</string>
        <string>start</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>{{ .chezmoi.homeDir }}/.local/share/mise/shims:{{ .chezmoi.homeDir }}/.local/bin:{{ if .is_arm }}/opt/homebrew/bin:/opt/homebrew/sbin:{{ end }}/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>WorkingDirectory</key>
    <string>{{ .chezmoi.homeDir }}</string>

    <key>RunAtLoad</key>
    <true/>

    <key>AbandonProcessGroup</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
./tests/run.sh codex-daemon
```
Expected: `ok    codex-daemon  N/N`, where N is the assertion count, with 0 failed. (From Task 8 on, run this suite as `./tests/codex-daemon.test.sh`: the filter would also match `live-codex-daemon`.)

- [ ] **Step 6: Commit**

```bash
git -C ~/.local/share/chezmoi branch --show-current   # feat/xreview-codex-daemon
git -C ~/.local/share/chezmoi add --chmod=+x tests/codex-daemon.test.sh dot_local/bin/executable_codex-daemon
git -C ~/.local/share/chezmoi add Library/LaunchAgents/be.netronix.codex-app-server.plist.tmpl
git -C ~/.local/share/chezmoi commit -m "Start the Codex daemon from launchd with a clean environment"
```

---

### Task 2: `codex` launcher, and the host shim resolving past it

**Files:**
- Create: `dot_local/bin/executable_codex`
- Modify: `dot_local/bin/executable_codex-code-mode-host:21-29`
- Create: `tests/codex-launcher.test.sh`
- Modify: `tests/codex-code-mode-host.test.sh`

**Interfaces:**
- Consumes: `codex-daemon real-bin | ensure | check` (Task 1).
- Produces: `~/.local/bin/codex`, which:
  - execs the real binary for non-interactive subcommands and for an explicit `--no-daemon`;
  - exits 2 on refused flags (`-c` and friends, `--remote`);
  - exits 1 when the daemon cannot be started.

- [ ] **Step 1: Write the failing launcher test** — `tests/codex-launcher.test.sh`

```bash
#!/usr/bin/env bash
# Tests dot_local/bin/executable_codex, the launcher that makes every interactive Codex
# start attach to the shared daemon (spec section 5). codex-daemon is stubbed, so each
# case asserts only the launcher's own classification: which starts need the daemon,
# which are refused, and which pass straight through.
#
# Run: ./tests/run.sh codex-launcher   (sandboxed is fine)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/dot_local/bin/executable_codex"
[ -f "$L" ] || { echo "missing file under test: $L" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/codex-launcher.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/localbin" "$T/brew"
export CALLS="$T/calls" REALBIN="$T/brew/codex"
cp "$L" "$T/localbin/codex"
printf '#!/bin/sh\necho "REAL $*"\n' > "$T/brew/codex"
cat > "$T/localbin/codex-daemon" <<'D'
#!/bin/sh
echo "codex-daemon $*" >> "$CALLS"
case "$1" in
  real-bin) echo "$REALBIN" ;;
  ensure) exit "${ENSURE_RC:-0}" ;;
  check) [ "${CHECK_RC:-0}" = 0 ] || echo "codex-daemon: the daemon carries a herdr pane's environment" >&2
         exit "${CHECK_RC:-0}" ;;
esac
D
chmod +x "$T/localbin/codex" "$T/brew/codex" "$T/localbin/codex-daemon"

run() { : > "$CALLS"; PATH="$T/localbin:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$T/localbin/codex" "$@" 2>"$T/err"; }
ensured() { grep -c 'codex-daemon ensure' "$CALLS"; }

echo "A. interactive starts attach to the daemon"
is "a bare start execs the real binary"          "$(run)" "REAL "
is "after ensuring the daemon"                   "$(ensured)" 1
is "resume is interactive"                       "$(run resume abc)" "REAL resume abc"
is "and ensures the daemon"                      "$(ensured)" 1
is "fork is interactive"                         "$(run fork)" "REAL fork"
is "a prompt argument is interactive"            "$(run 'fix the tests')" "REAL fix the tests"
is "option values are not mistaken for commands" "$(run -m exec resume x)" "REAL -m exec resume x"
is "and that start ensures the daemon"           "$(ensured)" 1
is "the pane command's own flags are allowed"    "$(run --sandbox read-only --ask-for-approval never)" "REAL --sandbox read-only --ask-for-approval never"

echo "B. a daemon that cannot start refuses the session"
out="$(ENSURE_RC=1 run)"; rc=$?
is "the start is refused"        "$rc" 1
is "and the real binary never runs" "$out" ""

echo "C. a contaminated daemon warns but does not block"
out="$(CHECK_RC=1 run)"; rc=$?
is "the session still starts"    "$out" "REAL "
is "with a warning"              "$(grep -c 'starting anyway' "$T/err")" 1

echo "D. overrides that would leave the daemon are refused"
for args in "-c model=x" "--config=model=x" "--enable foo" "--disable=foo" "resume -c k=v id"; do
  # shellcheck disable=SC2086
  out="$(run $args)"; rc=$?
  is "'$args' is refused"        "$rc" 2
  is "'$args' names --no-daemon" "$(grep -c -- '--no-daemon' "$T/err")" 1
  is "'$args' never starts"      "$out" ""
done

echo "E. --remote is refused for an interactive start"
out="$(run --remote ws://h:1)"; rc=$?
is "--remote <addr> is refused" "$rc" 2
is "and says herdr cannot map it" "$(grep -c 'herdr' "$T/err")" 1
out="$(run --remote=ws://h:1)"; rc=$?
is "--remote=<addr> is refused" "$rc" 2

echo "F. explicit --no-daemon and non-interactive commands pass straight through"
is "--no-daemon passes through"          "$(run --no-daemon)" "REAL --no-daemon"
is "without touching the daemon"         "$(ensured)" 0
is "--no-daemon keeps its overrides"     "$(run --no-daemon -c k=v)" "REAL --no-daemon -c k=v"
is "exec passes through"                 "$(run exec 'do x')" "REAL exec do x"
is "exec keeps its -c overrides"         "$(run -c k=v exec foo)" "REAL -c k=v exec foo"
is "app-server passes through"           "$(run app-server daemon version)" "REAL app-server daemon version"
is "and none of them ensured the daemon" "$(ensured)" 0
is "--help passes through"               "$(run --help)" "REAL --help"
is "--version passes through"            "$(run --version)" "REAL --version"

echo "G. no real binary is an error, never a loop"
printf '#!/bin/sh\nexit 1\n' > "$T/localbin/codex-daemon"; chmod +x "$T/localbin/codex-daemon"
run >/dev/null; is "the launcher exits 127" "$?" 127

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod 755 tests/codex-launcher.test.sh
./tests/run.sh codex-launcher
```
Expected: exit 2, `missing file under test: …/executable_codex`.

- [ ] **Step 3: Write `dot_local/bin/executable_codex`**

```sh
#!/bin/sh
# codex - start interactive Codex sessions on the shared daemon, or refuse.
#
# Managed by chezmoi (source: dot_local/bin/executable_codex).
# Design: docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md, section 5.
#
# ~/.local/bin is first on PATH, so this shadows the Homebrew binary. Every interactive start
# must attach to the daemon: with features.daemon_auto_start off, a TUI that finds no daemon
# runs its own server instead, off the daemon and out of xreview's reach. So the daemon is
# started through launchd first, and a start that would silently leave it is refused.
# `--no-daemon` is the one deliberate escape (operator decision, 2026-09-26).
#
# Anything that needs the real binary resolves it with `codex-daemon real-bin`, never
# `command -v codex`, which answers with this script.
set -eu

real="$(codex-daemon real-bin)" || {
  echo "codex: no real codex on PATH outside ${XDG_BIN_HOME:-$HOME/.local/bin}" >&2
  exit 127
}

# Subcommands that are not interactive sessions (codex --help, 0.157.1).
PASSTHROUGH=" exec e review login logout mcp plugin app-server remote-control app completion update doctor sandbox debug apply a queue archive delete migrate-rollouts unarchive cloud exec-server features help agents "

sub=""
overrides=0
nodaemon=0
remote=0
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    --no-daemon) nodaemon=1 ;;
    --remote) remote=1; skip=1 ;;
    --remote=*) remote=1 ;;
    -c|--config|--enable|--disable) overrides=1; skip=1 ;;
    -c?*|--config=*|--enable=*|--disable=*) overrides=1 ;;
    -h|--help|-V|--version) [ -n "$sub" ] || sub="$a" ;;
    -m|--model|-p|--profile|-s|--sandbox|-a|--ask-for-approval|-C|--cd|-i|--image|--add-dir|--remote-auth-token-env|--local-provider) skip=1 ;;
    -*) ;;
    *) [ -n "$sub" ] || sub="$a" ;;
  esac
done

case "$PASSTHROUGH" in *" $sub "*) exec "$real" "$@" ;; esac
case "$sub" in -h|--help|-V|--version) exec "$real" "$@" ;; esac
if [ "$nodaemon" = 1 ]; then exec "$real" "$@"; fi

if [ "$remote" = 1 ]; then
  cat >&2 <<'MSG'
codex: refusing --remote for an interactive session. A remote server runs its own hooks, so
herdr could never learn this session's thread id. Start it on this machine's daemon instead.
MSG
  exit 2
fi
if [ "$overrides" = 1 ]; then
  cat >&2 <<'MSG'
codex: refusing -c/--config/--enable/--disable for an interactive session. Any override makes
the session run its own server instead of the shared daemon. Put the setting in
~/.codex/config.toml (chezmoi: dot_codex/modify_private_config.toml), or opt out explicitly:
  codex --no-daemon ...
MSG
  exit 2
fi

codex-daemon ensure || exit 1
codex-daemon check || printf 'codex: starting anyway; xreview refuses to dispatch until the daemon is restarted\n' >&2
exec "$real" "$@"
```

- [ ] **Step 4: Run the launcher test to verify it passes**

```bash
./tests/run.sh codex-launcher
```
Expected: `ok    codex-launcher  N/N`, 0 failed.

- [ ] **Step 5: Extend the host-shim test so it fails**

In `tests/codex-code-mode-host.test.sh`:

1. Directly after `mkdir -p "$T/cask/1.0.0/bin" "$T/bin"`, add:
```bash
# The shim now resolves the real binary through codex-daemon, which skips ~/.local/bin.
mkdir -p "$T/localbin"
cp "$ROOT/dot_local/bin/executable_codex-daemon" "$T/localbin/codex-daemon"
chmod +x "$T/localbin/codex-daemon"
```
2. Replace the `run()` helper with:
```bash
run() { PATH="$T/localbin:$T/bin:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$SHIM" "$@" 2>&1; }
```
3. In section C, replace the "no codex on PATH" block with:
```bash
out="$(PATH="$T/localbin:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$SHIM" 2>&1)"; rc=$?
is "no codex on PATH is an error"      "$rc" "127"
is "and it says why"                   "$(printf '%s' "$out" | grep -c 'no real codex on PATH')" "1"
```
4. Before the final `RESULT` line, add section D:
```bash
echo
echo "D. installed beside the launcher, it never resolves to itself"
# ~/.local/bin/codex is now a script. `command -v codex` would answer with it, the sibling
# host would be the shim itself, and the shim would exec itself forever. Bounded, so a
# regression fails the suite instead of hanging it.
printf '#!/bin/sh\necho HOST-3.0.0 "$@"\n' > "$T/cask/2.0.0/bin/codex-code-mode-host"
chmod +x "$T/cask/2.0.0/bin/codex-code-mode-host"
cp "$ROOT/dot_local/bin/executable_codex" "$T/localbin/codex"
cp "$SHIM" "$T/localbin/codex-code-mode-host"
chmod +x "$T/localbin/codex" "$T/localbin/codex-code-mode-host"
( PATH="$T/localbin:$T/bin:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" \
    sh "$T/localbin/codex-code-mode-host" --x > "$T/d.out" 2>&1 ) &
dpid=$!
( sleep 5; kill "$dpid" 2>/dev/null ) & wpid=$!
wait "$dpid" 2>/dev/null; kill "$wpid" 2>/dev/null
is "the installed shim reaches the cask's host" "$(cat "$T/d.out")" "HOST-3.0.0 --x"
```

- [ ] **Step 6: Run the shim test to verify it fails**

```bash
./tests/run.sh codex-code-mode-host
```
Expected: FAIL on "and it says why" (the shim still says `no codex on PATH`) and on section D (it resolves to `$T/localbin`, finds no host there or loops, and is killed after 5 s).

- [ ] **Step 7: Change the shim** — in `dot_local/bin/executable_codex-code-mode-host`, replace lines 21–29 (the `codex_bin=` block through `host=`) with:

```sh
# ~/.local/bin/codex is the daemon launcher, a script, so `command -v codex` would answer
# with it and the "sibling" host would be this shim, exec'ing itself forever. The real
# binary is resolved the one way everything here resolves it.
real="$(codex-daemon real-bin 2>/dev/null)" || {
  echo "codex-code-mode-host: no real codex on PATH outside ${XDG_BIN_HOME:-$HOME/.local/bin} to resolve the host from" >&2
  exit 127
}
host="$(dirname "$real")/codex-code-mode-host"
```

- [ ] **Step 8: Run both suites to verify they pass**

```bash
./tests/run.sh codex-launcher codex-code-mode-host && ./tests/codex-daemon.test.sh
```
Expected: both run.sh suites `ok`, and `codex-daemon` ends `RESULT: N passed, N total, 0 failed`.

- [ ] **Step 9: Commit**

```bash
git -C ~/.local/share/chezmoi branch --show-current   # feat/xreview-codex-daemon
git -C ~/.local/share/chezmoi add --chmod=+x dot_local/bin/executable_codex tests/codex-launcher.test.sh
git -C ~/.local/share/chezmoi add dot_local/bin/executable_codex-code-mode-host tests/codex-code-mode-host.test.sh
git -C ~/.local/share/chezmoi commit -m "Launch interactive Codex on the daemon, and resolve the host past the launcher"
```

---

### Task 3: The pane-map hook

**Files:**
- Create: `dot_codex/executable_herdr-codex-pane-map.py`
- Create: `tests/herdr-codex-pane-map.test.sh`

**Interfaces:**
- Produces: `~/.codex/herdr-codex-pane-map.py`.
  - As a hook it reads `SessionStart` JSON on stdin; `--reconcile` runs a pass with no input.
  - It always exits 0.
  - Test knobs: `HERDR_BIN` (used exclusively when set), `PANE_MAP_RETRY_SECS` (default 5), `PANE_MAP_DEADLINE_SECS` (default 8; the whole run, including every herdr call, stays inside it, under the 10 s hook timeout).
  - For every herdr pane with `agent == "codex"` whose title (`terminal_title_stripped`, else `terminal_title`) starts with a UUID different from its `agent_session.value`, it calls `herdr pane report-agent-session <pane> --source herdr:codex --agent codex --agent-session-id <uuid> --seq <ns>`, plus `--session-start-source <src>` for the starting session's pane.

- [ ] **Step 1: Write the failing test** — `tests/herdr-codex-pane-map.test.sh`

```bash
#!/usr/bin/env bash
# Tests dot_codex/executable_herdr-codex-pane-map.py (spec section 6). The hook runs inside
# the Codex daemon on every SessionStart and reconciles herdr's session id for EVERY Codex
# pane from the thread id at the start of its title - so one wrong report, from anywhere, is
# repaired by the next session start. It must never guess and never fail a session.
#
# Run: ./tests/run.sh herdr-codex-pane-map   (sandboxed is fine)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/dot_codex/executable_herdr-codex-pane-map.py"
[ -f "$HOOK" ] || { echo "missing file under test: $HOOK" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/pane-map.XXXXXX")"; trap 'rm -rf "$T"' EXIT
export CALLS="$T/calls" PANES="$T/panes.json" HERDR_BIN="$T/herdr" PANE_MAP_RETRY_SECS=1
cat > "$T/herdr" <<'H'
#!/bin/sh
case "$1 $2" in
  "pane list") [ -n "${HERDR_FAIL:-}" ] && exit 1; cat "$PANES" ;;
  "pane report-agent-session") shift 2; echo "$*" >> "$CALLS" ;;
esac
exit 0
H
chmod +x "$T/herdr"
U1=11111111-1111-4111-8111-111111111111
U2=22222222-2222-4222-8222-222222222222
U3=33333333-3333-4333-8333-333333333333
pane() { # pane <id> <agent> <title> <session-or-empty>
  local s='null'; [ -n "$4" ] && s="{\"value\":\"$4\"}"
  printf '{"pane_id":"%s","agent":"%s","terminal_title":"◐ %s","terminal_title_stripped":"%s","agent_session":%s}' \
    "$1" "$2" "$3" "$3" "$s"
}
fixture() { printf '{"result":{"panes":[%s]}}' "$1" > "$PANES"; : > "$CALLS"; }
hook() { python3 "$HOOK" "$@"; }
reports() { grep -c . "$CALLS" 2>/dev/null || true; }

echo "A. --reconcile repairs every Codex pane whose title disagrees"
fixture "$(pane w1:p2 codex "$U1 | t | d" "")","$(pane w2:p2 codex "$U2 | t | d" "$U2")","$(pane w3:p2 codex "Greet user | chezmoi" "$U3")","$(pane w4:p1 claude "$U3 | x" "")","$(pane w5:p2 codex "$U3 | t | d" "$U1")"
hook --reconcile; rc=$?
is "it exits 0"                                     "$rc" 0
is "two panes disagreed, two reports"               "$(reports)" 2
is "a pane with no session gets its title's id"     "$(grep -c "^w1:p2 --source herdr:codex --agent codex --agent-session-id $U1 --seq [0-9]*$" "$CALLS")" 1
is "a pane showing another pane's id is corrected"  "$(grep -c "^w5:p2 .*--agent-session-id $U3 " "$CALLS")" 1
is "a matching pane is left alone"                  "$(grep -c '^w2:p2' "$CALLS")" 0
is "a title without a UUID is never guessed from"   "$(grep -c '^w3:p2' "$CALLS")" 0
is "a non-Codex pane is ignored"                    "$(grep -c '^w4:p1' "$CALLS")" 0

echo "B. as a SessionStart hook"
fixture "$(pane w1:p2 codex "$U1 | t | d" "")"
printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup"}' "$U1" | hook; rc=$?
is "it exits 0" "$rc" 0
is "the starting session's pane carries its start source" \
   "$(grep -c "^w1:p2 .*--agent-session-id $U1 .*--session-start-source startup$" "$CALLS")" 1

echo "C. a session whose id is on no title yet"
fixture "$(pane w1:p2 codex "$U1 | t | d" "$U1")"
start=$(date +%s)
printf '{"session_id":"%s","source":"startup"}' "$U2" | hook; rc=$?
took=$(( $(date +%s) - start ))
is "it gives up and exits 0"              "$rc" 0
is "within its retry budget"              "$([ "$took" -le 3 ] && echo yes || echo "no ($took s)")" yes
is "and reports nothing it cannot see"    "$(reports)" 0

echo "D. repeated passes never report the same thing twice"
fixture "$(pane w1:p2 codex "$U1 | t | d" "")"
printf '{"session_id":"%s"}' "$U2" | hook
is "one report despite several retry passes" "$(reports)" 1

echo "F. the whole run stays inside its deadline"
# Four reports that each stall for 2 s would take 8 s; the hook timeout is 10 s and the
# pass must never be what Codex kills.
cat > "$T/slowherdr" <<'H'
#!/bin/sh
case "$1 $2" in
  "pane list") cat "$PANES" ;;
  "pane report-agent-session") sleep 2 ;;
esac
exit 0
H
chmod +x "$T/slowherdr"
U4=44444444-4444-4444-8444-444444444444
fixture "$(pane w1:p2 codex "$U1 | t" "")","$(pane w2:p2 codex "$U2 | t" "")","$(pane w3:p2 codex "$U3 | t" "")","$(pane w6:p2 codex "$U4 | t" "")"
start=$(date +%s)
HERDR_BIN="$T/slowherdr" PANE_MAP_DEADLINE_SECS=3 hook --reconcile; rc=$?
took=$(( $(date +%s) - start ))
is "stalled reports still end within the deadline" "$([ "$took" -le 4 ] && echo yes || echo "no ($took s)")" yes
is "and exit 0" "$rc" 0

echo "E. it never fails a session"
fixture ""
HERDR_FAIL=1 hook --reconcile; is "herdr failing exits 0" "$?" 0
printf 'not json' > "$PANES"; hook --reconcile; is "garbage from herdr exits 0" "$?" 0
printf '{{{' | hook; is "garbage on stdin exits 0" "$?" 0
HERDR_BIN="$T/nonexistent" hook --reconcile; is "no herdr at all exits 0" "$?" 0

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod 755 tests/herdr-codex-pane-map.test.sh
./tests/run.sh herdr-codex-pane-map
```
Expected: exit 2, `missing file under test`.

- [ ] **Step 3: Write `dot_codex/executable_herdr-codex-pane-map.py`**

```python
#!/usr/bin/env python3
"""Reconcile herdr's session id for every Codex pane from the thread id in its title.

Managed by chezmoi (source: dot_codex/executable_herdr-codex-pane-map.py).
Design: docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md, section 6.

Runs inside the Codex daemon as a SessionStart hook (hook JSON on stdin), beside herdr's own
hook, which exits there because the daemon carries no pane environment. Every TUI puts its
thread id first in its terminal title (tui.terminal_title), so the title is the join between
a pane and its thread. Each pass repairs every Codex pane, so one wrong report from anywhere
is fixed by the next session start. An id that is not on a title is never reported.

`--reconcile` runs one pass without hook input. The whole run - listing, every report and
the retries - shares one deadline (PANE_MAP_DEADLINE_SECS, 8 s), inside the 10 s hook timeout.
Never exits non-zero; never blocks a session.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

UUID = re.compile(r"^\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?![0-9a-f-])")
DEADLINE = time.monotonic() + float(os.environ.get("PANE_MAP_DEADLINE_SECS", "8"))


def left():
    return DEADLINE - time.monotonic()


def run(cmd):
    """Run a herdr command bounded by what is left of the deadline; None when out of time."""
    budget = min(3.0, left())
    if budget <= 0:
        return None
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=budget)
    except Exception:
        return None


def herdr_bin():
    env = os.environ.get("HERDR_BIN")
    if env:
        return env if os.access(env, os.X_OK) else None
    for c in ("/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", shutil.which("herdr")):
        if c and os.access(c, os.X_OK):
            return c
    return None


def panes(herdr):
    out = run([herdr, "pane", "list"])
    try:
        return json.loads(out.stdout)["result"]["panes"] if out else []
    except Exception:
        return []


def title_uuid(pane):
    title = pane.get("terminal_title_stripped") or pane.get("terminal_title") or ""
    m = UUID.match(title)
    return m.group(1) if m else None


def report(herdr, pane_id, uuid, start_source):
    cmd = [herdr, "pane", "report-agent-session", pane_id, "--source", "herdr:codex",
           "--agent", "codex", "--agent-session-id", uuid, "--seq", str(time.time_ns())]
    if start_source:
        cmd += ["--session-start-source", start_source]
    run(cmd)


def reconcile(herdr, done, session_id=None, start_source=None):
    """One pass. Returns the set of ids currently on Codex pane titles."""
    seen = set()
    for p in panes(herdr):
        if left() <= 0:
            break
        if p.get("agent") != "codex":
            continue
        uuid = title_uuid(p)
        if not uuid:
            continue
        seen.add(uuid)
        current = (p.get("agent_session") or {}).get("value")
        key = (p.get("pane_id"), uuid)
        if uuid != current and key not in done and p.get("pane_id"):
            done.add(key)
            report(herdr, p["pane_id"], uuid, start_source if uuid == session_id else None)
    return seen


def main():
    herdr = herdr_bin()
    if not herdr:
        return
    done = set()
    if "--reconcile" in sys.argv[1:]:
        reconcile(herdr, done)
        return
    try:
        hook = json.loads(sys.stdin.read() or "{}")
    except Exception:
        hook = {}
    if not isinstance(hook, dict):
        hook = {}
    sid = hook.get("session_id") if isinstance(hook.get("session_id"), str) else None
    src = hook.get("source") if isinstance(hook.get("source"), str) else None
    retry_until = time.monotonic() + float(os.environ.get("PANE_MAP_RETRY_SECS", "5"))
    while True:
        seen = reconcile(herdr, done, sid, src)
        if not sid or sid in seen or time.monotonic() >= retry_until or left() <= 0.5:
            return
        time.sleep(0.5)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
```

- [ ] **Step 4: Run it to verify it passes**

```bash
./tests/run.sh herdr-codex-pane-map
```
Expected: `ok    herdr-codex-pane-map  N/N`.

- [ ] **Step 5: Commit**

```bash
git -C ~/.local/share/chezmoi branch --show-current   # feat/xreview-codex-daemon
git -C ~/.local/share/chezmoi add --chmod=+x dot_codex/executable_herdr-codex-pane-map.py tests/herdr-codex-pane-map.test.sh
git -C ~/.local/share/chezmoi commit -m "Reconcile herdr's Codex session ids from the pane titles"
```

---

### Task 4: Wire the title, the hook and the allowlist

**Files:**
- Modify: `dot_codex/modify_private_config.toml` (after the `tui.keymap` lines)
- Modify: `dot_codex/modify_private_hooks.json`
- Modify: `.chezmoiignore:92-93` (the `.codex` allowlist)
- Modify: `tests/codex-config.test.sh` (sections A2, H, I, J)

**Interfaces:**
- Consumes: the `~/.codex/herdr-codex-pane-map.py` path (Task 3).
- Produces:
  - `tui.terminal_title = ["thread-id", "thread-title", "current-dir"]` in `~/.codex/config.toml`.
  - `hooks.SessionStart` holds two entries: herdr's, unchanged, then `{"type":"command","command":"python3 '<home>/.codex/herdr-codex-pane-map.py'","timeout":10}`.

- [ ] **Step 1: Write the failing tests** — in `tests/codex-config.test.sh`:

1. After section A2, add:
```bash
echo "A3. every TUI puts its thread id first in its title"
# The pane-map hook and xreview join a pane to its thread through the title. Codex
# truncates long titles, so thread-id must be FIRST or it is the part that gets cut.
emit 'tui.terminal_title = ["current-dir"]'
has '^\s*terminal_title = \["thread-id", "thread-title", "current-dir"\]' "terminal_title pinned with thread-id first"
```
2. Replace section H's jq body with:
```bash
MAPCMD="python3 '$HOME/.codex/herdr-codex-pane-map.py'"
emit_hooks '{}'
if printf '%s' "$OUT" | jq -e --arg cmd "bash '$HOME/.codex/herdr-agent-state.sh' session" --arg map "$MAPCMD" '
  (keys == ["hooks"])
  and (.hooks | keys == ["SessionStart"])
  and (.hooks.SessionStart | length == 2)
  and (.hooks.SessionStart[0].hooks == [{type: "command", command: $cmd, timeout: 10}])
  and (.hooks.SessionStart[1].hooks == [{type: "command", command: $map, timeout: 10}])
' >/dev/null 2>&1; then
  _pass "fresh hooks.json has herdr's entry, then the pane-map entry"
else
  _fail "fresh hooks.json has herdr's entry, then the pane-map entry" "$(printf '%s' "$OUT" | head -c 300)"
fi
```
3. In section I, change the fixture so that it also carries a stale pane-map entry, and assert exactly one of each survives. Replace the `fixture=` line and the first jq check with:
```bash
fixture='{"other":42,"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/bin/true"}]},{"hooks":[{"type":"command","command":"bash '\''/old/.codex/herdr-agent-state.sh'\'' session","timeout":5}]},{"hooks":[{"type":"command","command":"python3 '\''/old/.codex/herdr-codex-pane-map.py'\''"}]}],"Stop":[{"hooks":[{"type":"command","command":"/bin/false"}]}]}}'
emit_hooks "$fixture"
first="$OUT"
if printf '%s' "$first" | jq -e --arg cmd "bash '$HOME/.codex/herdr-agent-state.sh' session" --arg map "$MAPCMD" '
  .other == 42
  and (.hooks.Stop[0].hooks[0].command == "/bin/false")
  and ([.hooks.SessionStart[] | select(any(.hooks[]?; .command == "/bin/true"))] | length == 1)
  and ([.hooks.SessionStart[]?.hooks[]? | select((.command // "") | contains("herdr-agent-state.sh"))] == [{type: "command", command: $cmd, timeout: 10}])
  and ([.hooks.SessionStart[]?.hooks[]? | select((.command // "") | contains("herdr-codex-pane-map.py"))] == [{type: "command", command: $map, timeout: 10}])
' >/dev/null 2>&1; then
  _pass "unrelated hooks survive and each stale entry is replaced exactly once"
else
  _fail "unrelated hooks survive and each stale entry is replaced exactly once" "$(printf '%s' "$first" | head -c 300)"
fi
```
4. In section J, change the target list to:
```bash
for target in .codex/config.toml .codex/herdr-agent-state.sh .codex/hooks.json .codex/herdr-codex-pane-map.py; do
```

- [ ] **Step 2: Run it to verify it fails**

```bash
./tests/run.sh codex-config
```
Expected: FAIL on A3, H, I, and J (`.codex/herdr-codex-pane-map.py is chezmoi-managed`).

- [ ] **Step 3: Pin the title** — in `dot_codex/modify_private_config.toml`, after the `tui.keymap.chat.interrupt_turn` line, add:

```
{{- /* Every TUI puts its thread id FIRST in its terminal title: the title is the join
       between a herdr pane and its Codex thread, for the pane-map hook and for xreview.
       Codex truncates long titles, so anything after the id may be cut but the id is not.
       Set here, never with -c: any -c override makes a TUI leave the shared daemon. */ -}}
{{- $config = setValueAtPath "tui.terminal_title" (list "thread-id" "thread-title" "current-dir") $config -}}
```

- [ ] **Step 4: Register the hook** — in `dot_codex/modify_private_hooks.json`, replace everything from the `{{- $cmd := printf …` line to the end of the file with:

```
{{- $cmd := printf "bash '%s/.codex/herdr-agent-state.sh' session" .chezmoi.homeDir -}}
{{- /* The pane-map hook reconciles herdr's session ids from the pane titles. Herdr's own
       hook exits inside the daemon (no pane environment there), so this is the one that
       reports. Spec: docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md §6. */ -}}
{{- $mapCmd := printf "python3 '%s/.codex/herdr-codex-pane-map.py'" .chezmoi.homeDir -}}
{{- /* Drop any existing entry of ours first, so re-applying cannot duplicate either. */ -}}
{{- $kept := list -}}
{{- range $start -}}
{{-   $ours := false -}}
{{-   range (get . "hooks" | default list) -}}
{{-     $c := get . "command" | default "" -}}
{{-     if or (contains "herdr-agent-state.sh" $c) (contains "herdr-codex-pane-map.py" $c) -}}
{{-       $ours = true -}}
{{-     end -}}
{{-   end -}}
{{-   if not $ours -}}{{- $kept = append $kept . -}}{{- end -}}
{{- end -}}
{{- $entry := dict "hooks" (list (dict "type" "command" "command" $cmd "timeout" 10)) -}}
{{- $mapEntry := dict "hooks" (list (dict "type" "command" "command" $mapCmd "timeout" 10)) -}}
{{- $hooks = set $hooks "SessionStart" (append (append $kept $entry) $mapEntry) -}}
{{- $cfg = set $cfg "hooks" $hooks -}}
{{ $cfg | toPrettyJson }}
```

- [ ] **Step 5: Allow the file** — in `.chezmoiignore`, after `!.codex/hooks.json`, add:

```
!.codex/herdr-codex-pane-map.py
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
./tests/run.sh codex-config herdr-codex-pane-map
chezmoi diff ~/.codex/hooks.json ~/.codex/config.toml ~/.codex/herdr-codex-pane-map.py
```
Expected: both suites `ok`. The diff shows only the new title line, the second hook entry and the new file.

- [ ] **Step 7: Commit**

```bash
git -C ~/.local/share/chezmoi branch --show-current   # feat/xreview-codex-daemon
git -C ~/.local/share/chezmoi add dot_codex/modify_private_config.toml dot_codex/modify_private_hooks.json .chezmoiignore tests/codex-config.test.sh
git -C ~/.local/share/chezmoi commit -m "Put the thread id in every Codex title and register the pane-map hook"
```

---

### Task 5: `xreview-rpc` and the findings schema

**Files:**
- Create: `dot_local/bin/executable_xreview-rpc`
- Create: `dot_config/xreview/findings.schema.json`
- Create: `tests/xreview-rpc.test.sh`

**Interfaces:**
- Produces:
  - `xreview-rpc health`: exit 0, or 5.
  - `xreview-rpc thread-status --thread ID`: prints `{"loaded":bool,"status":str,"running":bool}`, exit 0.
  - `xreview-rpc turn-start --thread ID --input FILE --schema FILE [--known FILE]`:
    - prints the turn id, exit 0;
    - exit 1: the daemon refused;
    - exit 5: unreachable, nothing sent;
    - exit 6: `turn/start` was sent but not answered, so the turn may be running.
    - `--known` first writes the thread's existing turn ids (a JSON list) to FILE, so an unanswered start can still be found later.
  - `xreview-rpc turn-wait --thread ID (--turn ID | --new-since FILE) --budget SECS [--schema FILE]`. `--new-since` resolves the oldest turn whose id is not in FILE's list. Every connection and call is bounded by the remaining budget. Exit codes:
    - exit 0: prints the answer, pretty JSON when a schema is given;
    - exit 1: failed, interrupted or unknown turn;
    - exit 3: still running at the budget;
    - exit 4: answer not schema-valid (raw text on stdout);
    - exit 5: unreachable for the whole budget.
  - `xreview-rpc thread-archive --thread ID`: exit 0, or 1.
  - Env: `XREVIEW_RPC_SOCK` (socket path), `XREVIEW_RPC_STDIO` (test transport command), `CODEX_HOME`.
  - Module functions `ws_frame(payload, opcode=1, mask=None) -> bytes`, `ws_parse(buf) -> (fin, opcode, payload, rest) | None`, and `validate(value, schema) -> list[str]`.
  - `~/.config/xreview/findings.schema.json`.

- [ ] **Step 1: Write the findings schema** — `dot_config/xreview/findings.schema.json`

The spec (§7.5) left `verdict` and `severity` untyped. Here they carry `"type": "string"`, because structured output wants every property typed.

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["verdict", "findings"],
  "properties": {
    "verdict": {"type": "string", "enum": ["approve", "changes"]},
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["severity", "file", "line", "summary", "failure_scenario"],
        "properties": {
          "severity": {"type": "string", "enum": ["P0", "P1", "P2", "P3"]},
          "file": {"type": "string"},
          "line": {"type": "integer"},
          "summary": {"type": "string"},
          "failure_scenario": {"type": "string"}
        }
      }
    }
  }
}
```

- [ ] **Step 2: Write the failing test** — `tests/xreview-rpc.test.sh`

```bash
#!/usr/bin/env bash
# Tests dot_local/bin/executable_xreview-rpc, xreview's client for the Codex daemon
# (spec section 7.1). The daemon speaks JSON-RPC over a WebSocket on a unix socket, but the
# Claude sandbox denies binding one (F20), so the fake daemon here speaks newline-delimited
# JSON on stdio through XREVIEW_RPC_STDIO. The WebSocket framing is tested as functions, and
# against the real daemon by live-codex-daemon.test.sh.
#
# Run: ./tests/run.sh xreview-rpc   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
RPC="$SRC/dot_local/bin/executable_xreview-rpc"
SCHEMA="$SRC/dot_config/xreview/findings.schema.json"
for f in "$RPC" "$SCHEMA"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/xreview-rpc.XXXXXX")"; trap 'rm -rf "$T"' EXIT
cat > "$T/fake.py" <<'PY'
# A fake Codex daemon on stdio. FAKE_SCENARIO holds {"runs": [run, ...]}; each process
# start takes the next run (FAKE_COUNTER), so a dropped connection and the reconnect can
# behave differently. A run maps a method to its response and to notifications sent after
# that response; "exit_after" drops the connection after that many messages sent,
# "drop_on" vanishes on receiving a method, and "silent" never answers a method.
import json, os, sys
scen = json.load(open(os.environ["FAKE_SCENARIO"]))
runs = scen.get("runs") or [scen]
n = 0
cf = os.environ.get("FAKE_COUNTER")
if cf:
    try:
        n = int(open(cf).read())
    except Exception:
        n = 0
    open(cf, "w").write(str(n + 1))
run = runs[min(n, len(runs) - 1)]
log = open(os.environ["FAKE_LOG"], "a")
sent = 0
def out(m):
    global sent
    sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush(); sent += 1
    if run.get("exit_after") is not None and sent >= run["exit_after"]:
        sys.exit(0)
for line in sys.stdin:
    m = json.loads(line); log.write(json.dumps(m) + "\n"); log.flush()
    meth = m.get("method")
    if meth in run.get("drop_on", []):        # accept the request, then vanish unanswered
        sys.exit(0)
    if "id" in m and meth and meth not in run.get("silent", []):
        resp = run.get("responses", {}).get(meth, {"result": {}})
        out(dict(resp, id=m["id"]))
        for note in run.get("after", {}).get(meth, []):
            out(note)
PY
export FAKE_LOG="$T/log" FAKE_COUNTER="$T/counter" FAKE_SCENARIO="$T/scenario.json"
export XREVIEW_RPC_STDIO="python3 $T/fake.py"
scenario() { printf '%s' "$1" > "$FAKE_SCENARIO"; : > "$FAKE_LOG"; rm -f "$FAKE_COUNTER"; }
rpc() { python3 "$RPC" "$@"; }
params() { jq -c "select(.method == \"$1\") | .params" "$FAKE_LOG" | head -1; }
ANSWER='{"verdict":"changes","findings":[{"severity":"P1","file":"a.sh","line":3,"summary":"s","failure_scenario":"f"}]}'
turn() { # turn <status> <final-text>
  jq -nc --arg s "$1" --arg t "$2" '{id:"turn-1",status:$s,
    error:(if $s == "completed" then null else {message:"boom"} end),
    items:[{type:"userMessage"},{type:"agentMessage",phase:"final_answer",text:$t}]}'
}
listing() { jq -nc --argjson t "$1" '{result:{data:[$t]}}'; }

echo "A. WebSocket framing"
out="$(python3 - "$RPC" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("xreview_rpc", sys.argv[1])
spec = importlib.util.spec_from_loader("xreview_rpc", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
ok = True
for n in (5, 200, 70000):          # 7-bit, 16-bit and 64-bit length encodings
    p = bytes(range(256)) * (n // 256) + b"x" * (n % 256)
    f = m.ws_frame(p, mask=b"\x01\x02\x03\x04")
    ok &= m.ws_parse(f) == (True, 1, p, b"")
    ok &= m.ws_parse(f[:-1]) is None
ok &= m.ws_parse(b"\x81\x02hi" + b"tail") == (True, 1, b"hi", b"tail")   # server frames are unmasked
print("ok" if ok else "bad")
PY
)"
is "frames round-trip at every length encoding, and partial frames wait" "$out" ok

echo "B. health"
scenario '{}'
rpc health; is "a daemon that answers initialize is healthy" "$?" 0
is "the client sends initialized after initialize" "$(jq -r 'select(.method=="initialized") | .method' "$FAKE_LOG")" initialized
XREVIEW_RPC_STDIO=false rpc health 2>/dev/null; is "a daemon that goes away is unreachable (5)" "$?" 5
env -u XREVIEW_RPC_STDIO XREVIEW_RPC_SOCK="$T/no.sock" python3 "$RPC" health 2>/dev/null
is "a missing socket is unreachable (5)" "$?" 5

echo "C. thread-status"
scenario '{"responses":{"thread/read":{"result":{"thread":{"status":{"type":"active","activeFlags":[]}}}}}}'
is "an active thread is loaded and running" "$(rpc thread-status --thread th | jq -c '[.loaded,.running]')" '[true,true]'
scenario '{"responses":{"thread/read":{"result":{"thread":{"status":{"type":"idle"}}}}}}'
is "an idle thread is loaded and not running" "$(rpc thread-status --thread th | jq -c '[.loaded,.running]')" '[true,false]'
scenario '{"responses":{"thread/read":{"error":{"code":-32600,"message":"no thread"}}}}'
is "an unknown thread is not loaded" "$(rpc thread-status --thread th | jq -c '.loaded')" false

echo "D. turn-start"
printf 'the packet\n' > "$T/in"
scenario '{"responses":{"turn/start":{"result":{"turn":{"id":"turn-9","status":"inProgress"}}}}}'
is "it prints the turn id" "$(rpc turn-start --thread th --input "$T/in" --schema "$SCHEMA")" turn-9
p="$(params turn/start)"
is "the turn targets the thread"          "$(printf '%s' "$p" | jq -r .threadId)" th
is "the input is the packet file"         "$(printf '%s' "$p" | jq -r '.input[0].text')" "the packet"
is "read-only is set on the turn itself"  "$(printf '%s' "$p" | jq -r .sandboxPolicy.type)" readOnly
is "approval is never, on the turn"       "$(printf '%s' "$p" | jq -r .approvalPolicy)" never
is "the findings schema is the outputSchema" "$(printf '%s' "$p" | jq -c .outputSchema)" "$(jq -c . "$SCHEMA")"
scenario '{"responses":{"turn/start":{"error":{"code":-1,"message":"busy"}}}}'
rpc turn-start --thread th --input "$T/in" --schema "$SCHEMA" 2>/dev/null
is "a refused turn/start exits 1" "$?" 1
# Sent but never answered is not "not started": the turn may be running. It gets its own
# exit code, and --known has already recorded what was on the thread before it.
scenario '{"responses":{"thread/turns/list":{"result":{"data":[{"id":"t-old","status":"completed","items":[]}]}}},"drop_on":["turn/start"]}'
rpc turn-start --thread th --input "$T/in" --schema "$SCHEMA" --known "$T/known" 2>/dev/null
is "an unanswered turn/start exits 6" "$?" 6
is "the thread's earlier turns were recorded first" "$(jq -c . "$T/known")" '["t-old"]' 

echo "E. turn-wait on a turn that already finished"
scenario "$(jq -nc --argjson l "$(listing "$(turn completed "$ANSWER")")" '{responses:{"thread/turns/list":$l}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA")"; rc=$?
is "it exits 0"                         "$rc" 0
is "it prints the schema-valid answer"  "$(printf '%s' "$out" | jq -r .verdict)" changes
is "it subscribed before looking"       "$(jq -r 'select(.method) | .method' "$FAKE_LOG" | grep -E 'thread/(resume|turns/list)' | head -1)" thread/resume

new_turn="$(turn completed "$ANSWER" | jq -c '.id = "turn-2"')"
old_turn='{"id":"t-old","status":"completed","items":[]}'
scenario "$(jq -nc --argjson n "$new_turn" --argjson o "$old_turn" '{responses:{"thread/turns/list":{result:{data:[$n,$o]}}}}')"
out="$(rpc turn-wait --thread th --new-since "$T/known" --budget 5 --schema "$SCHEMA")"; rc=$?
is "E2 --new-since finds the turn that was not there before" "$rc/$(printf '%s' "$out" | jq -r .verdict)" "0/changes"
scenario "$(jq -nc --argjson o "$old_turn" '{responses:{"thread/turns/list":{result:{data:[$o]}}}}')"
rpc turn-wait --thread th --new-since "$T/known" --budget 2 --schema "$SCHEMA" >/dev/null 2>&1
is "E3 and exits 1 when nothing new is on the thread" "$?" 1

echo "F. turn-wait on a running turn"
done_note="$(jq -nc --argjson t "$(turn completed "$ANSWER")" '{method:"turn/completed",params:{threadId:"th",turn:$t}}')"
approval='{"id":77,"method":"item/commandExecution/requestApproval","params":{}}'
scenario "$(jq -nc --argjson l "$(listing "$(turn inProgress "")")" --argjson n "$done_note" --argjson a "$approval" \
  '{responses:{"thread/turns/list":$l},after:{"thread/turns/list":[$a,$n]}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA")"; rc=$?
is "it waits for turn/completed and exits 0" "$rc" 0
is "with the answer" "$(printf '%s' "$out" | jq -r '.findings[0].severity')" P1
is "a server approval request is declined" "$(jq -c 'select(.id == 77) | .result.decision' "$FAKE_LOG")" '"decline"'

echo "G. still running at the budget"
scenario "$(jq -nc --argjson l "$(listing "$(turn inProgress "")")" '{responses:{"thread/turns/list":$l}}')"
rpc turn-wait --thread th --turn turn-1 --budget 1 --schema "$SCHEMA" >/dev/null 2>&1
is "it exits 3" "$?" 3

echo "H. a turn that did not complete"
scenario "$(jq -nc --argjson l "$(listing "$(turn failed "")")" '{responses:{"thread/turns/list":$l}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA" 2>&1)"; rc=$?
is "H1 a failed turn exits 1" "$rc" 1
is "H1 and says failed" "$(printf '%s' "$out" | grep -c failed)" 1
scenario "$(jq -nc --argjson l "$(listing "$(turn interrupted "")")" '{responses:{"thread/turns/list":$l}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA" 2>&1)"; rc=$?
is "H2 an interrupted turn (f12 in the pane) exits 1" "$rc" 1
is "H2 and says interrupted" "$(printf '%s' "$out" | grep -c interrupted)" 1
scenario '{"responses":{"thread/turns/list":{"result":{"data":[]}}}}'
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA" 2>&1)"; rc=$?
is "H3 an unknown turn exits 1" "$rc" 1
is "H3 and says there is no such turn" "$(printf '%s' "$out" | grep -c 'no turn')" 1

echo "I. answers that do not match the schema"
for bad in 'not json at all' '{"verdict":"maybe","findings":[]}' \
           "$(printf '```json\n%s\n```' "$ANSWER")" \
           '{"verdict":"approve","findings":[{"severity":"P1","file":"a","line":"3","summary":"s","failure_scenario":"f"}]}'; do
  scenario "$(jq -nc --argjson l "$(listing "$(turn completed "$bad")")" '{responses:{"thread/turns/list":$l}}')"
  out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA" 2>/dev/null)"; rc=$?
  is "I '$(printf '%s' "$bad" | head -c 30)' exits 4" "$rc" 4
  is "I and the raw text is on stdout" "$out" "$bad"
done

echo "J. a dropped connection is resumed within the budget"
scenario "$(jq -nc --argjson l "$(listing "$(turn completed "$ANSWER")")" \
  '{runs:[{exit_after:2},{responses:{"thread/turns/list":$l}}]}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 10 --schema "$SCHEMA")"; rc=$?
is "it reconnects and exits 0" "$rc" 0
is "on the second connection" "$(cat "$FAKE_COUNTER")" 2

echo "L. the budget bounds connection setup too"
scenario '{"silent":["initialize"]}'
start=$(date +%s)
rpc turn-wait --thread th --turn turn-1 --budget 1 --schema "$SCHEMA" >/dev/null 2>&1; rc=$?
took=$(( $(date +%s) - start ))
is "a daemon that never answers initialize ends at the budget" "$([ "$took" -le 3 ] && echo yes || echo "no ($took s)")" yes
is "as unreachable (5)" "$rc" 5

echo "K. thread-archive"
scenario '{}'
rpc thread-archive --thread th; is "it exits 0" "$?" 0
is "it archives that thread" "$(params thread/archive | jq -r .threadId)" th

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 3: Run it to verify it fails**

```bash
chmod 755 tests/xreview-rpc.test.sh
./tests/run.sh xreview-rpc
```
Expected: exit 2, `missing file under test: …/executable_xreview-rpc`.

- [ ] **Step 4: Write `dot_local/bin/executable_xreview-rpc`**

```python
#!/usr/bin/env python3
"""xreview-rpc - xreview's client for Codex's shared app-server daemon.

Managed by chezmoi (source: dot_local/bin/executable_xreview-rpc).
Design: docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md, section 7.1.

The daemon speaks JSON-RPC over a WebSocket on a unix socket (GET /rpc), without a
"jsonrpc" field. XREVIEW_RPC_STDIO replaces that transport with a command speaking
newline-delimited JSON on stdio: the Claude sandbox denies binding a unix socket, so the
tests' fake daemon cannot listen on one.

  health
  thread-status  --thread ID                               {"loaded", "status", "running"}
  turn-start     --thread ID --input FILE --schema FILE [--known FILE]   prints the turn id
  turn-wait      --thread ID (--turn ID | --new-since FILE) --budget SECS [--schema FILE]
  thread-archive --thread ID

Exit codes: 0 ok, 1 failed or unknown, 2 usage, 3 still running at the budget,
4 answer does not match the schema (raw text on stdout), 5 daemon unreachable,
6 turn/start sent but not answered - the turn may be running, so never re-dispatch.
"""
import argparse
import base64
import json
import os
import select
import socket
import struct
import subprocess
import sys
import time

TERMINAL = ("completed", "failed", "interrupted")


class Unreachable(Exception):
    pass


class Closed(Exception):
    pass


def err(msg):
    print(f"xreview-rpc: {msg}", file=sys.stderr)


def sock_path():
    return os.environ.get("XREVIEW_RPC_SOCK") or os.path.join(
        os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"),
        "app-server-control", "app-server-control.sock")


# --- WebSocket framing (RFC 6455), client side ----------------------------------------

def ws_frame(payload, opcode=1, mask=None):
    """A single final frame. Client frames must be masked."""
    mask = mask if mask is not None else os.urandom(4)
    n = len(payload)
    head = bytes([0x80 | opcode])
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def ws_parse(buf):
    """Split one frame off the front of buf: (fin, opcode, payload, rest), or None."""
    if len(buf) < 2:
        return None
    b0, b1 = buf[0], buf[1]
    n, i = b1 & 0x7F, 2
    if n == 126:
        if len(buf) < 4:
            return None
        n, i = struct.unpack(">H", buf[2:4])[0], 4
    elif n == 127:
        if len(buf) < 10:
            return None
        n, i = struct.unpack(">Q", buf[2:10])[0], 10
    mask = None
    if b1 & 0x80:
        if len(buf) < i + 4:
            return None
        mask, i = buf[i:i + 4], i + 4
    if len(buf) < i + n:
        return None
    data = buf[i:i + n]
    if mask:
        data = bytes(b ^ mask[k % 4] for k, b in enumerate(data))
    return bool(b0 & 0x80), b0 & 0x0F, data, buf[i + n:]


class WsTransport:
    def __init__(self, path, timeout=10):
        try:
            self.s = socket.socket(socket.AF_UNIX)
            self.s.settimeout(min(10.0, max(0.1, timeout)))
            self.s.connect(path)
            key = base64.b64encode(os.urandom(16)).decode()
            self.s.sendall(("GET /rpc HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\n"
                            "Upgrade: websocket\r\nSec-WebSocket-Version: 13\r\n"
                            f"Sec-WebSocket-Key: {key}\r\n\r\n").encode())
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = self.s.recv(4096)
                if not chunk:
                    raise Unreachable("connection closed during the WebSocket handshake")
                buf += chunk
        except OSError as e:
            raise Unreachable(f"{path}: {e}")
        head, self.buf = buf.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            raise Unreachable("no WebSocket upgrade: " + status.decode(errors="replace"))
        self.frag = b""

    def send(self, obj):
        try:
            self.s.sendall(ws_frame(json.dumps(obj).encode()))
        except OSError as e:
            raise Closed(str(e))

    def recv(self, timeout):
        """The next JSON message, or None when nothing arrives within timeout."""
        deadline = time.monotonic() + timeout
        while True:
            f = ws_parse(self.buf)
            if f is None:
                left = deadline - time.monotonic()
                if left <= 0:
                    return None
                self.s.settimeout(left)
                try:
                    chunk = self.s.recv(65536)
                except socket.timeout:
                    return None
                except OSError as e:
                    raise Closed(str(e))
                if not chunk:
                    raise Closed("daemon closed the connection")
                self.buf += chunk
                continue
            fin, op, data, self.buf = f
            if op == 9:
                self.send_raw(ws_frame(data, opcode=10))
                continue
            if op == 10:
                continue
            if op == 8:
                raise Closed("daemon closed the connection")
            self.frag += data
            if fin:
                msg, self.frag = self.frag, b""
                return json.loads(msg)

    def send_raw(self, frame):
        try:
            self.s.sendall(frame)
        except OSError as e:
            raise Closed(str(e))


class StdioTransport:
    """Test transport: a command speaking newline-delimited JSON on stdio."""

    def __init__(self, cmd):
        self.p = subprocess.Popen(cmd, shell=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.fd = self.p.stdout.fileno()
        self.buf = b""

    def send(self, obj):
        try:
            self.p.stdin.write((json.dumps(obj) + "\n").encode())
            self.p.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            raise Closed(str(e))

    def recv(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buf:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            ready, _, _ = select.select([self.fd], [], [], left)
            if not ready:
                return None
            chunk = os.read(self.fd, 65536)
            if not chunk:
                raise Closed("fake daemon exited")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)


class Client:
    """One connection. Every call is bounded by min(its own timeout, the client deadline)."""

    def __init__(self, deadline=None):
        self.deadline = deadline if deadline is not None else time.monotonic() + 60
        stdio = os.environ.get("XREVIEW_RPC_STDIO")
        self.t = StdioTransport(stdio) if stdio else WsTransport(sock_path(), self.deadline - time.monotonic())
        self.next_id = 0
        self.notes = []
        r = self.call("initialize", {"clientInfo": {"name": "xreview", "version": "1"}})
        if "error" in r:
            raise Unreachable("initialize refused: " + json.dumps(r["error"]))
        self.t.send({"method": "initialized"})

    def call(self, method, params, timeout=30):
        self.next_id += 1
        rid = self.next_id
        self.t.send({"id": rid, "method": method, "params": params})
        deadline = min(time.monotonic() + timeout, self.deadline)
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise Closed(f"no response to {method} within the budget")
            m = self.t.recv(left)
            if m is None:
                continue
            if m.get("id") == rid and ("result" in m or "error" in m):
                return m
            self._other(m)

    def _other(self, m):
        if "method" in m and "id" in m:
            # A server request, such as an approval. approvalPolicy is never, so none should
            # arrive; if one does, decline rather than leave the turn hanging.
            self.t.send({"id": m["id"], "result": {"decision": "decline"}})
        elif "method" in m:
            self.notes.append(m)

    def wait_note(self, pred, deadline):
        """The first queued or incoming notification matching pred, or None at deadline."""
        while True:
            for i, m in enumerate(self.notes):
                if pred(m):
                    return self.notes.pop(i)
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            m = self.t.recv(min(left, 5))
            if m is not None:
                self._other(m)


# --- the findings schema ---------------------------------------------------------------

def validate(v, s, path="$"):
    """The JSON Schema subset the findings schema uses. Returns a list of problems."""
    if "enum" in s and v not in s["enum"]:
        return [f"{path}: {v!r} is not one of {s['enum']}"]
    t = s.get("type")
    kinds = {"object": dict, "array": list, "string": str, "boolean": bool}
    if t == "integer":
        if not isinstance(v, int) or isinstance(v, bool):
            return [f"{path}: expected an integer"]
    elif t in kinds and not isinstance(v, kinds[t]):
        return [f"{path}: expected {t}"]
    out = []
    if isinstance(v, dict):
        props = s.get("properties", {})
        out += [f"{path}: missing {k}" for k in s.get("required", []) if k not in v]
        if s.get("additionalProperties") is False:
            out += [f"{path}: unexpected {k}" for k in v if k not in props]
        for k, sub in props.items():
            if k in v:
                out += validate(v[k], sub, f"{path}.{k}")
    if isinstance(v, list) and "items" in s:
        for i, x in enumerate(v):
            out += validate(x, s["items"], f"{path}[{i}]")
    return out


def final_text(turn):
    msgs = [i for i in turn.get("items") or [] if i.get("type") == "agentMessage"]
    final = [i for i in msgs if i.get("phase") == "final_answer"] or msgs[-1:]
    return final[-1].get("text") if final else None


def finish(turn, schema):
    status = turn.get("status")
    if status != "completed":
        err(f"reviewer turn {status}: {json.dumps(turn.get('error'))}")
        return 1
    text = final_text(turn)
    if text is None:
        err("reviewer turn completed with no answer")
        return 1
    if schema is None:
        print(text)
        return 0
    try:
        doc = json.loads(text)
        problems = validate(doc, schema)
    except ValueError:
        doc, problems = None, ["not JSON"]
    if problems:
        sys.stdout.write(text + ("" if text.endswith("\n") else "\n"))
        err("the answer does not match the findings schema: " + "; ".join(problems[:5]))
        return 4
    print(json.dumps(doc, indent=2))
    return 0


# --- commands ----------------------------------------------------------------------------

def cmd_thread_status(c, a):
    r = c.call("thread/read", {"threadId": a.thread})
    if "error" in r:
        print(json.dumps({"loaded": False, "status": "unknown", "running": False}))
        return 0
    st = ((r.get("result") or {}).get("thread") or {}).get("status") or {}
    kind = st.get("type", "unknown")
    print(json.dumps({"loaded": kind not in ("notLoaded", "unknown"), "status": kind,
                      "running": kind == "active"}))
    return 0


def cmd_turn_start(c, a):
    with open(a.input, encoding="utf-8") as fh:
        text = fh.read()
    with open(a.schema, encoding="utf-8") as fh:
        schema = json.load(fh)
    if a.known:
        # What is on the thread before this start, so an unanswered start can be found later
        # as the turn that was not there before.
        tl = c.call("thread/turns/list", {"threadId": a.thread, "limit": 50,
                                          "sortDirection": "desc", "itemsView": "notLoaded"})
        data = [] if "error" in tl else ((tl.get("result") or {}).get("data") or [])
        with open(a.known, "w", encoding="utf-8") as fh:
            json.dump([t.get("id") for t in data], fh)
    try:
        r = c.call("turn/start", {"threadId": a.thread,
                                  "input": [{"type": "text", "text": text}],
                                  "outputSchema": schema,
                                  "sandboxPolicy": {"type": "readOnly"},
                                  "approvalPolicy": "never"})
    except (Unreachable, Closed) as e:
        err(f"turn/start was sent but not answered ({e}); the turn may be running")
        return 6
    if "error" in r:
        err("turn/start refused: " + json.dumps(r["error"]))
        return 1
    print(r["result"]["turn"]["id"])
    return 0


def cmd_thread_archive(c, a):
    r = c.call("thread/archive", {"threadId": a.thread})
    if "error" in r:
        err("thread/archive refused: " + json.dumps(r["error"]))
        return 1
    return 0


def turn_state(c, thread, turn, known=None):
    """The turn by id, or with known given, the oldest turn whose id is not in it."""
    r = c.call("thread/turns/list", {"threadId": thread, "limit": 50,
                                     "sortDirection": "desc", "itemsView": "summary"})
    if "error" in r:
        return None
    data = (r.get("result") or {}).get("data") or []
    if turn:
        return next((t for t in data if t.get("id") == turn), None)
    new = [t for t in data if t.get("id") not in (known or [])]
    return new[-1] if new else None   # newest first, so the last new one is the oldest


def cmd_turn_wait(a):
    schema = None
    if a.schema:
        with open(a.schema, encoding="utf-8") as fh:
            schema = json.load(fh)
    known = None
    if a.new_since:
        with open(a.new_since, encoding="utf-8") as fh:
            known = json.load(fh)
    deadline = time.monotonic() + a.budget
    last = "never connected"
    while True:
        try:
            c = Client(deadline)
            c.call("thread/resume", {"threadId": a.thread})   # subscribe before looking
            t = turn_state(c, a.thread, a.turn, known)
            if t is None:
                err(f"no turn {a.turn or 'started since the dispatch'} on thread {a.thread}")
                return 1
            turn_id = t.get("id")
            while t.get("status") not in TERMINAL:
                n = c.wait_note(lambda m: m.get("method") == "turn/completed"
                                and ((m.get("params") or {}).get("turn") or {}).get("id") == turn_id,
                                deadline)
                if n is None:
                    err(f"turn {turn_id} is still running")
                    return 3
                t = n["params"]["turn"]
            return finish(t, schema)
        except (Unreachable, Closed) as e:
            last = str(e)
            if time.monotonic() >= deadline:
                err(f"Codex daemon unreachable: {last}")
                return 5
            time.sleep(min(1.0, max(0.0, deadline - time.monotonic())))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="xreview-rpc")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("health")
    for name in ("thread-status", "thread-archive"):
        sub.add_parser(name).add_argument("--thread", required=True)
    p = sub.add_parser("turn-start")
    p.add_argument("--thread", required=True)
    p.add_argument("--input", required=True)
    p.add_argument("--schema", required=True)
    p.add_argument("--known")
    p = sub.add_parser("turn-wait")
    p.add_argument("--thread", required=True)
    which = p.add_mutually_exclusive_group(required=True)
    which.add_argument("--turn")
    which.add_argument("--new-since")
    p.add_argument("--budget", type=float, required=True)
    p.add_argument("--schema")
    a = ap.parse_args(argv)
    if a.cmd == "turn-wait":
        return cmd_turn_wait(a)
    try:
        c = Client()
    except (Unreachable, Closed) as e:
        err(f"Codex daemon unreachable: {e}")
        return 5
    try:
        if a.cmd == "health":
            return 0
        if a.cmd == "thread-status":
            return cmd_thread_status(c, a)
        if a.cmd == "turn-start":
            return cmd_turn_start(c, a)
        return cmd_thread_archive(c, a)
    except (Unreachable, Closed) as e:
        err(f"Codex daemon connection lost: {e}")
        return 5


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Run it to verify it passes**

```bash
./tests/run.sh xreview-rpc
```
Expected: `ok    xreview-rpc  N/N`, 0 failed.

- [ ] **Step 6: Commit**

```bash
git -C ~/.local/share/chezmoi branch --show-current   # feat/xreview-codex-daemon
git -C ~/.local/share/chezmoi add --chmod=+x dot_local/bin/executable_xreview-rpc tests/xreview-rpc.test.sh
git -C ~/.local/share/chezmoi add dot_config/xreview/findings.schema.json
git -C ~/.local/share/chezmoi commit -m "Add a daemon JSON-RPC client for xreview with schema-checked answers"
```

---

### Task 6: xreview on the daemon, pane first

**Files:**
- Modify (rewrite): `dot_local/bin/executable_xreview`
- Create: `dot_config/xreview/reviewer.md`
- Create: `dot_config/herdr/codex-pane-command`
- Modify: `dot_config/herdr/executable_layout.sh:37-41`
- Modify (rewrite): `tests/xreview.test.sh`

**Interfaces:**
- Consumes:
  - `codex-daemon ensure|check` (Task 1);
  - `xreview-rpc thread-status|turn-start|turn-wait|thread-archive` and `~/.config/xreview/findings.schema.json` (Task 5);
  - `herdr pane list|get|send-keys|run|report-agent-session`.
- Produces: the `xreview` CLI.
  - `dispatch [--diff <range>] <body-file>`, `collect <nonce> [budget]`, `thread`, `init [id]`, `tier [thread]`, `receipts [--tiers]`, `apply <nonce>|--done`, `round [--reset]`.
  - Env: `XREVIEW_PANE`, `XREVIEW_THREAD`, `XREVIEW_PANE_WAIT` (default 20), `XREVIEW_MAX_ROUNDS`, `XREVIEW_MAX_DIFF_BYTES`, `XREVIEW_SCHEMA`, `XREVIEW_REVIEWER`.
  - State under `$XDG_STATE_HOME/xreview/<repo>/`: `thread`, `pin`, `superseded`, `turns/<nonce>`, `rounds`, `reviews.jsonl`, `applying`.

- [ ] **Step 1: Write the two small config files**

`dot_config/herdr/codex-pane-command`:
```
# The command every Codex pane runs. Read by layout.sh, which builds the pane, and by xreview,
# which restarts it on a review thread. Only the first non-comment line counts.
#
# Codex's documented role here is reviewer, not implementer, so its panes launch unable to
# write. Without this they inherit workspace-write with $HOME writable. Read-only is not
# confinement - reads are still unrestricted - but it removes the write half. Launch an
# implementer session by hand when you actually want one.
codex --sandbox read-only --ask-for-approval never
```

`dot_config/xreview/reviewer.md`:
```
You are the independent reviewer in a cross-model review. Review only what this request
carries: the artifact, the constraints it must satisfy, and any alternatives already
rejected. Your session is read-only; do not try to change files.

Answer in the findings schema:
- verdict: "approve" when you have no actionable findings, otherwise "changes".
- findings: one entry per concrete problem.
  - file and line locate it. Use line 0 when it is not tied to a line, as for a design-level
    finding.
  - severity runs from P0 (it cannot work) to P3 (minor).
  - summary states the defect in one sentence.
  - failure_scenario gives the inputs or state, and what goes wrong.
Skip anything you cannot tie to a concrete failure.
```

- [ ] **Step 2: Point layout.sh at the file** — in `dot_config/herdr/executable_layout.sh`, replace lines 37–41 (the comment block and `CODEX_CMD=`) with:

```zsh
# The Codex pane command lives in one file beside this script, read here and by xreview
# (which restarts the pane on a review thread with the same flags). The reasoning for its
# flags is in that file.
CODEX_CMD="$(grep -v '^[[:space:]]*#' "${0:A:h}/codex-pane-command" 2>/dev/null | grep . | head -1)"
[[ -n "$CODEX_CMD" ]] || { print -ru2 -- "layout.sh: missing ${0:A:h}/codex-pane-command"; exit 1 }
```

Run the layout suite, which asserts the exact pane command (`G2 codex runs read-only`). Execute it directly, because the `dev` filter would also run `dev-topology` and the interactive `dev-integrations`:
```bash
./tests/dev.test.sh
```
Expected: its summary line shows 0 failed.

- [ ] **Step 3: Write the failing xreview test** — replace `tests/xreview.test.sh` entirely:

```bash
#!/usr/bin/env bash
# Tests for dot_local/bin/executable_xreview on the Codex daemon (spec section 7).
#
# Every collaborator is stubbed on PATH:
#   herdr         one Codex pane, w1:p2, whose title and agent live in files under $P
#   codex-daemon  ensure/check exit codes
#   xreview-rpc   thread status, turn start and wait, archive
# Each stub logs its calls to $CALLS, so ordering is asserted from the log. Nothing may
# reach the pane or the reviewer before the preconditions pass, and no turn may start
# before the pane shows the thread.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
XREVIEW="$SRC/dot_local/bin/executable_xreview"
[ -f "$XREVIEW" ] || { echo "missing CLI under test: $XREVIEW" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xreview.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state" XDG_CONFIG_HOME="$ROOT/config" CODEX_HOME="$ROOT/codex"
mkdir -p "$XDG_CONFIG_HOME/xreview" "$XDG_CONFIG_HOME/herdr"
cp "$SRC/dot_config/xreview/findings.schema.json" "$SRC/dot_config/xreview/reviewer.md" "$XDG_CONFIG_HOME/xreview/"
cp "$SRC/dot_config/herdr/codex-pane-command" "$XDG_CONFIG_HOME/herdr/"
export XREVIEW_PANE_WAIT=3
unset XREVIEW_MAX_ROUNDS XREVIEW_PANE XREVIEW_THREAD

mkdir -p "$ROOT/repo" && cd "$ROOT/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t
git config commit.gpgsign false
git commit -q --allow-empty -m init || { printf 'fixture setup failed\n' >&2; exit 1; }
printf 'body\n' > b.md
CWD="$(git rev-parse --show-toplevel)"
STATE="$XDG_STATE_HOME/xreview/$(printf '%s' "$CWD" | tr '/' '_' | sed 's/^_//')"

# --- stubs ------------------------------------------------------------------------
STUB="$ROOT/stub"; P="$ROOT/pane"; mkdir -p "$STUB" "$P"
export CALLS="$ROOT/calls" P CWD
U0=aaaaaaaa-0000-4000-8000-000000000000   # the thread the pane shows at the start
U1=bbbbbbbb-1111-4111-8111-111111111111   # the thread a fresh session in the pane creates
U2=cccccccc-2222-4222-8222-222222222222
export NEW_UUID="$U1"
cat > "$STUB/herdr" <<'H'
#!/bin/sh
echo "herdr $*" >> "$CALLS"
pane_json() {
  a="$(cat "$P/agent" 2>/dev/null)"; t="$(cat "$P/title" 2>/dev/null)"
  s="$(cat "$P/status" 2>/dev/null || echo idle)"
  af=""; [ -n "$a" ] && af="\"agent\":\"$a\","
  printf '{%s"agent_status":"%s","cwd":"%s","pane_id":"w1:p2","terminal_title":"%s","terminal_title_stripped":"%s"}' \
    "$af" "$s" "${PANE_CWD:-$CWD}" "$t" "$t"
}
case "$1 $2" in
  "pane list") printf '{"result":{"panes":[%s%s]}}\n' "$(pane_json)" "${EXTRA_PANES:-}" ;;
  "pane get") printf '{"result":{"pane":%s}}\n' "$(pane_json)" ;;
  "pane send-keys")
    n=$(cat "$P/ctrlc" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/ctrlc"
    if [ "$n" -ge 2 ] && [ -z "${STUCK_TUI:-}" ]; then : > "$P/agent"; fi ;;
  "pane run")
    echo 0 > "$P/ctrlc"
    [ -n "${NO_TITLE:-}" ] && exit 0
    printf codex > "$P/agent"
    case "$4" in
      *" resume "*) printf '%s | t | d' "${4##* resume }" > "$P/title" ;;
      *) printf '%s | t | d' "$NEW_UUID" > "$P/title" ;;
    esac ;;
esac
exit 0
H
cat > "$STUB/codex-daemon" <<'D'
#!/bin/sh
echo "codex-daemon $*" >> "$CALLS"
case "$1" in
  ensure) exit "${ENSURE_RC:-0}" ;;
  check) [ "${CHECK_RC:-0}" = 0 ] || echo "codex-daemon: carries a herdr pane's environment" >&2
         exit "${CHECK_RC:-0}" ;;
esac
D
cat > "$STUB/xreview-rpc" <<'R'
#!/bin/sh
echo "xreview-rpc $*" >> "$CALLS"
cmd="$1"; shift
th=""; input=""; known=""
while [ "$#" -gt 0 ]; do
  case "$1" in --thread) th="$2"; shift ;; --input) input="$2"; shift ;; --known) known="$2"; shift ;; esac; shift
done
case "$cmd" in
  thread-status)
    n=$(cat "$P/status_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/status_calls"
    if [ -n "${RPC_NOT_LOADED:-}" ] || { [ -n "${RPC_NOT_LOADED_ONCE:-}" ] && [ "$n" = 1 ]; }; then
      echo '{"loaded":false,"status":"notLoaded","running":false}'
    else echo '{"loaded":true,"status":"idle","running":false}'; fi ;;
  turn-start) cp "$input" "$P/packet"; [ -n "$known" ] && echo '[]' > "$known"
              [ -n "${RPC_START_FAIL:-}" ] && exit 1
              [ -n "${RPC_START_UNCERTAIN:-}" ] && exit 6
              echo "turn-$th" ;;
  turn-wait) printf '%s\n' "${RPC_WAIT_OUT:-}"; exit "${RPC_WAIT_RC:-0}" ;;
esac
exit 0
R
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

fresh() { # a pane showing U0, idle; clean log and state
  unset ENSURE_RC CHECK_RC RPC_NOT_LOADED RPC_NOT_LOADED_ONCE RPC_START_FAIL RPC_START_UNCERTAIN \
        NO_TITLE STUCK_TUI EXTRA_PANES PANE_CWD XREVIEW_PANE XREVIEW_THREAD RPC_WAIT_OUT RPC_WAIT_RC
  export NEW_UUID="$U1"
  printf codex > "$P/agent"; printf '%s | t | d' "$U0" > "$P/title"; echo idle > "$P/status"
  echo 0 > "$P/ctrlc"; rm -f "$P/packet" "$P/status_calls"
  bash "$XREVIEW" round --reset >/dev/null 2>&1
  rm -rf "$STATE/superseded" "$STATE/pin" "$STATE/turns"
  : > "$CALLS"
}
called() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
first() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
untouched() { # nothing reached the pane or the reviewer
  [ "$(called 'herdr pane send-keys')$(called 'herdr pane run')$(called 'xreview-rpc turn-start')" = 000 ] && echo yes || echo no
}

echo "A. the round cap binds before a turn is spent"
fresh
capped() { bash "$XREVIEW" dispatch b.md 2>&1 | grep -c 'exceeds the cap'; }
is "round counter starts at zero" "$(bash "$XREVIEW" round)" 0
for _ in $(seq 9); do capped >/dev/null; done
is "nine rounds are permitted"        "$(bash "$XREVIEW" round)" 9
is "the tenth round is still allowed" "$(capped)" 0
starts="$(called 'xreview-rpc turn-start')"
is "the eleventh round is refused"    "$(capped)" 1
is "and starts no turn"               "$(called 'xreview-rpc turn-start')" "$starts"
is "a refused round still increments, so retrying stays refused" "$(bash "$XREVIEW" round)" 11
bash "$XREVIEW" round --reset >/dev/null
is "reset returns the counter to zero" "$(bash "$XREVIEW" round)" 0
XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "XREVIEW_MAX_ROUNDS lowers the cap" "$(XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch b.md 2>&1 | grep -c 'exceeds the cap')" 1

echo "B. inline diffs"
# A dispatch that names a path makes the reviewer go and read it; carrying the diff inline
# lets it answer from what it was handed (measured 2026-09-01: ~16 steps per review).
printf 'change\n' > tracked.txt && git add tracked.txt && git commit -q -m "a change to review"
fresh
bash "$XREVIEW" dispatch --diff HEAD~1..HEAD b.md >/dev/null 2>&1
is "the diff travels in the packet"          "$(grep -q 'tracked.txt' "$P/packet" && echo yes || echo no)" yes
is "with the caller's body"                  "$(grep -c '^body$' "$P/packet")" 1
is "and the reviewer instructions"           "$(grep -c 'independent reviewer' "$P/packet")" 1
is "wrapped as an authorized request"        "$(head -1 "$P/packet")" "<cross-review-request>"
is "with no correlation line any more"       "$(grep -c 'correlation' "$P/packet")" 0
fresh
out="$(XREVIEW_MAX_DIFF_BYTES=10 bash "$XREVIEW" dispatch --diff HEAD~1..HEAD b.md 2>&1)"
is "an oversized diff is refused, never truncated" "$(printf '%s' "$out" | grep -c 'too large')" 1
is "before anything is touched" "$(untouched)" yes
fresh
out="$(bash "$XREVIEW" dispatch --diff no-such-ref..HEAD b.md 2>&1)"
is "an unresolvable range is refused" "$(printf '%s' "$out" | grep -c 'cannot diff')" 1
fresh
out="$(bash "$XREVIEW" dispatch --diff HEAD..HEAD b.md 2>&1)"
is "an empty range is refused" "$(printf '%s' "$out" | grep -c 'nothing to review')" 1
out="$(bash "$XREVIEW" dispatch --expect x b.md 2>&1)"; rc=$?
is "--expect is rejected, not absorbed" "$rc" 1
is "and mints no nonce" "$(printf '%s' "$out" | grep -c '^xr-')" 0

echo "C. preconditions refuse before anything is touched"
fresh; out="$(ENSURE_RC=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "C1 a daemon that will not start refuses" "$rc" 1
is "C1 untouched" "$(untouched)" yes
fresh; out="$(CHECK_RC=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "C2 a contaminated daemon refuses" "$rc" 1
is "C2 and says why" "$(printf '%s' "$out" | grep -c 'refusing to dispatch while the daemon')" 1
is "C2 untouched" "$(untouched)" yes
fresh; : > "$P/agent"; out="$(bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "C3 no Codex pane refuses" "$(printf '%s' "$out" | grep -c 'no Codex pane')" 1
is "C3 untouched" "$(untouched)" yes
fresh
export EXTRA_PANES=",{\"agent\":\"codex\",\"agent_status\":\"idle\",\"cwd\":\"$CWD\",\"pane_id\":\"w9:p2\",\"terminal_title\":\"x\"}"
out="$(bash "$XREVIEW" dispatch b.md 2>&1)"
is "C4 several Codex panes refuse" "$(printf '%s' "$out" | grep -c 'several Codex panes')" 1
is "C4 naming both" "$(printf '%s' "$out" | grep -c 'w1:p2 w9:p2')" 1
is "C4 untouched" "$(untouched)" yes
out="$(XREVIEW_PANE=w1:p2 bash "$XREVIEW" dispatch b.md 2>&1)"
is "C5 XREVIEW_PANE picks one" "$(printf '%s' "$out" | grep -c '^xr-')" 1
fresh; echo working > "$P/status"; out="$(bash "$XREVIEW" dispatch b.md 2>&1)"
is "C6 a pane mid-turn refuses" "$(printf '%s' "$out" | grep -c 'mid-turn')" 1
is "C6 untouched" "$(untouched)" yes
fresh; mkdir .codex; out="$(bash "$XREVIEW" dispatch b.md 2>&1)"; rmdir .codex
is "C7 a project .codex refuses" "$(printf '%s' "$out" | grep -c 'refusing to dispatch')" 1
is "C7 untouched" "$(untouched)" yes
fresh; out="$(XREVIEW_SCHEMA="$ROOT/none.json" bash "$XREVIEW" dispatch b.md 2>&1)"
is "C8 a missing schema refuses" "$(printf '%s' "$out" | grep -c 'missing findings schema')" 1

echo "D. the pane comes first"
fresh
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "D1 a nonce is printed" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "D1 the pane's session is ended" "$(called 'herdr pane send-keys w1:p2 ctrl+c')" 2
is "D1 a fresh session runs the pane command" \
   "$(called 'herdr pane run w1:p2 codex --sandbox read-only --ask-for-approval never')" 1
is "D1 the new thread is confirmed loaded" "$(called "xreview-rpc thread-status --thread $U1")" 1
is "D1 herdr is told the pane's thread" \
   "$(called "herdr pane report-agent-session w1:p2 --source herdr:codex --agent codex --agent-session-id $U1")" 1
is "D1 the turn goes to the thread the pane shows" "$(called "xreview-rpc turn-start --thread $U1")" 1
is "D1 and only after the pane shows it" \
   "$([ "$(first 'herdr pane run')" -lt "$(first 'xreview-rpc turn-start')" ] && echo yes || echo no)" yes
is "D1 the checkpoint thread is recorded" "$(cat "$STATE/thread")" "$U1"
is "D1 the nonce maps to thread and turn" "$(cat "$STATE/turns/$nonce")" "$U1 turn-$U1"
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D2 the next round finds the pane already on the thread" "$(called 'herdr pane send-keys')" 0
is "D2 and goes to the same thread" "$(called "xreview-rpc turn-start --thread $U1")" 1
printf '%s | t | d' "$U0" > "$P/title"; : > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D3 a pane that moved off the thread is resumed onto it" "$(called "herdr pane run w1:p2 codex --sandbox read-only --ask-for-approval never resume $U1")" 1
fresh; out="$(NO_TITLE=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D4 a pane that never shows a thread refuses" "$rc" 1
is "D4 and no turn starts" "$(called 'xreview-rpc turn-start')" 0
fresh; printf 'Greet user | chezmoi' > "$P/title"
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "D5 a pane whose title has no id is restarted and adopted" "$(cat "$STATE/thread" 2>/dev/null)" "$U1"
fresh; out="$(STUCK_TUI=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D6 a session that will not exit refuses" "$(printf '%s' "$out" | grep -c 'did not exit')" 1
is "D6 and never starts a new one" "$(called 'herdr pane run')" 0
fresh; out="$(RPC_NOT_LOADED=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D7 a thread the daemon has not loaded refuses" "$rc" 1
is "D7 and no turn starts" "$(called 'xreview-rpc turn-start')" 0
fresh; out="$(RPC_START_FAIL=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D8 a refused turn fails the dispatch" "$rc" 1
is "D8 and records no nonce" "$(ls "$STATE/turns" 2>/dev/null | grep -c .)" 0
fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1        # the pane now shows U1, recorded
: > "$CALLS"; rm -f "$P/status_calls"
RPC_NOT_LOADED_ONCE=1 bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D9 a matching title on a thread the daemon lost is resumed, not trusted" \
   "$(called "herdr pane run w1:p2 codex --sandbox read-only --ask-for-approval never resume $U1")" 1
is "D9 and the turn starts after that" "$(called "xreview-rpc turn-start --thread $U1")" 1
fresh
nonce="$(RPC_START_UNCERTAIN=1 bash "$XREVIEW" dispatch b.md 2>"$ROOT/err")"; rc=$?
is "D10 an unanswered turn/start still hands back a nonce" "$rc/$(printf '%s' "$nonce" | grep -c '^xr-')" "0/1"
is "D10 with a do-not-re-dispatch warning" "$(grep -c 'do NOT re-dispatch' "$ROOT/err")" 1
is "D10 the record marks the turn unknown" "$(cat "$STATE/turns/$nonce")" "$U1 ?"
bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
is "D10 collect looks for what is new on the thread" \
   "$(called "turn-wait --thread $U1 --new-since $STATE/turns/$nonce.known")" 1

echo "E. checkpoints and pins"
fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
bash "$XREVIEW" round --reset >/dev/null 2>&1
is "E1 reset drops the checkpoint thread" "$([ -e "$STATE/thread" ] && echo kept || echo dropped)" dropped
export NEW_UUID="$U2"; : > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "E1 the next checkpoint starts a fresh thread" "$(cat "$STATE/thread")" "$U2"
is "E1 the old thread is archived" "$(called "xreview-rpc thread-archive --thread $U1")" 1
is "E1 after the new turn started" \
   "$([ "$(first 'xreview-rpc turn-start')" -lt "$(first 'xreview-rpc thread-archive')" ] && echo yes || echo no)" yes
fresh
bash "$XREVIEW" init "$U0" >/dev/null
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "E2 a pin is used as the review thread" "$(called "xreview-rpc turn-start --thread $U0")" 1
is "E2 and is not recorded as a checkpoint thread" "$([ -e "$STATE/thread" ] && echo yes || echo no)" no
bash "$XREVIEW" round --reset >/dev/null 2>&1; : > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "E2 a pinned thread is never archived" "$(called "thread-archive --thread $U0")" 0
fresh
is "E3 XREVIEW_THREAD overrides" "$(XREVIEW_THREAD=$U2 bash "$XREVIEW" thread)" "$U2"
out="$(bash "$XREVIEW" thread 2>&1)"; rc=$?
is "E4 no thread yet says the next dispatch starts one" "$(printf '%s' "$out" | grep -c 'next dispatch starts one')" 1
bash "$XREVIEW" init >/dev/null
is "E5 init without an id pins the pane's thread" "$(cat "$STATE/pin")" "$U0"
out="$(bash "$XREVIEW" init '../../x' 2>&1)"; rc=$?
is "E6 an unsafe id is refused" "$(printf '%s' "$out" | grep -c 'refusing unsafe identifier')" 1

echo "F. collect"
ANSWER='{"verdict":"changes","findings":[{"severity":"P1","file":"a","line":1,"summary":"s","failure_scenario":"f"}]}'
fresh
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
out="$(RPC_WAIT_OUT="$ANSWER" bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F1 a finished review exits 0" "$rc" 0
is "F1 and prints the findings" "$(printf '%s' "$out" | jq -r .verdict)" changes
is "F1 waiting with the findings schema" "$(called "turn-wait --thread $U1 --turn turn-$U1 --budget 2700 --schema $XDG_CONFIG_HOME/xreview/findings.schema.json")" 1
r="$(tail -1 "$STATE/reviews.jsonl")"
is "F1 the receipt keeps the old fields" "$(printf '%s' "$r" | jq -r '[.thread,.nonce,(.ts|length>0),(.head|length>0),has("tier")] | map(tostring) | join(" ")')" "$U1 $nonce true true true"
is "F1 and adds turn, verdict and finding count" "$(printf '%s' "$r" | jq -r '[.turn,.verdict,.findings] | map(tostring) | join(" ")')" "turn-$U1 changes 1"
out="$(RPC_WAIT_RC=3 bash "$XREVIEW" collect "$nonce" 60 2>&1)"; rc=$?
is "F2 a running turn exits 3" "$rc" 3
is "F2 says so and how to keep waiting" "$(printf '%s' "$out" | grep -c "xreview collect $nonce")" 1
out="$(RPC_WAIT_RC=4 RPC_WAIT_OUT='prose' bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F3 a schema miss exits 4" "$rc" 4
is "F3 and labels the text untrusted" "$(printf '%s' "$out" | grep -c UNTRUSTED)" 1
out="$(RPC_WAIT_RC=1 bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F4 a failed turn exits 1" "$rc" 1
out="$(RPC_WAIT_RC=5 bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F5 an unreachable daemon exits 1 and says so" "$rc/$(printf '%s' "$out" | grep -c unreachable)" "1/1"
out="$(bash "$XREVIEW" collect xr-1-nosuchnonce 2>&1)"; rc=$?
is "F6 an unknown nonce is ambiguous and exits 1" "$rc/$(printf '%s' "$out" | grep -c 'do NOT retry')" "1/1"
out="$(bash "$XREVIEW" collect "$U1" "$nonce" 2>&1)"; rc=$?
is "F7 the old thread-first form is refused with the usage" "$rc/$(printf '%s' "$out" | grep -c 'usage: xreview collect <nonce>')" "1/1"
is "F8 the default budget is at least 30 minutes" \
   "$(grep -E '^COLLECT_BUDGET_DEFAULT=' "$XREVIEW" | cut -d= -f2 | awk '{print ($1 >= 1800)}')" 1

echo "G. the reviewer tier is reported, never enforced"
ROLL="$CODEX_HOME/sessions/2026/09/01"; mkdir -p "$ROLL"
tc() { printf '{"type":"turn_context","payload":{"model":"%s","effort":"%s"}}\n' "$1" "$2"; }
{ tc gpt-5.6-sol xhigh; tc gpt-5.6-terra high; } > "$ROLL/rollout-2026-09-01T10-00-00-faketh.jsonl"
is "tier reflects the last turn's setting" "$(bash "$XREVIEW" tier faketh 2>&1)" "gpt-5.6-terra/high"
: > "$STATE/reviews.jsonl"
for _ in 1 2; do printf '{"thread":"t","nonce":"n","tier":"gpt-5.6-sol/xhigh"}\n' >> "$STATE/reviews.jsonl"; done
printf '{"thread":"t","nonce":"n"}\n' >> "$STATE/reviews.jsonl"
out="$(bash "$XREVIEW" receipts --tiers 2>&1)"
is "the tier summary counts each tier" "$(printf '%s' "$out" | grep -c 'gpt-5.6-sol/xhigh')" 1
is "and receipts without a tier as unrecorded" "$(printf '%s' "$out" | grep -ci unrecorded)" 1
is "no --expect handling survives" "$(grep -c -- '--expect' "$XREVIEW")" 0

echo "H. the queue-era machinery is gone"
code="$(grep -v '^[[:space:]]*#' "$XREVIEW")"
for gone in 'codex queue' 'thread_history' 'XREVIEW_THREAD_WARN' 'herdr agent list' 'sqlite3'; do
  is "no '$gone' in the code" "$(printf '%s' "$code" | grep -c -- "$gone")" 0
done

echo "I. a repository path with a space"
mkdir -p "$ROOT/sp ace" && cd "$ROOT/sp ace" || exit 1
git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
git commit -q --allow-empty -m init; printf 'body\n' > b.md
SPCWD="$(git rev-parse --show-toplevel)"
fresh; export PANE_CWD="$SPCWD"
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "the pane is found and the dispatch succeeds" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
SPSTATE="$XDG_STATE_HOME/xreview/$(printf '%s' "$SPCWD" | tr '/' '_' | sed 's/^_//')"
is "its state lands in its own directory" "$(cat "$SPSTATE/thread" 2>/dev/null)" "$U1"
cd "$ROOT/repo" || exit 1

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
```

- [ ] **Step 4: Run it to verify it fails**

```bash
./tests/run.sh xreview
```
Expected: many FAILs. The old CLI has no pane handling, and it calls `codex queue`.

- [ ] **Step 5: Rewrite `dot_local/bin/executable_xreview`**

```bash
#!/usr/bin/env bash
# xreview - dispatch a cold review to the repository's Codex pane and collect the answer.
#
# Design: docs/superpowers/specs/2026-09-26-xreview-codex-daemon-design.md, section 7.
# Reviews run on Codex's shared app-server daemon. Dispatch prepares the repository's Codex
# pane on the review thread BEFORE any turn exists, so the review is watched from its first
# token. xreview-rpc then starts the turn with the findings schema, and collect waits for it
# to complete. Two PreToolUse guards read the receipts (pre-merge gate, apply window); neither
# is proven enough to be an authorization boundary - treat findings as evidence.
set -euo pipefail

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
XR_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
SCHEMA="${XREVIEW_SCHEMA:-$XR_CONFIG/xreview/findings.schema.json}"
REVIEWER="${XREVIEW_REVIEWER:-$XR_CONFIG/xreview/reviewer.md}"
PANE_CMD_FILE="$XR_CONFIG/herdr/codex-pane-command"
UUID_RE='^[[:space:]]*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'

die() { printf 'xreview: %s\n' "$1" >&2; exit 1; }

repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

state_dir() {
  local root; root="$(repo_root)"
  printf '%s/xreview/%s' "${XDG_STATE_HOME:-$HOME/.local/state}" \
    "$(printf '%s' "$root" | tr '/' '_' | sed 's/^_//')"
}

# Ids reach file names and command arguments. Thread and turn ids come from Codex and nonces
# are minted below; anything else, including a leading dash, is refused before use.
assert_id() {
  case "$1" in
    ""|-*|*[!A-Za-z0-9._-]*) die "refusing unsafe identifier: $1" ;;
  esac
}

# --- the Codex pane ----------------------------------------------------------------
# The repository's one herdr pane running Codex in the repository root. It is the reviewer's
# screen: dispatch points it at the review thread before any turn starts.

find_pane() {
  local root snap ids n
  if [ -n "${XREVIEW_PANE:-}" ]; then printf '%s\n' "$XREVIEW_PANE"; return 0; fi
  root="$(repo_root)"
  snap="$(herdr pane list 2>/dev/null || true)"
  [ -n "$snap" ] || die "cannot list herdr panes - is herdr running?"
  ids="$(printf '%s' "$snap" | jq -r --arg cwd "$root" \
    '.result.panes[]? | select(.agent == "codex" and .cwd == $cwd) | .pane_id' 2>/dev/null)" \
    || die "cannot read herdr's pane list"
  n="$(printf '%s' "$ids" | grep -c . || true)"
  case "$n" in
    1) printf '%s\n' "$ids" ;;
    0) die "no Codex pane for $root. Apply the project layout, or set XREVIEW_PANE" ;;
    *) die "several Codex panes for $root: $(printf '%s' "$ids" | tr '\n' ' ' | sed 's/ $//') - set XREVIEW_PANE to one of them" ;;
  esac
}

pane_field() { # pane_field <pane> <jq-path>
  herdr pane get "$1" 2>/dev/null | jq -r ".result.pane | $2 // empty" 2>/dev/null || true
}

pane_title_uuid() { # the thread id at the start of the pane's title, if any
  local t; t="$(pane_field "$1" '(.terminal_title_stripped // .terminal_title)')"
  if [[ "$t" =~ $UUID_RE ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
}

pane_command() {
  local c
  c="$(grep -v '^[[:space:]]*#' "$PANE_CMD_FILE" 2>/dev/null | grep . | head -1 || true)"
  [ -n "$c" ] || die "missing $PANE_CMD_FILE - the Codex pane command is defined there"
  printf '%s\n' "$c"
}

loaded() { # loaded <thread>: the daemon has the thread in memory
  xreview-rpc thread-status --thread "$1" 2>/dev/null | jq -e '.loaded' >/dev/null 2>&1
}

# pane_prepare <pane> [thread] - make the pane show <thread>, or a fresh session when none is
# given, and print the thread id it shows. No turn exists yet, so a refusal here loses nothing.
# A matching title alone is not trusted: after a daemon restart a disconnected TUI keeps its
# title while the new daemon has not loaded the thread, so the pane is resumed onto it.
pane_prepare() {
  local pane="$1" want="${2:-}" before cmd now ok waited=0 wait="${XREVIEW_PANE_WAIT:-20}"
  before="$(pane_title_uuid "$pane")"
  if [ -n "$want" ] && [ "$before" = "$want" ] && loaded "$want"; then printf '%s\n' "$want"; return 0; fi
  cmd="$(pane_command)"
  herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1 || true
  sleep 0.5
  herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1 || true
  while [ "$(pane_field "$pane" '.agent')" = "codex" ]; do
    [ "$waited" -lt "$wait" ] || die "the Codex pane $pane did not exit its session within ${wait}s; no review was started"
    sleep 1; waited=$((waited + 1))
  done
  [ -z "$want" ] || cmd="$cmd resume $want"
  herdr pane run "$pane" "$cmd" >/dev/null 2>&1 || die "could not start Codex in pane $pane; no review was started"
  while :; do
    now="$(pane_title_uuid "$pane")"
    ok=0
    if [ -n "$now" ]; then
      if [ -n "$want" ]; then
        [ "$now" != "$want" ] || ok=1
      else
        [ "$now" = "$before" ] || ok=1
      fi
    fi
    if [ "$ok" = 1 ] && loaded "$now"; then
      printf '%s\n' "$now"; return 0
    fi
    [ "$waited" -lt "$wait" ] || die "the Codex pane $pane did not show ${want:-a new thread} within ${wait}s; no review was started"
    sleep 1; waited=$((waited + 1))
  done
}

report_to_herdr() { # report_to_herdr <pane> <thread>
  herdr pane report-agent-session "$1" --source herdr:codex --agent codex \
    --agent-session-id "$2" --seq "$(python3 -c 'import time; print(time.time_ns())')" \
    >/dev/null 2>&1 || true
}

# --- threads and checkpoints --------------------------------------------------------
# The review thread, in precedence order: XREVIEW_THREAD > an `xreview init` pin > this
# checkpoint's thread. Empty means the next dispatch starts one, in the pane.
target_thread() {
  local dir; dir="$(state_dir)"
  if [ -n "${XREVIEW_THREAD:-}" ]; then printf '%s\n' "$XREVIEW_THREAD"; return 0; fi
  if [ -r "$dir/pin" ]; then cat "$dir/pin"; return 0; fi
  if [ -r "$dir/thread" ]; then cat "$dir/thread"; fi
}

cmd_thread() {
  local t; t="$(target_thread)"
  [ -n "$t" ] || { printf 'xreview: no review thread for this checkpoint yet - the next dispatch starts one\n' >&2; return 1; }
  printf '%s\n' "$t"
}

# A pin is an instruction, not a cache entry: it outranks the checkpoint thread and is never
# archived. `xreview round --reset` drops it. Without an id, the pane's current thread.
cmd_init() {
  local dir id
  dir="$(state_dir)"
  id="${1:-}"
  [ -n "$id" ] || id="$(pane_title_uuid "$(find_pane)")"
  [ -n "$id" ] || die "the Codex pane shows no thread id; pass one: xreview init <thread-id>"
  assert_id "$id"
  mkdir -p "$dir" && printf '%s\n' "$id" > "$dir/pin"
  printf 'xreview: %s -> %s\n' "$(repo_root)" "$id"
}

# Archive the thread a `round --reset` superseded, once the pane has moved off it.
archive_superseded() { # archive_superseded <current-thread>
  local f old; f="$(state_dir)/superseded"
  [ -r "$f" ] || return 0
  old="$(cat "$f")"; rm -f "$f"
  if [ -n "$old" ] && [ "$old" != "$1" ]; then
    xreview-rpc thread-archive --thread "$old" >/dev/null 2>&1 || true
  fi
}

# A receipt is the only durable evidence that a review actually happened. It records the
# branch head at collection time so a reader can tell how far the branch has moved since;
# it deliberately does not try to invalidate itself, because applying a finding necessarily
# moves HEAD and a self-invalidating receipt would demand a second review of the fix.
# The tier is recorded, never enforced: which model and effort the reviewer runs at is
# Michael's setting, and a gate pinned to model names refuses every dispatch the day a new
# one ships.
record_receipt() { # record_receipt <thread> <nonce> <turn> <findings-json>
  local dir tier verdict count; dir="$(state_dir)"
  mkdir -p "$dir" || return 0
  tier="$(codex_tier "$1" 2>/dev/null)" || tier=""
  verdict="$(printf '%s' "$4" | jq -r '.verdict // ""' 2>/dev/null)" || verdict=""
  count="$(printf '%s' "$4" | jq -r '(.findings // []) | length' 2>/dev/null)" || count=0
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg branch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" \
         --arg head "$(git rev-parse HEAD 2>/dev/null)" \
         --arg thread "$1" --arg nonce "$2" --arg tier "$tier" --arg turn "$3" \
         --arg verdict "$verdict" --argjson findings "${count:-0}" \
    '{ts:$ts,branch:$branch,head:$head,thread:$thread,nonce:$nonce,tier:$tier,turn:$turn,verdict:$verdict,findings:$findings}' \
    >> "$dir/reviews.jsonl" 2>/dev/null || true
}

# An apply window bounds the blast radius of acting on a finding. While it is open,
# review-driven edits are confined to files already in the branch diff, plus test paths —
# the RED-test rule requires ADDING a test, so a rule confined strictly to the diff would
# forbid the very thing it demands.
# Review rounds iterate until the models converge or genuinely disagree, so the stop
# condition cannot be "one round" — but it cannot be unbounded either. The cap is mechanical
# because a limit that depends on noticing you have hit it is not a limit.
round_file() { printf '%s/rounds' "$(state_dir)"; }

cmd_round() {
  local f; f="$(round_file)"
  case "${1:-show}" in
    --reset) # The checkpoint's thread is superseded, not forgotten: the next dispatch
             # archives it once the pane has moved to a fresh one. A pin is never archived.
             if [ -r "$(state_dir)/thread" ]; then cp "$(state_dir)/thread" "$(state_dir)/superseded" 2>/dev/null || true; fi
             rm -f "$f" "$(state_dir)/thread" "$(state_dir)/pin"
             printf 'xreview: round counter reset; cached thread and pin dropped\n' ;;
    show)    printf '%s\n' "$(current_round)" ;;
    *)       die "usage: xreview round [--reset]" ;;
  esac
}

current_round() {
  local f b n; f="$(round_file)"; b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -r "$f" ] || { printf 0; return; }
  n="$(sed -n "s/^$b=//p" "$f" 2>/dev/null | head -1)"
  printf '%s' "${n:-0}"
}

bump_round() {
  local f b n; f="$(round_file)"; b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  n=$(( $(current_round) + 1 ))
  mkdir -p "$(dirname "$f")" || return 0
  { [ -r "$f" ] && grep -v "^$b=" "$f" 2>/dev/null; printf '%s=%s\n' "$b" "$n"; } \
    > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  printf '%s' "$n"
}

cmd_apply() {
  local dir; dir="$(state_dir)"
  if [ "${1:-}" = "--done" ]; then
    rm -f "$dir/applying"; printf 'xreview: apply window closed\n'; return 0
  fi
  [ -n "${1:-}" ] || die "usage: xreview apply <nonce> | xreview apply --done"
  local base; base="$(git merge-base HEAD origin/HEAD 2>/dev/null \
                      || git merge-base HEAD main 2>/dev/null || printf '')"
  mkdir -p "$dir"
  { printf 'nonce=%s\n' "$1"
    { [ -n "$base" ] && git diff --name-only "$base"..HEAD 2>/dev/null
      git diff --name-only 2>/dev/null
      git diff --cached --name-only 2>/dev/null
    } | sort -u | sed 's/^/file=/'
  } > "$dir/applying"
  printf 'xreview: apply window open for %s (%s files in scope)\n' \
    "$1" "$(grep -c '^file=' "$dir/applying" 2>/dev/null || printf 0)"
}

cmd_receipts() {
  local f; f="$(state_dir)/reviews.jsonl"
  [ -r "$f" ] || { printf 'no reviews recorded for %s\n' "$(repo_root)"; return 1; }
  if [ "${1:-}" = "--tiers" ]; then
    jq -r '(.tier // "") | if . == "" then "(unrecorded)" else . end' "$f" 2>/dev/null \
      | sort | uniq -c | sort -rn
    return 0
  fi
  cat "$f"
}

# A repo listed as trusted in ~/.codex/config.toml has its own .codex/config.toml applied,
# which can widen the reviewer's sandbox and register MCP servers. Until the trust entries
# are narrowed this stays a tripwire rather than a wall: refuse and let a human look.
guard_project_config() {
  local root; root="$(repo_root)"
  [ -e "$root/.codex" ] && die "refusing to dispatch: $root/.codex exists and can alter the reviewer's sandbox and tools - inspect it first"
  return 0
}

# A dispatch that names a path makes the reviewer open it, and every search and read is a
# full-context model step (measured 2026-09-01: ~16 steps and ~2.0M tokens per review).
# Refuse an oversized diff rather than truncating it: a reviewer handed half a change reviews
# half a change and reports nothing on the rest, which reads as a clean review.
inline_diff() {
  local range="$1" out max
  max="${XREVIEW_MAX_DIFF_BYTES:-100000}"
  out="$(git diff "$range" 2>/dev/null)" \
    || die "cannot diff $range - check the range resolves in this repository"
  [ -n "$out" ] || die "cannot diff $range - the range is empty, so there is nothing to review"
  if [ "${#out}" -gt "$max" ]; then
    die "diff for $range is too large to carry inline (${#out} bytes, cap $max).
Review it in slices, or raise XREVIEW_MAX_DIFF_BYTES if the reviewer can hold it."
  fi
  printf '%s' "$out"
}

# Codex writes one `turn_context` record per turn into the thread's rollout file, each
# carrying the model and effort that turn ran with; the LAST one is the current setting.
codex_tier() {
  local thread="$1" f
  case "$thread" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  f="$(find "$CODEX_HOME_DIR/sessions" -name "rollout-*-$thread.jsonl" 2>/dev/null | sort | tail -1)"
  [ -n "$f" ] && [ -r "$f" ] || return 1
  jq -r 'select(.type == "turn_context") | select(.payload.model != null)
         | "\(.payload.model)/\(.payload.effort)"' "$f" 2>/dev/null | tail -1 | grep . || return 1
}

cmd_tier() {
  local thread
  if [ "$#" -ge 1 ]; then thread="$1"; else
    thread="$(target_thread)"; [ -n "$thread" ] || die "no review thread yet"
  fi
  codex_tier "$thread" || die "cannot read the reviewer tier for $thread"
}

cmd_dispatch() {
  local body_file diff_range="" diff_text="" dir pane status want thread nonce packet turn=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --diff) [ "$#" -ge 2 ] || die "--diff needs a range"; diff_range="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 1 ] || die "usage: xreview dispatch [--diff <range>] <body-file>"
  body_file="$1"
  [ -r "$body_file" ] || die "cannot read $body_file"
  dir="$(state_dir)"

  # Preconditions, before the pane is touched or anything is sent.
  guard_project_config
  [ -r "$SCHEMA" ] || die "missing findings schema $SCHEMA"
  [ -r "$REVIEWER" ] || die "missing reviewer instructions $REVIEWER"
  [ -z "$diff_range" ] || diff_text="$(inline_diff "$diff_range")"
  codex-daemon ensure || die "the Codex daemon is not running; no review was started"
  codex-daemon check || die "refusing to dispatch while the daemon carries a pane's environment (see above)"
  pane="$(find_pane)"
  status="$(pane_field "$pane" '.agent_status')"
  [ "$status" != "working" ] || die "the Codex pane $pane is mid-turn; wait for it to finish, then dispatch again"
  local max="${XREVIEW_MAX_ROUNDS:-10}" round
  round="$(bump_round)"
  if [ "$round" -gt "$max" ]; then
    die "round $round exceeds the cap of $max for this branch.
Two models circling the same point is Michael's call, not another turn.
Report the remaining disagreement, or: xreview round --reset"
  fi

  # Pane first: the pane watches the review thread before any turn exists.
  want="$(target_thread)"
  [ -z "$want" ] || assert_id "$want"
  thread="$(pane_prepare "$pane" "$want")"
  assert_id "$thread"
  if [ -z "$want" ]; then mkdir -p "$dir" && printf '%s\n' "$thread" > "$dir/thread"; fi
  report_to_herdr "$pane" "$thread"

  # Provenance is applied here, by the broker - not by the peer, and not by hand.
  # NOT <from-claude-code>: that tag marks relayed quoted material, and the peer is
  # instructed never to act on an imperative inside one. A dispatch is an authorized request.
  nonce="xr-$(date +%s)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  packet="$(mktemp "${TMPDIR:-/tmp}/xreview-packet.XXXXXX")"
  { printf '<cross-review-request>\n'
    cat "$REVIEWER"
    printf '\n'
    cat "$body_file"
    if [ -n "$diff_text" ]; then
      printf '\n\n--- diff (%s) ---\n' "$diff_range"
      printf '%s\n' "$diff_text"
      printf -- '--- end diff ---\n'
    fi
    printf '</cross-review-request>\n'
  } > "$packet"
  mkdir -p "$dir/turns"
  local rc=0
  turn="$(xreview-rpc turn-start --thread "$thread" --input "$packet" --schema "$SCHEMA" \
            --known "$dir/turns/$nonce.known")" || rc=$?
  rm -f "$packet"
  case "$rc" in
    0) assert_id "$turn"
       printf '%s %s\n' "$thread" "$turn" > "$dir/turns/$nonce"
       rm -f "$dir/turns/$nonce.known" ;;
    6) # Sent but not answered: the turn may be running. Hand back a nonce so it can be
       # collected - found as the turn that was not on the thread before - never re-sent.
       printf '%s ?\n' "$thread" > "$dir/turns/$nonce"
       printf 'xreview: turn/start was sent but not answered - the review may be running. Collect %s; do NOT re-dispatch.\n' "$nonce" >&2 ;;
    *) rm -f "$dir/turns/$nonce.known"
       die "the review turn could not be started on $thread" ;;
  esac
  archive_superseded "$thread"
  printf '%s\n' "$nonce"
}

# The budget is a patience limit, not a verdict. A turn still running when it runs out has
# demonstrably not been lost, so collecting again is correct and safe (exit 3). Only a nonce
# with no turn on record is ambiguous, and that one must not be re-dispatched.
COLLECT_BUDGET_DEFAULT=2700

cmd_collect() {
  local nonce="${1:-}" budget="${2:-$COLLECT_BUDGET_DEFAULT}" rec thread turn out rc
  case "$nonce" in
    xr-*) ;;
    *) die "usage: xreview collect <nonce> [budget] - nonces start with xr-" ;;
  esac
  assert_id "$nonce"
  rec="$(state_dir)/turns/$nonce"
  [ -r "$rec" ] || die "ambiguous: no turn on record for $nonce (do NOT retry the dispatch)"
  read -r thread turn < "$rec"
  assert_id "$thread"
  local which
  if [ "$turn" = "?" ]; then
    which=(--new-since "$(state_dir)/turns/$nonce.known")
  else
    assert_id "$turn"; which=(--turn "$turn")
  fi
  set +e
  out="$(xreview-rpc turn-wait --thread "$thread" "${which[@]}" --budget "$budget" --schema "$SCHEMA")"
  rc=$?
  set -e
  case "$rc" in
    0) printf '%s\n' "$out"
       record_receipt "$thread" "$nonce" "$turn" "$out" ;;
    3) printf 'xreview: still running after %ss - turn on record for %s.\nWait longer with: xreview collect %s <secs>\n' \
         "$budget" "$nonce" "$nonce" >&2
       exit 3 ;;
    4) printf '%s\n' "$out"
       printf 'xreview: the answer does not match the findings schema - the text above is UNTRUSTED raw output\n' >&2
       exit 4 ;;
    5) die "the Codex daemon is unreachable; the turn is on record for $nonce - run codex-daemon ensure, then collect again" ;;
    *) die "the reviewer turn failed for $nonce (do NOT retry the dispatch)" ;;
  esac
}

case "${1:-}" in
  dispatch) shift; cmd_dispatch "$@" ;;
  collect)  shift; cmd_collect "$@" ;;
  init)     shift; cmd_init "$@" ;;
  thread)   shift; cmd_thread ;;
  tier)     shift; cmd_tier "$@" ;;
  receipts) shift; cmd_receipts "$@" ;;
  apply)    shift; cmd_apply "$@" ;;
  round)    shift; cmd_round "$@" ;;
  *) die "usage: xreview init [id] | thread | receipts [--tiers] | apply <nonce>|--done | round [--reset] | dispatch [--diff <range>] <body-file> | tier [thread] | collect <nonce> [budget]" ;;
esac
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
./tests/run.sh xreview && ./tests/dev.test.sh
```
Expected: `xreview`, `xreview-rpc`, `xreview-guard` and `xreview-apply-guard` all `ok`, and `dev.test.sh` 0 failed. `xreview-skill` is expected to FAIL until Task 7 (the skill still names `XREVIEW_THREAD_WARN`); record that failure, don't fix it here.

- [ ] **Step 7: Commit**

```bash
git -C ~/.local/share/chezmoi branch --show-current   # feat/xreview-codex-daemon
git -C ~/.local/share/chezmoi add dot_local/bin/executable_xreview tests/xreview.test.sh \
  dot_config/xreview/reviewer.md dot_config/herdr/codex-pane-command dot_config/herdr/executable_layout.sh
git -C ~/.local/share/chezmoi commit -m "Dispatch reviews pane-first on the Codex daemon with structured findings"
```

---

### Task 7: The cross-review skill and its drift test

**Files:**
- Modify: `dot_claude/skills/cross-review/SKILL.md`
- Modify: `tests/xreview-skill.test.sh` (the block at lines 181–188 and the block at 266–284)

**Interfaces:**
- Consumes: the xreview CLI from Task 6 (subcommands, `XREVIEW_PANE`, exit codes 3 and 4, `codex-daemon restart`).

- [ ] **Step 1: Update the drift test so it fails**

1. Replace the staleness-threshold block (the `code_warn=` block, lines 181–188) with:
```bash
# A schema miss is its own exit code. The skill must say what to do with it, or the model
# treats raw reviewer prose as findings.
if grep -q 'Exit 4' "$SKILL" && strip_comments "$XREVIEW" | grep -q 'exit 4'; then
  _pass "the skill and the CLI agree that a schema miss exits 4"
else
  _fail "the skill and the CLI agree that a schema miss exits 4" "skill/CLI mismatch"
fi
```
2. Replace the two blocks asserting `only staleness signal` and `XREVIEW_THREAD_WARN` with:
```bash
# Rotation is now mechanical: each checkpoint starts on a fresh thread by itself. The old
# staleness warning and "start a fresh Codex session by hand" advice must not survive in the
# skill, or the model rotates threads that the workflow already rotates.
if grep -qi 'Staleness is mechanical' "$SKILL"; then
  _pass "the skill says staleness is mechanical"
else
  _fail "the skill says staleness is mechanical" "staleness looks like a judgement call again"
fi
for stale in 'XREVIEW_THREAD_WARN' 'answered eight' 'send the pane one message' 'Start a fresh Codex session' 'codex queue'; do
  if grep -qi -- "$stale" "$SKILL"; then
    _fail "the skill no longer says '$stale'" "still present"
  else
    _pass "the skill no longer says '$stale'"
  fi
done
if grep -qi 'The pane comes first' "$SKILL"; then
  _pass "the skill explains pane-first dispatch"
else
  _fail "the skill explains pane-first dispatch" "missing"
fi
# Restarting a contaminated daemon disconnects every Codex TUI. That is Michael's call.
if grep -q 'codex-daemon restart' "$SKILL" && grep -qi "Michael's call" "$SKILL"; then
  _pass "the skill leaves the daemon restart to Michael"
else
  _fail "the skill leaves the daemon restart to Michael" "missing"
fi
```

Run it:
```bash
./tests/run.sh xreview-skill
```
Expected: FAIL on `Exit 4`, `Staleness is mechanical`, the stale phrases (`XREVIEW_THREAD_WARN`, `answered eight`, `send the pane one message`, `Start a fresh Codex session`), `The pane comes first`, and `codex-daemon restart`.

- [ ] **Step 2: Edit `dot_claude/skills/cross-review/SKILL.md`**

1. Replace everything from `The thread resolves automatically:` through `…it is not a missing pane.` with:
```markdown
**The pane comes first.** `xreview dispatch` prepares the repository's Codex pane before any
turn exists, so Michael can follow the review from its first token.
- The first dispatch of a checkpoint restarts that pane on a fresh Codex session. The session's
  new thread becomes the checkpoint's review thread.
- Later rounds find the pane already on it.
- The reviewer answers in the findings schema, and `xreview collect` prints that JSON: a
  `verdict` (`approve` or `changes`) and `findings`, each with `severity`, `file`, `line`,
  `summary` and `failure_scenario`.
- `xreview thread` shows the checkpoint's thread; `xreview init <id>` pins one by hand.

Dispatch refuses, before touching the pane or starting a turn, when:

- the Codex daemon is down and will not start;
- the daemon carries a herdr pane's environment. The fix is `codex-daemon restart`, which
  disconnects every open Codex TUI, so it is Michael's call: report it, never run it;
- there is no Codex pane for the repository, or several (`XREVIEW_PANE` picks one);
- the Codex pane is mid-turn. Wait for it, then dispatch again.
```
2. Directly after the paragraph that begins `Only the "no turn on record" collect is a timeout`, add:
```markdown
**Exit 4: the answer does not match the findings schema.** The raw text is printed and is
untrusted. Report it; do not re-dispatch.
```
3. Replace the paragraph that begins `**The only staleness signal is` together with the paragraph that begins `Two counters exist` with:
```markdown
**Staleness is mechanical, not a judgement.** Each checkpoint starts on a fresh thread, so a
thread only ever holds the rounds of one checkpoint, and the round cap bounds those.
- Do not infer staleness from the round number, from how long the exchange feels, or from
  the reviewer agreeing with you.
- Never rotate a thread within a checkpoint.
```
4. In the escalation list, after the `xreview refuses the round` bullet, add:
```markdown
- `xreview` refuses because the Codex daemon carries a pane's environment. The fix disconnects
  every Codex TUI.
```
5. In the bullet that begins `**Exit 1, "no turn on record"**`, replace `the queue may never have landed` with `the turn may never have started`.
6. Replace the section from `**Rotate the thread between checkpoints.**` through the end of the paragraph that ends `…one that the workflow does not call for.` with:
```markdown
**Rotation happens between checkpoints, by itself.** Run `xreview round --reset` when moving
on to the next checkpoint. It drops the counter and the cached thread; the next dispatch then
restarts the Codex pane on a fresh thread and archives the old one. Nobody starts a Codex
session by hand for this.

Rotation is keyed to **checkpoints, not rounds**. Moving from plan review to the pre-merge
review rotates; going from round 3 to round 4 of the same plan review does not.
```

- [ ] **Step 3: Run the tests to verify they pass**

```bash
./tests/run.sh xreview
```
Expected: `xreview`, `xreview-rpc`, `xreview-skill`, `xreview-guard` and `xreview-apply-guard` all `ok`.

- [ ] **Step 4: Commit**

```bash
git -C ~/.local/share/chezmoi branch --show-current   # feat/xreview-codex-daemon
git -C ~/.local/share/chezmoi add dot_claude/skills/cross-review/SKILL.md tests/xreview-skill.test.sh
git -C ~/.local/share/chezmoi commit -m "Teach the cross-review skill pane-first dispatch and structured findings"
```

---

### Task 8: Live canary and the testing table

**Files:**
- Create: `tests/live-codex-daemon.test.sh`
- Modify: `AGENTS.md` (the Rules list and the Testing table)

**Interfaces:**
- Consumes: the deployed `codex-daemon`, the pane-map hook and the title config; the source `xreview-rpc`, `findings.schema.json` and `codex-pane-command`.

- [ ] **Step 1: Write the suite** — `tests/live-codex-daemon.test.sh`

```bash
#!/usr/bin/env bash
# Live canary for xreview's Codex daemon path: the real daemon, a scratch herdr tab and one
# small real turn. Re-checks facts F11 and F14-F17 and the pane-map hook after a Codex update,
# when the experimental app-server protocol may have moved (spec section 9). Needs everything
# deployed (`chezmoi apply`) and a clean daemon (`codex-daemon check`).
# test-requires: unsandboxed, herdr, codex-daemon  # drives the real daemon and a scratch herdr tab
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
RPCF="$SRC/dot_local/bin/executable_xreview-rpc"
SCHEMA="$SRC/dot_config/xreview/findings.schema.json"
PCMD="$SRC/dot_config/herdr/codex-pane-command"
for f in "$RPCF" "$SCHEMA" "$PCMD"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }
rpc() { python3 "$RPCF" "$@"; }

command -v herdr >/dev/null || { echo "INCONCLUSIVE: herdr not on PATH" >&2; exit 2; }
codex-daemon check || { echo "INCONCLUSIVE: the Codex daemon is not running clean" >&2; exit 2; }
ws="${HERDR_WORKSPACE_ID:-}"
[ -n "$ws" ] || { echo "INCONCLUSIVE: run from inside a herdr pane" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/live-codex.XXXXXX")"
tab=""; pane=""; thread=""
cleanup() {
  if [ -n "$pane" ]; then
    herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1; sleep 0.5
    herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1; sleep 1
  fi
  [ -n "$tab" ] && herdr tab close "$tab" >/dev/null 2>&1
  [ -n "$thread" ] && rpc thread-archive --thread "$thread" >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT

out="$(herdr tab create --workspace "$ws" --cwd "$SRC" --label live-codex --no-focus)"
tab="$(printf '%s' "$out" | jq -r '.result.tab.tab_id')"
pane="$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')"
herdr pane run "$pane" "$(grep -v '^[[:space:]]*#' "$PCMD" | grep . | head -1)" >/dev/null

echo "F11/F14: the title carries the thread id at launch, and the daemon has it loaded"
t=""
for _ in $(seq 20); do
  t="$(herdr pane get "$pane" | jq -r '.result.pane.terminal_title_stripped // .result.pane.terminal_title // ""')"
  thread="$(printf '%s' "$t" | grep -oE '^[[:space:]]*[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tr -d ' ' || true)"
  [ -n "$thread" ] && break; sleep 1
done
if [ -n "$thread" ]; then _pass "the pane title starts with the thread id"; else _fail "the pane title starts with the thread id" "$t"; fi
is "the daemon has the new thread loaded" "$(rpc thread-status --thread "$thread" | jq -r .loaded)" true

echo "F15: a turn from another client renders in the pane"
printf 'Live canary. Reply with verdict "approve" and no findings.\n' > "$T/in"
turn="$(rpc turn-start --thread "$thread" --input "$T/in" --schema "$SCHEMA")"
seen=0
for _ in $(seq 10); do
  herdr pane read "$pane" 2>/dev/null | grep -q 'Live canary' && { seen=1; break; }; sleep 1
done
is "the pane shows the turn another client started" "$seen" 1

echo "F16/F17: waiting from a fresh connection returns schema-valid JSON"
res="$(rpc turn-wait --thread "$thread" --turn "$turn" --budget 180 --schema "$SCHEMA")"; rc=$?
is "turn-wait completes" "$rc" 0
is "with the schema's verdict" "$(printf '%s' "$res" | jq -r .verdict 2>/dev/null)" approve

echo "the pane-map hook tells herdr the pane's thread after its first turn"
s=""
for _ in $(seq 15); do
  s="$(herdr pane get "$pane" | jq -r '.result.pane.agent_session.value // empty')"
  [ "$s" = "$thread" ] && break; sleep 1
done
is "herdr knows the scratch pane's thread" "$s" "$thread"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

```bash
chmod 755 tests/live-codex-daemon.test.sh
./tests/run.sh
```
The run has no filter on purpose: a filtered run executes tagged suites instead of skipping them. Expected: `live-codex-daemon` is listed as `skip … needs: unsandboxed, herdr, codex-daemon`, and every other suite is `ok`. The live run itself happens in Task 9.

- [ ] **Step 2: Update `AGENTS.md`**

1. In the Rules list, after the Brewfile bullet, add:
```markdown
- `~/.local/bin/codex` is a launcher that shadows Homebrew's `codex`: interactive starts
  attach to the launchd-started daemon or refuse (`--no-daemon` is the escape). Anything
  needing the real binary uses `codex-daemon real-bin`, never `command -v codex`.
```
2. In the Testing table, after the `dev-integrations` row, add:
```markdown
| `live-codex-daemon` | unsandboxed + live `herdr` + clean daemon | drives the real Codex daemon and a scratch tab; the canary for Codex protocol changes. Run from inside a herdr pane after `chezmoi apply` |
```

- [ ] **Step 3: Commit**

```bash
git -C ~/.local/share/chezmoi branch --show-current   # feat/xreview-codex-daemon
git -C ~/.local/share/chezmoi add --chmod=+x tests/live-codex-daemon.test.sh
git -C ~/.local/share/chezmoi add AGENTS.md
git -C ~/.local/share/chezmoi commit -m "Add a live canary for the Codex daemon path"
```

---

### Task 9: Rollout and live verification (operator-confirmed)

This task changes the live machine. **Ask Michael before Step 3**: stopping the contaminated daemon disconnects every open Codex TUI.

**Files:** none; everything was committed in Tasks 1–8.

- [ ] **Step 1: Run the whole default suite**

```bash
./tests/run.sh
```
Expected: every suite `ok`; the `test-requires` suites are listed as skipped. Report the totals as passed/total.

- [ ] **Step 2: Deploy the changed files (targeted apply, unsandboxed)**

```bash
chezmoi apply ~/.local/bin/codex ~/.local/bin/codex-daemon ~/.local/bin/codex-code-mode-host \
  ~/.local/bin/xreview ~/.local/bin/xreview-rpc ~/.config/xreview ~/.config/herdr/codex-pane-command \
  ~/.config/herdr/layout.sh ~/.codex/config.toml ~/.codex/hooks.json ~/.codex/herdr-codex-pane-map.py \
  ~/.claude/skills/cross-review/SKILL.md ~/Library/LaunchAgents/be.netronix.codex-app-server.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/be.netronix.codex-app-server.plist
command -v codex; codex-daemon real-bin; codex-daemon check; echo "check rc=$?"
```
Expected:
- `command -v codex` prints `~/.local/bin/codex`.
- `real-bin` prints the Caskroom binary.
- `check` fails, naming `codex-daemon restart`: the running daemon still carries VM.Portal's pane environment.

- [ ] **Step 3: With Michael's explicit go-ahead, restart the daemon clean**

```bash
codex-daemon restart; echo "restart rc=$?"
for f in ~/.codex/app-server-daemon/daemon.pid ~/.codex/app-server-daemon/daemon-updater.pid; do
  pid="$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$f")"; ps eww -o command= -p "$pid" | tr ' ' '\n' | grep -c '^HERDR_'
done
```
Expected: `restart rc=0`, and `0` for both pids. If the supervisor survived `stop`, `restart` handled it; confirm no stale `app-server daemon` process remains:
```bash
ps -axo pid,lstart,command | grep 'codex app-server' | grep -v grep
```
Every process listed must have started after the restart.

- [ ] **Step 4: Relaunch the Codex panes and reconcile**

Ask Michael to relaunch each Codex pane (or do it on his go-ahead): in each, `herdr pane run <pane> "$(grep -v '^#' ~/.config/herdr/codex-pane-command | grep . | head -1)"`. Then:
```bash
python3 ~/.codex/herdr-codex-pane-map.py --reconcile
herdr pane list | jq -r '.result.panes[] | select(.agent=="codex") | "\(.pane_id) \(.terminal_title_stripped // .terminal_title) :: \(.agent_session.value // "none")"'
```
Expected: every Codex pane's title starts with a UUID, and that same UUID is its session value.

- [ ] **Step 5: Run the live canary, from inside a herdr pane, unsandboxed**

```bash
./tests/run.sh live-codex-daemon
```
Expected: `ok`. On any FAIL, stop and report it with the output. The protocol facts no longer hold, and the design needs revisiting, not patching.

- [ ] **Step 6: Real dispatch**

The pre-merge cross-review of this branch is the real-world check:
1. `xreview round --reset` (moving from the spec checkpoint).
2. Dispatch the branch diff through the new `xreview`.
3. Confirm the chezmoi Codex pane restarts on a fresh thread and renders the review from its first token, and that `xreview collect` prints schema-valid JSON.

---

## Execution notes

- The spec status moves to `In progress` in Task 1 Step 0. Before merge, set it to `Implemented`, citing the MR or local merge, per the design-record policy. Mark this plan `**Status:** Implemented` in the same final pre-merge commit, so it is not re-executed.
- Tasks 1, 3 and 5 are independent of one another. Task 2 needs Task 1; Task 4 needs Task 3; Task 6 needs Tasks 1 and 5; Task 7 needs Task 6; Task 8 needs Tasks 1–6; Task 9 needs all of them.
