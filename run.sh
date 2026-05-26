#!/bin/bash
set -e
cd "$(dirname "$0")"

PYGAME_APT="python3-pygame=2.5.2-2"
PAHO_APT="python3-paho-mqtt"
ALL_GAMES=(paint memory letters battleship)

if [[ $# -eq 0 ]]; then
    echo "Usage: ./run.sh <game> [args...]"
    echo "Games: ${ALL_GAMES[*]}"
    exit 1
fi

GAME="$1"; shift

if [[ ! -f "games/$GAME/main.py" ]]; then
    echo "Unknown game '$GAME'. Available: ${ALL_GAMES[*]}"
    exit 1
fi

if ! python3 -c "import pygame" &>/dev/null; then
    echo "Installing $PYGAME_APT via apt..."
    sudo apt-get install -y "$PYGAME_APT"
fi

if ! python3 -c "import paho" &>/dev/null; then
    echo "Installing $PAHO_APT via apt..."
    sudo apt-get install -y "$PAHO_APT"
fi

exec python3 "games/$GAME/main.py" "$@"
