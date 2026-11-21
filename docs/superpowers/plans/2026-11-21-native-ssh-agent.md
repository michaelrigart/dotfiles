# Native SSH agent Implementation Plan

> **For agentic workers:** run this plan with the `plan-run` skill (it overrides
> superpowers:subagent-driven-development). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** agents and shells sign and authenticate through our own `/usr/bin/ssh-agent` on a fixed
socket, so the 1Password SSH agent and its prompts can be turned off.

**Architecture:** a LaunchAgent runs `~/.local/bin/ssh-agent-run`, which starts `ssh-agent -D` on
`$HOME/.local/state/ssh-agent/agent.sock` and loads a fixed key list. Claude Code's settings and
`zshenv` point `SSH_AUTH_SOCK` at that socket; the sandbox allows it and denies writes to its
directory.

**Tech Stack:** bash 3.2, zsh, launchd plist, jq (the settings `modify_` script), shell suites
under `tests/`.

**Spec:** `docs/superpowers/specs/2026-11-21-native-ssh-agent-design.md` (read it first).

## Global Constraints

- Socket path, everywhere: `$HOME/.local/state/ssh-agent/agent.sock`, spelled from `$HOME`, never
  `XDG_STATE_HOME`. Directory `$HOME/.local/state/ssh-agent`, mode 700.
- Key list, in this order: `michael`, `viumore_rsa`, `michael_rsa`. Never `borg*` or `huginn`.
- The 1Password socket stays as the second `allowUnixSockets` entry and the zshenv fallback:
  `$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`.
- Never read `~/.ssh` or print key material; suites use a temporary `HOME` and stubs.
- The sandbox forbids `bind()`: a fake socket is a symlink to a system socket under `/var/run`
  (as `tests/zshenv.test.sh` does).
- Every new suite: mode 755, correct shebang, exit 2 when its subject is missing, a
  `tests/missing-subject.test.sh` row, and `.scripts/test-audit/subjects.tsv` rows for the files it
  loads (`tests/AGENTS.md`).
- Repository is public: nothing private in any file.

## Review Focus

1. A stale socket left by a crash at the fixed path: the next start must remove it, not fail
   (Task 1, `stale socket` test).
2. Something other than a socket at that path (a planted file): refuse, keep it, exit 1
   (Task 1, `regular file` test).
3. The agent never comes up (bad binary, path too long): the script must not hang; it gives up
   after 5 s and exits 1 (Task 1, `no socket` test).
4. A key that fails to load (passphrase): logged by name, the other keys still load, nothing from
   `ssh-add`'s output reaches the log (Task 1, `failed add` test).
5. A shell where the native socket path exists but is not a socket: falls back exactly as today
   (Task 3, `non-socket native path` test).

---

Order: Tasks 1, 2 and 3 together (disjoint files except `subjects.tsv` and
`missing-subject.test.sh`, which only Task 1 touches); then Task 4.

### Task 1: The agent job (loader script and LaunchAgent)

**Depends on:** none.

**Files:**
- Create: `dot_local/bin/executable_ssh-agent-run`
- Create: `Library/LaunchAgents/be.netronix.ssh-agent.plist.tmpl`
- Create: `tests/ssh-agent-run.test.sh` (mode 755: `git add --chmod=+x`)
- Modify: `.scripts/test-audit/subjects.tsv` (rows for the script and the plist, both
  `own_suite`/`loaded_by` `ssh-agent-run`; lang `bash` and `data`)
- Modify: `tests/missing-subject.test.sh` (one `missing ssh-agent-run dot_local/bin/executable_ssh-agent-run` row)

**Interfaces:**
- Produces: `~/.local/bin/ssh-agent-run`, no arguments. Shebang `#!/bin/bash`;
  `PATH=${PINNED_PATH:-/usr/bin:/bin}` (the override is for the suite only, as in
  `dot_claude/hooks/executable_prompt-audit.sh`). Exit: the agent's status when it exits; 1 when
  the path holds a non-socket or the socket does not appear within 5 s; 143 on `SIGTERM`.
- Produces: log `$HOME/.local/state/ssh-agent/error.log`, one line per event,
  `<ISO-8601 UTC> <message>`; messages never include `ssh-add` output.
- Produces: LaunchAgent label `be.netronix.ssh-agent`.

- [ ] **Step 1: Write `tests/ssh-agent-run.test.sh`** (bash, prose `  PASS:`/`  FAIL:` idiom). It
  exits 2 if the script is missing, or if no system socket exists under `/var/run` to symlink.
  Each case gets a fresh temp `HOME` with `~/.ssh/{michael,viumore_rsa,borg,huginn}` (empty
  files; no `michael_rsa`) and a stub directory on `PINNED_PATH` holding:
  - `ssh-agent`: appends `agent $*` to `$STUB_LOG`; unless `STUB_NO_SOCKET=1`, symlinks the
    `-a` path to the system socket; traps `TERM` (appends `agent-term`, exits 143); then sleeps in
    a loop, or exits `$STUB_AGENT_RC` after `$STUB_AGENT_LIFE` seconds when that is set.
  - `ssh-add`: appends `add $SSH_AUTH_SOCK $*` to `$STUB_LOG`; when its last argument ends with
    `/$STUB_ADD_FAIL`, prints `STUBSECRET` to stderr and exits 1.
  - Plus `/bin/sleep`, `date`, `mkdir`, `chmod`, `rm`, `stat` reachable (append `/usr/bin:/bin`).
  Cases (assertion text is the label):
  - `agent runs on the fixed socket in the foreground`: `$STUB_LOG` has
    `agent -D -a $HOME/.local/state/ssh-agent/agent.sock`.
  - `loads exactly the listed keys that exist`: the `add` lines are exactly
    `add <sock> -q $HOME/.ssh/michael` then `… viumore_rsa`; none for `michael_rsa`, `borg`,
    `huginn`.
  - `state directory is mode 700`: `stat -f %Lp` prints `700`.
  - `exits with the agent's status`: `STUB_AGENT_LIFE=1 STUB_AGENT_RC=7` → rc 7.
  - `stale socket is removed`: pre-create the path as a symlink to the system socket → script
    starts the agent (rc 7 as above).
  - `regular file at the socket path is refused and kept`: pre-create a regular file → rc 1, no
    `agent` line, the file still exists, `error.log` has one line.
  - `gives up when no socket appears`: `STUB_NO_SOCKET=1` → rc 1 within 8 s, `agent-term` logged.
  - `failed add is logged by name only and the rest still load`: `STUB_ADD_FAIL=michael` →
    `error.log` names `michael`, does not contain `STUBSECRET`; the `viumore_rsa` add happened.
  - `SIGTERM stops the agent and removes the socket`: start in the background with a long-lived
    stub, wait for the socket symlink, `kill -TERM` the script → rc 143, `agent-term` logged,
    socket path gone.
  - `plist is valid and runs the script`: `plutil -lint` on the plist with `{{ .chezmoi.homeDir }}`
    replaced by the temp `HOME` (sed); `plutil -extract Label raw` is `be.netronix.ssh-agent`;
    `ProgramArguments.0` is `$HOME/.local/bin/ssh-agent-run`; `KeepAlive` and `RunAtLoad` are true.
- [ ] **Step 2: Run** `./tests/ssh-agent-run.test.sh`. Expected: exit 2 (subject missing).
- [ ] **Step 3: Write the script** per spec section 1 steps 1–5 and the Interfaces above. A
  `trap` on `TERM` kills the agent, waits for it, removes the socket, exits 143. The 5 s wait
  polls `-S` every 0.1 s.
- [ ] **Step 4: Write the plist**, modelled on
  `Library/LaunchAgents/be.netronix.codex-memory-share.plist.tmpl`: header comment (what it does,
  bootstrapped by `.scripts/configure.sh`, the hand-load command, this spec), `Label`,
  `ProgramArguments` = `{{ .chezmoi.homeDir }}/.local/bin/ssh-agent-run`, `RunAtLoad` true,
  `KeepAlive` true, `StandardOutPath`/`StandardErrorPath` `/dev/null`. No `ProcessType`.
- [ ] **Step 5: Run** `./tests/ssh-agent-run.test.sh`, `./tests/run.sh missing-subject run`.
  Expected: all pass.
- [ ] **Step 6: Commit** the five files, "Add a native SSH agent LaunchAgent and key loader".

### Task 2: Claude Code settings

**Depends on:** none.

**Files:**
- Modify: `dot_claude/modify_private_settings.json` (the `--arg agent_socket` line, the
  `allowUnixSockets` line, the `denyWrite` expression, the `permissions.deny` list)
- Modify: `tests/claude-settings.test.sh` (sections F, G and H pins, `EXP_DENY`, `EXP_DENY_WRITE`)

**Interfaces:** none produced for other tasks.

- [ ] **Step 1: Change the pins first.** `AGENT_SOCKET="$HOME/.local/state/ssh-agent/agent.sock"`;
  add `OP_AGENT_SOCKET` with the 1Password path; `env.SSH_AUTH_SOCK == $AGENT_SOCKET` (label
  "Claude uses the native agent socket"); `allowUnixSockets == [AGENT_SOCKET, OP_AGENT_SOCKET]`
  (label "allowUnixSockets is exactly the native socket, then the 1Password socket"); the section H
  check becomes `endswith("/.local/state/ssh-agent/agent.sock")`; `EXP_DENY` gains
  `"Edit(~/.local/state/ssh-agent)","Edit(~/.local/state/ssh-agent/**)"` right after
  `"Edit(~/.config/forge-protection/**)","Edit(~/.config/git/hooks/**)"`; `EXP_DENY_WRITE` gains
  `+ ["~/.local/state/ssh-agent", "~/.local/state/ssh-agent/**"]` at the end.
- [ ] **Step 2: Run** `./tests/claude-settings.test.sh`. Expected: those assertions FAIL, the rest
  pass.
- [ ] **Step 3: Change the template** to match: `--arg agent_socket` → the native path, a new
  `--arg op_agent_socket` with the 1Password path, `"allowUnixSockets": [$agent_socket,
  $op_agent_socket]`, the two `Edit` denies (with a one-line comment: a session rooted in `~`
  could otherwise replace the socket), and the two `denyWrite` entries appended last.
- [ ] **Step 4: Run** `./tests/claude-settings.test.sh`. Expected: all pass.
- [ ] **Step 5: Commit** both files, "Point Claude Code at the native SSH agent socket".

### Task 3: Shells

**Depends on:** none.

**Files:**
- Modify: `dot_config/zsh/zshenv:67-72`
- Modify: `tests/zshenv.test.sh` (the SSH_AUTH_SOCK block, lines ~100-130)

- [ ] **Step 1: Extend the suite.** Keep the five existing 1Password cases unchanged (they hold
  while no native socket exists). Then add, with `NATIVE="$FAKE/.local/state/ssh-agent/agent.sock"`:
  - `a non-socket native path is ignored`: regular file at `$NATIVE`, 1Password symlink present,
    herdr preset → `$OP_DIR/agent.sock`.
  - `the native agent wins over the 1Password agent and a herdr socket`: `$NATIVE` a symlink to
    the system socket → `$NATIVE`.
  - `an SSH login uses the native agent`: same, with `SSH_CONNECTION` set → `$NATIVE`.
  - `the native agent is used without 1Password`: remove the 1Password symlink → `$NATIVE`.
- [ ] **Step 2: Run** `./tests/zshenv.test.sh`. Expected: the three native-wins cases FAIL.
- [ ] **Step 3: Change zshenv** per spec section 3: native socket if `-S`, else (local shell only)
  the 1Password socket if `-S`, else leave `SSH_AUTH_SOCK`. Update the comment above it in two
  lines; unset both helper variables.
- [ ] **Step 4: Run** `./tests/zshenv.test.sh`. Expected: all pass. (`wt-functions` and `zshrc`
  also load zshenv; `--changed` in Task 4 runs the heavy one, and `zshrc` needs an unsandboxed
  pty, so it is listed for Michael in the final report.)
- [ ] **Step 5: Commit** both files, "Prefer the native SSH agent in every shell".

### Task 4: Preflight, docs, finish

**Depends on:** Tasks 1, 2, 3.

**Files:**
- Modify: `.scripts/preflight-ssh-agent.sh` (candidate list)
- Modify: `README.md` (feature line 22 and the SSH agent steps)
- Modify: `docs/superpowers/specs/2026-11-21-native-ssh-agent-design.md` (Status)

- [ ] **Step 1: Preflight.** Put `$HOME/.local/state/ssh-agent/agent.sock` first in the `for c in`
  list. Check: `bash -n .scripts/preflight-ssh-agent.sh`.
- [ ] **Step 2: README.** Feature line: keys and secrets come from 1Password; a native agent
  serves the SSH keys. Add a short "SSH agent" section with the spec's "Michael's steps after
  merge" 1–5 and the rollback, pointing to the spec for the reasons.
- [ ] **Step 3: Status.** Spec `**Status:** In progress`, plus the PR reference once it exists.
- [ ] **Step 4: Full run.** `./tests/run.sh --changed`; report totals as passed/total and quote
  the heavy-suite lines.
- [ ] **Step 5: Commit**, "Document the native SSH agent".
