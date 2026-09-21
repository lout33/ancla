# Ancla ⚓

A native macOS overlay that interrupts you every ~30 minutes and **conducts a 15-second regulation cycle** — part body metronome, part nervous-system training for showing up calm in social moments.

> The two clocks: **projects fast, people slow.** One engine (urgency) wants to hurry both. Ancla is the governor — a machine whose only job is slowing you down on purpose, system-fired, zero willpower.

## The cycle (15 s, guided by a breathing circle)

1. **presiona** — thumb hard against the meñique (pinky). The anchor: an invisible, always-carried gesture
2. **exhala** — the circle deflates for 7 s; eyes follow the circle, lungs follow the eyes (long exhale > inhale = physiological sigh)
3. **ensancha** — the circle expands; widen the gaze to the whole room, three things unrelated to the task
4. **gente, lento** — return to work at that tempo

**Why:** the exhale + peripheral-widen is the antidote to tunnel-vision fixation; the thumb-press is a proprioceptive cue the body can find faster than a thought. Practiced at the desk ~48×/day, the chain generalizes to real "doors" (a match goes quiet, a room feels slow, a date reaches the ramp, someone says *not yet*).

## The two screens

| Screen | When | Shows |
|---|---|---|
| **1 — breath** | most fires | circle + 🤏 |
| **2 — body** | every 4th fire (~2 h) | circle + 🤏 🧍 🚶 (stand+walk) or 🤏 🔄 🪑 (change position), alternating |

Special modes: **test rep** (every 6th launch — no guidance, *"haz el ciclo — tú diriges"*; prompt fading: the goal is the app becoming unnecessary) and **daily mission** (first launch of the day surfaces one line from `~/.local/state/ancla-mission.txt`).

## Cadence

`launchd` fires every 15 min; the script gates launches (~60% of fires, 20-min minimum gap) → **variable ~20–40 min**. Variable intervals resist habituation; fixed ones go invisible. Idle > 2 min → skip (nobody at the desk). Singleton lockfile → never two overlays.

## Architecture

```
launchd (com.pepe.movement, StartInterval 900)
  └─ scripts/movement-reminder.sh        # cadence gate, streak, mission, mode selection
       └─ open ~/.local/bin/Ancla.app    # LaunchServices-detached native app
            └─ src/Ancla.swift           # full-screen overlay, level .screenSaver, all Spaces

launchd (com.pepe.anclabar, KeepAlive)   # always-on menu bar indicator
  └─ src/AnclaBar.swift                  # ⚓ + minutes since last rep; menu:
                                         #   fuego ahora · pausar/reanudar · misión · log · salir
```

- **Window:** borderless, `level = .screenSaver` (above fullscreen apps), `canJoinAllSpaces + fullScreenAuxiliary` (any Space) — the properties osascript alerts don't have
- **No permissions, no dependencies** — one Swift file, ~57 KB binary
- **State** (`~/.local/state/`): rep counter (daily), streak, lockfile, last-launch, mission, CSV log (`ancla-log.csv`) for weekly review

## Install / uninstall

```bash
./install.sh          # build + install + load agent
launchctl kickstart gui/$(id -u)/com.pepe.movement   # test now
launchctl unload ~/Library/LaunchAgents/com.pepe.movement.plist   # pause
launchctl load ~/Library/LaunchAgents/com.pepe.movement.plist     # resume
plutil -replace StartInterval -integer 1800 ~/Library/LaunchAgents/com.pepe.movement.plist  # change interval
```

## Design principles

1. **The circle is the instruction.** Words compete with the breath; the breath is the interface.
2. **No autoregulation — pre-decisions.** The moment only executes what calm-you decided. (Same law as the fleet: Luis-discipline dies, systems survive.)
3. **System-fired, not Luis-discipline.** The metronome lives in launchd, not in memory or motivation.
4. **Prompt fading.** Every 6th rep is unguided; success metric = the app stops being needed.
5. **Rejection list:** sound design, phone sync, dashboards, "smart" timing — system-building costumes.

## Origin

Built 2026-09-20 as the regulation layer for the romance two-clocks work (see `../../projects/people/practice/romance-fundamentals.md` — the anchor chain, the four doors, the inverted-timing loop). The body rep merged the pre-existing `com.pepe.movement` stand-up habit; the breath rep carries the anchor training.
