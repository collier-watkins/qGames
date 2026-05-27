#!/bin/bash
# Uninstall one or all qGames for the current user (no sudo required).
# Removes the binary, XDG icons, .desktop entry, and taskbar launcher entry.
#
# Usage:  ./uninstall.sh              — uninstall all games
#         ./uninstall.sh paint        — uninstall just paint
#         ./uninstall.sh paint memory — uninstall two games
#
# Taskbar support:
#   Raspberry Pi OS Bookworm  →  wf-panel-pi  (~/.config/wf-panel-pi/wf-panel-pi.ini)
#   Raspberry Pi OS Bullseye  →  LXPanel      (~/.config/lxpanel/.../panel)
set -euo pipefail
cd "$(dirname "$0")"

ALL_GAMES=(paint memory letters battleship sequence simon)
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
    [sequence]="Sequence"
    [simon]="Simon"
)

# Validate names up front so we don't do a partial uninstall on a typo.
for GAME in "${GAMES[@]}"; do
    if [[ -z "${GAME_NAMES[$GAME]+x}" ]]; then
        echo "ERROR: unknown game '$GAME'. Known games: ${ALL_GAMES[*]}"
        exit 1
    fi
done

# ── Taskbar removal (Raspberry Pi OS) ─────────────────────────────────────────

_PANEL_CHANGED=0

_pi_panel_remove() {
    local GAME="$1"

    # ── wf-panel-pi  (Raspberry Pi OS Bookworm / Wayland) ────────────────────
    local WF="$HOME/.config/wf-panel-pi/wf-panel-pi.ini"
    if command -v wf-panel-pi &>/dev/null || [[ -f "$WF" ]]; then
        if [[ -f "$WF" ]] && grep -qE "^launchers[[:space:]]*=.*\b${GAME}\b" "$WF" 2>/dev/null; then
            python3 - "$WF" "$GAME" <<'PYEOF'
import sys, re
path, game = sys.argv[1], sys.argv[2]

with open(path) as f:
    conf = f.read()

def remove_game(m):
    vals = [v.strip() for v in m.group(1).strip().split() if v.strip() and v.strip() != game]
    return 'launchers=' + ' '.join(vals)

conf = re.sub(r'(?m)^launchers\s*=(.*)', remove_game, conf)

with open(path, 'w') as f:
    f.write(conf)
PYEOF
            echo "  taskbar  → removed from wf-panel-pi"
            _PANEL_CHANGED=1
        fi
        return   # don't fall through to LXPanel check
    fi

    # ── LXPanel  (Raspberry Pi OS Bullseye and older) ─────────────────────────
    local DESK="$DESK_DIR/$GAME.desktop"
    local LX
    LX=$(find "$HOME/.config/lxpanel" -name "panel" -type f 2>/dev/null | head -1)
    [[ -z "$LX" ]] && return   # not an LXPanel desktop — silently skip

    if grep -qF "$DESK" "$LX" 2>/dev/null; then
        cp "$LX" "${LX}.bak"   # safety backup
        python3 - "$LX" "$DESK" <<'PYEOF'
import sys, re
path, desktop = sys.argv[1], sys.argv[2]

with open(path) as f:
    conf = f.read()

# Remove the Button { id=<desktop> } block inserted by install.sh.
conf = re.sub(
    r'[ \t]*Button\s*\{[^}]*\bid=' + re.escape(desktop) + r'[^}]*\}[ \t]*\n?',
    '',
    conf
)

with open(path, 'w') as f:
    f.write(conf)
PYEOF
        echo "  taskbar  → removed from LXPanel"
        _PANEL_CHANGED=1
    fi
}

_pi_panel_reload() {
    [[ $_PANEL_CHANGED -eq 0 ]] && return
    if command -v wf-panel-pi &>/dev/null; then
        # SIGKILL (not SIGTERM) — wf-panel-pi writes its in-memory launcher state
        # back to the config file on graceful exit, overwriting our changes.
        pkill -KILL wf-panel-pi 2>/dev/null || true
        echo "  panel    → wf-panel-pi reloaded"
    elif command -v lxpanelctl &>/dev/null; then
        lxpanelctl restart 2>/dev/null || true
        echo "  panel    → LXPanel restarted"
    fi
}

# ── Uninstall games ───────────────────────────────────────────────────────────

for GAME in "${GAMES[@]}"; do
    NAME="${GAME_NAMES[$GAME]}"
    echo "Uninstalling $NAME"

    # Binary
    if [[ -f "$BIN_DIR/$GAME" ]]; then
        rm -f "$BIN_DIR/$GAME"
        echo "  binary  → removed $BIN_DIR/$GAME"
    else
        echo "  binary  → not found (skipping)"
    fi

    # XDG icons
    removed_icons=0
    for SIZE in 64 128 256; do
        ICON_PATH="$ICON_DIR/${SIZE}x${SIZE}/apps/$GAME.png"
        if [[ -f "$ICON_PATH" ]]; then
            rm -f "$ICON_PATH"
            removed_icons=1
        fi
    done
    if [[ $removed_icons -eq 1 ]]; then
        echo "  icons   → removed from $ICON_DIR/{64,128,256}x.../apps/"
    else
        echo "  icons   → not found (skipping)"
    fi

    # .desktop entry
    DESK="$DESK_DIR/$GAME.desktop"
    if [[ -f "$DESK" ]]; then
        rm -f "$DESK"
        echo "  desktop → removed $DESK"
    else
        echo "  desktop → not found (skipping)"
    fi

    _pi_panel_remove "$GAME"

    echo ""
done

# Refresh desktop and icon caches
update-desktop-database "$DESK_DIR" 2>/dev/null || true
gtk-update-icon-cache -f -t "$ICON_DIR" 2>/dev/null || true

_pi_panel_reload

echo "Done."
