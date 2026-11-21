# Native SSH agent for agents and shells

**Status:** Implemented — PR #40 (https://github.com/michaelrigart/dotfiles/pull/40)
**Signed off:** Michael, 2026-11-21, with the key list as proposed.
**Amended:** 2026-11-21, after the final review: AddKeysToAgent step, the agent-contents probe, and the step corrections listed in the PR.
**Amended again:** 2026-11-21, after merge (PR #44,
https://github.com/michaelrigart/dotfiles/pull/44): `michael_rsa` is dropped from the key list. On
fenrir it did not load (`could not load key michael_rsa` in `error.log`), no host in the ssh
config names it, and github.com, gitlab.com and ssh.dev.azure.com authenticated through the native
agent with `michael` and `viumore_rsa` alone.
Loading it would only widen what agents can use without a prompt. The key file, its 1Password item
and the ssh config are unchanged; removing the key is Michael's call.
**Size:** about 120 lines of non-test code: one LaunchAgent plist (mostly its header comment), one
loader script of about 40 lines, about 10 lines in `dot_claude/modify_private_settings.json`,
about 6 in `dot_config/zsh/zshenv`, 3 in `.scripts/preflight-ssh-agent.sh`, a subject-map row and a
few lines of docs. Comparable: `be.netronix.codex-memory-share` (plist plus script). No increments.

## Why

Michael named "the constant consent I need to give to provide the AI agent with access to specific
1Password items" as a major friction (review answers E5 and H1, 2026-11-20). Measured 2026-11-21:

- **The prompts are the 1Password SSH agent's, for commit signing and SSH push and fetch.** The
  Claude transcripts changed in the 14 days before 2026-11-21 hold about 2,460 agent `git commit`
  and about 1,500 remote git operations (push, fetch, pull, ls-remote, clone), from 158 distinct
  sessions; on busy days 20 to 28 sessions each sign and authenticate. Michael confirmed that his
  prompts are SSH and signing, and come back when 1Password closes or locks.
- **`op` is not the source.** Agents ran about 40 `op` commands in a month, most refused by the
  deny rules before reaching 1Password. `review` wrote no report in those 14 days.
- **1Password cannot make a key prompt-free** (www.1password.dev/ssh/agent/security and
  /authorization, read 2026-11-21). Approval is per key and per application (or per terminal tab),
  remembered until lock by default or for at most 24 hours. A service account cannot serve SSH keys
  or read the Private vault. An approval names only the application and the key, not the operation
  or destination: once given, every process under that application signs and pushes anything.
- **The private keys are on disk already.** `private_dot_ssh/` renders them from 1Password at
  apply; agents cannot read them only because the sandbox denies `~/.ssh`. So the 1Password agent's
  approval prompt is the only thing it adds over an agent that holds those files.
- **hercules** (spec 2026-11-15-hercules-agent-machine) will run agents remotely, where nobody is
  at the machine to approve a 1Password prompt.

## Goal, non-goals, anti-goals

- **Goal:** agents and Michael's shells sign and authenticate with no 1Password prompt, on fenrir
  and on hercules, without letting an agent read or copy a private key.
- **Non-goals:** chezmoi's `onepasswordRead` templates and Michael's own `op` use (unchanged);
  the `op` deny rules (unchanged); a separate agent-only key or vault (rejected below).
- **Anti-goals:** an agent able to read a private key file; the borg keys reachable through the
  agent; a socket allowlist entry that admits more than one fixed path (a wildcard over the launchd
  directory, rejected in spec 2026-07-30-claude-code-security-posture).

## Approaches

| | Prompts | What a runaway agent or a process running as Michael gains | Work |
|---|---|---|---|
| A. 1Password agent, approval remembered 24 h, per application | one unlock after each lock, one approval per key per day | signs and pushes once approved, which is nearly always | three app settings |
| B. macOS built-in `ssh-agent` | none after loading | signs and pushes always | not possible: its socket is `/var/run/com.apple.launchd.<random>/Listeners`, new every boot, and the sandbox allows a socket only by a fixed path |
| **C. Our own `/usr/bin/ssh-agent` on a fixed socket (chosen)** | none after loading | signs and pushes always; never reads a key | this spec |
| D. Agent-only key in a dedicated vault plus service account | unchanged: service accounts do not serve SSH keys | n/a | n/a |

Michael chose C on 2026-11-21: it removes every prompt, and hercules needs a native agent anyway.
A was the alternative: cheaper, but it keeps a daily prompt per key and nothing on hercules.

## Design

### 1. The agent job

`Library/LaunchAgents/be.netronix.ssh-agent.plist.tmpl` runs `~/.local/bin/ssh-agent-run` with
`RunAtLoad` and `KeepAlive` true, in the user's `gui` domain like the other `be.netronix.*` jobs.
Its header comment follows theirs: what it does, that `.scripts/configure.sh` bootstraps it, the
hand-load command, and a pointer to this spec. launchd output goes to `/dev/null`; the script logs
its own errors.

`dot_local/bin/executable_ssh-agent-run` (bash 3.2, pins `PATH=/usr/bin:/bin`, with a `PINNED_PATH`
override for its suite only, as `prompt-audit.sh` does):

1. `umask 077`; create `$HOME/.local/state/ssh-agent` and `chmod 700` it.
2. Remove `agent.sock` there if it exists **and is a socket** (left by a previous run; `ssh-agent
   -a` refuses an existing path). Anything else at that path: log and exit 1.
3. Start `ssh-agent -D -a "$HOME/.local/state/ssh-agent/agent.sock"` in the background (`-D`: stay
   in the foreground, no fork) and wait up to 5 s for the socket.
4. For each name in its fixed key list, if `~/.ssh/<name>` exists, `ssh-add -q` it with
   `SSH_AUTH_SOCK` set to the socket and stdin from `/dev/null`. A missing file is skipped
   silently (a machine may lack a rendered key); a failed add (a passphrase, a bad file) is logged.
5. `wait` on the agent. When it exits, the script exits with its status; `KeepAlive` restarts the
   job, which reloads the keys. On `SIGTERM` (a `launchctl bootout` or `kickstart -k`) the script
   stops the agent and removes the socket before exiting, so no dead socket is left for a shell to
   prefer.

Errors go to `$HOME/.local/state/ssh-agent/error.log`, one dated line each, never key material.

**The socket path is fixed: `$HOME/.local/state/ssh-agent/agent.sock`**, spelled from `$HOME`, never
from `XDG_STATE_HOME`, because `settings.json` holds an absolute path and the two must agree. It is
49 bytes for this home, well under macOS's 104-byte socket path limit.

**Key list:** `michael`, `viumore_rsa`. Signed off as `michael`, `viumore_rsa`, `michael_rsa`, my
call from the remotes in `~/Code` (42 GitHub, 39 GitLab, 4 Azure DevOps, which accepts only RSA
keys, 1 other) and the key names; the ssh config that maps hosts to keys is private and was not
read. `michael_rsa` was dropped after merge, when no host turned out to use it (the second
amendment above). `michael` and `viumore_rsa` are rendered by chezmoi on every machine, so fenrir
and hercules load the same two keys. Never `borg`,
`borg-append-only`, `borg-append-only-fenrir`, `borg-fenrir`, `borg-hercules`, `borg-synology` or
`huginn`. The list lives in the script, not in a config file: changing it is a reviewed change.

Keys load without a passphrase, as rendered: `onepasswordRead "…?ssh-format=openssh"` exports them
unencrypted. A key that later gets a passphrase fails to load and is logged; Keychain passphrases
(`ssh-add --apple-use-keychain`) are out of scope until then.

### 2. Claude Code settings

In `dot_claude/modify_private_settings.json`:

- `$agent_socket` becomes `$HOME/.local/state/ssh-agent/agent.sock`, so `env.SSH_AUTH_SOCK` points
  at the native agent.
- `sandbox.network.allowUnixSockets` becomes `[native, 1Password]`, in that order. The 1Password
  entry keeps sessions started before the apply working until they restart, and is the fallback
  once the native job is booted out (see Rollback). Settings and `zshenv` prefer the native socket
  whenever it exists, so turning the 1Password agent back on is not a rollback while the job runs.
  Once that agent is off its socket does not exist and the entry admits nothing.
- `sandbox.filesystem.denyWrite` gains `~/.local/state/ssh-agent` and
  `~/.local/state/ssh-agent/**`, and `permissions.deny` gains the matching `Edit(...)` pair. A
  session started in `~` has `~` as a write root; without these it could delete the socket (denial
  of service) or plant a symlink at `agent.sock` pointing elsewhere. The sandbox forbids `bind()`, so
  binding its own agent there is not the risk.

### 3. Shells

`dot_config/zsh/zshenv`: if `$HOME/.local/state/ssh-agent/agent.sock` is a socket, export it as
`SSH_AUTH_SOCK`, **whether or not the shell is an SSH login**; otherwise, for a local shell, the
1Password socket as today; otherwise leave `SSH_AUTH_SOCK` alone. An SSH login into hercules thus
uses hercules' own agent, which outlives the login, rather than a forwarded one that dies with it.
The herdr proxy problem the current block solves is solved the same way: the fixed socket wins.

### 4. Preflight and docs

- `.scripts/preflight-ssh-agent.sh` tries the native socket first, then the two 1Password paths.
- `README.md` line "1Password integration for SSH keys and secrets": keys and secrets come from
  1Password; a native agent serves the SSH keys. Michael's steps (below) go in the README section
  that covers the SSH agent, or a new short one.
- The 2026-07-30 security-posture spec is not edited (point-in-time); this spec supersedes its
  "agent-backed private operation" choice of socket.

## What changes for an attacker or a runaway agent

- **Gains:** sign commits and authenticate to every host the two loaded keys open, at any time,
  with no approval and no lock gate. Today it can do the same after one approval per key, which a
  busy day always gives.
- **Gains:** empty or lock the agent (`ssh-add -D`, `ssh-add -x`). Git then fails until the job
  restarts; `KeepAlive` does not notice an emptied agent, so the fix is
  `launchctl kickstart -k gui/$(id -u)/be.netronix.ssh-agent`. Accepted: denial of service only.
- **Loses:** the borg and huginn keys. The 1Password agent offers every SSH key item in the Private
  vault by default (no `agent.toml` exists), so if the backup keys are SSH key items, as their
  `ssh-format` references suggest, an approved process can use them today; the native agent holds
  them only if something adds them, since `ssh-agent` accepts keys from any client. The
  `AddKeysToAgent` step below and the live probe in `live-credential-boundary` keep it that way.
- **Unchanged:** no agent can read or copy a private key (the `~/.ssh` read denial and
  `sandbox.credentials` stay); a non-agent process running as Michael could read the key files
  already, with or without this change.

## Michael's steps after merge

On each machine (fenrir, then hercules):

1. `chezmoi apply`, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/be.netronix.ssh-agent.plist`.
2. Check: `SSH_AUTH_SOCK=~/.local/state/ssh-agent/agent.sock ssh-add -l` lists the two listed
   keys, `michael` and `viumore_rsa`, on each machine. A key that failed to load is named in
   `~/.local/state/ssh-agent/error.log`.
3. For each borg and huginn host, `ssh -G <host> | grep -i '^addkeystoagent'` must print
   `addkeystoagent false`. If not, set `AddKeysToAgent no` in the ssh config (the 1Password note
   "SSH config"): the loader now loads the keys agents need, so the directive has no use left, and
   with `yes` Michael running ssh or borg by hand from any zsh would add a borg or huginn key to the
   native agent, where every agent session could then use it.
4. Lock 1Password. Locking clears its remembered approvals, so any request its agent still serves
   prompts and is noticed; an `IdentityAgent` pin or a fallback to its socket then shows.
5. In his own terminal (not a Claude session), check that every forge host authenticates through
   the native agent alone: `SSH_AUTH_SOCK=~/.local/state/ssh-agent/agent.sock ssh -T git@github.com`,
   the same for `git@gitlab.com` and `git@ssh.dev.azure.com`, and a `git ls-remote` against the
   remaining host. Each must authenticate without a 1Password prompt; one that prompts or fails
   names a missing key, or an `IdentityAgent` line in the ssh config (the 1Password note "SSH
   config") that pins hosts to the 1Password socket. Delete a per-host pin; if it is a catch-all
   (`Host *`, as 1Password's stock snippet is), set its value to
   `~/.local/state/ssh-agent/agent.sock` instead, so processes that never source `zshenv` (GUI git
   clients, launchd jobs) still reach an agent with keys. The 1Password agent stays on until every
   host passes.
6. Restart Claude Code sessions as convenient; in a fresh one (sandboxed, so git goes through
   `ssh-sandbox-proxy`), run `./tests/run.sh live-agent-signing live-credential-boundary
   live-agent-auth`, which signs with `michael`, authenticates this repository's GitHub remote and
   checks that the native agent holds only `michael` and `viumore_rsa`, then `./tests/live-agent-auth.test.sh
   <repo>` once for a repository on each other forge.
7. When no running shell or Claude Code session predates step 1 (open new tabs and panes, restart
   sessions; a shell keeps the `SSH_AUTH_SOCK` it started with): 1Password → Settings → Developer →
   turn off "Use the SSH agent". From then on, no SSH or signing prompt should appear.

An emptied or locked native agent is not a rollback: `launchctl kickstart -k
gui/$(id -u)/be.netronix.ssh-agent` restarts it with its keys. Run it also after a key in `~/.ssh`
changes, since a rotated key stays loaded in the running agent until it restarts.

Rollback, on each machine:

1. Turn the 1Password SSH agent back on.
2. If step 5 pointed a catch-all `IdentityAgent` at the native socket, set it back to the 1Password
   socket (`IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"`,
   quoted for the space) in the "SSH config"
   note and run `chezmoi apply` (this renders `~/.ssh/config` again), before booting the job out, so
   ssh never points at a missing socket (which would break sandboxed git authentication and GUI
   clients).
3. `launchctl bootout gui/$(id -u)/be.netronix.ssh-agent`: the script removes the socket, so new
   shells fall back to the 1Password socket at once.
4. Revert the PR, `chezmoi apply`, and `rm ~/Library/LaunchAgents/be.netronix.ssh-agent.plist`
   (chezmoi never deletes a file that left the source).
5. Restart shells and Claude Code sessions: one started before step 4 still exports the native
   socket path.

## Tests

- `tests/ssh-agent-run.test.sh` (new): stub `ssh-agent` and `ssh-add` on `PINNED_PATH`, since the
  sandbox forbids `bind()`. Pins: the directory is created mode 700; a stale socket is removed and
  a regular file at the path is refused; `SIGTERM` stops the agent and removes the socket;
  `ssh-add` is called for exactly the listed keys that exist, never `michael_rsa`, a borg key or
  `huginn`, with the fixed socket; a failed add is logged without its input; the script exits with
  the agent's status.
- `tests/claude-settings.test.sh`: the socket pins move to the native path, `allowUnixSockets` is
  exactly `[native, 1Password]`, and the new `denyWrite` and `Edit` denies are present.
- `tests/zshenv.test.sh`: the native socket wins over a herdr socket, over the 1Password socket and
  in an SSH login; without it, today's behaviour holds.
- `plutil -lint` on the rendered plist, wherever the existing plists are checked, or in the new suite.
- `.scripts/test-audit/subjects.tsv`: rows for the plist and the script.
- `tests/live-credential-boundary.test.sh`: a probe that the native agent holds only the listed keys
  (`michael`, `viumore_rsa`; `AGENT_FOREIGN_KEYS`), and that its socket exists
  (`AGENT_NATIVE`).
- Acceptance after apply: Michael's steps 5 and 6.

## Left to the builder

Log line format, the wait loop's granularity, and where in the README the steps go.
