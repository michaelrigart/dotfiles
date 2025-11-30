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
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# ============================================================================
# Set Hostname
# ============================================================================
while [[ ! $answer = 'y' ]]; do
    echo -n 'Enter the hostname: '
    read HOSTNAME

    echo -n "You have entered $HOSTNAME, is this correct (y/n)? "
    read answer
done

log_info "Setting hostname to $HOSTNAME..."
if ! scutil --get ComputerName | grep -q "$HOSTNAME" 2>/dev/null; then
  sudo scutil --set ComputerName "$HOSTNAME"
fi
if ! scutil --get HostName | grep -q "$HOSTNAME" 2>/dev/null; then
  sudo scutil --set HostName "$HOSTNAME"
fi
if ! scutil --get LocalHostName | grep -q "$HOSTNAME" 2>/dev/null; then
  sudo scutil --set LocalHostName "$HOSTNAME"
fi
log_info "✓ Hostname set to $HOSTNAME"

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
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
defaults write NSGlobalDomain com.apple.mouse.tapBehavior -int 1

# Trackpad: enable three finger drag
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag -bool true
defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag -bool true

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
defaults write com.apple.menuextra.battery ShowPercent -string "YES"

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
