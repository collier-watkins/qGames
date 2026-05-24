# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

qGames is a collection of educational kids games that run natively on a Raspberry Pi 5 desktop. Games are simple 2D — colors, letters, sounds, patterns, and memory exercises in the style of standard online educational games.

**Target hardware:** Raspberry Pi 5 (ARM64, Raspberry Pi OS or Ubuntu)  
**Dev machine:** Intel x86_64, Ubuntu 24.04

## Stack

- **Python 3** + **Pygame 2** — native 2D game framework, no browser/Electron
- No virtual environment; system pygame via `apt` is preferred for Pi compatibility

## Running

```bash
./run.sh          # auto-installs pygame if missing, then launches
python3 main.py   # direct launch once pygame is installed
```

Install pygame manually if needed:
```bash
sudo apt install python3-pygame
```

## Architecture

```
main.py          # Entry point: pygame init, main game loop, screen/scene routing
games/           # One module per game (e.g. games/color_match.py)
assets/
  fonts/         # .ttf files
  images/        # .png / .jpg sprites and backgrounds
  sounds/        # .wav / .ogg effects and music
```

### Adding a game

1. Create `games/my_game.py` with a class that exposes `update(events)` and `draw(screen)`.
2. Import and wire it into the scene router in `main.py`.

Games should never call `pygame.init()` or `pygame.quit()` — that is owned by `main.py`. Each game receives the already-initialized `screen` surface and the current event list each frame.

### Performance notes for Pi

- Target 60 FPS; cap with `clock.tick(60)`.
- Prefer solid-color fills and `pygame.draw.*` over large image blits where possible.
- Pre-load all assets at game startup, not per-frame.
- Use `pygame.Surface.convert()` / `convert_alpha()` on loaded images immediately after load.
