# qGames

Small educational games for kids, built with Python + Pygame, designed to run natively on a Raspberry Pi desktop.

---

## Games

| Game | Status | Description |
|---|---|---|
| `paint` | ✓ done | MS Paint-style canvas with colour palette, undo/redo, and PNG export |
| `memory` | ✓ done | 4×4 card pair-matching game |
| `battleship` | ✓ done | Single-player naval strategy vs AI |
| `sequence` | ✓ done | Spot the repeating pattern and choose what comes next |
| `letters` | stub | Keyboard keys speak letter names |

> **Rule for new games:** every game must publish MQTT stats. See [MQTT](#mqtt) below.

---

## Running in development

```bash
./run.sh paint        # auto-installs pygame + paho-mqtt if needed, then launches
./run.sh memory
./run.sh battleship
```

Or launch directly (skips the apt check):

```bash
python3 games/paint/main.py
```

---

## Building native executables

Executables are architecture-specific — build on the target machine (Pi for ARM64).

```bash
./build.sh              # build all games → dist/
./build.sh paint        # build one game
./build.sh paint memory # build two games
```

> Run `./run.sh <game>` first to ensure `python3-paho-mqtt` is installed before building,
> so MQTT support gets bundled into the executable.

---

## Installing desktop launchers

```bash
./install.sh            # install all games
./install.sh paint      # install one game
```

Installs to `~/.local/bin/`, icons to `~/.local/share/icons/`, and `.desktop` entries
to `~/.local/share/applications/`. No `sudo` required.

On Raspberry Pi OS (Bookworm/Wayland) the games are also added to the taskbar launcher automatically.

---

## MQTT

Game stats are published to your MQTT broker when notable events occur (game won, image saved, etc.).

### Setup

On first run, `./install.sh` creates `~/.config/qgames/mqtt.env` from the template.
Edit it to point at your broker:

```ini
MQTT_BROKER=192.168.1.100
MQTT_PORT=1883
MQTT_USERNAME=
MQTT_PASSWORD=
MQTT_TOPIC_PREFIX=qGames
```

If `MQTT_BROKER` is blank the games skip publishing silently — no errors.

### Topics

| Topic | Value | Published when |
|---|---|---|
| `qGames/memory/moves` | integer | Game won |
| `qGames/memory/result` | `win` | Game won |
| `qGames/memory/ts` | Unix timestamp | Game won |
| `qGames/paint/saved` | filename | Image saved (Ctrl+S or Save button) |
| `qGames/paint/ts` | Unix timestamp | Image saved |
| `qGames/battleship/result` | `win` or `loss` | Game over |
| `qGames/battleship/shots` | integer | Game over |
| `qGames/battleship/ts` | Unix timestamp | Game over |
| `qGames/sequence/result` | `correct` or `wrong` | Each answer |
| `qGames/sequence/score` | integer | Each answer |
| `qGames/sequence/total` | integer | Each answer |
| `qGames/sequence/ts` | Unix timestamp | Each answer |

### Home Assistant sensors

Each game's directory contains a `mqtt_sensor_sample.yaml` ready to copy into your
`configuration.yaml`. Trigger automations off the `ts` sensor — it always changes,
even when other values repeat.

---

## Ideas / wishlist

### Games to implement
- Tic-Tac-Toe
- Connect 4
- Go Fish
- Tetris
- Match lower-case and upper-case letters
- Type words by sound
- Count numbers

### Music
- Piano?

### Theme
- Animal Crossing / farm theme to combine all games?
