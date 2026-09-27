#!/bin/bash
# Stop Ancla and remove it from this Mac. Your rep data is kept by default.
# Usage: ./uninstall.sh [--purge]   # --purge also deletes ~/.local/state/ancla*
set -euo pipefail

LABEL=com.pepe.ancla
UID_NUM=$(id -u)
BIN="$HOME/.local/bin"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$BIN/Ancla.app"
rm -f "$BIN/ancla"

echo "uninstalled ✓"
if [ "${1:-}" = "--purge" ]; then
  rm -f "$HOME/.local/state/ancla.json" \
        "$HOME/.local/state/ancla-log.csv" \
        "$HOME/.local/state/ancla-events.log" \
        "$HOME/.local/state/ancla-mission.txt" \
        "$HOME/.local/state/ancla-mission-shown" \
        "$HOME/.local/state/ancla.lock" \
        "$HOME/.local/state/ancla-stdout.log" \
        "$HOME/.local/state/ancla-stderr.log"
  echo "  state purged"
else
  echo "  kept your data in ~/.local/state (ancla.json, ancla-log.csv, ancla-events.log, ancla-mission.txt)"
  echo "  delete it with: ./uninstall.sh --purge"
fi
