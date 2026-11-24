# Complete provisioning: a reinstalled Mac ends up as it is today

**Status:** Implemented (branch `feat/complete-provisioning`, its PR against `main`)
**Date:** 2026-11-22
**Branch:** `feat/complete-provisioning`, in the `wt` checkout
`~/.local/share/chezmoi-feat-complete-provisioning`
**Sign-off:** Michael, 2026-11-22, in the line's own pane: "signed off, D1 yes, D2 both. I follow
your recommendations". Codex approved the spec in round 3 (xr-1795308251-d19b9da8). D3 follows the
recommendation's fallback until Michael names the 1Password items (see D3). The retry rule in §3
("Found by the first VM run"): Michael, 2026-11-24, "yes, go ahead with your recommendation", then
"I follow your recommendations" for the night; the move-aside form is the line's ruling (see §3).
**Source:** Michael, 2026-11-22: "I want you to make sure when I do a complete reinstall, everything
gets installed and configured properly again." Relayed in the driver's brief (chezmoi-08) of the
same day.
**Size:** about 470 lines of non-test code: `.scripts/machine-check.sh` about 110, the checklist
`.scripts/machine-checklist.tsv` about 60, `.scripts/provision.sh` about 90 changed,
`.scripts/configure.sh` about 60 changed, `reconcile-agents.sh --check` about 25, the LaunchAgent
loader and its `run_onchange_` trigger about 65 (decision D1), the Brewfile and SSH key templates
about 10 (D2, D3). About 500 lines of test code: a new `tests/machine-check.test.sh` and
`tests/provisioning.test.sh`, and `tests/provision.test.sh` and `tests/reconcile-agents.test.sh`
extended. Comparable: the provisioning preflight (`provision.sh` and its suite). One increment
(without D1, about 405).
**Real size:** 579 lines of non-test code (+495 −84), 1.23 times the estimate; 1,441 lines of test
code. The review rounds added `reconcile-agents.sh`'s `--check` reporting, the loader's poll, retry
and source check, and the checklist lint's wider rules; the first VM run added the three
`provision.sh` fixes in §3 (44 lines). One increment.
**Provisioning:** `launchagents`, `codex-daemon-pin`, `netbird-service`, `herdr-plugins`,
`hercules-power`

## Why

`provision.sh` installs and configures most of a machine, and `configure.sh` (its last step) loads
every `be.netronix.*` LaunchAgent. But setup has grown since, mostly through specs whose "Michael's
steps" were written for machines that already existed. An inventory of every spec's after-merge,
rollout and manual sections (73 steps) against `provision.sh`, `configure.sh`, the `run_` scripts
(none), the externals and the LaunchAgents found three kinds of gap:

**Scriptable, but no script does it.**
- The Codex daemon pin, `codex app-server daemon update --from-cli` (security-locks-2 §4). Until it
  runs, a fresh machine's daemon updates itself hourly outside Homebrew. AGENTS.md says to re-run it
  after every `brew upgrade codex`; on fenrir today the CLI is 0.170.0 and the daemon 0.169.0, so the
  last re-pin was forgotten.
- NetBird's root daemon, `sudo netbird service install && sudo netbird service start`
  (hercules-agent-machine §8 B2). The Brewfile installs the binary only.
- Herdr's three TUI plugins: `dev.phase`, `dev.agent-rows` and smart-splits.nvim's bundled plugin.
  They are registered in the unmanaged `~/.config/herdr/plugins.json` by hand-run
  `herdr plugin link`; no file in the repository does it. smart-splits' plugin lives in lazy.nvim's
  plugin folder, which exists only after Neovim has installed its plugins.
- hercules' power settings: §8 F asks for "prevent sleep with the display off" and "wake for network
  access"; `configure.sh` sets only `autorestart`.

**Manual, and printed nowhere.** The weekly-research first run under launchd and its
`vault inbox: writable` check; `netbird up`; Syncthing's pairing and three folders; the Claude Code,
Codex, `gh`, `glab` and `az` logins (the phase badges need `gh` and `glab` in the keychain); Little
Snitch's extension and rules; hercules' Remote Login, key-only sshd (security-locks-2 §7, which
rejected scripting it) and automatic login; the Herdr machine entry on fenrir.

**Printed, never checked.** `provision.sh` ends with prose for Borg, Alfred and Herdr, and
`configure.sh` with four generic reminders. Nothing tells Michael which of them are already done.

Two more findings from fenrir's live state, read-only:
- fenrir's Borg keys (`~/.ssh/borg-fenrir`, `~/.ssh/borg-append-only-fenrir`) and the `huginn` key
  are not chezmoi-managed; hercules' Borg key is (`private_dot_ssh/private_borg-hercules.tmpl`,
  rendered on every machine like the other Borg keys). A reinstalled fenrir has no key for its own
  Borg repository (decision D3).
- fenrir's sshd: `launchctl print-disabled system` shows `com.openssh.sshd => enabled` and
  `/etc/ssh/sshd_config.d/` holds no hardening drop-in, so security-locks-2 §7's step ("Remote Login
  off, or key-only", on both Macs) looks undone there.
- `configure.sh` boots out and re-bootstraps every LaunchAgent on each run. For
  `be.netronix.codex-app-server` that disconnects every Codex TUI (xreview-reliable-codex-pane §4,
  "Michael decides when"), so re-running `configure.sh` on a working machine is not safe today.

And the brief's three suspicions, checked:
- (a) weekly-research's first run and status: confirmed missing (above). Whether a launchd job may
  write the vault inbox is a macOS permission no script grants; `weekly-research --status` reports it.
- (b) The Codex pin: confirmed needed on a fresh install (above), and scriptable non-interactively:
  `update --from-cli --yes`.
- (c) 1Password's SSH agent is off until turned on in its settings, so on a fresh install the step is
  "leave it off", checked by its socket refusing a connection.

## Goals

1. A wiped fenrir or hercules that runs `provision.sh` ends with everything a script can do done,
   and one ordered list of what is left, each item with the command that verifies it where one
   exists.
2. The same list checks an existing machine at any time: `.scripts/machine-check.sh` says, per item,
   done, not done, or no check. That makes drift visible (the forgotten Codex re-pin above) and
   proves the list against the machines as they are today.
3. It stays true: a later change that adds lasting machine setup must also reach provisioning,
   enforced by an AGENTS.md rule and a suite, not by memory.
4. Re-running `provision.sh` or `configure.sh` on a set-up machine is safe: it never disconnects a
   Codex session, reloads a LaunchAgent only when its plist changed, renames nothing (provision
   passes `--hostname`), and each step this spec adds skips when its work is done. What re-runs keep
   doing on purpose stays: `brew bundle install` upgrades outdated packages (the README's update
   path), Oh My Zsh pulls, and Dock, Finder and Alfred restart to apply their settings.

**Non-goals.** One-time checks and migrations from earlier specs (removing old files, unloading old
agents, canaries after a change) are not provisioning and do not become steps. Account-level work
done once, not per machine (the NetBird account, forge rulesets, 1Password items) stays out. App
data (vault contents, project checkouts, databases) is restored by its own tools, not provisioning.

**Anti-goals.** A checklist that drifts back into prose nobody checks. Automation that changes a
security boundary without the checks its spec asked for (hercules' sshd stays a guided manual step).
Anything that adds a question after the preflight: the run stays "every question up front, then
unattended".

## Approaches

- **A. A checklist file with a checker (chosen).** One tracked list of what a finished machine has,
  scripted and manual items alike, each with a read-only verify command. `machine-check.sh` runs the
  checks; `provision.sh` ends by printing the items still open. The scriptable gaps are closed in
  `provision.sh` and `configure.sh`. A suite holds the list well-formed and makes new specs and new
  setup scripts declare their provisioning.
- **B. Extend the printed "Next steps" and add the missing commands.** Least code, but nothing
  verifies the list, so it rots the way the current one did, and nothing can test that a new
  setup step reached it.
- **C. Make `chezmoi apply` converge the machine (`run_onchange_` scripts for every step).** Strong
  at staying true, but it puts sudo and system changes inside every apply, against AGENTS.md's
  deliberate rule that system-changing helpers are not `run_` scripts, and an apply could restart
  the Codex daemon mid-review. Used only for the narrow LaunchAgent case, if Michael chooses D1.

## Design

### 1. The checklist: `.scripts/machine-checklist.tsv`

Tab-separated, `#` comments and blank lines skipped, five columns:

| Column | Meaning |
|---|---|
| `id` | unique, `[a-z0-9-]+`; specs and code refer to items by it |
| `machines` | `all`, a name from `known_hostnames`, or `research_host` (resolved from `.chezmoidata/machines.toml`) |
| `by` | `script` (provisioning does it; the check confirms) or `you` (Michael does it) |
| `step` | what it is, and for `you` items what to do, in one line, citing a spec section for long procedures |
| `verify` | a read-only command, run with `zsh -f`, exiting 0 when the item is done; `-` when there is none (only for `you` items) |

Row order is the order to do things in; `script` rows come first. A row's check covers every
action its step names; an action that has no check gets a row of its own with `-`, so a passing
check never hides unfinished work. The rows at merge (verify commands abbreviated here; the file
holds them in full):

| id | machines | by | step | verify, in short |
|---|---|---|---|---|
| `identity` | all | script | ComputerName and HostName are the machine's name (preflight) | `scutil --get HostName` equals the name |
| `brewfile` | all | script | everything in the Brewfile is installed | `brew bundle check --no-upgrade` |
| `login-shell` | all | script | Homebrew zsh is the login shell | `dscl . -read /Users/$USER UserShell` |
| `oh-my-zsh` | all | script | Oh My Zsh in the XDG data folder | the folder exists |
| `mise-tools` | all | script | every mise tool installed | `mise ls --missing` prints nothing |
| `firewall` | all | script | the application firewall is on | `socketfilterfw --getglobalstate` |
| `claude-managed-policy` | all | script | the Claude Code managed policy is the repo's | `cmp` with `.scripts/claude-managed-settings.json` |
| `launchagents` | all | script | every `be.netronix.*` LaunchAgent in `~/Library/LaunchAgents` is loaded | `launchctl print gui/$UID/<label>` for each |
| `native-ssh-agent` | all | script | the native agent holds its two keys | `ssh-add -l` on its socket lists two |
| `github-ssh` | all | script | ssh to GitHub authenticates | `ssh -T git@github.com` |
| `netbird-service` | all | script | NetBird's root daemon is installed | `launchctl print system/netbird` |
| `herdr-plugins` | all | script | `dev.phase`, `dev.agent-rows`, `smart-splits.nvim` are linked | `herdr plugin list` |
| `codex-daemon-pin` | all | script | the Codex daemon runs a pinned copy of the CLI's package. Provisioning pins a fresh machine only; otherwise, when no review is active: `codex app-server daemon update --from-cli`, then the canary (AGENTS.md) | `current` links to `releases/local-*`, and when the daemon runs, `daemon version` has equal `cliVersion` and `appServerVersion` |
| `hercules-power` | hercules | script | no system sleep, wake for network access, restart after power loss | `pmset -g`: `sleep 0`, `womp 1`, `autorestart 1` |
| `borg-key-hercules` | hercules | script | chezmoi renders hercules' Borg key, `~/.ssh/borg-hercules` | the file exists |
| `op-ssh-agent-off` | all | you | leave 1Password → Settings → Developer → "Use the SSH agent" off; the native agent serves ssh | `ssh-add -l` on 1Password's socket cannot connect |
| `claude-login` | all | you | start `claude` once and sign in | `claude auth status` |
| `agent-plugins` | all | you | then run `.scripts/reconcile-agents.sh` again (its run during provisioning fails until Claude Code has started once) | `reconcile-agents.sh --check` (new: queries, installs nothing) |
| `codex-login` | all | you | start `codex` once in a plain terminal (not a Herdr pane) and sign in | `codex login status` (real binary) |
| `forge-logins` | all | you | `gh auth login`, `glab auth login`, `az login` | `gh auth status`, `glab auth status`, `az account show` |
| `orbstack` | all | you | open OrbStack once, so it installs its helper | its helper's LaunchDaemon exists |
| `alfred-powerpack` | all | you | open Alfred and enter the Powerpack licence | Alfred's `powerpack.*.dat` exists |
| `alfred-accessibility` | all | you | System Settings → Privacy & Security → Accessibility → add Alfred (without it the snippets expand nothing) | `-` |
| `alfred-snippets` | all | you | run `.scripts/configure.sh` from your terminal: it turns on snippet expansion and restarts Alfred to index the relay snippets (it may ask for Automation consent) | `autoExpandSnippets` is 1 under the machine's localhash, and Alfred's snippet index (`Databases/snippets.alfdb`) holds the `Relay` collection |
| `little-snitch-extension` | all | you | open Little Snitch and allow its network extension | `systemextensionsctl list` shows it `activated enabled` |
| `little-snitch-rules` | all | you | enter the licence and add the rules of hercules-agent-machine §8 G (netbird, Syncthing, hercules' sshd); neither has a check | `-` |
| `netbird-up` | all | you | `netbird up` and finish the SSO login | `netbird status` shows `Management: Connected` |
| `netbird-session-expiry` | hercules | you | NetBird dashboard → Peers → hercules → Session Expiration off (§8 B3) | `-` |
| `syncthing-settings` | all | you | Syncthing.app: a GUI user and password; Global Discovery, Relaying and NAT traversal off, Local Discovery on (§8 E1) | `config.xml` has a GUI user and those four options |
| `syncthing-old-device` | all | you | on a reinstalled machine, remove this machine's old device ID on the peer (it has a new one); no check sees the peer | `-` |
| `syncthing-folders` | all | you | pair with the peer again, add the three folders of §8 E3–E5; `claude-memory` Receive Only until Up to Date, then Send & Receive | the final state of §8 E3–E5 in `config.xml` (read with `xmllint --xpath`): `claude-memory` at `~/.claude/projects`, `sendreceive`, staggered versioning; this machine's `codex-memory-<name>` at the outbox, `sendonly`; the peer's at `inbox/<peer>`, `receiveonly`; each shared with a device besides this one. So the row stays open while `claude-memory` is still Receive Only |
| `herdr-app` | all | you | open the Herdr app, run `~/.config/herdr-app/bin/respaces` with its window open, pick the michael layout (cmd-shift-L) | the `michael-spaces` and `michael-menu` mods exist and the app's layout is `michael` |
| `vorta` | all | you | Vorta: this machine's own BorgBase repository (its existing one on a reinstall) and a schedule | Vorta's database has a profile with a repository and a schedule other than `off` |
| `borg-key-fenrir` | fenrir | you | restore `borg-fenrir`, `borg-append-only-fenrir` and `huginn` into `~/.ssh` from wherever they are kept (the repository does not render them; D3) | the three files exist |
| `login-items` | all | you | turn on Open at Login for Syncthing, Alfred, Vorta and the menu-bar apps | `-` |
| `privacy-and-sign-ins` | all | you | grant each app the permission it asks for at first launch, and sign in to the apps that need an account | `-` |
| `filevault-on` | fenrir | you | turn FileVault on (it travels) | `fdesetup status` |
| `filevault-off` | hercules | you | keep FileVault off (pre-boot has no network) | `fdesetup status` |
| `hercules-sharing` | hercules | you | turn on Remote Login and Screen Sharing (System Settings → General → Sharing) | `print-disabled system` shows sshd and screensharing enabled |
| `sshd-key-only` | all | you | Remote Login off, or on and key-only per security-locks-2 §7 (the key in `~/.ssh/authorized_keys`, a key login from the other Mac, then the `000-hardening.conf` drop-in) | sshd disabled, or the effective config (`sshd -G`) has `passwordauthentication no`, `kbdinteractiveauthentication no` and `permitrootlogin no` |
| `hercules-autologin` | hercules | you | automatic login, so the LaunchAgents run after a remote power-on | `autoLoginUser` is set |
| `hercules-host-key` | fenrir | you | `ssh hercules true` once, comparing the host key with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on hercules (§8 C); hercules must be reachable | `ssh` with `BatchMode`, `StrictHostKeyChecking=yes` and no authentication method reaches hercules' auth step, so a changed host key reads ✗ and nothing prompts |
| `herdr-machine` | fenrir | you | `hc machine add hercules` (§8 D) | `hc machine ls --json` lists hercules |
| `weekly-research` | research_host | you | first run under launchd: `launchctl kickstart gui/$(id -u)/be.netronix.weekly-research`, then read the note | `weekly-research --status` says `vault inbox: writable` |
| `acceptance` | all | you | in a fresh Claude Code session `./tests/run.sh live-agent-signing live-credential-boundary live-agent-auth`; start `codex` once in a Herdr pane and clear its first-run screens, then, unsandboxed, `./tests/run.sh live-codex-daemon`; with Remote Login on, `ssh -o PubkeyAuthentication=no <this Mac>` from the other Mac is refused | `-` |

### 2. `.scripts/machine-check.sh`

- `machine-check.sh [--machine <name>] [--todo]`. The machine defaults to `scutil --get ComputerName`
  and must be in `known_hostnames` (exit 2 otherwise).
- For each row that applies to the machine it runs the verify command as
  `/usr/bin/timeout 30 /bin/zsh -f -c "<verify>"`, stdin from `/dev/null`, with `PATH` set to
  `~/.local/bin`, Homebrew and the system directories, and `MACHINE` and `DOTFILES` (the source
  checkout the script lives in) exported. It prints one line per row: `✓`, `✗` (with the step), or
  `·` for a row with no check (with the step).
- `--todo` prints only the `✗` and `·` rows, numbered, in file order: the end-of-run checklist. Each
  `✗` row is followed by an indented line `check: <verify>`, so the list names the command that
  verifies it; a `·` row ends `(no check)` and has none.
- Exit 0 when every check passes, 1 when one fails, 2 on a usage or checklist error.
- It is read-only by construction (the suite lints the verify column, §5). It runs outside the
  sandbox: sandboxed, `launchctl`, `herdr`, the firewall and the extension list misreport (measured
  2026-11-22: the firewall read "disabled" sandboxed and "enabled" outside). An agent's sandboxed
  run is never evidence about a machine.

### 3. `provision.sh`

New steps, each skipped when already done, none asking anything:

- **After the Brewfile (step 8):** NetBird's daemon, `sudo netbird service install` and
  `sudo netbird service start`, when `launchctl print system/netbird` fails. The sudo credential is
  the one cached at step 0.
- **After mise (step 12):** Neovim installs its plugins headless (`nvim --headless "+Lazy! install" +qa`),
  then `herdr plugin link` runs for each `~/.config/herdr/plugin-*` folder holding a
  `herdr-plugin.toml`, and for lazy.nvim's `smart-splits.nvim`, unless `herdr plugin list` already
  names it. Failures are warnings; the `herdr-plugins` row shows them.
- **After `configure.sh` (step 16):** the Codex pin, `"$(codex-daemon real-bin)" app-server daemon
  update --from-cli --yes`, only on a fresh machine: when `~/.codex/packages/app-server-daemon/current`
  did not exist when the run started (read before step 1, so no earlier step can hide it). It runs with
  a clean environment like the LaunchAgent's (`HOME`, its `PATH` and the XDG variables, no
  `HERDR_*`), because the pin restarts the daemon and a daemon that inherits a Herdr pane's variables
  fails `codex-daemon check` (security-locks-2 §4). Any machine that already had a daemon package,
  pinned or not, stale or not, is left alone, because a pin may interrupt a running review; the
  `codex-daemon-pin` row reports it with the command.
- **`reconcile-agents.sh --check`:** a mode that runs the same queries and reports what is missing or
  differs, installing and removing nothing (exit 1 when something is missing), so `agent-plugins`
  has a read-only check.
- **The end of the run** prints `machine-check.sh --todo --machine <name>` instead of the
  hard-coded "Next steps" (their Borg, Alfred and Herdr items are rows now), plus the existing
  "restart your terminal" line. `configure.sh`'s "Manual tasks still required" list goes the same
  way: it points at `machine-check.sh`.
- **`PROVISION_REF`** (only with D2's VM run), a test knob defaulting to `main`, makes the clone
  check out another branch, so a VM can provision from a branch before it merges. A ref other than
  `main` is refused unless `sysctl -n kern.hv_vmm_present` prints 1: on a real Mac provisioning
  deploys only reviewed `main`, as today. The summary before "Proceed?" shows the ref when it is not
  `main`.

**Found by the first VM run (2026-11-24), fixed here.** Three faults in steps older than this
change kept a fresh machine from being provisioned at all:

- **1Password.** The preflight polled `op whoami` for 15 minutes. 1Password authorizes each
  terminal session, and `op whoami` only reports that, so a fresh terminal never passed (measured in
  the VM: "account is not signed in" before `op signin` in the same session, signed in after). The
  run now waits until `op account list` shows an account, then runs `op signin` itself, evaluating
  what it prints (nothing with the app integration; the session variable for an account added with
  `op account add`), and checks `op whoami`. A failed sign-in ends the run before anything changes.
  The wait prints a line each minute.
- **A checkout an earlier run left.** Any existing checkout counted as "already provisioned", so a
  run that stopped after its clone (at the 1Password wait, say) skipped `chezmoi init` and `apply`
  on every retry, and nothing was deployed. Now step 4 moves a checkout that chezmoi never ran
  from (no `~/.config/chezmoi/chezmoi.toml`) aside, to `<source>.earlier-<time>`, and clones
  afresh, so step 6 applies only the run's own clone; the closing list names the old checkout for
  Michael to delete. A machine with a chezmoi config keeps today's skip and its pointer to the
  wrapper. Michael approved a gate instead (apply the left checkout when it is clean and at
  origin's commit, the wrapper's checks); the cold review showed git's view is not what chezmoi
  reads (ignored files such as `*.log`, skip-worktree flags, replace refs, `core.worktree`), which
  is why the wrapper itself applies a fresh clone. Moving aside keeps the rule he approved (only
  origin's reviewed commit is applied), deletes nothing, and a retry also works after origin moved.
- **The login shell.** Step 10 pointed the login shell at Homebrew's zsh even when no Brewfile had
  installed it, so no new terminal could start. It now changes the shell only when that zsh is
  executable, and otherwise warns to run `provision.sh` again once the Brewfile is installed; the
  closing "exec" hint appears only when that zsh exists. A missing Brewfile is a warning in the
  closing list, not only an error line.

### 4. `configure.sh`

- **LaunchAgents, safe to re-run.** A job is bootstrapped when it is not loaded. A loaded job is
  reloaded (bootout, bootstrap) only when its plist differs from the copy recorded at its last load
  under `~/.local/state/launchagents/`. `be.netronix.codex-app-server` is bootstrapped when absent
  and never reloaded, because a reload disconnects every Codex TUI; a change to its plist keeps
  shipping with its own after-merge step, as today. On the first run after this change no copies
  exist, so the other jobs reload once. A deployed plist whose `<label>.plist[.tmpl]` is gone from
  the loader's own source tree is skipped and reported (`not in the source`), never loaded, so a
  retired LaunchAgent left behind by chezmoi is not started again at the next apply.
- **No Apple Events in the unattended run.** The wallpaper (`osascript` to System Events) and
  Alfred's quit and relaunch send Apple Events, which on a fresh machine open an Automation consent
  dialog: that is a question after the preflight, and, unanswered or refused, the `osascript` fails
  and under `set -e` ends `configure.sh` before the LaunchAgents load. With `--hostname` (provision's
  call) `configure.sh` skips the wallpaper, and skips the Alfred toggle while Alfred is running
  (writing it needs Alfred quit, by an Apple Event), and says so for each; on a fresh machine Alfred
  has never run, so its block is skipped already. Michael's own run, which the `alfred-snippets` row
  asks for, does them attended, with `|| log_warn` on the wallpaper. The LaunchAgents also move
  before both steps. The wallpaper is a default, not tracked setup (fenrir's differs today), so it
  has no row.
- **hercules' power:** `sudo pmset -a sleep 0 womp 1` beside the existing `autorestart 1`.

### 5. Keeping it true

**The rule (AGENTS.md, Rules):** a change that adds lasting setup to a machine (a package, a
LaunchAgent, a daemon, a login, a permission, a system setting) reaches provisioning in the same
change: a step in `provision.sh` or `configure.sh` when a script can do it, and in every case a row
in `.scripts/machine-checklist.tsv`, with a verify command where one exists. A spec whose after-merge
section has steps carries a `**Provisioning:**` header line naming its rows, or `none — <reason>`.
Commands handed to Michael after a merge are for machines already set up; they never stand in for
provisioning. AGENTS.md is at 238 of its 240-line cap (`tests/agent-instructions.test.sh`), so the
rule replaces wording in the `.scripts/` bullet it extends rather than adding lines past the cap.

**The suite, `tests/provisioning.test.sh`:**
1. **The checklist is well-formed:** five columns, unique ids, valid `machines` and `by`, `-` only on
   `you` rows, each verify command parses (`zsh -n`), and none contains `sudo`, `op read`,
   `op inject`, `op run`, `rm `, `kickstart`, `bootstrap` or `bootout` (it must stay read-only).
2. **New specs declare their provisioning:** every spec dated 2026-11-22 or later with a heading
   matching Michael's steps, after the merge, after Michael's apply, post-merge, rollout, migration,
   activation or acceptance carries a `**Provisioning:**` line (which ends at the next blank line or
   `**Header:**` line), either `none — <reason>` or ids that exist in the checklist. Older specs
   are exempt (this spec's inventory covered them).
3. **Every setup script is reachable:** each executable directly in `.scripts/` (not its
   subfolders) other than the entry point `provision.sh` is called by name (the whole file name, not a part of a
   longer one) in `provision.sh` or `configure.sh`, or appears in the suite's ad-hoc table with its reason (`forge-protection.sh`,
   `skill-updates.sh`, `measure-interventions.py`, `preflight-ssh-agent.sh`).
4. **Every LaunchAgent is loaded by provisioning:** each plist under `Library/LaunchAgents/` in the
   source has a `be.netronix.` label, the prefix `configure.sh` and the `launchagents` row load.
5. **Every Herdr plugin is linked by provisioning:** each `dot_config/herdr/plugin-*/herdr-plugin.toml`
   is under the folder glob `provision.sh` links.

What this does not catch, said plainly: a small change with no spec that adds a manual step and no
row. The rule covers it, and checks 3 to 5 catch the common shapes (a new script, LaunchAgent or
plugin).

### 6. Testing

- `tests/machine-check.test.sh` (new): a fixture checklist and a temporary `HOME`; pass, fail and
  no-check rows; machine scoping (`all`, a name, `research_host`); `--todo`; an unknown machine and
  a malformed list exit 2; a verify that hangs is cut at the timeout.
- `tests/provision.test.sh` (extended, its existing stubs): NetBird installed only when absent; the
  plugin links only for unlisted plugins; the Codex pin only when no daemon package existed before
  `configure.sh`, never on a machine with one (pinned or not); the end of the run calls
  `machine-check.sh --todo`; `PROVISION_REF` reaches the clone and is refused outside a VM;
  `configure.sh` loads absent jobs, reloads only changed ones, never reloads codex-app-server, sends
  no Apple Event with `--hostname`, survives a failing wallpaper `osascript` without it, and sets
  hercules' `pmset` keys.
- `tests/reconcile-agents.test.sh` (extended; unsandboxed, as today): `--check` reports a missing
  marketplace, plugin and MCP server, exits 1, and calls no `add`, `install` or `remove`.
- `tests/provisioning.test.sh` (new): §5's five checks against the real repository, each with a
  negative fixture showing it can fail.
- Each new suite gets its `tests/subjects/<suite>.tsv`.

## Decisions for Michael

**D1. Should `chezmoi apply` load a changed LaunchAgent?** Recommended: **yes, narrowly.** A
`run_onchange_after_` script embeds the hash of each rendered `be.netronix.*` plist; when one
changes, apply runs §4's loader (moved into `.scripts/load-launchagents.sh`, which `configure.sh`
then calls too). It touches only the user's launchd domain, needs no sudo and asks nothing; it never
reloads codex-app-server; and it does nothing during provisioning's first apply, which runs before
the Brewfile (`provision.sh` sets `DOTFILES_PROVISIONING=1` for that apply), so `configure.sh` keeps
that load. For: the launchctl lines disappear from after-merge
steps (four plist changes in the last ten days each needed them), and a plist change can no longer
be forgotten on one machine. Against: an apply gets a side effect beyond files (a changed
`ssh-agent` plist restarts the agent, about a second without keys); AGENTS.md's "not `run_` scripts"
rule gains one stated exception. **No** keeps today's flow with §4's safe re-run: after a merge that
changes a plist, Michael runs `configure.sh` or the printed launchctl lines.

**D2. How a reinstall gets verified.** No unit test proves one. Recommended: **both of these, before
merge**, so a wrong row is fixed in this PR, not a follow-up.
- **On the real machines:** the branch's `machine-check.sh` on fenrir, run by the line outside the
  sandbox (every verify command is read-only), and on hercules by Michael, from a copy of the
  branch's `.scripts` and `.chezmoidata` (`git archive origin/feat/complete-provisioning .scripts
  .chezmoidata | tar -x -C <tmp>`, then `<tmp>/.scripts/machine-check.sh`; about two minutes). Each
  `✗` is either drift to fix on that machine after merge or a wrong row the line fixes now. Cheap,
  and it proves the list against "as it is today", hercules-only rows included.
- **One full run in a throwaway macOS VM on fenrir**, with Tart (`openai/tools/tart`, the project's
  documented tap since it moved to OpenAI; FSL-1.1 licence, free for personal use; added to fenrir's
  Brewfile with that tap trusted, inside the fenrir-only block, so it is there for the next big
  provisioning change). The image `ghcr.io/cirruslabs/macos-golden-gate-vanilla` is macOS 27.2 like
  the host (about 33 GB download, 80 GB disk; fenrir has 381 GB free). Michael runs the branch's
  `provision.sh` inside the VM with `PROVISION_REF=feat/complete-provisioning` as `hercules`, signs
  in to 1Password there, and afterwards deletes the VM and removes its 1Password device; the
  rendered keys go with the VM. Pass: every `script` row `✓` after one run; a second run prints the
  same `machine-check` result, reloads no LaunchAgent and adds no warning; the `you` rows print in
  order. Not testable in a VM: Touch ID, the App Store, likely Little Snitch's extension; never
  `netbird up`, Syncthing pairing or Borg inside it. About three hours, mostly unattended; about 20
  minutes of Michael's time. The PR opens ready for review with its merge state on hold until
  Michael reports the VM run; a failure is fixed on the branch first.
- Rejected as the default: wiping hercules for real. Most faithful, but destructive and hours of his
  time; worth it only when he plans a reinstall anyway, and then `machine-check.sh` is the gate.
- Without the VM run, `PROVISION_REF` and Tart are dropped and the PR has no hold.

**D3. fenrir's Borg keys and the `huginn` key.** `~/.ssh/borg-fenrir`, `borg-append-only-fenrir`
and `huginn` exist on fenrir but no template renders them, so a reinstall loses them. Recommended:
if they are in 1Password, template them like the other Borg keys (`private_borg-hercules.tmpl`,
rendered on every machine; scoping keys per machine is a separate change), so the `borg` row can
check the key. A wrong `op://` path fails every `chezmoi apply`, so the item and field names must
come from Michael. If they are not in 1Password, the `borg` row says where they come from instead.
Which is it, and what are the item names? And which host uses `huginn`?

**Decided at sign-off:** D1 yes, D2 both. D3: the item names were not given, so `borg-key-fenrir`
is a `you` row (restore this machine's Borg keys into `~/.ssh`, checked by the files existing) unless
Michael names the items before that task runs; then the keys are templated and the row becomes
`script`, as `borg-key-hercules` already is.

## Michael's steps after merge

1. `chezmoi apply` (D1: its first run loads the LaunchAgent loader, which reloads every loaded
   job except codex-app-server once, because no records exist yet; the ssh-agent is without keys
   for about a second), then `brew bundle install --file ~/.config/homebrew/Brewfile` (fenrir:
   Tart).
2. On fenrir and on hercules, from his own terminal: `~/.local/share/chezmoi/.scripts/machine-check.sh`,
   and work down its `✗` lines. On fenrir that includes the Codex re-pin (`codex-daemon-pin`).

## Left to the builder

- The exact verify commands, within §1's intent, measured on fenrir outside the sandbox and on
  hercules by D2's run.
- How the AGENTS.md rule fits the 240-line cap (§5): which `.scripts/` and LaunchAgent wording it
  replaces.
- Whether `herdr plugin link` needs a running Herdr server (if it does, the step starts none and
  warns; the row shows it) and whether the Codex pin needs a running daemon (it runs after
  `configure.sh` loaded the agent either way). The VM run settles both.
- The suite layout, within §6.
