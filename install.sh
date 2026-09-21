#!/bin/bash
# Install the Ancla metronome on this Mac (compiles, bundles, installs, loads).
# Usage: ./install.sh
set -e
cd "$(dirname "$0")"

./build.sh

mkdir -p "$HOME/.local/bin" "$HOME/.local/state"
cp build/ancla "$HOME/.local/bin/ancla"
rm -rf "$HOME/.local/bin/Ancla.app"
cp -R build/Ancla.app "$HOME/.local/bin/Ancla.app"
cp scripts/movement-reminder.sh "$HOME/.local/bin/movement-reminder.sh"
chmod +x "$HOME/.local/bin/movement-reminder.sh"

cp resources/com.pepe.movement.plist ~/Library/LaunchAgents/com.pepe.movement.plist
launchctl unload ~/Library/LaunchAgents/com.pepe.movement.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.pepe.movement.plist

echo "installed. interval: $(plutil -extract StartInterval raw ~/Library/LaunchAgents/com.pepe.movement.plist)s"
echo "test now:          launchctl kickstart gui/\$(id -u)/com.pepe.movement"
echo "pause:             launchctl unload ~/Library/LaunchAgents/com.pepe.movement.plist"
echo "daily mission:     echo 'tu mision' > ~/.local/state/ancla-mission.txt"
