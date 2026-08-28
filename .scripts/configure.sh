#!/usr/bin/env zsh
# macOS System Configuration Script
# Based on: https://github.com/drduh/macOS-Security-and-Privacy-Guide

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo "${RED}[ERROR]${NC} $1"; }

echo ""
log_info "========== macOS System Configuration =========="
echo ""

# Ask for sudo password upfront and keep alive
# --hostname <name>: driven by provision.sh, which already owns the identity. In that
# mode this script VERIFIES and never renames — it is invoked after preflight, so a
# rename here would be a machine change nobody confirmed.
HOSTNAME_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) shift; HOSTNAME_ARG="$1" ;;
    *) log_error "unknown option: $1"; exit 2 ;;
  esac
  shift
done

sudo -v
# stdout closed as well as stderr: a background loop holding stdout hangs any caller
# capturing this script's output with $( ).
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done >/dev/null 2>&1 &

# ============================================================================
# Set Hostname
# ============================================================================
if [ -n "$HOSTNAME_ARG" ]; then
  HOSTNAME="$HOSTNAME_ARG"
  # All three, not just ComputerName: HostName drives hostname(1) and Borg archive
  # naming, so checking only the first would let the Borg-critical field drift.
  if [ "$(scutil --get ComputerName)" != "$HOSTNAME" ]; then
    log_error "ComputerName is '$(scutil --get ComputerName)' but --hostname says '${HOSTNAME}'"
    exit 1
  fi
  if [ "$(scutil --get HostName)" != "$HOSTNAME" ]; then
    log_error "HostName is '$(scutil --get HostName)' but --hostname says '${HOSTNAME}'"
    exit 1
  fi
  case "$(scutil --get LocalHostName)" in
    "$HOSTNAME"|"$HOSTNAME"-<->) ;;
    *) log_error "LocalHostName is '$(scutil --get LocalHostName)', expected ${HOSTNAME} or ${HOSTNAME}-N"; exit 1 ;;
  esac
  log_info "✓ identity verified: ${HOSTNAME}"
else
  while true; do
    echo -n "Enter the hostname for this machine: "
    read HOSTNAME
    echo -n "You have entered $HOSTNAME, is this correct (y/n)? "
    read answer
    case "$answer" in y|Y) break ;; esac
  done
  log_info "Setting hostname to $HOSTNAME..."
  # Exact comparison: the old `grep -q` substring match treated "hercules" as already
  # set on a machine named "hercules-2".
  [ "$(scutil --get ComputerName)"  = "$HOSTNAME" ] || sudo scutil --set ComputerName  "$HOSTNAME"
  [ "$(scutil --get HostName)"      = "$HOSTNAME" ] || sudo scutil --set HostName      "$HOSTNAME"
  [ "$(scutil --get LocalHostName)" = "$HOSTNAME" ] || sudo scutil --set LocalHostName "$HOSTNAME"
  log_info "✓ Hostname set to $HOSTNAME"
fi

# ============================================================================
# Security Settings
# ============================================================================
log_info "Checking System Integrity Protection status..."
csrutil status

log_info "Enabling FileVault (if not already enabled)..."
if fdesetup status | grep -q "FileVault is Off"; then
  log_warn "FileVault is disabled. Enable it in System Settings > Privacy & Security"
else
  log_info "✓ FileVault is enabled"
fi

log_info "Enabling Firewall..."
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
log_info "✓ Firewall enabled"

# ============================================================================
# Keyboard Settings
# ============================================================================
log_info "Configuring keyboard settings..."
defaults write NSGlobalDomain InitialKeyRepeat -int 15
defaults write NSGlobalDomain KeyRepeat -int 2
log_info "✓ Keyboard repeat rate increased"

# ============================================================================
# Dock Settings
# ============================================================================
log_info "Configuring Dock..."
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock tilesize -int 25
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.dock minimize-to-application -bool true
log_info "✓ Dock configured (autohide, smaller icons, no recents)"

# ============================================================================
# Finder Settings
# ============================================================================
log_info "Configuring Finder..."

# Start in home directory
defaults write com.apple.finder NewWindowTarget -string 'PfHm'
defaults write com.apple.finder NewWindowTargetPath -string "file://${HOME}/"

# Show all file extensions
defaults write NSGlobalDomain AppleShowAllExtensions -bool true

# Show hidden files
defaults write com.apple.finder AppleShowAllFiles -bool true

# Show path bar
defaults write com.apple.finder ShowPathbar -bool true

# Show status bar
defaults write com.apple.finder ShowStatusBar -bool true

# Unhide ~/Library folder
chflags nohidden ~/Library

# Show full path in Finder title
defaults write com.apple.finder _FXShowPosixPathInTitle -bool true

# Avoid creating .DS_Store files on network or USB volumes
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true

# Use list view in all Finder windows by default
defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"

log_info "✓ Finder configured"

# ============================================================================
# Screenshots
# ============================================================================
log_info "Configuring screenshot settings..."

# Create Screenshots directory if it doesn't exist
mkdir -p "${HOME}/Pictures/Screenshots"

# Save screenshots to ~/Pictures/Screenshots
defaults write com.apple.screencapture location -string "${HOME}/Pictures/Screenshots"

# Save screenshots in PNG format (other options: BMP, GIF, JPG, PDF, TIFF)
defaults write com.apple.screencapture type -string "png"

# Disable shadow in screenshots
defaults write com.apple.screencapture disable-shadow -bool true

log_info "✓ Screenshots will be saved to ~/Pictures/Screenshots"

# ============================================================================
# Trackpad & Mouse Settings
# ============================================================================
log_info "Configuring trackpad and mouse..."

# Enable tap to click for this user and for the login screen
if [ "$HOSTNAME" = "fenrir" ]; then
  defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
  defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
  defaults write NSGlobalDomain com.apple.mouse.tapBehavior -int 1

  # Trackpad: enable three finger drag
  defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag -bool true
  defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag -bool true
fi

log_info "✓ Trackpad configured"

# ============================================================================
# Safari & Privacy Settings
# ============================================================================
log_info "Configuring Safari privacy settings..."

# Note: Safari settings may not work due to sandboxing in modern macOS
# These settings should be configured manually in Safari preferences
log_warn "Safari settings must be configured manually due to app sandboxing:"
log_warn "  - Disable search suggestions in Safari > Settings > Search"
log_warn "  - Enable Develop menu in Safari > Settings > Advanced"

# These will only work if Safari is not sandboxed (unlikely in modern macOS)
# defaults write com.apple.Safari UniversalSearchEnabled -bool false 2>/dev/null || true
# defaults write com.apple.Safari SuppressSearchSuggestions -bool true 2>/dev/null || true
# defaults write com.apple.Safari IncludeDevelopMenu -bool true 2>/dev/null || true

log_info "✓ Safari configuration noted (manual setup required)"

# ============================================================================
# Activity Monitor
# ============================================================================
log_info "Configuring Activity Monitor..."

# Show the main window when launching Activity Monitor
defaults write com.apple.ActivityMonitor OpenMainWindow -bool true

# Show all processes in Activity Monitor
defaults write com.apple.ActivityMonitor ShowCategory -int 0

# Sort Activity Monitor results by CPU usage
defaults write com.apple.ActivityMonitor SortColumn -string "CPUUsage"
defaults write com.apple.ActivityMonitor SortDirection -int 0

log_info "✓ Activity Monitor configured"

# ============================================================================
# Time Machine
# ============================================================================
log_info "Configuring Time Machine..."

# Prevent Time Machine from prompting to use new hard drives as backup volume
defaults write com.apple.TimeMachine DoNotOfferNewDisksForBackup -bool true

log_info "✓ Time Machine configured"

# ============================================================================
# Text & Input
# ============================================================================
log_info "Configuring text input..."

# Disable auto-correct
defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false

# Disable automatic capitalization
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false

# Disable smart dashes
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false

# Disable automatic period substitution
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false

# Disable smart quotes
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false

log_info "✓ Text input configured"

# ============================================================================
# Menu Bar
# ============================================================================
log_info "Configuring menu bar..."

# Show battery percentage
[ "$HOSTNAME" = "fenrir" ] && defaults write com.apple.menuextra.battery ShowPercent -string "YES"

# Show date and time in menu bar
defaults write com.apple.menuextra.clock DateFormat -string "EEE MMM d  h:mm a"
defaults write com.apple.menuextra.clock Show24Hour -bool false
defaults write com.apple.menuextra.clock ShowDate -int 1

log_info "✓ Menu bar configured"

# ============================================================================
# Install Desktop Backgrounds
# ============================================================================
log_info "Installing desktop backgrounds..."

# Create Pictures/Backgrounds directory if it doesn't exist
mkdir -p "${HOME}/Pictures/Backgrounds"

# Copy backgrounds from chezmoi repo if they exist
if [ -d "${XDG_DATA_HOME}/chezmoi/.backgrounds" ]; then
  cp -r "${XDG_DATA_HOME}/chezmoi/.backgrounds/"* "${HOME}/Pictures/Backgrounds/" 2>/dev/null || true
  log_info "✓ Backgrounds copied to ~/Pictures/Backgrounds"

  # Set desktop wallpaper (you can change which image to use)
  # This sets it for the current desktop space
  if [ -f "${HOME}/Pictures/Backgrounds/skyline-appartment.png" ]; then
    osascript -e "tell application \"System Events\" to tell every desktop to set picture to \"${HOME}/Pictures/Backgrounds/skyline-appartment.png\""
    log_info "✓ Desktop wallpaper set to skyline-appartment.png"
  fi
else
  log_warn "Backgrounds directory not found in chezmoi repo"
fi

# ============================================================================
# Alfred Snippets (cross-model relay tags)
# ============================================================================
log_info "Configuring Alfred snippet auto-expansion..."

# The relay snippet COLLECTION is chezmoi-managed (Library/Application Support/Alfred/...),
# but the switch that makes it fire is not: Alfred stores autoExpandSnippets under
# preferences/local/<localhash>/, and that hash is machine-specific. Tracking the path
# literally would apply on this Mac and silently no-op on the next one — the snippets would
# land, the toggle would not, and `;codex` would quietly do nothing. So it is computed here.
alfred_prefs_json="${HOME}/Library/Application Support/Alfred/prefs.json"
if [[ -f "$alfred_prefs_json" ]]; then
  alfred_localhash=$(sed -n 's/.*"localhash" *: *"\([^"]*\)".*/\1/p' "$alfred_prefs_json")
  if [[ -n "$alfred_localhash" ]]; then
    alfred_clip_prefs="${HOME}/Library/Application Support/Alfred/Alfred.alfredpreferences/preferences/local/${alfred_localhash}/features/clipboard/prefs.plist"

    # Order matters, and not for tidiness: while Alfred is running it owns these prefs and
    # `defaults write` is silently discarded — it reports success, and both the file and the
    # cache keep their old value. Alfred must be stopped BEFORE the write.
    alfred_was_running=false
    if pgrep -x "Alfred" &> /dev/null; then
      alfred_was_running=true
      osascript -e 'tell application "Alfred 5" to quit' &> /dev/null || true
      sleep 2
    fi

    mkdir -p "$(dirname "$alfred_clip_prefs")"
    defaults write "${alfred_clip_prefs%.plist}" autoExpandSnippets -bool true

    # Alfred indexes a file added to a collection it already knows about live, but discovers
    # a NEW collection directory only on launch. After a fresh `chezmoi apply` it must be
    # (re)started or the Relay snippets exist on disk and in no index.
    if [[ "$alfred_was_running" == true ]]; then
      open -a "Alfred 5" &> /dev/null || true
      log_info "Alfred restarted to apply the toggle and index snippet collections"
    else
      log_warn "Alfred is not running — launch it to index the relay snippets"
    fi
  else
    log_warn "Could not read Alfred localhash — enable snippet auto-expansion manually"
  fi
else
  log_warn "Alfred has not been launched yet — re-run this script after first launch"
fi

# ============================================================================
# Apply Changes
# ============================================================================
log_info "Applying changes..."

# Restart affected applications
for app in "Dock" "Finder" "SystemUIServer"; do
  killall "$app" &> /dev/null || true
done

echo ""
log_info "=========================================="
log_info "✓ macOS configuration complete!"
log_info "=========================================="
echo ""
log_warn "Manual tasks still required:"
log_warn "  1. Configure Spotlight privacy settings (System Settings > Siri & Spotlight)"
log_warn "  2. Review Privacy & Security settings (System Settings > Privacy & Security)"
log_warn "  3. Configure Little Snitch rules"
log_warn "  4. Sign in to applications (1Password, browsers, etc.)"
log_warn "  5. Some settings may require a logout/restart to take full effect"
echo ""
log_info "Consider restarting your Mac to ensure all settings are applied."
echo ""
