#!/bin/zsh
# Install Overflow: archive script + config, weekly launchd job, and the menu bar app.
# Re-running is safe; it upgrades in place and keeps your config.zsh.
set -e
cd "$(dirname "$0")"
SUPPORT="$HOME/Library/Application Support/Overflow"
LABEL=com.overflow.archive
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="/Applications/Overflow Monitor.app"

echo "→ script and config"
mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp bin/overflow-archive.sh "$SUPPORT/overflow-archive.sh"; chmod +x "$SUPPORT/overflow-archive.sh"
if [[ ! -f "$SUPPORT/config.zsh" ]]; then cp config.example.zsh "$SUPPORT/config.zsh"; echo "  created $SUPPORT/config.zsh (edit it to pick your sources)"; fi

echo "→ overflow volume"
DEST=$(zsh "$SUPPORT/overflow-archive.sh" --print-config | awk -F= '/^DEST=/{print $2}')
if [[ -d "$DEST" ]]; then
  [[ -f "$DEST/.overflow-stick" ]] || { touch "$DEST/.overflow-stick"; echo "  marked $DEST as the overflow volume"; }
else
  echo "  $DEST is not mounted; plug in the drive and run install.sh again (or just create $DEST/.overflow-stick later)"
fi

echo "→ weekly job (Sundays 03:00)"
if [[ "${SKIP_LAUNCHD:-0}" != 1 ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  # legacy label from the pre-packaged version
  launchctl bootout "gui/$(id -u)/com.dmarantz.archive-to-overflow" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.dmarantz.archive-to-overflow.plist"
  sed "s|__HOME__|$HOME|g" launchd/com.overflow.archive.plist > "$PLIST"
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "  loaded $LABEL"
else
  echo "  skipped (SKIP_LAUNCHD=1)"
fi

echo "→ menu bar app"
zsh app/build.sh

echo
echo "Done. Open the Overflow Monitor menu (near the clock) and turn on “Start at login”."
echo "Preview a run any time:   zsh \"$SUPPORT/overflow-archive.sh\""
