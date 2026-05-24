# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

qGames is a suite of standalone educational games for kids that run natively on a Raspberry Pi 5 desktop. Each game ships as its own binary with its own desktop icon.

**Target hardware:** Raspberry Pi 5 (ARM64, Raspberry Pi OS or Ubuntu)  
**Dev machine:** Intel x86_64, Ubuntu 24.04

## Stack

- **Python 3** + **Pygame 2** — native 2D, no browser/Electron
- One external dependency: `pygame==2.5.2`. Keep it that way.
- Install via `apt` (distro-signed, GPG-verified): `python3-pygame=2.5.2-2`
- Do **not** use pip for runtime deps — pip packages are unsigned

## Games

| Game | Status | Description |
|---|---|---|
| `paint` | done | MS Paint-style canvas with colour palette and PNG export |
| `memory` | done | 4×4 card pair-matching game |
| `letters` | stub | Keyboard keys speak letter names (TBD) |

## Running in development

```bash
./run.sh paint              # launch paint (auto-installs pygame if needed)
./run.sh memory
./run.sh letters
python3 games/paint/main.py # direct launch, skips apt check
```

## Building native executables

```bash
./build.sh              # build all games → dist/paint, dist/memory, dist/letters
./build.sh paint        # build one game
```

Executables are architecture-specific — build on the target machine (Pi 5 for ARM64).

## Installing desktop launchers

```bash
./install.sh            # install all games
./install.sh paint      # install one game
```

Installs to `~/.local/bin/`, `~/.local/share/icons/`, and `~/.local/share/applications/`.  
No `sudo` required. Adds the game to the GNOME app menu with its icon.

## Repository structure

```
shared/
  util.py           # resource_path() — resolves assets in dev and PyInstaller bundles
  status_bar.py     # StatusBar class (window dimensions, font +/- buttons)
games/
  <name>/
    main.py         # entry point — run directly or via ./run.sh
    assets/
      icons/        # <name>.png — 256×256 game icon
assets/
  icons/
    qgames.png      # suite icon (256×256)
tools/
  make_icon.py      # regenerate all game icons (uses pygame, no extra deps)
```

## Adding a new game

1. `mkdir -p games/<name>/assets/icons`
2. Add an icon entry to `tools/make_icon.py` and run it
3. Write `games/<name>/main.py` — see any existing game for the pattern:
   - `sys.path.insert(0, ROOT)` so `shared/` is importable
   - Load icon with `resource_path("assets/icons/<name>.png", GAME_DIR)`
   - Use `StatusBar` from `shared.status_bar`
   - Never call `pygame.init()` more than once; never skip `pygame.quit()`
4. Add the game name to `ALL_GAMES` in `build.sh`, `install.sh`, and `run.sh`
5. Add a row to the Games table above

## Shared utilities

### `resource_path(relative, base=None)`

Resolves asset paths correctly in both dev and PyInstaller bundles.

```python
GAME_DIR = os.path.dirname(os.path.abspath(__file__))
icon = pygame.image.load(resource_path("assets/icons/paint.png", GAME_DIR))
```

In a bundle `sys._MEIPASS` is used automatically; `base` is ignored.

### `StatusBar`

Drawn last each frame so it always sits on top of game content.  
`status_bar.height` gives the pixel height (varies with font size).

## Git workflow

After every task, stage, commit, and push:

```bash
git add -p
git commit -m "<type>: <short imperative summary>"
git push
```

Types: `feat`, `fix`, `refactor`, `chore`, `docs`.

## Performance notes for Pi

- Cap at 60 FPS with `clock.tick(60)`
- Prefer `pygame.draw.*` over image blits for simple shapes
- Pre-load assets once at startup; call `.convert()` / `.convert_alpha()` immediately after load

## Compiling to a native binary

PyInstaller bundles the Python runtime + pygame + SDL into one file. Run on the target arch:

```bash
./build.sh <game>
# output: dist/<game>  — copy to any linux/<arch> machine, no deps needed
```

For true AOT compilation, Nuitka is an option but significantly more complex.
