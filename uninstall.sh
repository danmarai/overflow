#!/bin/zsh
# Remove Overflow. Archived data on the external volume is left untouched.
LABEL=com.overflow.archive
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -x OverflowMonitor 2>/dev/null || true
rm -rf "/Applications/Overflow Monitor.app"
rm -rf "$HOME/Library/Application Support/Overflow"
echo "Removed. Symlinks to archived folders still point at the external volume;"
echo "restore any folder with:  rm <symlink>; rsync -a '/Volumes/Overflow/<path>/' ~/<path>/"
