#!/bin/bash
# Ancla metronome — launchd fires every 15 min; the script launches the overlay
# with variable cadence (~20-40 min, 60% of eligible fires, 20-min min-gap).
# Modes: breath (default) · body every 4th launch (stand/change alternating) ·
# test rep every 6th launch (prompt fading) · daily mission rides the first launch of the day.

STATE="$HOME/.local/state/movement-reminder.state"   # stand | reposition
COUNT="$HOME/.local/state/movement-count.state"      # total launches
STREAK="$HOME/.local/state/ancla-streak"             # "N YYYY-MM-DD"
MISSION="$HOME/.local/state/ancla-mission.txt"       # one line: today's field mission
MSHOWN="$HOME/.local/state/ancla-mission-shown"
LASTLAUNCH="$HOME/.local/state/ancla-lastlaunch"     # epoch of last actual launch
mkdir -p "$(dirname "$STATE")"

now=$(date +%s)
lastlaunch=$(cat "$LASTLAUNCH" 2>/dev/null || echo 0)

# variable cadence gate
gap=$((now - lastlaunch))
if [ "$gap" -lt 1200 ]; then exit 0; fi
if [ $((RANDOM % 100)) -ge 60 ]; then exit 0; fi
echo "$now" > "$LASTLAUNCH"

# streak (consecutive days with at least one rep)
today=$(date +%Y-%m-%d)
sline=$(cat "$STREAK" 2>/dev/null || echo "0 $today")
sn=$(echo "$sline" | cut -d' ' -f1)
sd=$(echo "$sline" | cut -d' ' -f2)
if [ "$sd" != "$today" ]; then
  if [ "$sd" = "$(date -v-1d +%Y-%m-%d)" ]; then sn=$((sn + 1)); else sn=1; fi
  echo "$sn $today" > "$STREAK"
fi

# launch counter → mode
n=$(cat "$COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$COUNT"

last=$(cat "$STATE" 2>/dev/null || echo "reposition")
mission=""

# daily mission: first launch of the day that has one set
if [ -s "$MISSION" ]; then
  mdate=$(cat "$MSHOWN" 2>/dev/null || echo none)
  if [ "$mdate" != "$today" ]; then
    mission=$(cat "$MISSION")
    echo "$today" > "$MSHOWN"
  fi
fi

if [ -n "$mission" ]; then
  mode="mission"
elif [ $((n % 6)) -eq 0 ]; then
  mode="test"
elif [ $((n % 4)) -eq 0 ]; then
  if [ "$last" = "stand" ]; then
    mode="change"
    echo "reposition" > "$STATE"
  else
    mode="stand"
    echo "stand" > "$STATE"
  fi
else
  mode="breath"
fi

open "$HOME/.local/bin/Ancla.app" --args "$mode" "$mission"
