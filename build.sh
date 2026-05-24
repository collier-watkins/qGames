#!/bin/bash
# Packages qGames into a single self-contained executable using PyInstaller.
# The binary embeds the Python runtime and all libraries — no dependencies are
# required on the target machine. Must be built on the target architecture.
#
# Tested architectures: x86_64, aarch64 (Pi 5), armv7l (Pi 4 32-bit)
set -euo pipefail
cd "$(dirname "$0")"

ARCH=$(uname -m)
APP="qgames"
OUT="dist/$APP"
BUILD_VENV=".build-venv"
PYINSTALLER_VER="6.3.0"   # update here when bumping

echo "Building $APP  [linux/$ARCH]"
echo ""

# ── 1. Locate or install PyInstaller ──────────────────────────────────────────
# Prefer the distro apt package (GPG-signed). If unavailable, create an
# isolated build venv and pip-install a pinned version.
# PyInstaller runs only on the build machine and is never shipped to users.

if python3 -m PyInstaller --version &>/dev/null 2>&1; then
    PYINST=(python3 -m PyInstaller)

elif apt-cache show python3-pyinstaller &>/dev/null 2>&1; then
    echo "Installing python3-pyinstaller via apt..."
    sudo apt-get install -y python3-pyinstaller
    PYINST=(python3 -m PyInstaller)

else
    echo "python3-pyinstaller not in apt — falling back to pip venv..."
    if [[ ! -x "$BUILD_VENV/bin/pyinstaller" ]]; then
        sudo apt-get install -y python3-venv
        python3 -m venv "$BUILD_VENV"
        "$BUILD_VENV/bin/pip" install --quiet "pyinstaller==$PYINSTALLER_VER"
    fi
    PYINST=("$BUILD_VENV/bin/pyinstaller")
fi

echo "PyInstaller: $("${PYINST[@]}" --version)"
echo ""

# ── 2. Clean previous artifacts ───────────────────────────────────────────────
rm -rf build dist "$APP.spec"

# ── 3. Build ──────────────────────────────────────────────────────────────────
"${PYINST[@]}" \
    --onefile \
    --name "$APP" \
    --add-data "assets:assets" \
    --hidden-import pygame \
    --log-level WARN \
    main.py

# ── 4. Report ─────────────────────────────────────────────────────────────────
SIZE=$(du -sh "$OUT" | cut -f1)
echo ""
echo "  Output : $OUT"
echo "  Size   : $SIZE"
echo "  Arch   : $ARCH"
echo ""
echo "Copy '$OUT' to any linux/$ARCH machine and run it directly."
echo "No Python or pygame installation required on the target."
