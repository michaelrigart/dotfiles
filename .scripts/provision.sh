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

# Collected non-fatal problems, printed at the end. Under `set -e` anything optional
# must be called as `cmd || warn "..."`, or the whole run dies on one bad cask.
typeset -a WARNINGS=()
warn() { WARNINGS+=("$1"); log_warn "$1"; }

# Overridden only by .scripts/test-provision.sh; nothing else sets these.
BREW_BIN="${PROVISION_BREW_BIN:-/opt/homebrew/bin/brew}"

# Set temporary XDG variables for bootstrap (will be properly set by chezmoi later)
export XDG_CACHE_HOME="${HOME}/.cache"
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_DATA_HOME="${HOME}/.local/share"
export XDG_STATE_HOME="${HOME}/.local/state"
export XDG_BIN_HOME="${HOME}/.local/bin"

echo ""
log_info "========== Starting macOS Provision =========="
echo ""

# ============================================================================
# 0. sudo, once, up front
# ============================================================================
# This must precede Homebrew, not sit in preflight below. NONINTERACTIVE=1 stops the
# Homebrew installer prompting for confirmation, but it also stops it prompting for a
# password -- so it needs the sudo credential already cached or it aborts with
# "Need sudo access on macOS". Acquiring it here also makes the password the first
# thing asked, and the keepalive holds it for the rest of the run.
log_info "Requesting sudo (held for the whole run, so nothing prompts later)..."
sudo -v
# stdout is closed too, not just stderr: a background loop that keeps stdout open
# hangs any caller capturing this script's output with $( ).
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done >/dev/null 2>&1 &

# ============================================================================
# 1. Install Xcode Command Line Tools
# ============================================================================
if ! xcode-select -p &>/dev/null; then
  log_info "Installing Xcode Command Line Tools — accept the dialog that just opened."
  xcode-select --install 2>/dev/null || true
  # macOS gives no completion signal, and a cancelled dialog is indistinguishable from
  # a slow one: both just keep failing. One bounded wait covers both, instead of the
  # old `exit 0` that reported success and asked for a manual re-run.
  waited=0
  until xcode-select -p &>/dev/null; do
    if [ "$waited" -ge 1800 ]; then
      log_error "No Xcode CLT after 30 minutes — was the dialog cancelled?"
      exit 1
    fi
    sleep 5; waited=$((waited + 5))
    [ $((waited % 60)) -eq 0 ] && log_info "  still waiting for the Xcode CLT dialog (${waited}s)"
  done
  log_info "✓ Xcode Command Line Tools installed"
else
  log_info "✓ Xcode Command Line Tools already installed"
fi

# ============================================================================
# 2. Install Homebrew
# ============================================================================
if ! command -v brew &>/dev/null; then
  log_info "Installing Homebrew..."
  # NONINTERACTIVE=1: the installer otherwise stops on "Press RETURN to continue",
  # which would break the unattended promise before it starts.
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Add Homebrew to PATH for this session
  eval "$("${BREW_BIN}" shellenv)"
  export HOMEBREW_PREFIX=$("${BREW_BIN}" --prefix)
else
  log_info "✓ Homebrew already installed"
  eval "$("${BREW_BIN}" shellenv)"
  export HOMEBREW_PREFIX=$("${BREW_BIN}" --prefix)

  log_info "Updating Homebrew..."
  brew update
fi

# ============================================================================
# 3. Install essential tools for bootstrap
# ============================================================================
log_info "Installing essential bootstrap tools..."
brew install chezmoi 1password-cli git
# The desktop app supplies CLI integration, so it is bootstrap work, not Brewfile work:
# step 6 renders op:// templates and cannot wait for step 8.
# NOT optional, so not a warning: every op:// template depends on it, and without the
# app the gate below would poll for 15 minutes waiting for something never installed.
if ! op whoami &>/dev/null; then
  brew install --cask 1password
fi

# ============================================================================
# 4. Clone the dotfiles source
# ============================================================================
# A plain `git clone`, not `chezmoi init`. `chezmoi init` would also render the config,
# capturing the machine's CURRENT name — but the name is not chosen until preflight,
# below. Cloning first also makes the machine allowlist readable before we prompt.
SRC_DIR="${PROVISION_SRC_OVERRIDE:-${XDG_DATA_HOME}/chezmoi}"
if [ -d "${SRC_DIR}/.git" ]; then
  log_info "✓ dotfiles source already present"
else
  log_info "Cloning dotfiles source..."
  git clone https://github.com/michaelrigart/dotfiles.git "${SRC_DIR}"
fi

# ============================================================================
# 5. Preflight — every question is asked here, and nowhere else
# ============================================================================
# The point of this block: the rest of the run is unattended. Previously the script
# stopped for input four separate times, potentially hours apart.

# 5a. 1Password. The desktop app's CLI integration means no Secret Key is typed, which
# matters because the Emergency Kit is deliberately stored off this machine.
if op whoami &>/dev/null; then
  log_info "✓ 1Password CLI already authenticated"
else
  open -a "1Password" 2>/dev/null || true
  echo ""
  echo "  In the 1Password app:"
  echo "    1. Sign in and unlock (you must see your vaults, not just a lock screen)"
  echo "    2. Settings → Developer → ☑ Integrate with 1Password CLI"
  echo "    3. Quit the app fully (⌘Q) and reopen it — the CLI link is established"
  echo "       at launch, so enabling it in a running app often does not take."
  echo ""
  echo "  To check from another terminal:  ${HOMEBREW_PREFIX}/bin/op account list"
  echo "  (Homebrew was just installed, so plain \`op\` is not on PATH in any tab you"
  echo "   already had open. Use the full path above, or open a new tab.)"
  echo ""
  echo "  If that list stays EMPTY the integration is not connected. Add the account"
  echo "  directly instead — the signed-in app shows your Secret Key under"
  echo "  your account → Set Up Another Device:"
  echo "    ${HOMEBREW_PREFIX}/bin/op account add --address my.1password.com --email <you>"
  echo ""
  waited=0
  until op whoami &>/dev/null; do
    if [ "$waited" -ge 900 ]; then
      log_error "1Password CLI still unavailable after 15 minutes."
      exit 1
    fi
    sleep 3; waited=$((waited + 3))
  done
  log_info "✓ 1Password CLI authenticated"
fi

# 5b. Machine name, validated against the allowlist. An unlisted name is refused rather
# than silently taking the wrong branch of the hostname conditionals in the Brewfile.
KNOWN=$(sed -n 's/^known_hostnames *= *\[\(.*\)\]/\1/p' \
          "${SRC_DIR}/.chezmoidata/machines.toml" 2>/dev/null | tr -d '" ' | tr ',' ' ')
if [ -z "$KNOWN" ]; then
  log_error "No known_hostnames in ${SRC_DIR}/.chezmoidata/machines.toml"
  exit 1
fi
MACHINE_NAME=""
while [ -z "$MACHINE_NAME" ]; do
  echo -n "  Machine name (${KNOWN}): "
  read -r REPLY_NAME
  for k in ${=KNOWN}; do
    [ "$REPLY_NAME" = "$k" ] && MACHINE_NAME="$k"
  done
  [ -z "$MACHINE_NAME" ] && log_warn "Unknown machine '${REPLY_NAME}' — add it to .chezmoidata/machines.toml first"
done

# 5c. sudo was acquired in step 0, which had to precede Homebrew. Refresh it here in
# case the Xcode CLT download ran long.
sudo -v

# 5d. One confirmation. Nothing machine-specific has changed yet, so declining here
# leaves the machine's identity and configuration exactly as they were found.
echo ""
echo "══ Provision: ${MACHINE_NAME} ═══════════════════"
echo "  Machine name ....... ${MACHINE_NAME}"
echo "  Dotfiles source .... ${SRC_DIR}"
echo "  1Password .......... authenticated"
echo "─────────────────────────────────────────────────"
echo -n "  Proceed? [y/N] "
read -r REPLY_GO
case "$REPLY_GO" in
  y|Y) ;;
  *) log_warn "Aborted. Nothing machine-specific was changed."; exit 1 ;;
esac

# 5e. Apply the identity, then read it back. All three fields matter: ComputerName is
# what chezmoi records, and HostName is what `hostname` — and therefore Borg's archive
# naming — resolves to. LocalHostName tolerates the numeric suffix macOS appends by
# itself when the Bonjour name collides on the network.
log_info "Setting machine identity to ${MACHINE_NAME}..."
sudo scutil --set ComputerName  "${MACHINE_NAME}"
sudo scutil --set HostName      "${MACHINE_NAME}"
sudo scutil --set LocalHostName "${MACHINE_NAME}"
[ "$(scutil --get ComputerName)" = "${MACHINE_NAME}" ] || { log_error "ComputerName did not take"; exit 1; }
[ "$(scutil --get HostName)"     = "${MACHINE_NAME}" ] || { log_error "HostName did not take"; exit 1; }
case "$(scutil --get LocalHostName)" in
  "${MACHINE_NAME}"|"${MACHINE_NAME}"-<->) ;;
  *) log_error "LocalHostName did not take"; exit 1 ;;
esac
log_info "✓ identity set to ${MACHINE_NAME}"

# ============================================================================
# 6. Generate the chezmoi config, then apply
# ============================================================================
# Only now, with the identity settled, does chezmoi capture it.
log_info "Generating chezmoi config..."
chezmoi init
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
cd "${SRC_DIR}"
git remote set-url origin git@github.com:michaelrigart/dotfiles.git

# Test SSH connection
log_info "Testing SSH connection to GitHub..."
# accept-new, not the default `ask`: a fresh machine has no known_hosts entry for
# github.com, and the prompt would break the unattended run.
if ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
  log_info "✓ SSH connection to GitHub successful"
else
  warn "SSH to GitHub not confirmed — check ~/.ssh/michael"
fi

# ============================================================================
# 8. Install Homebrew packages from Brewfile
# ============================================================================
if [ -f "${XDG_CONFIG_HOME}/homebrew/Brewfile" ]; then
  log_info "Installing packages from Brewfile..."
  export HOMEBREW_BUNDLE_FILE="${XDG_CONFIG_HOME}/homebrew/Brewfile"

  # Homebrew refuses to load formulae/casks from third-party taps until they are
  # trusted, which aborts `brew bundle` on a fresh machine. Trust each tap the
  # Brewfile declares — adding a tap there is already the decision to install and
  # run software from it. Tap-level (rather than per-formula) trust also covers
  # entries written as a bare name, e.g. cask "basecamp-cli" from basecamp/tap.
  # Idempotent, so re-running provisioning is safe.
  for tap in $(sed -n 's/^tap "\([^"]*\)".*/\1/p' "${HOMEBREW_BUNDLE_FILE}"); do
    log_info "Trusting tap: ${tap}"
    brew trust --tap "${tap}" || warn "could not trust tap ${tap}"
  done

  # A licence-gated cask must not end the run — the remaining steps still matter.
  # `brew bundle` fails for the whole file, so ask `check` which items actually missed.
  #
  # The retry is not superstition: `brew bundle` installs every formula before any
  # cask, and borgbackup-fuse is a formula that requires the macfuse cask. On a clean
  # machine the first pass always fails on it; by the second pass macfuse exists.
  if ! brew bundle install --file "${HOMEBREW_BUNDLE_FILE}"; then
    log_warn "brew bundle had failures — retrying once (formula-before-cask ordering)"
    brew bundle install --file "${HOMEBREW_BUNDLE_FILE}" || true
  fi
  if ! brew bundle check --file "${HOMEBREW_BUNDLE_FILE}" >/dev/null 2>&1; then
    # Process substitution, not a pipeline: `cmd | while read` runs the loop in a
    # subshell, so every warn() inside it appends to a WARNINGS array that is thrown
    # away when the subshell exits. The end-of-run summary silently lost every item.
    while read -r item; do
      [ -n "$item" ] && warn "brewfile: ${item}"
    done < <(brew bundle check --verbose --file "${HOMEBREW_BUNDLE_FILE}" 2>/dev/null | sed -n 's/^→ *//p')
    warn "brew bundle did not complete — see the items above"
  fi
else
  log_error "Brewfile not found at ${XDG_CONFIG_HOME}/homebrew/Brewfile"
fi

# ============================================================================
# 9. Reconcile AI agent plugins (Claude Code + Codex)
# ============================================================================
if [ -x "${SRC_DIR}/.scripts/reconcile-agents.sh" ]; then
  log_info "Reconciling AI agent plugins..."
  "${SRC_DIR}/.scripts/reconcile-agents.sh" \
    || warn "agent plugins: reconcile incomplete — if Claude Code has never run here, its plugin state does not exist yet; launch it once, then re-run .scripts/reconcile-agents.sh"
else
  log_warn "reconcile-agents.sh not found, skipping agent plugin setup"
fi

# ============================================================================
# 10. Set default shell to Homebrew zsh
# ============================================================================
log_info "Setting default shell to Homebrew zsh..."
if [[ "$SHELL" != "${HOMEBREW_PREFIX}/bin/zsh" ]]; then
  if ! grep -qxF "${HOMEBREW_PREFIX}/bin/zsh" /etc/shells; then
    log_info "Adding Homebrew zsh to /etc/shells..."
    echo "${HOMEBREW_PREFIX}/bin/zsh" | sudo tee -a /etc/shells
  fi
  log_info "Changing shell to ${HOMEBREW_PREFIX}/bin/zsh..."
  # sudo chsh, not bare chsh: bare chsh prompts for the user's password mid-run.
  sudo chsh -s "${HOMEBREW_PREFIX}/bin/zsh" "${USER}"
else
  log_info "✓ Shell already set to Homebrew zsh"
fi

# ============================================================================
# 11. Install oh-my-zsh (with XDG support)
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
  # KEEP_ZSHRC=yes is load-bearing: ~/.zshrc is chezmoi-managed (dot_zshrc), and the
  # installer otherwise replaces it with its own template, backs the real one up to
  # ~/.zshrc.pre-oh-my-zsh, and step 14 then deletes that backup.
  KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended
fi

# ============================================================================
# 12. Install mise tools
# ============================================================================
if command -v mise &>/dev/null; then
  log_info "Installing mise tools..."
  mise install
else
  log_warn "mise not found, skipping tool installation"
fi

# ============================================================================
# 13. Create necessary cache directories
# ============================================================================
log_info "Creating cache directories..."
mkdir -p "${XDG_CACHE_HOME}/zsh"
mkdir -p "${XDG_CACHE_HOME}/irb"
mkdir -p "${XDG_CACHE_HOME}/bundler/cache"
mkdir -p "${XDG_CACHE_HOME}/bundler/plugin"
mkdir -p "${XDG_CACHE_HOME}/gem/specs"

# ============================================================================
# 14. Cleanup oh-my-zsh artifacts
# ============================================================================
log_info "Cleaning up installation artifacts..."
rm -f "${HOME}/.zprofile"
rm -f "${HOME}/.zprofile.bak"
rm -f "${HOME}/.zshrc.pre-oh-my-zsh"
rm -f "${HOME}/.shell.pre-oh-my-zsh"

# ============================================================================
# 15. Homebrew cleanup
# ============================================================================
log_info "Cleaning up Homebrew..."
brew cleanup

# ============================================================================
# 16. Run macOS configuration
# ============================================================================
if [ -f "${SRC_DIR}/.scripts/configure.sh" ]; then
  log_info "Running macOS configuration..."
  # --hostname: preflight already owns the identity, so configure.sh verifies instead
  # of prompting. It never renames in this mode.
  "${SRC_DIR}/.scripts/configure.sh" --hostname "${MACHINE_NAME}" \
    || warn "macOS configuration reported problems"
else
  log_warn "macOS configuration script not found at ${SRC_DIR}/.scripts/configure.sh"
fi

# ============================================================================
# Done!
# ============================================================================
echo ""
log_info "=========================================="
log_info "✓ macOS provision complete!"
log_info "=========================================="
echo ""
if [ ${#WARNINGS[@]} -gt 0 ]; then
  log_warn "${#WARNINGS[@]} item(s) need you:"
  for w in "${WARNINGS[@]}"; do
    echo "    ⚠ ${w}"
  done
  echo ""
fi
log_info "Next steps:"
log_info "  0. Borg: this machine needs its OWN BorgBase repo and keypair — archives are"
log_info "     named from the hostname, so sharing a repo interleaves two machines."
log_info "  1. Restart your terminal or run: exec ${HOMEBREW_PREFIX}/bin/zsh"
log_info "  2. Verify chezmoi is using SSH: cd ~/.local/share/chezmoi && git remote -v"
log_info "  3. Test making changes: chezmoi edit ~/.zshrc"
log_info "  4. Some macOS settings may require a logout/restart to take effect"
log_info "  5. The ;codex / ;claude relay snippets are Alfred snippets. Two steps remain:"
log_info "       a. System Settings > Privacy & Security > Accessibility > add Alfred."
log_info "          Without it Alfred runs and shows the snippets in its UI while expanding"
log_info "          nothing — it never sees the keystrokes."
log_info "       b. Run .scripts/configure.sh, which enables snippet auto-expansion and"
log_info "          restarts Alfred so it indexes the collection (a NEW collection is only"
log_info "          discovered at launch, so a bare 'chezmoi apply' is not enough)."
log_info "       Verify with: bash .scripts/test-alfred-relay.sh"
echo ""
