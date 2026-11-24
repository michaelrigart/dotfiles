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

# Overridden only by tests/provision.test.sh; nothing else sets these.
BREW_BIN="${PROVISION_BREW_BIN:-/opt/homebrew/bin/brew}"

# Set temporary XDG variables for bootstrap (will be properly set by chezmoi later)
export XDG_CACHE_HOME="${HOME}/.cache"
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_DATA_HOME="${HOME}/.local/share"
export XDG_STATE_HOME="${HOME}/.local/state"
export XDG_BIN_HOME="${HOME}/.local/bin"
# Before zshenv exists: op learns the 1Password app integration is on from the app's
# group-container settings, which macOS 27.2 may refuse the terminal (see zshenv).
export OP_BIOMETRIC_UNLOCK_ENABLED=true

# PROVISION_REF (a test knob for a VM run, see the spec) makes the clone check out a branch.
# Checked before anything else, sudo included: on a real Mac provisioning deploys only
# reviewed main, so any other ref is refused unless this is a VM.
PROVISION_REF="${PROVISION_REF:-main}"
if [ "$PROVISION_REF" != "main" ] && [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" != "1" ]; then
  log_error "PROVISION_REF=${PROVISION_REF} is refused outside a VM: provisioning a real Mac deploys main only."
  exit 1
fi

# Recorded before anything installs: a cask, reconcile-agents.sh's codex plugin step or
# configure.sh's LaunchAgent load can each create the package link, and only a machine that had
# no daemon package at all when the run started is pinned (step 17). A set-up machine has it.
DAEMON_CURRENT="${HOME}/.codex/packages/app-server-daemon/current"
if [ -e "$DAEMON_CURRENT" ] || [ -L "$DAEMON_CURRENT" ]; then
  CODEX_FRESH=0
else
  CODEX_FRESH=1
fi

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
# jq: the first apply (step 6) runs modify_ scripts whose jq programs the system jq rejects.
brew install chezmoi 1password-cli git jq
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
# An earlier run that stopped after its clone left a checkout chezmoi never finished applying:
# chezmoi never ran from it (neither its config nor its state yet), or its clone still carries
# UNAPPLIED, which step 6 removes only once its apply has succeeded. Step 6 applies only this run's
# own clone, so such a checkout is moved aside, never deleted, and cloned afresh: git status cannot
# vouch for it, because chezmoi applies the files themselves (ignored ones too), which is why the
# chezmoi wrapper applies a fresh clone as well. A machine chezmoi has applied keeps its checkout,
# and so does one with wt siblings, whose links into its .git a move would break (an apply by
# hand leaves the mark in place).
UNAPPLIED="${SRC_DIR}/.git/provision-unapplied"
LINKED_WORKTREES=( "${SRC_DIR}"/.git/worktrees/*(DN) )
if [ -d "${SRC_DIR}/.git" ] && (( ${#LINKED_WORKTREES} == 0 )) \
   && { [ -e "${UNAPPLIED}" ] || { [ ! -e "${XDG_CONFIG_HOME}/chezmoi/chezmoi.toml" ] \
   && [ ! -e "${XDG_CONFIG_HOME}/chezmoi/chezmoistate.boltdb" ]; }; }; then
  EARLIER_SRC="${SRC_DIR}.earlier-$(date +%Y%m%d-%H%M%S)"
  mv "${SRC_DIR}" "${EARLIER_SRC}"
  warn "An earlier run's checkout, which chezmoi never finished applying, is now ${EARLIER_SRC}; delete it once nothing in it is needed"
fi
SRC_PRESENT=0
if [ -d "${SRC_DIR}/.git" ]; then
  SRC_PRESENT=1
  log_info "✓ dotfiles source already present"
else
  log_info "Cloning dotfiles source..."
  git clone --branch "${PROVISION_REF}" https://github.com/michaelrigart/dotfiles.git "${SRC_DIR}"
  : > "${UNAPPLIED}"
fi

# ============================================================================
# 5. Preflight — every question is asked here, and nowhere else
# ============================================================================
# The point of this block: the rest of the run is unattended. Previously the script
# stopped for input four separate times, potentially hours apart.

# 5a. 1Password. The desktop app's CLI integration means no Secret Key is typed, which
# matters because the Emergency Kit is deliberately stored off this machine. 1Password
# authorizes each terminal session, and `op whoami` only reports that, never asks for it: so
# the run waits until op sees an account, then signs in itself, in this session.
if op whoami &>/dev/null </dev/null; then
  log_info "✓ 1Password CLI already authenticated"
else
  open -a "1Password" 2>/dev/null || true
  echo ""
  echo "  In the 1Password app:"
  echo "    1. Sign in and unlock (you must see your vaults, not just a lock screen)"
  echo "    2. Settings → Developer → ☑ Integrate with 1Password CLI"
  echo "    3. Quit the app fully (⌘Q) and reopen it — the CLI link is established"
  echo "       at launch, so enabling it in a running app often does not take."
  echo "    4. Approve 1Password's request to let this terminal use the CLI."
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
  until op account list --format=json 2>/dev/null </dev/null | grep -q '"url"'; do
    if [ "$waited" -ge 900 ]; then
      log_error "1Password CLI still sees no account after 15 minutes."
      exit 1
    fi
    sleep 3; waited=$((waited + 3))
    [ $((waited % 60)) -eq 0 ] && log_info "  still waiting for the 1Password app (${waited}s)"
  done
  # The output is empty with the app integration; an account added with `op account add`
  # prints its session variable instead.
  OP_SIGNIN=$(op signin) && eval "$OP_SIGNIN" && op whoami &>/dev/null </dev/null \
    || { log_error "1Password CLI sign-in failed — run provision.sh again"; exit 1; }
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
if [ "$PROVISION_REF" != "main" ]; then
  if [ "$SRC_PRESENT" -eq 1 ]; then
    # An existing checkout is never switched: say what provisioning really uses.
    CHECKOUT_BRANCH=$(git -C "${SRC_DIR}" branch --show-current 2>/dev/null || true)
    echo "  Branch ............. ${CHECKOUT_BRANCH:-detached HEAD} (existing checkout, used as is)"
  else
    echo "  Branch ............. ${PROVISION_REF}"
  fi
fi
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
# Only on this run's own clone (step 4). This runs in zsh as a script, so the chezmoi wrapper
# that deploys only origin's main is not loaded: on a machine whose checkout already existed,
# init and apply would deploy the working tree, which the checkout cannot prove was reviewed.
if [ "$SRC_PRESENT" -eq 1 ]; then
  warn "Machine already provisioned: chezmoi init and apply are skipped. Run chezmoi apply --init from zsh, which deploys origin's main."
else
  log_info "Generating chezmoi config..."
  chezmoi init
  log_info "Applying dotfiles with chezmoi..."
  # Force apply to overwrite any local changes. DOTFILES_PROVISIONING=1 is set on this one
  # command and never exported: a value that leaked to a later apply would make the
  # run_onchange_ script skip its work and chezmoi record that version as run.
  DOTFILES_PROVISIONING=1 chezmoi apply --force
  rm -f "${UNAPPLIED}"
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
  log_info "Installing packages from Brewfile (Homebrew downloads several at once and can print nothing for many minutes)..."
  export HOMEBREW_BUNDLE_FILE="${XDG_CONFIG_HOME}/homebrew/Brewfile"

  # A licence-gated cask must not end the run — the remaining steps still matter.
  # `brew bundle` fails for the whole file, so ask `check` which items actually missed.
  # A single retry absorbs transient download failures. --no-upgrade, like the brewfile row:
  # a release published during the run leaves an item outdated, not missing.
  BUNDLE_FAILED=0
  if ! brew bundle install --file "${HOMEBREW_BUNDLE_FILE}"; then
    log_warn "brew bundle had failures — retrying once"
    brew bundle install --file "${HOMEBREW_BUNDLE_FILE}" || BUNDLE_FAILED=1
  fi
  if ! brew bundle check --no-upgrade --file "${HOMEBREW_BUNDLE_FILE}" >/dev/null 2>&1; then
    # Process substitution, not a pipeline: `cmd | while read` runs the loop in a
    # subshell, so every warn() inside it appends to a WARNINGS array that is thrown
    # away when the subshell exits. The end-of-run summary silently lost every item.
    # Homebrew writes the missed items to stderr.
    while read -r item; do
      [ -n "$item" ] && warn "brewfile: ${item}"
    done < <(brew bundle check --no-upgrade --verbose --file "${HOMEBREW_BUNDLE_FILE}" 2>&1 | sed -n 's/^→ *//p')
    warn "brew bundle did not complete — see the items above"
  elif [ "$BUNDLE_FAILED" -eq 1 ]; then
    warn "brew bundle failed although every Brewfile item is installed (an upgrade, most likely) — see its output above"
  fi
else
  warn "Brewfile not found at ${XDG_CONFIG_HOME}/homebrew/Brewfile — chezmoi apply deploys it"
fi

# ============================================================================
# 8b. NetBird's daemon
# ============================================================================
# The cask installs the binary; the system daemon is a separate step. Skipped when launchd
# already lists it. The sudo credential is the one step 0 cached.
# Every external command below reads /dev/null, so an unexpected prompt fails into its warning
# instead of hanging the unattended run.
if NETBIRD_STATE=$(launchctl print system/netbird 2>/dev/null </dev/null); then
  # Installed is not running: a daemon launchd lists without `state = running` is started.
  case "$NETBIRD_STATE" in
    *"state = running"*) log_info "✓ NetBird daemon already installed and running" ;;
    *) log_info "Starting the NetBird daemon..."
       sudo netbird service start </dev/null \
         || warn "NetBird daemon installed but not started — run: sudo netbird service start" ;;
  esac
else
  log_info "Installing the NetBird daemon..."
  { sudo netbird service install && sudo netbird service start; } </dev/null \
    || warn "NetBird daemon not installed or started — run: sudo netbird service install && sudo netbird service start"
fi

# ============================================================================
# 9. Reconcile AI agent plugins (Claude Code + Codex)
# ============================================================================
if [ -x "${SRC_DIR}/.scripts/reconcile-agents.sh" ]; then
  log_info "Reconciling AI agent plugins..."
  "${SRC_DIR}/.scripts/reconcile-agents.sh" \
    || warn "agent plugins: reconcile incomplete (its warnings are above) — re-run dotfiles-run reconcile-agents"
else
  log_warn "reconcile-agents.sh not found, skipping agent plugin setup"
fi

# ============================================================================
# 10. Set default shell to Homebrew zsh
# ============================================================================
log_info "Setting default shell to Homebrew zsh..."
# Never to a zsh that is not there: no new terminal could start.
if [ ! -x "${HOMEBREW_PREFIX}/bin/zsh" ]; then
  warn "Homebrew zsh is not installed, so the login shell stays ${SHELL} — run provision.sh again once the Brewfile is installed"
elif [[ "$SHELL" != "${HOMEBREW_PREFIX}/bin/zsh" ]]; then
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
  (cd "${XDG_DATA_HOME}/oh-my-zsh" && git pull)
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
# 12b. Neovim plugins and Herdr plugin links
# ============================================================================
log_info "Installing Neovim plugins, Mason's tools and the treesitter parsers..."
# A headless Neovim that quits aborts the installs LazyVim starts in the background, so
# nvim-finish-install.lua waits for them. Mason's Ruby tools need mise's Ruby, not macOS's,
# and the shims are on PATH only once zshenv is.
PATH="${XDG_DATA_HOME}/mise/shims:${PATH}" nvim --headless "+Lazy! install" \
  "+luafile ${SRC_DIR}/.scripts/nvim-finish-install.lua" "+cq 2" </dev/null \
  || warn "neovim: not everything installed (named above) — open nvim once: LazyVim installs what is missing at start"

# Herdr's TUI plugins are linked, not copied: ~/.config/herdr/plugin-* (chezmoi) and
# smart-splits.nvim's bundled one (lazy.nvim, installed by the install above). A plugin is
# linked only when `herdr plugin list` does not already show its [local:<dir>].
if HERDR_PLUGINS=$(herdr plugin list 2>&1 </dev/null); then
  for dir in "${XDG_CONFIG_HOME}"/herdr/plugin-*(N/) "${XDG_DATA_HOME}/nvim/lazy/smart-splits.nvim"; do
    [ -f "${dir}/herdr-plugin.toml" ] || continue
    case "$HERDR_PLUGINS" in
      *"[local:${dir}]"*) log_info "✓ herdr plugin already linked: ${dir}" ;;
      *) herdr plugin link "${dir}" </dev/null || warn "herdr plugin not linked — run: herdr plugin link ${dir}" ;;
    esac
  done
else
  warn "herdr plugins: could not list them — run: herdr plugin list, then herdr plugin link <folder> for each ~/.config/herdr/plugin-* and ~/.local/share/nvim/lazy/smart-splits.nvim"
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
# 17. Pin the Codex daemon to the CLI's package (fresh machines only)
# ============================================================================
# A pin restarts the daemon, which would interrupt a running review on a machine that has
# one, so only a machine with no daemon package is pinned; `codex-daemon-pin` in the
# checklist reports the rest. env -i, with the LaunchAgent's PATH and XDG variables: a
# daemon restarted from a Herdr pane keeps its HERDR_* variables and fails `codex-daemon check`.
if [ "$CODEX_FRESH" -eq 1 ]; then
  log_info "Pinning the Codex daemon to the CLI's package..."
  CODEX_PIN_CMD='codex app-server daemon update --from-cli --yes'
  if ! CODEX_BIN=$("${HOME}/.local/bin/codex-daemon" real-bin 2>/dev/null </dev/null) || [ -z "$CODEX_BIN" ]; then
    warn "codex daemon not pinned: codex-daemon real-bin found no codex — run: ${CODEX_PIN_CMD} (with the real codex, from a shell outside Herdr)"
  else
    # The update needs a selected package, which the daemon configure.sh's LaunchAgent started
    # selects on its own time (the third VM run pinned too early and failed).
    waited=0
    until [ -e "$DAEMON_CURRENT" ] || [ -L "$DAEMON_CURRENT" ] || [ "$waited" -ge 300 ]; do
      sleep 5; waited=$((waited + 5))
      [ $((waited % 60)) -eq 0 ] && log_info "  still waiting for the Codex daemon to select its package (${waited}s)"
    done
    if [ ! -e "$DAEMON_CURRENT" ] && [ ! -L "$DAEMON_CURRENT" ]; then
      warn "codex daemon not pinned: it selected no package within 5 minutes — check ~/.local/state/codex-daemon.log, then run: ${CODEX_PIN_CMD} (with the real codex, from a shell outside Herdr)"
    else
      # TMPDIR as launchd gives a daemon: the per-user temp directory, else the caller's.
      PIN_TMPDIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null </dev/null) || PIN_TMPDIR=""
      [ -n "$PIN_TMPDIR" ] || PIN_TMPDIR="${TMPDIR:-/tmp}"
      env -i HOME="${HOME}" USER="${USER}" LOGNAME="${LOGNAME:-${USER}}" SHELL="${SHELL}" TMPDIR="${PIN_TMPDIR}" \
        PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${HOMEBREW_PREFIX}/bin:${HOMEBREW_PREFIX}/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" XDG_DATA_HOME="${XDG_DATA_HOME}" \
        XDG_STATE_HOME="${XDG_STATE_HOME}" XDG_CACHE_HOME="${XDG_CACHE_HOME}" \
        "$CODEX_BIN" app-server daemon update --from-cli --yes </dev/null \
        || warn "codex daemon not pinned — run: ${CODEX_BIN} app-server daemon update --from-cli --yes (from a shell outside Herdr)"
    fi
  fi
else
  log_info "✓ Codex daemon package already present, not pinning"
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
# The checklist replaces the old hard-coded next steps: Borg, Alfred, Herdr and the rest are
# rows in it. Read-only; a row that is not done is not a failure of the run.
"${SRC_DIR}/.scripts/machine-check.sh" --todo --machine "${MACHINE_NAME}" </dev/null || true
log_info "Check again any time, from a new shell: dotfiles-run machine-check"
echo ""
log_info "Next steps:"
if [ -x "${HOMEBREW_PREFIX}/bin/zsh" ]; then
  log_info "  1. Restart your terminal or run: exec ${HOMEBREW_PREFIX}/bin/zsh"
else
  log_info "  1. Restart your terminal"
fi
log_info "  2. Verify chezmoi is using SSH: cd ~/.local/share/chezmoi && git remote -v"
log_info "  3. Test making changes: chezmoi edit ~/.zshrc"
log_info "  4. Some macOS settings may require a logout/restart to take effect"
echo ""
