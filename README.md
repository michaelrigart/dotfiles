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
- 🛡️ **1Password integration** for SSH keys and secrets
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
8. Reconcile the AI agent plugins, then set Homebrew zsh as the default shell
9. Install Oh My Zsh
10. Install development tools via mise
11. Apply macOS system settings

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
# Edit a dotfile
chezmoi edit ~/.zshrc

# Preview changes
chezmoi diff

# Apply changes
chezmoi apply

# Update from repository
chezmoi update
```

### Managing Dotfiles

```bash
# Add a new file to dotfiles
chezmoi add ~/.config/newapp/config.toml

# Commit and push changes
cd ~/.local/share/chezmoi
git add .
git commit -m "Update configuration"
git push
```

### Re-running Scripts

```bash
# Re-apply macOS system settings
~/.local/share/chezmoi/.scripts/configure.sh

# Update all Homebrew packages
brew bundle install --file ~/.config/homebrew/Brewfile

# Update development tools
mise install
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

# 4. Set the machine identity BEFORE chezmoi runs: `chezmoi init` records ComputerName,
#    and the Brewfile refuses a machine not listed in .chezmoidata/machines.toml.
#    <name> is one of those listed names (fenrir, hercules).
sudo scutil --set ComputerName  <name>
sudo scutil --set HostName      <name>
sudo scutil --set LocalHostName <name>

# 5. Initialize and apply dotfiles
chezmoi init https://github.com/michaelrigart/dotfiles.git
chezmoi apply --force

# 6. Switch to SSH
cd ~/.local/share/chezmoi
git remote set-url origin git@github.com:michaelrigart/dotfiles.git

# 7. Install packages. The Brewfile marks its taps `trusted: true`, so
#    `brew bundle install` trusts them itself.
export HOMEBREW_BUNDLE_FILE=~/.config/homebrew/Brewfile
brew bundle install --file "$HOMEBREW_BUNDLE_FILE"

# 8. Default shell, then Oh My Zsh (~/.zshrc sources it unconditionally).
#    KEEP_ZSHRC=yes stops the installer replacing the chezmoi-managed ~/.zshrc.
chsh -s $(brew --prefix)/bin/zsh
export ZSH="$HOME/.local/share/oh-my-zsh"
KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended

# 9. Development tools, then macOS settings
mise install
~/.local/share/chezmoi/.scripts/configure.sh
```

---

## 🔐 Security

### SSH Key Management

SSH keys are stored in 1Password and templated automatically:

```toml
# Example: private_dot_ssh/private_michael.tmpl
{{ onepasswordRead "op://Private/michael/private key?ssh-format=openssh" }}
```

### Secrets in Config

Environment variables and API keys can be templated from 1Password:

```bash
export API_KEY='{{ (onepasswordItemFields "vault" "item").api_key.value }}'
```

### macOS Hardening

The [configure.sh](.scripts/configure.sh) script:
- Checks FileVault and warns when its state doesn't match the machine (it never changes it)
- Enables the system firewall
- Applies secure Finder and system defaults

---

## 🛠️ Maintenance

```bash
# Update everything
chezmoi update                    # Pull dotfiles
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
├── .chezmoi.toml.tmpl    # Chezmoi config, generated by `chezmoi init`
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
