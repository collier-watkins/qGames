# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

qGames is a collection of educational kids games that run natively on a Raspberry Pi 5 desktop. Games are simple 2D — colors, letters, sounds, patterns, and memory exercises in the style of standard online educational games.

**Target hardware:** Raspberry Pi 5 (ARM64, Raspberry Pi OS or Ubuntu)  
**Dev machine:** Intel x86_64, Ubuntu 24.04

## Stack

- **Python 3** + **Pygame 2** — native 2D game framework, no browser/Electron
- Only one external dependency: `pygame`. Keep it that way unless there is a strong reason.
- Install via `apt` (distro-signed, GPG-verified). Do **not** use pip unless apt is unavailable — pip packages are unsigned and subject to supply-chain attacks. The pinned apt package is `python3-pygame=2.5.2-2`.

## Running

```bash
./run.sh                          # windowed 1280×720 (default)
./run.sh --fullscreen             # fullscreen at native resolution
./run.sh --width 800 --height 600 # arbitrary windowed size
python3 main.py [same flags]      # direct launch, skips apt check
```

## Architecture

```
main.py          # Entry point: arg parsing, pygame init, main game loop, scene routing
games/           # One module per game (e.g. games/color_match.py)
assets/
  fonts/         # .ttf files
  images/        # .png / .jpg sprites
  sounds/        # .wav / .ogg effects and music
```

### Adding a game

1. Create `games/my_game.py` with a class exposing `update(events)` and `draw(screen)`.
2. Import and wire it into the scene router in `main.py`.

Games must never call `pygame.init()` or `pygame.quit()` — those are owned by `main.py`. Each game receives the already-initialized `screen` surface and the current event list each frame.

### Performance notes for Pi

- Target 60 FPS; cap with `clock.tick(60)`.
- Prefer solid-color fills and `pygame.draw.*` over large image blits.
- Pre-load all assets at game startup, not per-frame.
- Call `.convert()` / `.convert_alpha()` on every loaded image immediately after load.

## Git workflow

After every task is complete, stage all changed files, commit, and push:

```bash
git add -p                        # review and stage changes
git commit -m "<type>: <short imperative summary>"
git push
```

Commit message format: `<type>: <what changed>` where type is one of `feat`, `fix`, `refactor`, `chore`, or `docs`. Example: `feat: add color-match game with keyboard input`.

## Compiling to a native binary (Raspberry Pi)

PyInstaller bundles the Python runtime + pygame into a single self-contained executable. It must be built **on** the Pi (the output is architecture-specific ARM64):

```bash
sudo apt install python3-pyinstaller=6.3.0+dfsg-1   # pin version
pyinstaller --onefile --name qgames main.py
# output: dist/qgames  — copy this binary anywhere on the Pi
```

The result is not truly ahead-of-time compiled (Python bytecode still runs inside), but it is a single standalone binary with no runtime dependencies. For true native compilation, Nuitka is an option but significantly more complex to set up.
