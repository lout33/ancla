# Changelog

All notable changes to Ancla are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Optional morning + night 5-minute sits (off by default): breathing circle,
  space to mark a return, one word at the end. Morning = first return after
  5 h or more away (05:00–14:00); night = 00:30, waits until 02:00; misses
  are logged, never fired late.
- Practice log (`~/.local/state/ancla-practice.csv`): sits, training, live
  reps. Menu: Log ▸ training…, live rep…, view; training-this-week line.
- If-then lines (`~/.local/state/ancla-ifthens.txt`) rotate through reps as
  the intention, titled "practice".
- CLI: `ancla sit`, `ancla sits on|off`, `ancla rhythm`, `ancla log`.

### Changed
- Clicks close a rep only after 5 s (ESC still 1.5 s): in practice most reps
  were closed by a reflex click within 2 s.

## [2.0] — 2026-09-27

A complete re-architecture: one menu bar app owns the cadence end to end.
Built after six days of undetected launch crashes in 1.1 (see History below).

### Added
- In-process scheduler: variable 20–40 min cadence (rhythm presets: 15–25,
  20–40, 40–60 min); a rep due while away (idle > 2 min or screen locked)
  waits for your return; 60 s settle after login and wake.
- Reps count only once the overlay is actually on screen; the CSV records
  `completed` or `closed with esc|click at Ns`.
- Crash detection: a mid-rep crash is caught on restart, the menu bar shows
  `⚓ !`, and the retry waits a full interval so a crash can't loop.
- Pause persisted to disk (30 min / 1 hour / 2 hours / until 08:00 / until
  resumed) with automatic resume; survives app restarts.
- Every scheduling decision logged to `~/.local/state/ancla-events.log`.
- CLI: `ancla status` (exit 1 when not running), `ancla fire`, `ancla preview`.
- Media pause: Now Playing audio/video pauses during a rep and resumes after —
  only what Ancla itself paused.
- One random intention per rep: understand · connect · express clearly ·
  set a boundary · enjoy the moment.
- Overlay on every connected screen; takes keyboard focus (ESC works) and
  returns focus to the previous app; 1.5 s grace against stray clicks.

### Changed
- macOS UI language is now English (the name and the origin story stay Spanish).
- Singleton via `flock` — released by the kernel on death, so a stale lock
  can never block the overlay.

### Removed
- The launchd bash metronome, the separate AnclaBar app, PID-lockfiles and
  the force-flag file. `install.sh` retires all v1 pieces by moving them to
  `~/.local/state/ancla-retired/`.

## [1.1] — 2026-09-21

Last release of the three-piece architecture (launchd bash metronome +
overlay app + menu bar app). Known broken from 13:31 this day: a regression
made the overlay crash on every launch while the log, counter and streak
still counted each one. Fixed in 2.0's rewrite.

## [1.0] — 2026-09-20

First release: native full-screen anchor overlay with the 15 s cycle
(press · exhale · widen · people, slow), variable ~20–40 min cadence via
launchd, body reps every 4th launch, unguided test reps every 6th, daily
mission, streak and CSV log.
