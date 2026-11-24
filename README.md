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
4. Authenticate with 1Password, then ask for the machine name (it must be listed in [machines.toml](.chezmoidata/machines.toml)), confirm, and set the macOS ComputerName, HostName and LocalHostName to it
5. Generate the chezmoi config and apply the dotfiles
6. Switch the chezmoi remote to SSH
7. Install all packages from [Brewfile](dot_config/homebrew/Brewfile.tmpl)
8. Install the NetBird daemon
9. Reconcile the AI agent plugins, then set Homebrew zsh as the default shell
10. Install Oh My Zsh
11. Install development tools via mise
12. Install the Neovim plugins and link the Herdr plugins
13. Apply macOS system settings
14. Only if no Codex daemon package existed when the run started, pin the Codex daemon to the CLI's package
15. Print what is left to do, from [machine-check.sh](.scripts/machine-check.sh)

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

```bash
# Pull the image (about 33 GB), clone it and give the clone room: the whole Brewfile fills 80 GB
tart clone ghcr.io/cirruslabs/macos-golden-gate-vanilla reinstall-test
tart set reinstall-test --disk-size 120
tart run reinstall-test

# In the VM (its window shares no clipboard, so type this): run the branch's script. It installs
# the 1Password app; when it asks, sign in there, turn on the CLI integration and approve the
# terminal's request. Answer `hercules` for the machine name: `fenrir` is taken on the network
# the VM shares with fenrir, and macOS renames the VM `fenrir (2)`.
# PROVISION_REF is honoured only inside a VM and picks the branch the clone checks out.
ref=<branch>
PROVISION_REF=$ref /bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/michaelrigart/dotfiles/refs/heads/$ref/.scripts/provision.sh)"

# Afterwards, on fenrir
tart delete reinstall-test
```

It passes when every `script` row of the final check is ✓ except the rows a VM cannot satisfy
(`hercules-power` if `pmset` rejects a key); the `you` rows, Little Snitch's extension among them,
print ✗ until Michael does them after one run, a second run prints the same machine-check
result, reloads no LaunchAgent and adds no warning, and the `you` rows print in order.

Then remove the VM's device from 1Password. Never run `netbird up`, pair Syncthing or start Borg
inside the VM.

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
- Checks FileVault and warns when its state doesn't match the machine (it never changes it)
- Enables the system firewall
- Installs the Claude Code managed policy that limits mods to the organization's (`allowManagedModsOnly`) via [install-claude-managed-settings.sh](.scripts/install-claude-managed-settings.sh), refusing a different existing policy unless run with `--replace`; to uninstall: `sudo rm "/Library/Application Support/ClaudeCode/managed-settings.json"`
- Applies secure Finder and system defaults

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
