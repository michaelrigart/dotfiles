<div align="center">

# 🏠 Dotfiles

### Michaël Rigart's macOS Development Environment

*Managed with [chezmoi](https://www.chezmoi.io/) • Secured with [1Password](https://1password.com/)*

[![chezmoi](https://img.shields.io/badge/managed%20with-chezmoi-blue?style=flat-square)](https://www.chezmoi.io/)
[![macOS](https://img.shields.io/badge/platform-macOS-lightgrey?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![XDG](https://img.shields.io/badge/XDG-compliant-green?style=flat-square)](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)

</div>

---

## ✨ Highlights

A modern, security-focused macOS development environment featuring:

- 🔧 **XDG Base Directory** compliant configuration
- 🛡️ **1Password integration** for secrets and SSH keys, served to git by a native SSH agent
- ⚡ **Modern CLI tools** replacing traditional Unix utilities
- 🎨 **Customized terminal** with Ghostty, Starship, and Zsh
- 📦 **Automated setup** with a single command
- 🔐 **Security hardened** macOS configuration

---

## 🚀 Quick Start

### Prerequisites

- macOS (Apple Silicon)
- Internet connection
- 1Password account with CLI access

### One-Line Install

```bash
/bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/michaelrigart/dotfiles/refs/heads/main/.scripts/provision.sh)"
```

This will:
1. Install Xcode Command Line Tools and Homebrew
2. Install the bootstrap tools (chezmoi, the 1Password CLI and app, git)
3. Clone the dotfiles source
4. Authenticate with 1Password, ask for the machine name (it must be listed in [machines.toml](.chezmoidata/machines.toml)), then read the secrets of the steps not yet done (the `NetBird setup key`, `Syncthing GUI` and `BorgBase <machine>` items) before the one confirmation that sets the macOS ComputerName, HostName and LocalHostName to it
5. Generate the chezmoi config and apply the dotfiles
6. Switch the chezmoi remote to SSH
7. Install all packages from [Brewfile](dot_config/homebrew/Brewfile.tmpl)
8. Install the NetBird daemon, join it with the setup key, then generate Syncthing's config with its GUI login, both only when not yet set up
9. Reconcile the AI agent plugins, then set Homebrew zsh as the default shell
10. Install Oh My Zsh
11. Install development tools via mise
12. Install the Neovim plugins and link the Herdr plugins
13. Start Vorta once so it imports its own export, which holds the backup profile, only when not yet set up
14. Apply macOS system settings, which loads the LaunchAgents, among them the one that opens the login apps
15. Only if no Codex daemon package existed when the run started, pin the Codex daemon to the CLI's package
16. Print what is left to do, from [machine-check.sh](.scripts/machine-check.sh)

No secret reaches a command's arguments or environment: each is piped to its one command (`netbird up`, `syncthing generate`), or written once to `~/.vorta-init.json`, which Vorta deletes after a successful import (the run warns when it stays); `jq` checks the Vorta export on stdin too. A step already done reads no item, so a second run changes nothing.

---

## 📂 What's Included

### Core Configuration

- **Shell:** Zsh with Oh My Zsh framework
- **Prompt:** Starship for a fast, informative prompt
- **Terminal:** Ghostty GPU-accelerated terminal
- **Editor:** Neovim with custom configuration
- **Version Manager:** mise for development tools

### Key Features

- **[Brewfile](dot_config/homebrew/Brewfile.tmpl)** - Declarative package management
- **[Zsh config](dot_config/zsh/)** - Custom aliases, functions, and settings
- **[Git config](dot_config/git/)** - Git aliases, templates, and commit signing
- **[SSH templates](private_dot_ssh/)** - Automated SSH key deployment via 1Password
- **[macOS settings](.scripts/configure.sh)** - Security and UX improvements

---

## 🔧 Daily Usage

```bash
# From ~/.local/share/chezmoi: get a checkout of the source and edit the dotfile there.
# <checkout> is ~/.local/share/chezmoi-<branch>, with each "/" in the branch name as "-".
wt <branch>

# Preview changes
command chezmoi --source <checkout> diff

# After the branch is merged, apply it
chezmoi apply

# Update from repository
chezmoi update

# Preview or apply a deliberate local change (uncommitted, off main, or offline)
chezmoi diff --dirty-ok
chezmoi apply --dirty-ok
```

In the shell, `apply` and `update` deploy origin's `main` from a fresh clone, and only from a
clean `main` equal to it; otherwise they refuse and say why. The previews (`diff`, `status`,
`cat`, `verify`, `dump`, `archive`, `execute-template`) are gated the same way. `--dirty-ok`
applies or previews the working tree instead, and offline you need it, because origin cannot
be read. `merge` and `merge-all` need it too. `chezmoi init` is refused in the shell: use
`chezmoi apply --init` to render the chezmoi config again.

### Managing Dotfiles

```bash
# Add a new file to dotfiles, into the wt checkout
command chezmoi --source <checkout> add ~/.config/newapp/config.toml

# Commit and push the branch
git -C <checkout> add .
git -C <checkout> commit -m "Update configuration"
git -C <checkout> push origin <branch>

# After the merge, deploy it
chezmoi apply
```

### Re-running Scripts

```bash
# These run from a fresh clone of origin's main, never from the checkout an agent can write
# Re-apply macOS system settings
dotfiles-run configure

# Update all Homebrew packages
brew bundle install --file ~/.config/homebrew/Brewfile

# Update development tools
mise install

# Print what is still to do on this machine
dotfiles-run machine-check --todo
```

---

## 🆕 Setting Up a New Machine

### Automated (Recommended)

Use the one-line installer above.

### Manual

```bash
# 1. Install Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Install essentials
brew install chezmoi 1password-cli

# 3. Sign in to 1Password
eval $(op signin)

# 4. Set the machine identity BEFORE chezmoi runs: the Brewfile render refuses a machine
#    whose live ComputerName is not listed in .chezmoidata/machines.toml.
#    <name> is one of those listed names (fenrir, hercules).
sudo scutil --set ComputerName  <name>
sudo scutil --set HostName      <name>
sudo scutil --set LocalHostName <name>

# 5. Initialize and apply dotfiles
#    DOTFILES_PROVISIONING=1 keeps the apply from loading LaunchAgents; step 9's configure.sh does.
chezmoi init https://github.com/michaelrigart/dotfiles.git
DOTFILES_PROVISIONING=1 chezmoi apply --force

# 6. Switch to SSH
cd ~/.local/share/chezmoi
git remote set-url origin git@github.com:michaelrigart/dotfiles.git

# 7. Install packages. The Brewfile marks its taps `trusted: true`, so
#    `brew bundle install` trusts them itself.
export HOMEBREW_BUNDLE_FILE=~/.config/homebrew/Brewfile
brew bundle install --file "$HOMEBREW_BUNDLE_FILE"

# 8. Default shell, then Oh My Zsh (~/.zshrc sources it unconditionally).
#    KEEP_ZSHRC=yes stops the installer replacing the chezmoi-managed ~/.zshrc.
grep -qx "$(brew --prefix)/bin/zsh" /etc/shells || echo "$(brew --prefix)/bin/zsh" | sudo tee -a /etc/shells
chsh -s $(brew --prefix)/bin/zsh
export ZSH="$HOME/.local/share/oh-my-zsh"
KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended

# 9. Development tools, then macOS settings
mise install
~/.local/share/chezmoi/.scripts/configure.sh

# 10. Herdr app: open it once, run `~/.config/herdr-app/bin/respaces` with its window open
#     (it builds the michael-spaces and michael-menu mods from Herdr's), then pick the
#     michael layout (cmd-shift-L).

# 11. NetBird daemon, then Neovim's plugins installed and Herdr's linked, then the Codex pin
sudo netbird service install && sudo netbird service start
PATH=~/.local/share/mise/shims:$PATH nvim --headless "+Lazy! install" \
  "+luafile $HOME/.local/share/chezmoi/.scripts/nvim-finish-install.lua" "+cq 2"
for dir in ~/.config/herdr/plugin-*(N/) ~/.local/share/nvim/lazy/smart-splits.nvim; do
  herdr plugin link "$dir"
done
#     the pin only if ~/.codex/packages/app-server-daemon/current did not exist before step 9,
#     from a plain terminal, not a Herdr pane
"$(codex-daemon real-bin)" app-server daemon update --from-cli --yes

# 12. What is left to do
~/.local/share/chezmoi/.scripts/machine-check.sh --todo
```

---

## 🧪 Testing a reinstall

Run the whole provisioning in a throwaway macOS VM on fenrir with [Tart](https://tart.run)
(`openai/tools/tart`). After `chezmoi apply`, `brew bundle install --file ~/.config/homebrew/Brewfile`
installs it on fenrir.

The VM reads its three 1Password items from a vault of its own, never from Michael's. Make the
vault with the same item names as the real ones: `NetBird setup key` (an ephemeral key that
auto-assigns a group of its own), `Syncthing GUI` (a throwaway login) and `BorgBase hercules` (a
real Vorta export, edited: `repo.url` is `ssh://nobody@127.0.0.1:9/./repo` and `password` a throwaway
passphrase, with its schedule kept, since Vorta's GUI cannot add an unreachable repository and an
export with the schedule off makes the `vorta` row read ✗ in the VM).
The run names it with `PROVISION_OP_VAULT=<test vault>`, which, like `PROVISION_REF`, is refused
outside a VM.

```bash
# Pull the image (about 33 GB), clone it and give the clone room: the whole Brewfile fills 80 GB
tart clone ghcr.io/cirruslabs/macos-golden-gate-vanilla reinstall-test
tart set reinstall-test --disk-size 120
tart run reinstall-test

# In the VM (its window shares no clipboard, so type this): run the branch's script. It installs
# the 1Password app; when it asks, sign in there, turn on the CLI integration and approve the
# terminal's request. Answer `hercules` for the machine name: `fenrir` is taken on the network
# the VM shares with fenrir, and macOS renames the VM `fenrir (2)`.
# PROVISION_REF is honoured only inside a VM and picks the branch the clone checks out;
# PROVISION_OP_VAULT, also VM-only, names the test vault the three items are read from.
ref=<branch>
PROVISION_REF=$ref PROVISION_OP_VAULT=<test vault> /bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/michaelrigart/dotfiles/refs/heads/$ref/.scripts/provision.sh)"

# Afterwards, on fenrir
tart delete reinstall-test
```

It passes when every `script` row of the final check is ✓ except the rows a VM cannot satisfy
(`hercules-power` if `pmset` rejects a key); the `you` rows, Little Snitch's extension among them,
print ✗ until Michael does them after one run, a second run prints the same machine-check
result, reloads no LaunchAgent and adds no warning, and the `you` rows print in order. With the test
vault, `netbird-up`, `netbird-session-expiry`, `syncthing-settings`, `vorta` and `login-items` are
also ✓ with no prompt, `~/.vorta-init.json` is gone, and the second run reads no item, leaves
`config.xml` unchanged, keeps the same NetBird peer and IP and adds no Vorta profile. None of the
three throwaway values may appear in NetBird's logs and config (`/var/log/netbird`,
`/var/lib/netbird`), `~/Library/Logs`, Syncthing's folder (only a bcrypt hash) or Vorta's
`settings.db` and log. Last, before `tart delete`: turn off the image's automatic login (`sudo
sysadminctl -autologin off`), restart the VM from its Apple menu and leave it at the login screen.
Within a few minutes the VM's peer must show as connected on the dashboard's Peers page: hercules
has no automatic login, and after its FileVault unlock nobody is logged in, so NetBird connecting at
the login window is how an unlocked hercules is reached away from home.

Then remove the VM's device from 1Password. Run the VM only with that test vault, never with
Michael's own items, and still never pair Syncthing or start a backup there.

---

## 🔐 Security

### SSH Key Management

SSH keys are stored in 1Password and templated automatically:

```toml
# Example: private_dot_ssh/private_michael.tmpl
{{ onepasswordRead "op://Private/michael/private key?ssh-format=openssh" }}
```

### SSH Agent

Agents and shells sign and authenticate through a native `ssh-agent` on
`~/.local/state/ssh-agent/agent.sock`, run by the `be.netronix.ssh-agent` LaunchAgent, so the
1Password SSH agent and its prompts can be turned off. Reasons and design:
`docs/superpowers/specs/2026-11-21-native-ssh-agent-design.md`.

After merge, on each machine:

1. `chezmoi apply`, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/be.netronix.ssh-agent.plist`.
2. `SSH_AUTH_SOCK=~/.local/state/ssh-agent/agent.sock ssh-add -l` lists the two keys, `michael`
   and `viumore_rsa`, on each machine; a key that failed to load is named in
   `~/.local/state/ssh-agent/error.log`.
3. For each borg and huginn host, `ssh -G <host> | grep -i '^addkeystoagent'` must print
   `addkeystoagent false`; if not, set `AddKeysToAgent no` in the "SSH config" 1Password note, or a
   by-hand ssh or borg run would add a backup key to the agent every session can use.
4. Lock 1Password, so any request its agent still serves prompts and is noticed.
5. In your own terminal, check that `git@github.com`, `git@gitlab.com` and `git@ssh.dev.azure.com`
   authenticate with that `SSH_AUTH_SOCK` and no 1Password prompt (`ssh -T`), plus a `git ls-remote`
   against any other host. A host that prompts or fails is missing a key, or has an `IdentityAgent`
   line in the "SSH config" note that pins it to the 1Password socket: delete a per-host pin; if
   it is a catch-all (`Host *`), set its value to `~/.local/state/ssh-agent/agent.sock` instead, so
   processes that never source `zshenv` (GUI git clients, launchd jobs) still reach an agent. Keep
   the 1Password agent on until every host passes.
6. In a fresh Claude Code session, run `./tests/run.sh live-agent-signing live-credential-boundary
   live-agent-auth` (the boundary suite also checks that the agent holds only `michael` and
   `viumore_rsa`), then `./tests/live-agent-auth.test.sh <repo>` once for a
   repository on each other forge.
7. When no running shell or Claude Code session predates step 1 (open new tabs and panes, restart
   sessions), turn off 1Password → Settings → Developer → "Use the SSH agent".

An emptied or locked agent is fixed by `launchctl kickstart -k gui/$(id -u)/be.netronix.ssh-agent`;
run it also after a key in `~/.ssh` changes, since a rotated key stays loaded until the agent
restarts.

Rollback, on each machine: turn the 1Password SSH agent back on; if step 5 pointed a catch-all
`IdentityAgent` at the native socket, set it back to
`"~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"` (quoted for the space) in the
"SSH config" note and run
`chezmoi apply` (this renders `~/.ssh/config` again) before booting the job out, so ssh never
points at a missing socket; `launchctl bootout gui/$(id -u)/be.netronix.ssh-agent`; revert the PR,
`rm ~/Library/LaunchAgents/be.netronix.ssh-agent.plist`, then `chezmoi apply` (the plist goes
first, so the apply hook cannot load it again); restart shells and Claude Code sessions.

### Secrets in Config

Environment variables and API keys can be templated from 1Password:

```bash
export API_KEY='{{ (onepasswordItemFields "vault" "item").api_key.value }}'
```

### macOS Hardening

The [configure.sh](.scripts/configure.sh) script:
- Checks FileVault and warns when it is off, on every machine (it never changes it)
- Enables the system firewall
- Installs the Claude Code managed policy that limits mods to the organization's (`allowManagedModsOnly`) via [install-claude-managed-settings.sh](.scripts/install-claude-managed-settings.sh), refusing a different existing policy unless run with `--replace`; to uninstall: `sudo rm "/Library/Application Support/ClaudeCode/managed-settings.json"`
- Applies secure Finder and system defaults

### Little Snitch

Each machine's Little Snitch configuration is backed up in the 1Password Document `Little Snitch
backup <machine>` in the Private vault. Make the backup with Settings › Security › "Allow access
via Terminal" off. The backup is plain text, so outside 1Password it exists only in `/tmp`: for the
minutes a backup or restore takes, and for the length of a periodic review. No script touches
Little Snitch; this section is the whole procedure. Reasons and design:
`docs/superpowers/specs/2026-11-25-little-snitch-provisioning-design.md`.

Set `machine` to this machine's name as in `machines.toml`. Set `from` to the machine whose backup
you restore: this one, or the closest one for a machine without a backup of its own. Do not use
`scutil --get LocalHostName`: a machine set up before provisioning set it can have another name.

```bash
machine=<the machine name, as in machines.toml>
```

```bash
from=<the machine whose backup you restore: this one, or the closest>
```

1. **Restore, on a fresh install only.** Delete a leftover file, then fetch the backup.

   ```bash
   rm -f /tmp/little-snitch.lsbackup
   ```

   ```bash
   op document get "Little Snitch backup ${from:?}" --vault Private --out-file /tmp/little-snitch.lsbackup
   ```

   Run the check and read its result before you go on.

   ```bash
   jq -c '[.globalDefaults.allowCommandLineAccess // 0, [.users[].uid | select(. != 0)]]' /tmp/little-snitch.lsbackup
   ```

   Expect `[0,[<the output of id -u>]]`. Anything else, or no output, means do not restore it:
   delete the file with the `rm` command in step 2, *Check*, before you stop. A first value of `1`
   or `true` means the backup turns Terminal access on: neither restore it nor store it.

   If the user ID in the result is the output of `id -u`, restore with File › Restore from
   Backup… › Browse… (⇧⌘G `/tmp`), and skip the three commands below.

   If it differs, do not restore from the menu. Turn Terminal access on first, list the backup's
   users, set `backup_uid` to the one that belongs to you and restore with the users mapped.

   ```bash
   sudo "/Applications/Little Snitch.app/Contents/Components/littlesnitch" restore-model -l /tmp/little-snitch.lsbackup
   ```

   ```bash
   backup_uid=<the user ID that restore-model -l lists>
   ```

   ```bash
   sudo "/Applications/Little Snitch.app/Contents/Components/littlesnitch" restore-model --map-users "0 > 0, ${backup_uid:?} > $(id -u)" /tmp/little-snitch.lsbackup
   ```

   That restore turns Terminal access off again. If it fails or you abandon it, turn Terminal
   access off by hand. Never pass `--preserve-terminal-access`.

   Whichever way you restored, when it was from another machine's backup, delete that machine's
   own rules afterwards (hercules' incoming sshd rule) and, on hercules, add the rules of section
   8 G of `docs/superpowers/specs/2026-11-15-hercules-agent-machine-design.md`. Then store this
   machine's own backup with step 4, *Refresh* (`create`).

2. **Check.** Settings › Registration shows the licence, Settings › Security has Terminal access
   off, and the rules list shows your rules. Terminal access is checked always, whether the
   restore worked or not. Then delete the file.

   ```bash
   rm /tmp/little-snitch.lsbackup
   ```

3. **First use.** Answer the alerts as they come: Homebrew tools (a changed identity) and mise
   tools whose version moved (a new path). On hercules, before you leave it, check `netbird
   status`, an ssh login over NetBird, one Vorta backup and one agent line, so the tools that later
   run unattended raise their alerts now.

4. **Refresh.** Do this after a rule review, and after any rule change worth keeping, removals and
   narrowings included: a stale backup brings a removed allow rule back without an alert. Delete a
   leftover file.

   ```bash
   rm -f /tmp/little-snitch.lsbackup
   ```

   With Terminal access off, use File › Create Backup… and save it to `/tmp`, named
   `little-snitch.lsbackup` in the save dialog. Then make it private.

   ```bash
   chmod 600 /tmp/little-snitch.lsbackup
   ```

   Run the check and read its result: it must be `[0,[<the output of id -u>]]`. Anything else, or
   no output, means do not store it: delete the file with the `rm` command at the end of this
   step before you stop or start again. For a first value of `1` or `true`, turn Terminal access
   off and start Refresh again.

   ```bash
   jq -c '[.globalDefaults.allowCommandLineAccess // 0, [.users[].uid | select(. != 0)]]' /tmp/little-snitch.lsbackup
   ```

   Store it. Run `edit` when the machine has an item, or `create` when it has none yet; never both.

   ```bash
   op document edit "Little Snitch backup ${machine:?}" --vault Private /tmp/little-snitch.lsbackup
   ```

   ```bash
   op document create /tmp/little-snitch.lsbackup --title "Little Snitch backup ${machine:?}" --vault Private
   ```

   Then delete the file.

   ```bash
   rm /tmp/little-snitch.lsbackup
   ```

5. **Never restore onto a machine in use,** except to roll back or to apply a periodic review
   (below). A restore discards every rule made since the backup; Little Snitch keeps an automatic
   copy of what it replaced.

6. **Periodic review.** Do this every month or two, and after a burst of alerts. An agent reviews
   your rules; you restore them. The review's aims are in the spec's section 5.

   With Terminal access off, delete a leftover base file.

   ```bash
   rm -f /tmp/little-snitch-base.lsbackup
   ```

   Use File › Create Backup… and save it to `/tmp`, named `little-snitch-base.lsbackup` in the save
   dialog. Then make it private.

   ```bash
   chmod 600 /tmp/little-snitch-base.lsbackup
   ```

   Ask an agent for the review. A restart clears `/tmp`: if that happens, start again here.

   When the agent has written `review-rules.json` and `review-log.md` in
   `~/Code/.metrics/little-snitch/`, read `review-log.md` and go on only if you accept every change
   it lists. If you do not, delete your base backup with the first command of this part, `rm -f
   /tmp/little-snitch-base.lsbackup`, and stop. Otherwise delete a leftover file.

   ```bash
   rm -f /tmp/little-snitch.lsbackup
   ```

   Build the file to restore. This line keeps every setting of your own backup and takes only
   `.rules` from the agent's file. It gives an empty file for anything but exactly one array.

   ```bash
   (umask 077; jq --slurpfile r ~/Code/.metrics/little-snitch/review-rules.json '.rules = ($r | if length == 1 then .[0] else empty end | arrays)' /tmp/little-snitch-base.lsbackup > /tmp/little-snitch.lsbackup)
   ```

   Run the check on it and read its result: it must be `[0,[<the output of id -u>]]`. Anything
   else, or no output (an empty file), means do not restore it: delete both files with the `rm`
   command that closes this part before you stop or start again. For a first value of `1` or
   `true`, turn Terminal access off and start the review again.

   ```bash
   jq -c '[.globalDefaults.allowCommandLineAccess // 0, [.users[].uid | select(. != 0)]]' /tmp/little-snitch.lsbackup
   ```

   Restore right after, with File › Restore from Backup… › Browse… (⇧⌘G `/tmp`), choosing
   `little-snitch.lsbackup` and not the base file, and only if nothing changed in Little Snitch
   since your base backup: no alert answered, no rule or setting changed by hand. If something did,
   start again, because a restore discards every change made since its source backup. Then delete
   both files.

   ```bash
   rm /tmp/little-snitch.lsbackup /tmp/little-snitch-base.lsbackup
   ```

   Store a fresh backup with step 4, *Refresh*, then tell the agent, which deletes
   `review-rules.json` and `review-log.md`.

---

## 🛠️ Maintenance

```bash
# Update everything
chezmoi update                    # Pull dotfiles and apply origin's main
brew update && brew upgrade       # Update packages
mise upgrade                      # Update dev tools
cd $ZSH && git pull              # Update Oh My Zsh
```

---

## 📁 Repository Structure

```
~/.local/share/chezmoi/
├── .backgrounds/          # Desktop wallpapers
├── .scripts/              # Bootstrap and configuration scripts
├── dot_config/            # Application configs (~/.config)
│   ├── ghostty/          # Terminal
│   ├── git/              # Git configuration
│   ├── homebrew/         # Brewfile.tmpl
│   ├── nvim/             # Neovim
│   ├── starship/         # Prompt
│   └── zsh/              # Shell configuration
├── dot_local/             # Local binaries and data
├── private_dot_ssh/       # SSH keys (1Password templates)
├── tests/                 # Test suites (`./tests/run.sh`)
├── .chezmoi.toml.tmpl    # Chezmoi config, generated by `chezmoi init` (or `chezmoi apply --init`)
├── .chezmoiignore        # Excluded files
├── .chezmoiversion       # Minimum version (2.67.0)
└── README.md             # This file
```

---

## 📚 Resources

- [chezmoi Documentation](https://www.chezmoi.io/)
- [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)
- [macOS Security and Privacy Guide](https://github.com/drduh/macOS-Security-and-Privacy-Guide)

---

<div align="center">

Made with ❤️ by [Michaël Rigart](https://github.com/michaelrigart)

⭐ Star this repo if you found it helpful!

</div>
