# qGames — Project State

_Verified against the tree at commit 681f47c on 2026-08-20. Facts below were read from
source unless marked ASSUMPTION._

## What it is

A suite of standalone educational games for a 3–4 year old, running natively on a
Raspberry Pi 5 desktop. Each game is its own Pygame program, its own PyInstaller
binary, and its own desktop icon. Games report play stats to an MQTT broker so
Home Assistant can surface "what did the kid play today".

## Architecture

Flat by design. No engine, no framework, no shared game loop.

```
shared/            imported by every game via sys.path.insert(0, ROOT)
  util.py          resource_path, maximize_window (SDL2 via ctypes),
                   single_instance (abstract AF_UNIX socket lock), draw_splash
  status_bar.py    StatusBar — bottom bar showing "W × H" + font -/+ buttons
  mqtt_stats.py    publish / publish_many / publish_image — fire-and-forget,
                   daemon thread, 10 s hard timeout, max 8 in-flight
  diag.py          opt-in RSS/FD/thread logger, gated on $QGAMES_DIAG
games/<name>/main.py     one file per game, self-contained
games/<name>/assets/icons/<name>.png
tools/make_icon.py       straight-line script; regenerates ALL icons
*.sh                     run / build / install / uninstall
mqtt.yaml                Home Assistant sensor definitions for all topics
```

Every game is a single `main.py` with module-level constants, free functions for
drawing, and one long `main()` holding all state as locals plus nested closures
(`reset()`, `try_flip()`). No classes except where a game genuinely needs them
(paint: `Toolbar`, `Canvas`; memory: `Card`; battleship: `Ship`, `Board`, `AI`).

### The shared boilerplate every game repeats

```python
ROOT = <three dirnames up>; sys.path.insert(0, ROOT)
GAME_DIR = os.path.dirname(os.path.abspath(__file__))
TITLE = ...; FPS = ...
def main():
    single_instance("<name>")
    pygame.init()
    pygame.display.set_icon(pygame.image.load(resource_path("assets/icons/<name>.png", GAME_DIR)))
    screen = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
    maximize_window(); pygame.display.set_caption(TITLE); draw_splash(screen, TITLE)
    clock = pygame.time.Clock(); status_bar = StatusBar()
    while running:
        for event in pygame.event.get(): ...; status_bar.handle_event(event)
        ...
        status_bar.draw(screen)   # always last — sits on top
        pygame.display.flip(); clock.tick(FPS)
    pygame.quit(); sys.exit()
```

Copy-paste, not inheritance. That is a deliberate tradeoff: each game stays
readable in isolation and PyInstaller bundles stay simple.

## Per-game facts

| Game | LOC | FPS | Dirty-rect? | Classes | Resize | MQTT topics |
|---|---|---|---|---|---|---|
| paint | 742 | 60 | yes | Toolbar, Canvas | recompute from `get_size()` | `paint/image` (binary PNG, retained), `paint/saved`, `paint/ts` |
| battleship | 803 | 60 | **no** — full redraw every frame | Ship, Board, AI | recompute | `battleship/result`, `/shots`, `/ts` |
| sequence | 532 | 30 | yes | — | recompute | `sequence/score`, `/total`, `/ts` |
| simon | 328 | 60 | yes | — | handles `VIDEORESIZE` explicitly | `simon/rounds`, `/ts` |
| memory | 281 | 30 | yes | Card | recompute | `memory/moves`, `/result`, `/ts` |
| letters | 60 | 60 | no | — | recompute | none — **stub**, just a "Coming soon" screen |

Divergences worth knowing before you edit:
- **Timestamp ordering rule.** Every game publishes its `*/ts` topic **last** in a
  single ordered connection, so a Home Assistant automation triggered by `ts`
  sees the other values already updated. `publish_many` / `publish_image` exist
  precisely to guarantee one connection, in list order. Keep this invariant.
- **paint** is the only game importing `diag` and the only one publishing an image.
  It scales the canvas to 800 px wide (`_make_thumb`) before publishing.
- **paint** auto-saves before Clear if the canvas is non-empty (`canvas.can_undo`).
  Saves land in `~/Pictures/qGames`.
- **battleship** does not use the `dirty` flag; it redraws unconditionally at 60 FPS
  and carries its own font +/- buttons (`_draw_font_btns`) separate from `StatusBar`.
- **battleship** takes coordinate input from the keyboard (`_parse_input`), not mouse.
- **simon** synthesises its tones at runtime (`array` + `pygame.mixer`); it is the
  only game using audio, and the only one calling `pygame.mixer.pre_init`.
- **memory / sequence** run at 30 FPS; their animation TTLs are tuned in frames for
  30 FPS, so changing FPS silently changes animation durations.
- Randomness is inconsistent: `secrets` in memory/sequence/simon, `random` in
  battleship. No seeding anywhere.
- Keys: `R` restarts memory, sequence, battleship. Paint uses `C` (clear),
  `S` (save), Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y (undo/redo). `ESC` quits everywhere.

## MQTT

Config is read fresh on every publish from `~/.config/qgames/mqtt.env`, falling
back to `<repo>/mqtt.env` (gitignored). Blank `MQTT_BROKER` → silent no-op, so an
unconfigured machine costs nothing. `paho-mqtt` is imported lazily inside the
publish thread; its absence is swallowed. Topic prefix defaults to `qGames`.

Hardening already in place (from the FD/thread-leak fixes in history): 10 s bound
on connect, handshake, and each publish; teardown in a `finally`; a bounded
semaphore capping 8 concurrent publishes and dropping the excess.

Home Assistant side lives in `mqtt.yaml` — one `camera` entity for the paint image
(reverted from `image` because the Companion app handles `camera` better, commit
1d64446) plus one sensor per scalar topic.

**Doc drift, unverified fix:** `README.md` documents `qGames/sequence/result` as
published on every answer. The code publishes only `score`/`total`/`ts`, once per
10-question round (commit f0d8dff changed the behaviour; the README table was not
updated). `paint/image` is also missing from that table.

## Build / install

- Runtime dep: `pygame==2.5.2` from apt (`python3-pygame`), plus `python3-paho-mqtt`.
  No pip at runtime — apt packages are distro-signed. `run.sh` installs both on demand.
- `build.sh` → PyInstaller `--onefile` per game into `dist/`. Prefers apt PyInstaller,
  falls back to a pinned pip venv at `.build-venv/`. Adds paho hidden-imports only if
  paho is importable on the build machine — so **run `./run.sh <game>` before building**
  or MQTT silently drops out of the binary.
- `install.sh` → `~/.local/bin`, `~/.local/share/icons/hicolor`, `.desktop` entries,
  and Raspberry Pi taskbar integration (wf-panel-pi on Bookworm, LXPanel on Bullseye).
  No sudo. `uninstall.sh` reverses it.
- Binaries are arch-specific: build on the Pi for ARM64. Dev box is x86_64 Ubuntu 24.04.
- The game list is hardcoded in **four** places: `run.sh`, `build.sh`, `install.sh`,
  `uninstall.sh` (`ALL_GAMES`), plus name/comment maps in install/uninstall and a
  section in `tools/make_icon.py`. Adding a game means touching all of them.

## Decisions and rejected alternatives

- **Pygame over browser/Electron** — native, no runtime download, runs acceptably on Pi.
- **apt over pip for runtime deps** — signed packages; pip only for the build-time
  PyInstaller venv, which never ships.
- **Duplication over a shared game framework** — each `main.py` stands alone.
- **MQTT `camera` entity over `image`** for the paint canvas — the HA Companion app
  renders `camera` better (1d64446 reverted 38977c1).
- **Abstract Unix socket over lockfile** for single-instance — no stale files.
- **PyInstaller over Nuitka** — Nuitka is true AOT but far more complex; not pursued.

## Current state

Working: paint, memory, battleship, sequence, simon — all playable, all publishing MQTT.
Stub: `letters` — window, icon, and status bar only; no letter logic, no audio, no MQTT.

## Open threads

- `letters` is the one unfinished game. Speech is unsolved: nothing in the repo does TTS,
  and `simon` is the only existing audio precedent (runtime tone synthesis, no assets).
  A decision is needed — bundled WAV/OGG per letter vs. an espeak/piper dependency.
  ASSUMPTION: bundled audio assets fit the "one dependency" rule better.
- README MQTT table is stale (see above).
- `battleship` is the only game without dirty-rect rendering — a Pi 5 power/heat
  consideration, not yet measured.
- Wishlist in README: Tic-Tac-Toe, Connect 4, Go Fish, Tetris, upper/lower-case letter
  matching, type-words-by-sound, counting, piano; and an Animal-Crossing/farm theme
  unifying the suite.

## Environment

- Dev: `/home/dadmin/Projects/qGames`, x86_64, Ubuntu 24.04, Python 3, branch `main`.
- Target: Raspberry Pi 5, ARM64, Raspberry Pi OS.
- MQTT credentials: `~/.config/qgames/mqtt.env` (never in the repo; `mqtt.env` is gitignored).
- Paint output: `~/Pictures/qGames`. Diag log: `~/.cache/qgames/diag-<game>.log`.
