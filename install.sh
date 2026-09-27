#!/bin/bash
# Install (or reinstall) Ancla on this Mac. Safe to run repeatedly.
# Usage: ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

LABEL=com.pepe.ancla
UID_NUM=$(id -u)
BIN="$HOME/.local/bin"
STATE="$HOME/.local/state"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
RETIRED="$STATE/ancla-retired"

./build.sh
mkdir -p "$BIN" "$STATE" "$AGENTS"

# --- retire the v1 pieces (script metronome + separate menu bar app) ---
# Moved aside, never deleted.
retire() {
  local src=$1
  if [ -e "$src" ]; then
    mkdir -p "$RETIRED"
    local dest="$RETIRED/$(basename "$src")"
    [ -e "$dest" ] && dest="$dest.$(date +%Y%m%d%H%M%S)"
    mv "$src" "$dest"
    echo "  retired $src → $dest"
  fi
}
for old in com.pepe.movement com.pepe.anclabar; do
  launchctl bootout "gui/$UID_NUM/$old" 2>/dev/null || true
  retire "$AGENTS/$old.plist"
done
retire "$BIN/AnclaBar.app"
retire "$BIN/movement-reminder.sh"
retire "$BIN/Ancla.swift"
# v1 installed the overlay as a bare binary; v2 installs a wrapper script here.
if [ -f "$BIN/ancla" ] && ! grep -q "Ancla.app/Contents/MacOS/Ancla" "$BIN/ancla" 2>/dev/null; then
  retire "$BIN/ancla"
fi

# --- stop the running app, swap the bundle ---
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
rm -rf "$BIN/Ancla.app"
cp -R build/Ancla.app "$BIN/Ancla.app"

cat > "$BIN/ancla" <<EOF
#!/bin/bash
exec "$BIN/Ancla.app/Contents/MacOS/Ancla" "\$@"
EOF
chmod +x "$BIN/ancla"

# --- LaunchAgent: start at login, restart on crash, stay quit after "Salir" ---
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN/Ancla.app/Contents/MacOS/Ancla</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$STATE/ancla-stdout.log</string>
    <key>StandardErrorPath</key><string>$STATE/ancla-stderr.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null

# bootout finishes asynchronously; retry bootstrap until launchd lets go.
for _ in $(seq 1 20); do
  if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then break; fi
  sleep 0.5
done
launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || { echo "failed to load $LABEL" >&2; exit 1; }

sleep 1
echo "installed ✓"
"$BIN/ancla" status || true
echo
echo "  menu bar ⚓ → fuego ahora · pausar · ritmo · misión · logs"
echo "  cli:         ancla fire | ancla preview [mode] | ancla status"
echo "  diagnostics: $STATE/ancla-events.log"
