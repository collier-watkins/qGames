#!/usr/bin/env python3
"""Generate all game icons. Re-run after design changes."""
import math
import os
import sys

import pygame

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
pygame.init()

SIZE = 256
C = SIZE // 2


def new_surf():
    s = pygame.Surface((SIZE, SIZE), pygame.SRCALPHA)
    pygame.draw.circle(s, (20, 30, 55), (C, C), C)
    return s


def save(surf, *parts):
    path = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    pygame.image.save(surf, path)
    print(f"  {path}")


# ── qgames suite icon ─────────────────────────────────────────────────────────
s = new_surf()
TILE, GAP = 56, 18
ox = C - TILE - GAP // 2
oy = C - TILE - GAP // 2
for i, color in enumerate([(220,80,80),(80,180,230),(80,200,100),(240,200,60)]):
    x = ox + (i % 2) * (TILE + GAP)
    y = oy + (i // 2) * (TILE + GAP)
    pygame.draw.rect(s, color, (x, y, TILE, TILE), border_radius=12)
save(s, "assets", "icons", "qgames.png")

# ── paint ─────────────────────────────────────────────────────────────────────
s = new_surf()
# Three overlapping paint blobs in primary colours
for color, (ox, oy) in [
    ((210, 60, 60),  (-38, 28)),
    ((60, 100, 220), ( 38, 28)),
    ((240, 210, 40), (  0,-36)),
]:
    pygame.draw.circle(s, color, (C + ox, C + oy), 64)
save(s, "games", "paint", "assets", "icons", "paint.png")

# ── memory ────────────────────────────────────────────────────────────────────
s = new_surf()
CW, CH, CR = 80, 106, 10
gap = 14
# Left card — face down (blue with inner border)
lx = C - CW - gap // 2
ly = C - CH // 2
pygame.draw.rect(s, (55, 95, 210), (lx, ly, CW, CH), border_radius=CR)
pygame.draw.rect(s, (80, 125, 240), (lx, ly, CW, CH), border_radius=CR, width=3)
inner = pygame.Rect(lx + 8, ly + 8, CW - 16, CH - 16)
pygame.draw.rect(s, (80, 125, 240), inner, border_radius=CR - 3, width=2)
# Right card — face up (white with a star)
rx = C + gap // 2
pygame.draw.rect(s, (245, 245, 250), (rx, ly, CW, CH), border_radius=CR)
scx, scy, sr = rx + CW // 2, ly + CH // 2, 30
pts = []
for i in range(10):
    angle = math.pi / 2 + i * 2 * math.pi / 10
    r = sr if i % 2 == 0 else sr * 0.42
    pts.append((scx + r * math.cos(angle), scy - r * math.sin(angle)))
pygame.draw.polygon(s, (240, 190, 40), pts)
save(s, "games", "memory", "assets", "icons", "memory.png")

# ── letters ───────────────────────────────────────────────────────────────────
s = new_surf()
font = pygame.font.SysFont("sans", 148, bold=True)
lbl = font.render("A", True, (240, 200, 60))
s.blit(lbl, (C - lbl.get_width() // 2, C - lbl.get_height() // 2))
save(s, "games", "letters", "assets", "icons", "letters.png")

# ── battleship ────────────────────────────────────────────────────────────────
s = new_surf()
# Ocean background
pygame.draw.circle(s, (20, 55, 105), (C, C), C - 4)
# Faint grid
for i in range(5):
    x = C - 60 + i * 30
    pygame.draw.line(s, (30, 70, 130), (x, C - 60), (x, C + 60), 1)
    y = C - 60 + i * 30
    pygame.draw.line(s, (30, 70, 130), (C - 60, y), (C + 60, y), 1)
# Ship hull (horizontal bar)
pygame.draw.rect(s, (175, 185, 195), (C - 56, C - 16, 112, 32), border_radius=8)
# Bridge
pygame.draw.rect(s, (135, 145, 158), (C - 12, C - 28, 24, 12), border_radius=4)
# Hit markers
hit_c = (220, 75, 55)
for hx, hy in [(C - 44, C - 44), (C + 28, C + 30)]:
    pygame.draw.line(s, hit_c, (hx - 9, hy - 9), (hx + 9, hy + 9), 3)
    pygame.draw.line(s, hit_c, (hx + 9, hy - 9), (hx - 9, hy + 9), 3)
# Miss marker (hollow circle)
pygame.draw.circle(s, (110, 155, 215), (C - 14, C + 44), 8, 3)
save(s, "games", "battleship", "assets", "icons", "battleship.png")

print("Done.")
