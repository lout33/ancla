# Ancla ⚓

A native macOS menu bar app that interrupts you every ~20–40 minutes and **conducts a 15-second regulation cycle** — part body metronome, part nervous-system training for showing up calm in social moments.

> The two clocks: **projects fast, people slow.** One engine (urgency) wants to hurry both. Ancla is the governor — a machine whose only job is slowing you down on purpose, system-fired, zero willpower.

## The cycle (15 s, guided by a breathing circle)

1. **presiona** — thumb hard against the meñique (pinky). The anchor: an invisible, always-carried gesture
2. **exhala** — the circle deflates for 7 s; eyes follow the circle, lungs follow the eyes (long exhale > inhale = physiological sigh)
3. **ensancha** — the circle expands and the forest field surfaces; widen the gaze to the whole room, three things unrelated to the task
4. **gente, lento** — return to work at that tempo

**Why:** the exhale + peripheral-widen is the antidote to tunnel-vision fixation; the thumb-press is a proprioceptive cue the body can find faster than a thought. Practiced at the desk many times a day, the chain generalizes to real "doors" (a match goes quiet, a room feels slow, a date reaches the ramp, someone says *not yet*).

## Modes

| Mode | When | Shows |
|---|---|---|
| **breath** | most reps | circle + 🤏 |
| **stand / change** | every 4th rep, alternating | circle + 🤏 🧍 🚶 or 🤏 🔄 🪑 |
| **test** | every 6th rep | no guidance — *"haz el ciclo — tú diriges"* (prompt fading: the goal is the app becoming unnecessary) |
| **mission** | first rep of the day, if a mission is set | your one line on top of the cycle |

## Using it

Everything lives in the **⚓ menu bar item**:

- **Title** — `⚓ 12m` minutes since the last real rep · `⚓ ‖` paused · `⚓ !` something failed (open the menu to see what)
- **Status lines** — last rep, reps today, streak, and when the next rep is due (or "sale cuando vuelvas" if one is waiting for you)
- **Fuego ahora** — a rep right now
- **Pausar ▸** 30 min · 1 hora · 2 horas · hasta mañana (08:00) · hasta que reanude — resumes by itself, survives restarts
- **Ritmo ▸** corto 15–25 · normal 20–40 · largo 40–60 min
- **Misión de hoy…** — type one line; it rides the next rep
- **Ver log de reps / Ver eventos** — the CSV of reps and the diagnostic trail
- **Salir de Ancla** — stays quit until next login (or `launchctl kickstart gui/$(id -u)/com.pepe.ancla`)

On the overlay: **ESC or click** closes it (ignored for the first 1.5 s so a click in flight doesn't kill the rep).

CLI (for agents and testing):

```bash
ancla status              # schedule, counters, failures; exit 1 if the app isn't running
ancla fire                # rep now in the running app
ancla preview [mode] [text]   # one overlay, touches no state
```

## Reliability rules

- **A rep counts only once it is on screen.** Counters, streak and the CSV are written after the window is visible, never before.
- **Due while you're away → it waits.** Idle > 2 min or screen locked: the rep stays pending and fires when you come back. After login or wake it waits 60 s to settle.
- **Failures are loud.** Every decision (shown, waiting, paused, woke, failed) goes to `ancla-events.log`. If the process dies mid-rep, launchd restarts it, the menu shows `⚓ !`, and the next attempt waits a full interval so a crash can't loop.
- **One instance, no stale locks.** Singleton via `flock`, released by the kernel when the process dies.
- **All screens** are covered; the cycle is drawn on the screen with the mouse.

## Architecture

```
launchd (com.pepe.ancla: RunAtLoad, KeepAlive on crash only)
  └─ ~/.local/bin/Ancla.app            one process, menu bar only (LSUIElement)
       src/main.swift       entry: app | fire | preview | status; flock singleton
       src/Scheduler.swift  cadence, idle-wait, wake, pause, mode rules, crash detection
       src/Overlay.swift    full-screen panels at .screenSaver level, the 15 s cycle
       src/MenuBar.swift    ⚓ status item and menu
       src/Store.swift      state (JSON), rep CSV, event log
```

State in `~/.local/state/`: `ancla.json` (schedule + counters), `ancla-log.csv` (one row per rep: time, mode, completo / cerrado con esc|clic a los Ns), `ancla-events.log` (diagnostics), `ancla-mission.txt`.

No permissions, no dependencies.

## Install

```bash
./install.sh     # build, install to ~/.local/bin, load the LaunchAgent; safe to rerun
./build.sh       # build only → build/Ancla.app
```

`install.sh` retires the v1 pieces (script metronome `com.pepe.movement`, separate `AnclaBar`) by moving them to `~/.local/state/ancla-retired/` — never deletes. v1 sources are kept in `legacy/`.

## Design principles

1. **The circle is the instruction.** Words compete with the breath; the breath is the interface.
2. **No autoregulation — pre-decisions.** The moment only executes what calm-you decided. (Same law as the fleet: Luis-discipline dies, systems survive.)
3. **System-fired, not Luis-discipline.** The metronome lives in launchd, not in memory or motivation.
4. **Prompt fading.** Every 6th rep is unguided; success metric = the app stops being needed.
5. **Rejection list:** sound design, phone sync, dashboards, "smart" timing — system-building costumes.

## History

- **v1 (2026-09-20)** — bash metronome under launchd + separate overlay app + separate menu bar app. Built as the regulation layer for the romance two-clocks work (see `../../projects/people/practice/romance-fundamentals.md`).
- **2026-09-21 → 09-27** — commit `65fb2f1` dropped the view stack from the hierarchy; every overlay crashed at launch for 6 days while the log, counter and streak still counted each one. Nobody could tell. Fixed in `e3d20f1`.
- **v2 (2026-09-27)** — one menu bar app that owns the cadence, counts only what reached the screen, waits for you instead of skipping, and makes failures visible.
