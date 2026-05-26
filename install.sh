#!/bin/bash
# Install one or all qGames for the current user (no sudo required).
# Creates a binary, XDG icon, and .desktop launcher for each game.
# On a Raspberry Pi desktop, also adds each game to the taskbar launcher.
#
# Usage:  ./install.sh              — install all games
#         ./install.sh paint        — install just paint
#
# Taskbar support:
#   Raspberry Pi OS Bookworm  →  wf-panel-pi  (~/.config/wf-panel-pi/wf-panel-pi.ini)
#   Raspberry Pi OS Bullseye  →  LXPanel      (~/.config/lxpanel/.../panel)
set -euo pipefail
cd "$(dirname "$0")"

ALL_GAMES=(paint memory letters battleship)
GAMES=("${ALL_GAMES[@]}")
if [[ $# -gt 0 ]]; then
    GAMES=("$@")
fi

BIN_DIR="$HOME/.local/bin"
ICON_DIR="$HOME/.local/share/icons/hicolor"
DESK_DIR="$HOME/.local/share/applications"

declare -A GAME_NAMES=(
    [paint]="Paint"
    [memory]="Memory Match"
    [letters]="Letter Sounds"
    [battleship]="Battleship"
)
declare -A GAME_COMMENTS=(
    [paint]="Draw and paint freely"
    [memory]="Flip cards and find matching pairs"
    [letters]="Learn letter sounds"
    [battleship]="Single-player naval strategy game"
)

# ── Taskbar integration (Raspberry Pi OS) ─────────────────────────────────────
# Called once per game after its .desktop file is written.
# Silently skips on non-Raspberry-Pi systems.

_PANEL_CHANGED=0

_pi_panel_add() {
    local GAME="$1"
    local DESK="$DESK_DIR/$GAME.desktop"

    # ── wf-panel-pi  (Raspberry Pi OS Bookworm / Wayland) ────────────────────
    # Config: ~/.config/wf-panel-pi/wf-panel-pi.ini
    # Format: launchers=app1;app2  (app name only, no .desktop, under [panel])
    # The panel watches the file via inotify — changes appear immediately.
    local WF="$HOME/.config/wf-panel-pi/wf-panel-pi.ini"
    if command -v wf-panel-pi &>/dev/null || [[ -f "$WF" ]]; then
        # Ensure the config file and its directory exist.
        if [[ ! -f "$WF" ]]; then
            mkdir -p "$(dirname "$WF")"
            local _seed
            for _seed in \
                    /etc/xdg/wf-panel-pi/wf-panel-pi.ini \
                    /etc/xdg/wf-panel-pi.ini; do
                if [[ -f "$_seed" ]]; then cp "$_seed" "$WF"; break; fi
            done
            [[ ! -f "$WF" ]] && printf '[panel]\n' > "$WF"
        fi
        if ! grep -qE "^launchers[[:space:]]*=.*\b${GAME}\b" "$WF" 2>/dev/null; then
            python3 - "$WF" "$GAME" <<'PYEOF'
import sys, re
path, game = sys.argv[1], sys.argv[2]

with open(path) as f:
    conf = f.read()

# Remove stale numbered-format entries from previous install attempts.
conf = re.sub(r'(?m)^launcher_\d{6}=.*\n?', '', conf)

# Already present in launchers= list?
if re.search(r'(?m)^launchers\s*=.*\b' + re.escape(game) + r'\b', conf):
    with open(path, 'w') as f:
        f.write(conf)
    sys.exit(0)

def append_game(m):
    # wf-panel-pi separates launcher entries with spaces (not semicolons).
    vals = [v.strip() for v in m.group(1).strip().split() if v.strip()]
    if game not in vals:
        vals.append(game)
    return 'launchers=' + ' '.join(vals)

if re.search(r'(?m)^launchers\s*=', conf):
    # Append to the existing launchers= line.
    conf = re.sub(r'(?m)^launchers\s*=(.*)', append_game, conf)
elif re.search(r'(?m)^\[panel\]', conf):
    # [panel] exists but no launchers= key yet.
    conf = re.sub(r'(?m)(^\[panel\]\n)', r'\1launchers=' + game + '\n', conf)
else:
    conf = conf.rstrip() + '\n\n[panel]\nlaunchers=' + game + '\n'

with open(path, 'w') as f:
    f.write(conf)
PYEOF
            echo "  taskbar  → wf-panel-pi"
            _PANEL_CHANGED=1
        fi
        return
    fi

    # ── LXPanel  (Raspberry Pi OS Bullseye and older) ─────────────────────────
    # The panel config contains Plugin { type=launchbar Config { Button { id=... } } }.
    # We parse it with Python to insert a Button entry safely.
    local LX
    LX=$(find "$HOME/.config/lxpanel" -name "panel" -type f 2>/dev/null | head -1)
    [[ -z "$LX" ]] && return   # not an LXPanel desktop — silently skip

    if ! grep -qF "$GAME" "$LX" 2>/dev/null; then
        cp "$LX" "${LX}.bak"   # safety backup
        python3 - "$LX" "$DESK" <<'PYEOF'
import sys
path, desktop = sys.argv[1], sys.argv[2]
with open(path) as f:
    conf = f.read()

if desktop in conf:
    sys.exit(0)

# Insert a Button entry into the launchbar Plugin's Config { } block.
btn = "\n    Button {\n      id=" + desktop + "\n    }"

idx = conf.find("type=launchbar")
if idx < 0:
    sys.exit(0)  # no launchbar plugin — leave file untouched

ci = conf.find("Config {", idx)
if ci < 0:
    sys.exit(0)

# Scan forward from after "Config {" to find its matching closing brace.
pos, depth = ci + len("Config {"), 1
while pos < len(conf) and depth > 0:
    if conf[pos] == '{':
        depth += 1
    elif conf[pos] == '}':
        depth -= 1
    pos += 1

# pos-1 is the Config closing '}'. Back up past its leading whitespace
# so we insert cleanly on its own line, not with a blank gap.
line_start = pos - 1
while line_start > 0 and conf[line_start - 1] in (' ', '\t'):
    line_start -= 1
btn = "    Button {\n      id=" + desktop + "\n    }\n"
conf = conf[:line_start] + btn + conf[line_start:]
with open(path, "w") as f:
    f.write(conf)
PYEOF
        echo "  taskbar  → LXPanel"
        _PANEL_CHANGED=1
    fi
}

_pi_panel_reload() {
    [[ $_PANEL_CHANGED -eq 0 ]] && return
    if command -v wf-panel-pi &>/dev/null; then
        # SIGKILL (not SIGTERM) — wf-panel-pi writes its in-memory launcher state
        # back to the config file on graceful exit, which would overwrite our
        # changes. SIGKILL prevents that; lwrespawn restarts the panel and it
        # reads the config we just wrote.
        pkill -KILL wf-panel-pi 2>/dev/null || true
        echo "  panel    → wf-panel-pi reloaded"
    elif command -v lxpanelctl &>/dev/null; then
        lxpanelctl restart 2>/dev/null || true
        echo "  panel    → LXPanel restarted"
    fi
}

# ── MQTT config template ───────────────────────────────────────────────────────

MQTT_CFG_DIR="$HOME/.config/qgames"
MQTT_CFG="$MQTT_CFG_DIR/mqtt.env"
if [[ ! -f "$MQTT_CFG" ]]; then
    mkdir -p "$MQTT_CFG_DIR"
    cp "$(dirname "$0")/mqtt.env.example" "$MQTT_CFG"
    echo "Created MQTT config at $MQTT_CFG"
    echo "  Edit it to add your broker IP and credentials."
    echo ""
fi

# ── Install games ──────────────────────────────────────────────────────────────

for GAME in "${GAMES[@]}"; do
    BIN="dist/$GAME"
    ICON="games/$GAME/assets/icons/$GAME.png"

    if [[ ! -f "$BIN" ]]; then
        echo "ERROR: $BIN not found — run ./build.sh $GAME first."
        exit 1
    fi

    NAME="${GAME_NAMES[$GAME]:-$GAME}"
    COMMENT="${GAME_COMMENTS[$GAME]:-}"

    # Binary
    install -Dm755 "$BIN" "$BIN_DIR/$GAME"

    # Icon at multiple XDG sizes (same source PNG, GTK scales as needed)
    for SIZE in 64 128 256; do
        install -Dm644 "$ICON" "$ICON_DIR/${SIZE}x${SIZE}/apps/$GAME.png"
    done

    # .desktop entry
    install -dm755 "$DESK_DIR"
    cat > "$DESK_DIR/$GAME.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$NAME
Comment=$COMMENT
Icon=$GAME
Exec=$BIN_DIR/$GAME
Terminal=false
Categories=Game;Education;
StartupNotify=true
EOF

    echo "Installed $NAME"
    echo "  binary  → $BIN_DIR/$GAME"
    echo "  icon    → $ICON_DIR/{64,128,256}x.../apps/$GAME.png"
    echo "  desktop → $DESK_DIR/$GAME.desktop"

    _pi_panel_add "$GAME"

    echo ""
done

# Refresh desktop and icon caches
update-desktop-database "$DESK_DIR" 2>/dev/null || true
gtk-update-icon-cache -f -t "$ICON_DIR" 2>/dev/null || true

# Reload the panel once, after all games are added
_pi_panel_reload

echo "Done. Launch from the app menu or run the game name directly."
