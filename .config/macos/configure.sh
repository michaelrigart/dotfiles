#!/usr/bin/env zsh

while [[ ! $answer = 'y' ]]; do
    echo -n 'Enter the hostname: '
    read HOSTNAME

    echo -n "You have entered $HOSTNAME, is this correct (y/n)? "
    read answer
done

echo '========== Set hostname =========='
if ! scutil --get ComputerName | grep $HOSTNAME > /dev/null 2>&1; then
  scutil --set ComputerName $HOSTNAME
fi
if ! scutil --get HostName | grep $HOSTNAME > /dev/null 2>&1; then
  scutil --set HostName $HOSTNAME
fi
if ! scutil --get LocalHostName | grep $HOSTNAME > /dev/null 2>&1; then
  scutil --set LocalHostName $HOSTNAME
fi

echo '========== Check if System Integrity is enabled =========='
csrutil status

echo '========== Disble some LaunchAgents =========='
launchctl remove /System/Library/LaunchAgents/com.apple.gamed.plist
launchctl remove /System/Library/LaunchAgents/com.apple.touristd.plist
launchctl remove /System/Library/LaunchAgents/com.apple.security.keychainsyncingoveridsproxy.plist
launchctl remove /System/Library/LaunchAgents/com.apple.CallHistorySyncHelper.plist
launchctl remove /System/Library/LaunchAgents/com.apple.syncdefaultsd.plist
launchctl remove /System/Library/LaunchAgents/com.apple.CalendarAgent.plist
launchctl remove /System/Library/LaunchAgents/com.apple.AddressBook.SourceSync.plist

echo '========== Increase keyboard speed =========='
defaults write NSGlobalDomain InitialKeyRepeat -int 15
defaults write NSGlobalDomain KeyRepeat -int 2

echo '========== Autohide dock and decrease tilesize =========='
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock tilesize -int 25

echo '========== Start Find in home directory =========='
defaults write com.apple.finder NewWindowTarget -string 'PfHm'
defaults write com.apple.finder NewWindowTargetPath -string "file://${HOME}/"

echo '========== Show battery percentage next to icon =========='
defaults write com.apple.menuextra.battery ShowPercent -string "YES"

echo '========== DO NOT FORGET =========='
echo ' ---- Set Spotlight preferences'
echo ' ---- Delete Game Center account'
echo ' ---- Disable iCloud services except Find My Mac'
echo ' ---- Configure TimeMachine'
