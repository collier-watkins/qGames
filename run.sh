#!/bin/bash
set -e
cd "$(dirname "$0")"

# Exact distro package — GPG-signed by Ubuntu, pinned to avoid drift
PYGAME_APT="python3-pygame=2.5.2-2"

if ! python3 -c "import pygame" &>/dev/null; then
    echo "Installing $PYGAME_APT via apt..."
    sudo apt-get install -y "$PYGAME_APT"
fi

# Pass all args through: --fullscreen, --width N, --height N
exec python3 main.py "$@"
