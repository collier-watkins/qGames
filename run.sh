#!/bin/bash
set -e
cd "$(dirname "$0")"

if ! python3 -c "import pygame" &>/dev/null; then
    echo "pygame not found — installing via apt..."
    sudo apt-get install -y python3-pygame
fi

exec python3 main.py
