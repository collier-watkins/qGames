#!/bin/bash
# Installs qGames for the current user (no sudo required).
# Sets up the binary, icon, and .desktop launcher so the app appears in the
# GNOME app menu and Nautilus shows the custom icon on the .desktop file.
#
# Linux does not embed icons in ELF binaries (unlike Windows .exe).
# The .desktop file is the standard mechanism for application icons on Linux.
set -euo pipefail
cd "$(dirname "$0")"

APP="qgames"
BINARY="dist/$APP"
ICON="assets/icons/qgames.png"

BIN_DIR="$HOME/.local/bin"
ICON_DIR="$HOME/.local/share/icons/hicolor"
DESKTOP_DIR="$HOME/.local/share/applications"

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ ! -f "$BINARY" ]]; then
    echo "Error: $BINARY not found — run ./build.sh first."
    exit 1
fi

# ── Binary ────────────────────────────────────────────────────────────────────
install -Dm755 "$BINARY" "$BIN_DIR/$APP"
echo "Installed binary  → $BIN_DIR/$APP"

# ── Icon (multiple sizes for the XDG icon theme) ──────────────────────────────
for SIZE in 64 128 256; do
    DEST="$ICON_DIR/${SIZE}x${SIZE}/apps/$APP.png"
    install -Dm644 "$ICON" "$DEST"
done
echo "Installed icons   → $ICON_DIR/{64,128,256}x{64,128,256}/apps/$APP.png"

# ── .desktop entry ────────────────────────────────────────────────────────────
install -dm755 "$DESKTOP_DIR"
cat > "$DESKTOP_DIR/$APP.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=qGames
Comment=Educational games for kids
Icon=$APP
Exec=$BIN_DIR/$APP
Terminal=false
Categories=Game;Education;
StartupNotify=true
EOF
echo "Installed launcher → $DESKTOP_DIR/$APP.desktop"

# ── Refresh caches ────────────────────────────────────────────────────────────
update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
gtk-update-icon-cache -f -t "$ICON_DIR" 2>/dev/null || true

echo ""
echo "Done. Launch qGames from the app menu or run: $APP"
