#!/bin/bash
# Build one or all qGames into self-contained Linux executables.
# Usage:  ./build.sh              — build all games
#         ./build.sh paint        — build just paint
#         ./build.sh paint memory — build two games
#
# Output lands in dist/<game>. Must be run on the target architecture.
set -euo pipefail
cd "$(dirname "$0")"

ALL_GAMES=(paint memory letters battleship sequence simon)
PYINSTALLER_VER="6.3.0"
BUILD_VENV=".build-venv"

GAMES=("${ALL_GAMES[@]}")
if [[ $# -gt 0 ]]; then
    GAMES=("$@")
fi

# Validate names up front so we don't do a partial build on a typo.
for GAME in "${GAMES[@]}"; do
    valid=0
    for g in "${ALL_GAMES[@]}"; do [[ "$g" == "$GAME" ]] && valid=1 && break; done
    if [[ $valid -eq 0 ]]; then
        echo "ERROR: unknown game '$GAME'. Known games: ${ALL_GAMES[*]}"
        exit 1
    fi
done

echo "Building: ${GAMES[*]}  [linux/$(uname -m)]"
echo ""

# ── 1. System deps ────────────────────────────────────────────────────────────
if ! command -v objdump &>/dev/null; then
    echo "Installing binutils (required by PyInstaller)..."
    sudo apt-get install -y binutils
fi

# ── 2. PyInstaller ────────────────────────────────────────────────────────────
# Prefer distro apt package (GPG-signed). Fall back to pinned pip venv.
# PyInstaller is a build tool — never shipped to users.
if python3 -m PyInstaller --version &>/dev/null 2>&1; then
    PYINST=(python3 -m PyInstaller)
elif apt-cache show python3-pyinstaller &>/dev/null 2>&1; then
    echo "Installing python3-pyinstaller via apt..."
    sudo apt-get install -y python3-pyinstaller
    PYINST=(python3 -m PyInstaller)
else
    if [[ ! -x "$BUILD_VENV/bin/pyinstaller" ]]; then
        echo "python3-pyinstaller not in apt — creating pip venv..."
        sudo apt-get install -y python3-venv
        python3 -m venv "$BUILD_VENV"
        "$BUILD_VENV/bin/pip" install --quiet \
            "pyinstaller==$PYINSTALLER_VER" \
            "pygame==2.5.2"
    fi
    PYINST=("$BUILD_VENV/bin/pyinstaller")
fi
echo "PyInstaller $("${PYINST[@]}" --version)"
echo ""

# ── 3. Build each game ────────────────────────────────────────────────────────
# Use absolute paths for all file args — PyInstaller resolves --add-data
# relative to --workpath, not the project root.
ROOT="$PWD"
mkdir -p dist

# Include paho-mqtt hidden imports if installed on the build machine.
PAHO_ARGS=()
if python3 -c "import paho" &>/dev/null 2>&1; then
    PAHO_ARGS=(--hidden-import paho.mqtt.publish --hidden-import paho.mqtt.client)
fi

for GAME in "${GAMES[@]}"; do
    GDIR="$ROOT/games/$GAME"
    if [[ ! -f "$GDIR/main.py" ]]; then
        echo "WARNING: $GDIR/main.py not found — skipping $GAME"
        continue
    fi

    echo "── $GAME ────────────────────────────────"

    ICON_ARGS=()
    if [[ -f "$GDIR/assets/icons/$GAME.png" ]]; then
        ICON_ARGS=(--icon "$GDIR/assets/icons/$GAME.png")
    fi

    "${PYINST[@]}" \
        --onefile \
        --name    "$GAME" \
        --distpath "$ROOT/dist" \
        --workpath "$ROOT/build/$GAME" \
        --specpath "$ROOT/build/$GAME" \
        --paths   "$ROOT" \
        --add-data "$GDIR/assets:assets" \
        "${ICON_ARGS[@]}" \
        --hidden-import pygame \
        "${PAHO_ARGS[@]}" \
        --log-level WARN \
        "$GDIR/main.py"

    echo "  → dist/$GAME  ($(du -sh "$ROOT/dist/$GAME" | cut -f1))"
done

echo ""
echo "Done. Run ./install.sh to install desktop launchers."
