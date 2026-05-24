#!/bin/bash
# Install one or all qGames for the current user (no sudo required).
# Creates a binary, XDG icon, and .desktop launcher for each game.
# Usage:  ./install.sh              — install all games
#         ./install.sh paint        — install just paint
#
# After running, each game appears in the GNOME app menu with its own icon.
# Nautilus shows the custom icon on the .desktop file (not the raw binary —
# Linux ELF executables cannot embed icons).
set -euo pipefail
cd "$(dirname "$0")"

ALL_GAMES=(paint memory letters)
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
)
declare -A GAME_COMMENTS=(
    [paint]="Draw and paint freely"
    [memory]="Flip cards and find matching pairs"
    [letters]="Learn letter sounds"
)

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
    echo ""
done

# Refresh desktop and icon caches
update-desktop-database "$DESK_DIR" 2>/dev/null || true
gtk-update-icon-cache -f -t "$ICON_DIR" 2>/dev/null || true

echo "Done. Launch from the app menu or run the game name directly."
