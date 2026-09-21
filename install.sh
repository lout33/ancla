#!/bin/bash
# Install the Ancla metronome + menu bar indicator on this Mac.
# Usage: ./install.sh
set -e
cd "$(dirname "$0")"

mkdir -p build "$HOME/.local/bin" "$HOME/.local/state" "$HOME/Library/LaunchAgents"

# --- overlay app ---
swiftc -O src/Ancla.swift -o build/ancla
APP=build/Ancla.app
mkdir -p "$APP/Contents/MacOS"
cp build/ancla "$APP/Contents/MacOS/Ancla"
cp resources/Ancla-Info.plist "$APP/Contents/Info.plist"
rm -rf "$HOME/.local/bin/Ancla.app"
cp -R build/Ancla.app "$HOME/.local/bin/Ancla.app"

# --- menu bar indicator ---
swiftc -O src/AnclaBar.swift -o build/AnclaBar
BAR=build/AnclaBar.app
mkdir -p "$BAR/Contents/MacOS"
cp build/AnclaBar "$BAR/Contents/MacOS/AnclaBar"
cp resources/AnclaBar-Info.plist "$BAR/Contents/Info.plist"
rm -rf "$HOME/.local/bin/AnclaBar.app"
cp -R build/AnclaBar.app "$HOME/.local/bin/AnclaBar.app"

# --- metronome script ---
cp scripts/movement-reminder.sh "$HOME/.local/bin/movement-reminder.sh"
chmod +x "$HOME/.local/bin/movement-reminder.sh"

# --- launchd agents (generated with real $HOME — portable) ---
cat > "$HOME/Library/LaunchAgents/com.pepe.movement.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.pepe.movement</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HOME/.local/bin/movement-reminder.sh</string>
    </array>
    <key>StartInterval</key><integer>900</integer>
    <key>RunAtLoad</key><false/>
</dict>
</plist>
EOF

cat > "$HOME/Library/LaunchAgents/com.pepe.anclabar.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.pepe.anclabar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/.local/bin/AnclaBar.app/Contents/MacOS/AnclaBar</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF

launchctl unload "$HOME/Library/LaunchAgents/com.pepe.movement.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.pepe.movement.plist"
launchctl unload "$HOME/Library/LaunchAgents/com.pepe.anclabar.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.pepe.anclabar.plist"

echo "installed ✓"
echo "  interval:        $(plutil -extract StartInterval raw "$HOME/Library/LaunchAgents/com.pepe.movement.plist")s (fires) → overlay cada ~20-40 min"
echo "  test now:        launchctl kickstart gui/\$(id -u)/com.pepe.movement"
echo "  pause/resume:    menu bar ⚓ → Pausar/Reanudar (o launchctl unload/load com.pepe.movement)"
echo "  daily mission:   echo 'tu mision' > ~/.local/state/ancla-mission.txt"
