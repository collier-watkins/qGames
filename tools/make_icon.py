#!/usr/bin/env python3
"""Generate assets/icons/qgames.png. Re-run whenever the icon design changes."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import pygame

pygame.init()

SIZE = 256
surf = pygame.Surface((SIZE, SIZE), pygame.SRCALPHA)

# Circular dark background
pygame.draw.circle(surf, (20, 30, 55), (SIZE // 2, SIZE // 2), SIZE // 2)

# 2×2 grid of coloured tiles — represents the educational game cards
COLORS = [
    (220,  80,  80),   # red    top-left
    ( 80, 180, 230),   # blue   top-right
    ( 80, 200, 100),   # green  bottom-left
    (240, 200,  60),   # yellow bottom-right
]
TILE, GAP = 56, 18
ox = SIZE // 2 - TILE - GAP // 2
oy = SIZE // 2 - TILE - GAP // 2

for i, color in enumerate(COLORS):
    x = ox + (i % 2) * (TILE + GAP)
    y = oy + (i // 2) * (TILE + GAP)
    pygame.draw.rect(surf, color, (x, y, TILE, TILE), border_radius=12)

out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "assets", "icons", "qgames.png")
pygame.image.save(surf, out)
print(f"Saved {out}")
