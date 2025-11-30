#!/usr/bin/env zsh
# macOS Provision Script
# Install by running: /bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/michaelrigart/dotfiles/refs/heads/main/.scripts/provision.sh)"

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo "${RED}[ERROR]${NC} $1"; }

# Set temporary XDG variables for bootstrap (will be properly set by chezmoi later)
export XDG_CACHE_HOME="${HOME}/.cache"
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_DATA_HOME="${HOME}/.local/share"
export XDG_STATE_HOME="${HOME}/.local/state"
export XDG_BIN_HOME="${HOME}/.local/bin"

# Confirmation prompt
while read "REPLY?Ready to provision macOS? This will install Homebrew, 1Password, and dotfiles. [y]es|[n]o: " && [[ $REPLY != 'y' ]]; do
  case $REPLY in
    n|q) log_warn "Installation cancelled."; exit 0;;
  esac
done

echo ""
log_info "========== Starting macOS Provision =========="
echo ""

# ============================================================================
# 1. Install Xcode Command Line Tools
# ============================================================================
if ! xcode-select -p &>/dev/null; then
    log_info "Installing Xcode Command Line Tools..."
    xcode-select --install
    log_warn "Please complete the Xcode installation in the dialog, then re-run this script."
    exit 0
else
  log_info "✓ Xcode Command Line Tools already installed"
fi

# ============================================================================
# 2. Install Homebrew
# ============================================================================
if ! command -v brew &>/dev/null; then
  log_info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Add Homebrew to PATH for this session
  eval "$(/opt/homebrew/bin/brew shellenv)"
  export HOMEBREW_PREFIX=$(brew --prefix)
else
  log_info "✓ Homebrew already installed"
  eval "$(/opt/homebrew/bin/brew shellenv)"
  export HOMEBREW_PREFIX=$(brew --prefix)

  log_info "Updating Homebrew..."
  brew update
fi

# ============================================================================
# 3. Install essential tools for bootstrap
# ============================================================================
log_info "Installing essential bootstrap tools..."
brew install chezmoi 1password-cli git

# ============================================================================
# 4. Authenticate with 1Password
# ============================================================================
if ! op account list &>/dev/null; then
  log_info "Authenticating with 1Password..."
  log_warn "You need to sign in to 1Password to access SSH keys and secrets."
  eval $(op signin)
else
  log_info "✓ Already signed in to 1Password"
fi

# ============================================================================
# 5. Initialize chezmoi with HTTPS (public repo)
# ============================================================================
if [ -d "${XDG_DATA_HOME}/chezmoi" ]; then
  log_info "✓ Chezmoi already initialized"
##  cd "${XDG_DATA_HOME}/chezmoi"
##  git pull
else
  log_info "Initializing chezmoi with dotfiles (HTTPS)..."
  chezmoi init https://github.com/michaelrigart/dotfiles.git
fi

# ============================================================================
# 6. Apply chezmoi (this renders SSH keys from 1Password templates)
# ============================================================================
log_info "Applying dotfiles with chezmoi..."
# Force apply to overwrite any local changes
chezmoi apply --force

# Set proper permissions on SSH directory and private keys only
if [ -d "${HOME}/.ssh" ]; then
  log_info "Setting SSH key permissions..."
  chmod 700 "${HOME}/.ssh"
  # Only change permissions on private keys (files without .pub extension and not config)
  find "${HOME}/.ssh" -type f ! -name "*.pub" ! -name "config" -exec chmod 600 {} \; 2>/dev/null || true
fi

# ============================================================================
# 7. Switch chezmoi remote to SSH for future commits
# ============================================================================
log_info "Switching chezmoi remote to SSH..."
cd "${XDG_DATA_HOME}/chezmoi"
git remote set-url origin git@github.com:michaelrigart/dotfiles.git

# Test SSH connection
log_info "Testing SSH connection to GitHub..."
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
  log_info "✓ SSH connection to GitHub successful"
else
  log_warn "SSH connection test inconclusive, but this might be normal for GitHub"
fi

# ============================================================================
# 8. Install Homebrew packages from Brewfile
# ============================================================================
if [ -f "${XDG_CONFIG_HOME}/homebrew/Brewfile" ]; then
  log_info "Installing packages from Brewfile..."
  export HOMEBREW_BUNDLE_FILE="${XDG_CONFIG_HOME}/homebrew/Brewfile"
  brew bundle install --file "${HOMEBREW_BUNDLE_FILE}"
else
  log_error "Brewfile not found at ${XDG_CONFIG_HOME}/homebrew/Brewfile"
fi

# ============================================================================
# 9. Set default shell to Homebrew zsh
# ============================================================================
log_info "Setting default shell to Homebrew zsh..."
if [[ "$SHELL" != "${HOMEBREW_PREFIX}/bin/zsh" ]]; then
  if ! grep -qxF "${HOMEBREW_PREFIX}/bin/zsh" /etc/shells; then
    log_info "Adding Homebrew zsh to /etc/shells..."
    echo "${HOMEBREW_PREFIX}/bin/zsh" | sudo tee -a /etc/shells
  fi
  log_info "Changing shell to ${HOMEBREW_PREFIX}/bin/zsh..."
  chsh -s "${HOMEBREW_PREFIX}/bin/zsh"
else
  log_info "✓ Shell already set to Homebrew zsh"
fi

# ============================================================================
# 10. Install oh-my-zsh (with XDG support)
# ============================================================================
log_info "Installing oh-my-zsh..."
if [ -d "${XDG_DATA_HOME}/oh-my-zsh" ]; then
  log_info "✓ oh-my-zsh already installed"
  cd "${XDG_DATA_HOME}/oh-my-zsh"
  git pull
else
  log_info "Installing oh-my-zsh to ${XDG_DATA_HOME}/oh-my-zsh..."
  # Set ZSH to XDG location before installation
  export ZSH="${XDG_DATA_HOME}/oh-my-zsh"
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended
fi

# ============================================================================
# 11. Install mise tools
# ============================================================================
if command -v mise &>/dev/null; then
  log_info "Installing mise tools..."
  mise install
else
  log_warn "mise not found, skipping tool installation"
fi

# ============================================================================
# 12. Create necessary cache directories
# ============================================================================
log_info "Creating cache directories..."
mkdir -p "${XDG_CACHE_HOME}/zsh"
mkdir -p "${XDG_CACHE_HOME}/irb"
mkdir -p "${XDG_CACHE_HOME}/bundler/cache"
mkdir -p "${XDG_CACHE_HOME}/bundler/plugin"
mkdir -p "${XDG_CACHE_HOME}/gem/specs"

# ============================================================================
# 13. Cleanup oh-my-zsh artifacts
# ============================================================================
log_info "Cleaning up installation artifacts..."
rm -f "${HOME}/.zprofile"
rm -f "${HOME}/.zprofile.bak"
rm -f "${HOME}/.zshrc.pre-oh-my-zsh"
rm -f "${HOME}/.shell.pre-oh-my-zsh"

# ============================================================================
# 14. Homebrew cleanup
# ============================================================================
log_info "Cleaning up Homebrew..."
brew cleanup

# ============================================================================
# 15. Run macOS configuration
# ============================================================================
if [ -f "${XDG_DATA_HOME}/chezmoi/.scripts/configure.sh" ]; then
  log_info "Running macOS configuration..."
  "${XDG_DATA_HOME}/chezmoi/.scripts/configure.sh"
else
  log_warn "macOS configuration script not found at ${XDG_DATA_HOME}/chezmoi/.scripts/configure.sh"
fi

# ============================================================================
# Done!
# ============================================================================
echo ""
log_info "=========================================="
log_info "✓ macOS provision complete!"
log_info "=========================================="
echo ""
log_info "Next steps:"
log_info "  1. Restart your terminal or run: exec ${HOMEBREW_PREFIX}/bin/zsh"
log_info "  2. Verify chezmoi is using SSH: cd ~/.local/share/chezmoi && git remote -v"
log_info "  3. Test making changes: chezmoi edit ~/.zshrc"
log_info "  4. Some macOS settings may require a logout/restart to take effect"
echo ""
