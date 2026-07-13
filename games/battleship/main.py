import math
import os
import random
import sys
import time

import pygame

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from shared.mqtt_stats import publish_many as mqtt_publish_many
from shared.status_bar import StatusBar
from shared.util import draw_splash, maximize_window, resource_path, single_instance

GAME_DIR = os.path.dirname(os.path.abspath(__file__))

TITLE    = "Battleship"
FPS      = 60
GRID     = 9
AI_DELAY = 60

SHIP_DEFS = [
    ("Carrier",    5, ( 90, 185, 235)),
    ("Battleship", 4, (220, 140,  50)),
    ("Cruiser",    3, ( 80, 205, 105)),
    ("Submarine",  3, (175, 100, 225)),
    ("Destroyer",  2, (235, 210,  50)),
]

# ── Palette ───────────────────────────────────────────────────────────────────

C_BG          = (  7,  14,  28)

# Fleet panel — ocean tactical map
C_FL_WATER    = ( 14,  42,  82)
C_FL_GRID     = ( 25,  60, 114)
C_FL_LABEL    = ( 95, 138, 192)
C_FL_SHIP     = (138, 152, 168)
C_FL_SUNK     = ( 62,  68,  78)
C_FL_HIT      = (210,  52,  38)
C_FL_HIT_X    = (255, 185, 175)
C_FL_MISS     = ( 90, 125, 188)
C_FL_FRAME    = ( 40,  70, 128)
C_FL_PAN      = (115, 158, 208)

# Radar panel — phosphor CRT green
C_RD_WATER    = (  2,  18,   5)
C_RD_ALT      = (  4,  24,   8)
C_RD_GRID     = (  0,  72,  16)
C_RD_LABEL    = (  0, 218,  55)
C_RD_FRAME1   = (  0, 175,  38)
C_RD_FRAME2   = (  0,  90,  20)
C_RD_FRAME3   = (  0,  40,   9)
C_RD_HIT      = (255,  70,  22)
C_RD_HITGLO   = (255, 155,  50)
C_RD_MISS1    = (  0, 155,  32)
C_RD_MISS2    = (  0,  75,  15)
C_RD_CURSOR   = (  0, 255,  65)
C_RD_CURSR2   = (  0, 135,  30)
C_RD_SHIP     = (  0,  95,  22)
C_RD_PAN      = (  0, 235,  60)

# HUD / log / input
C_HUD         = (122, 160, 210)
C_BTN_BG      = ( 22,  42,  82)
C_BTN_TXT     = (165, 200, 252)
C_BTN_FRAME   = ( 55,  90, 148)
C_LOG_BG      = ( 10,  22,  44)
C_LOG_TEXT    = (165, 194, 234)
C_LOG_GOOD    = ( 85, 225, 108)
C_LOG_BAD     = (225,  88,  78)
C_LOG_SUNK    = (232, 158,  38)
C_INP         = (  0, 235,  60)

# Enemy status (green tint to link visually to radar)
C_EN_TITLE    = (  0, 175,  40)
C_EN_ALIVE    = (  0, 148,  32)
C_EN_DEAD     = ( 40,  60,  42)

STATE_PLAYER  = "player"
STATE_AI      = "ai"
STATE_OVER    = "over"

PANEL_GAP     = 18
LABEL_SZ      = 22
PAN_LABEL_H   = 22
LOG_LINES     = 6

FONT_BASE_DEF = 19
FONT_BASE_MIN = 11
FONT_BASE_MAX = 30
FONT_STEP     = 2


# ── Data model ────────────────────────────────────────────────────────────────

class Ship:
    __slots__ = ("name", "size", "color", "cells", "hits")

    def __init__(self, name: str, size: int, color: tuple):
        self.name  = name
        self.size  = size
        self.color = color
        self.cells: list[tuple[int, int]] = []
        self.hits:  set[tuple[int, int]]  = set()

    @property
    def sunk(self) -> bool:
        return len(self.hits) == self.size


class Board:
    def __init__(self):
        self.grid:  list[list]           = [[None] * GRID for _ in range(GRID)]
        self.shots: set[tuple[int, int]] = set()
        self.ships: list[Ship]           = []

    def place_random(self):
        self.grid  = [[None] * GRID for _ in range(GRID)]
        self.ships = []
        for name, size, color in SHIP_DEFS:
            ship = Ship(name, size, color)
            for _ in range(2000):
                horiz = random.choice((True, False))
                if horiz:
                    r = random.randrange(GRID)
                    c = random.randrange(GRID - size + 1)
                    cells = [(r, c + i) for i in range(size)]
                else:
                    r = random.randrange(GRID - size + 1)
                    c = random.randrange(GRID)
                    cells = [(r + i, c) for i in range(size)]
                ok = all(
                    self.grid[nr][nc] is None
                    for cr, cc in cells
                    for dr in (-1, 0, 1)
                    for dc in (-1, 0, 1)
                    if 0 <= (nr := cr + dr) < GRID and 0 <= (nc := cc + dc) < GRID
                )
                if ok:
                    ship.cells = cells
                    for cr, cc in cells:
                        self.grid[cr][cc] = ship
                    self.ships.append(ship)
                    break

    def shoot(self, r: int, c: int) -> str:
        if (r, c) in self.shots:
            return "already"
        self.shots.add((r, c))
        ship = self.grid[r][c]
        if ship is None:
            return "miss"
        ship.hits.add((r, c))
        return "sunk" if ship.sunk else "hit"

    def all_sunk(self) -> bool:
        return all(s.sunk for s in self.ships)


class AI:
    """Checkerboard hunt + axis-focused target mode."""

    def __init__(self):
        self._hunt:    list[tuple[int, int]] = []
        self._targets: list[tuple[int, int]] = []
        self._hit_run: list[tuple[int, int]] = []
        self._axis:    str | None            = None
        self._reset_hunt()

    def _reset_hunt(self):
        cells = [(r, c) for r in range(GRID) for c in range(GRID) if (r + c) % 2 == 0]
        random.shuffle(cells)
        self._hunt = cells

    def choose(self, board: Board) -> tuple[int, int]:
        while self._targets:
            pos = self._targets.pop(0)
            if pos not in board.shots and _in_bounds(*pos):
                return pos
        while self._hunt:
            pos = self._hunt.pop(0)
            if pos not in board.shots:
                return pos
        remaining = [(r, c) for r in range(GRID) for c in range(GRID)
                     if (r, c) not in board.shots]
        return random.choice(remaining)

    def record(self, r: int, c: int, result: str):
        if result == "sunk":
            self._hit_run.clear()
            self._targets.clear()
            self._axis = None
        elif result == "hit":
            self._hit_run.append((r, c))
            self._rebuild_targets(r, c)

    def _rebuild_targets(self, r: int, c: int):
        if len(self._hit_run) >= 2:
            r0, c0 = self._hit_run[0]
            r1, _  = self._hit_run[1]
            self._axis = "v" if r0 != r1 else "h"
        if self._axis == "h":
            cols = sorted(cc for _, cc in self._hit_run)
            self._targets = [(r, cols[0] - 1), (r, cols[-1] + 1)]
        elif self._axis == "v":
            rows = sorted(rr for rr, _ in self._hit_run)
            self._targets = [(rows[0] - 1, c), (rows[-1] + 1, c)]
        else:
            self._targets = [(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)]
        self._targets = [p for p in self._targets if _in_bounds(*p)]


def _in_bounds(r: int, c: int) -> bool:
    return 0 <= r < GRID and 0 <= c < GRID


def _row_label(r: int) -> str:
    return chr(ord('A') + r)


def _col_label(c: int) -> str:
    return str(c + 1)


def _parse_input(text: str) -> tuple[int, int] | None:
    text = text.strip().upper()
    if len(text) < 2:
        return None
    letter = text[0]
    max_letter = chr(ord('A') + GRID - 1)
    if not ('A' <= letter <= max_letter):
        return None
    try:
        num = int(text[1:])
    except ValueError:
        return None
    if not (1 <= num <= GRID):
        return None
    return (ord(letter) - ord('A'), num - 1)


def _handle_char(buf: str, ch: str) -> str:
    """Tolerant input: letter replaces letter, digit replaces digit."""
    cu = ch.upper()
    max_letter = chr(ord('A') + GRID - 1)
    if 'A' <= cu <= max_letter:
        # Keep existing digit if valid, replace letter
        suffix = buf[1:] if len(buf) >= 2 else ""
        return cu + suffix
    if cu.isdigit():
        num = int(cu)
        if 1 <= num <= GRID:
            # Keep existing letter if present, replace digit
            prefix = buf[0] if buf and buf[0].isalpha() else ""
            return prefix + cu
    return buf


def _make_fonts(base: int) -> dict:
    b = base
    return {
        "hud":   pygame.font.SysFont("sans", b + 2, bold=True),
        "label": pygame.font.SysFont("sans", max(9, b - 1), bold=True),
        "log":   pygame.font.SysFont("sans", b),
        "ship":  pygame.font.SysFont("sans", max(9, b - 1)),
        "pan":   pygame.font.SysFont("sans", b + 2, bold=True),
        "inp":   pygame.font.SysFont("sans", b + 6, bold=True),
        "over":  pygame.font.SysFont("sans", b + 30, bold=True),
        "btn":   pygame.font.SysFont("sans", max(9, b - 2), bold=True),
        "entit": pygame.font.SysFont("sans", max(9, b - 1), bold=True),
    }


# ── Drawing: fleet panel (ocean map style) ────────────────────────────────────

def _draw_fleet(screen: pygame.Surface, board: Board, cell: int,
                ox: int, oy: int, fonts: dict):
    """Small fleet panel: ocean map look. ox/oy = top of col-label row."""
    lf      = fonts["label"]
    grid_px = cell * GRID

    # Ocean fill + thin frame
    water_r = pygame.Rect(ox + LABEL_SZ, oy + LABEL_SZ, grid_px, grid_px)
    pygame.draw.rect(screen, C_FL_WATER, water_r)
    pygame.draw.rect(screen, C_FL_FRAME, water_r, 2)

    # Axis labels
    for c in range(GRID):
        s = lf.render(_col_label(c), True, C_FL_LABEL)
        screen.blit(s, (ox + LABEL_SZ + c * cell + cell // 2 - s.get_width() // 2,
                        oy + LABEL_SZ // 2 - s.get_height() // 2))
    for r in range(GRID):
        s = lf.render(_row_label(r), True, C_FL_LABEL)
        screen.blit(s, (ox + LABEL_SZ // 2 - s.get_width() // 2,
                        oy + LABEL_SZ + r * cell + cell // 2 - s.get_height() // 2))

    # Ships (always shown on fleet panel)
    for ship in board.ships:
        color = C_FL_SUNK if ship.sunk else ship.color
        for (r, c) in ship.cells:
            cr = pygame.Rect(ox + LABEL_SZ + c * cell + 1,
                             oy + LABEL_SZ + r * cell + 1, cell - 2, cell - 2)
            pygame.draw.rect(screen, color, cr, border_radius=max(2, cell // 8))

    # Shots on fleet (AI shots against player)
    for (r, c) in board.shots:
        ship = board.grid[r][c]
        cx = ox + LABEL_SZ + c * cell + cell // 2
        cy = oy + LABEL_SZ + r * cell + cell // 2
        if ship is not None:
            rad = max(2, cell // 4)
            pygame.draw.circle(screen, C_FL_HIT, (cx, cy), rad)
            d  = max(2, cell // 5)
            lw = max(1, cell // 10)
            pygame.draw.line(screen, C_FL_HIT_X, (cx-d, cy-d), (cx+d, cy+d), lw)
            pygame.draw.line(screen, C_FL_HIT_X, (cx+d, cy-d), (cx-d, cy+d), lw)
        else:
            rad = max(2, cell // 6)
            pygame.draw.circle(screen, C_FL_MISS, (cx, cy), rad, max(1, rad // 2))

    # Grid lines
    for i in range(GRID + 1):
        pygame.draw.line(screen, C_FL_GRID,
                         (ox + LABEL_SZ + i * cell, oy + LABEL_SZ),
                         (ox + LABEL_SZ + i * cell, oy + LABEL_SZ + grid_px))
        pygame.draw.line(screen, C_FL_GRID,
                         (ox + LABEL_SZ, oy + LABEL_SZ + i * cell),
                         (ox + LABEL_SZ + grid_px, oy + LABEL_SZ + i * cell))


def _draw_fleet_status(screen: pygame.Surface, board: Board,
                       ox: int, oy: int, cell: int, fonts: dict):
    sf    = fonts["ship"]
    bw    = max(8, min(13, cell - 4))
    gap   = 2
    row_h = max(16, bw + 6)
    for ship in board.ships:
        name_s = sf.render(ship.name, True, C_FL_SUNK if ship.sunk else ship.color)
        screen.blit(name_s, (ox + LABEL_SZ, oy))
        bx = ox + LABEL_SZ + 82
        for i, cell_pos in enumerate(ship.cells):
            color = C_FL_HIT if cell_pos in ship.hits else (
                C_FL_SUNK if ship.sunk else ship.color)
            br = pygame.Rect(bx + i * (bw + gap), oy + 2, bw, bw)
            pygame.draw.rect(screen, color, br, border_radius=2)
            pygame.draw.rect(screen, C_FL_GRID, br, 1, border_radius=2)
        oy += row_h


def _draw_enemy_status(screen: pygame.Surface, board: Board,
                       ox: int, oy: int, fonts: dict):
    """Compact enemy ship list in radar green — shows sunk/alive status."""
    tf    = fonts["entit"]
    sf    = fonts["ship"]
    title = tf.render("ENEMY SHIPS", True, C_EN_TITLE)
    screen.blit(title, (ox, oy))
    oy += title.get_height() + 6
    row_h = sf.get_height() + 5
    for ship in board.ships:
        color = C_EN_DEAD if ship.sunk else C_EN_ALIVE
        label = f"✕ {ship.name}" if ship.sunk else f"  {ship.name}"
        s = sf.render(label, True, color)
        screen.blit(s, (ox, oy))
        oy += row_h


# ── Drawing: radar panel (phosphor CRT green) ─────────────────────────────────

def _draw_radar(screen: pygame.Surface, board: Board, cell: int,
                ox: int, oy: int,
                cursor_row: int | None, cursor_col: int | None,
                tick: int, fonts: dict):
    """Large radar screen with phosphor CRT aesthetic.
    ox/oy = top of col-label row (LABEL_SZ before grid)."""
    lf      = fonts["label"]
    grid_px = cell * GRID
    grid_x  = ox + LABEL_SZ
    grid_y  = oy + LABEL_SZ

    # ── Water fill with alternating cell shading ──
    pygame.draw.rect(screen, C_RD_WATER, (grid_x, grid_y, grid_px, grid_px))
    alt_surf = pygame.Surface((cell, cell), pygame.SRCALPHA)
    alt_surf.fill((0, 255, 60, 18))
    for r in range(GRID):
        for c in range(GRID):
            if (r + c) % 2 == 0:
                screen.blit(alt_surf, (grid_x + c * cell, grid_y + r * cell))

    # ── Sunk ship outlines ──
    for ship in board.ships:
        if ship.sunk:
            for (r, c) in ship.cells:
                cr = pygame.Rect(grid_x + c * cell + 1, grid_y + r * cell + 1,
                                 cell - 2, cell - 2)
                pygame.draw.rect(screen, C_RD_SHIP, cr, border_radius=max(2, cell // 10))

    # ── Shots ──
    pulse = 0.5 + 0.5 * math.sin(tick * 0.07)
    for (r, c) in board.shots:
        ship = board.grid[r][c]
        cx   = grid_x + c * cell + cell // 2
        cy   = grid_y + r * cell + cell // 2
        if ship is not None:
            # Hit: glowing orange/red blast
            base_r = max(3, cell // 3)
            for ring in range(4, 0, -1):
                rr  = base_r + ring * 2
                col = C_RD_HITGLO if ring >= 3 else C_RD_HIT
                pygame.draw.circle(screen, col, (cx, cy), rr, max(1, 5 - ring))
            pygame.draw.circle(screen, C_RD_HIT, (cx, cy), base_r)
        else:
            # Miss: concentric sonar rings
            for ring in range(2, 0, -1):
                rr  = max(2, cell // 6) + (ring - 1) * max(2, cell // 6)
                col = C_RD_MISS1 if ring == 1 else C_RD_MISS2
                pygame.draw.circle(screen, col, (cx, cy), rr, max(1, ring))

    # ── Grid lines ──
    for i in range(GRID + 1):
        pygame.draw.line(screen, C_RD_GRID,
                         (grid_x + i * cell, grid_y),
                         (grid_x + i * cell, grid_y + grid_px))
        pygame.draw.line(screen, C_RD_GRID,
                         (grid_x, grid_y + i * cell),
                         (grid_x + grid_px, grid_y + i * cell))

    # ── Axis labels ──
    for c in range(GRID):
        s = lf.render(_col_label(c), True, C_RD_LABEL)
        screen.blit(s, (grid_x + c * cell + cell // 2 - s.get_width() // 2,
                        oy + LABEL_SZ // 2 - s.get_height() // 2))
    for r in range(GRID):
        s = lf.render(_row_label(r), True, C_RD_LABEL)
        screen.blit(s, (ox + LABEL_SZ // 2 - s.get_width() // 2,
                        grid_y + r * cell + cell // 2 - s.get_height() // 2))

    # ── Cursor ──
    if cursor_row is not None:
        glow = int(180 + 75 * pulse)
        if cursor_col is not None:
            cc  = (0, glow, int(glow * 0.25))
            ccx = grid_x + cursor_col * cell
            ccy = grid_y + cursor_row * cell
            pygame.draw.rect(screen, cc,
                             (ccx + 1, ccy + 1, cell - 2, cell - 2),
                             width=max(2, cell // 9))
        else:
            cc  = (0, int(glow * 0.55), int(glow * 0.14))
            ccy = grid_y + cursor_row * cell
            pygame.draw.rect(screen, cc,
                             (grid_x + 1, ccy + 1, grid_px - 2, cell - 2),
                             width=max(1, cell // 14))

    # ── Scanlines overlay ──
    scan_h   = grid_px
    step     = max(2, cell // 10)
    scan_s   = pygame.Surface((grid_px, scan_h), pygame.SRCALPHA)
    for sy in range(0, scan_h, step * 2):
        pygame.draw.rect(scan_s, (0, 0, 0, 28), (0, sy, grid_px, max(1, step - 1)))
    screen.blit(scan_s, (grid_x, grid_y))

    # ── Frame (layered green borders + corner brackets) ──
    inner_r = pygame.Rect(grid_x - 2, grid_y - 2, grid_px + 4, grid_px + 4)
    mid_r   = inner_r.inflate(8, 8)
    outer_r = mid_r.inflate(8, 8)

    pygame.draw.rect(screen, C_RD_FRAME1, inner_r, 3, border_radius=3)
    pygame.draw.rect(screen, C_RD_FRAME2, mid_r,   2, border_radius=5)
    pygame.draw.rect(screen, C_RD_FRAME3, outer_r, 1, border_radius=7)

    # Corner L-bracket accents
    bl = max(10, cell // 3)
    for (fx, fy, dx, dy) in (
        (outer_r.left,  outer_r.top,    1,  1),
        (outer_r.right, outer_r.top,   -1,  1),
        (outer_r.left,  outer_r.bottom,  1, -1),
        (outer_r.right, outer_r.bottom, -1, -1),
    ):
        pygame.draw.line(screen, C_RD_FRAME1, (fx, fy), (fx + dx * bl, fy), 2)
        pygame.draw.line(screen, C_RD_FRAME1, (fx, fy), (fx, fy + dy * bl), 2)


# ── Drawing: log ──────────────────────────────────────────────────────────────

def _draw_log(screen: pygame.Surface, log: list, y: int, h: int, sw: int,
              fonts: dict):
    pygame.draw.rect(screen, C_LOG_BG, (0, y, sw, h))
    pygame.draw.line(screen, (30, 55, 100), (0, y), (sw, y), 1)
    lf  = fonts["log"]
    lh  = lf.get_height() + 3
    row = y + h - lh - 4
    for text, color in reversed(log[-LOG_LINES:]):
        s = lf.render(text, True, color)
        screen.blit(s, (14, row))
        row -= lh


# ── Drawing: font size buttons ────────────────────────────────────────────────

def _draw_font_btns(screen: pygame.Surface,
                    minus_rect: pygame.Rect, plus_rect: pygame.Rect,
                    font_base: int, fonts: dict):
    """Draw [A-] [A+] buttons using pre-computed rects."""
    bf = fonts["btn"]
    for br, label, enabled in (
        (minus_rect, "A-", font_base > FONT_BASE_MIN),
        (plus_rect,  "A+", font_base < FONT_BASE_MAX),
    ):
        bg    = C_BTN_BG if enabled else (14, 28, 54)
        txt_c = C_BTN_TXT if enabled else (70, 90, 120)
        pygame.draw.rect(screen, bg, br, border_radius=4)
        pygame.draw.rect(screen, C_BTN_FRAME if enabled else (35, 55, 90),
                         br, 1, border_radius=4)
        s = bf.render(label, True, txt_c)
        screen.blit(s, (br.x + br.w // 2 - s.get_width() // 2,
                        br.y + br.h // 2 - s.get_height() // 2))


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    single_instance("battleship")
    pygame.init()

    icon = pygame.image.load(resource_path("assets/icons/battleship.png", GAME_DIR))
    pygame.display.set_icon(icon)

    screen     = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
    maximize_window()
    pygame.display.set_caption(TITLE)
    draw_splash(screen, TITLE)
    clock      = pygame.time.Clock()
    status_bar = StatusBar()

    font_base = FONT_BASE_DEF
    fonts     = _make_fonts(font_base)

    player_board: Board
    ai_board:     Board
    ai_agent:     AI
    log:          list
    state:        str
    ai_timer:     int
    input_buf:    str
    winner:       str
    tick:         int

    def reset():
        nonlocal player_board, ai_board, ai_agent, log, state, ai_timer, \
                 input_buf, winner, tick
        player_board = Board()
        ai_board     = Board()
        ai_agent     = AI()
        player_board.place_random()
        ai_board.place_random()
        log       = [("Game start! Type a coordinate (e.g. B4) then press Enter to fire.",
                      C_LOG_TEXT)]
        state     = STATE_PLAYER
        ai_timer  = 0
        input_buf = ""
        winner    = ""
        tick      = 0

    reset()

    running = True
    while running:
        tick    += 1
        sw, sh   = screen.get_size()
        status_h = status_bar.height

        # ── Layout ────────────────────────────────────────────────────────────
        HUD_H  = 34
        LOG_H  = max(72, min(108, sh // 7))
        avail_h = sh - status_h - HUD_H - LOG_H - 8

        # Radar: fill most of available height, cap at 60% screen width
        rd_max_h = avail_h - PAN_LABEL_H - LABEL_SZ - 6
        rd_max_w = (sw * 60 // 100 - LABEL_SZ - PANEL_GAP)
        rd_cell  = max(14, min(rd_max_h // GRID, rd_max_w // GRID))
        rd_px    = rd_cell * GRID

        # Radar position: right side, vertically centered in working area
        rd_ox  = sw - PANEL_GAP - LABEL_SZ - rd_px
        rd_oy  = HUD_H + (avail_h - PAN_LABEL_H - LABEL_SZ - rd_px) // 2

        # Fleet: top-left corner, ~36% of radar cell
        fl_cell = max(10, rd_cell * 36 // 100)
        fl_px   = fl_cell * GRID
        fl_ox   = PANEL_GAP
        fl_oy   = HUD_H + 4 + PAN_LABEL_H    # start of col-label row

        fl_status_y = fl_oy + LABEL_SZ + fl_px + 5

        # Enemy status: below fleet status in the left column
        ship_row_h   = fonts["ship"].get_height() + 5
        fl_total_h   = (fl_oy + LABEL_SZ + fl_px
                        + len(SHIP_DEFS) * (max(16, fl_cell - 4 + 6)) + 10)
        en_status_y  = fl_total_h + 12

        log_y = sh - status_h - LOG_H

        # ── Font button geometry (computed before events so clicks register) ───
        _bf    = fonts["btn"]
        _bh    = max(22, HUD_H - 8)
        _bw    = max(32, _bf.get_height() + 18)
        _by    = (HUD_H - _bh) // 2
        _bx_p  = sw - PANEL_GAP - _bw
        _bx_m  = _bx_p - 4 - _bw
        minus_rect = pygame.Rect(_bx_m, _by, _bw, _bh)
        plus_rect  = pygame.Rect(_bx_p, _by, _bw, _bh)

        # ── Cursor from input buffer ───────────────────────────────────────────
        cur_row: int | None = None
        cur_col: int | None = None
        if input_buf and state == STATE_PLAYER:
            ch = input_buf[0].upper()
            if 'A' <= ch <= chr(ord('A') + GRID - 1):
                cur_row = ord(ch) - ord('A')
                if len(input_buf) >= 2:
                    try:
                        num = int(input_buf[1:])
                        if 1 <= num <= GRID:
                            cur_col = num - 1
                    except ValueError:
                        pass

        # ── Events ────────────────────────────────────────────────────────────
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False

            elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                if minus_rect.collidepoint(event.pos):
                    if font_base > FONT_BASE_MIN:
                        font_base = max(FONT_BASE_MIN, font_base - FONT_STEP)
                        fonts = _make_fonts(font_base)
                elif plus_rect.collidepoint(event.pos):
                    if font_base < FONT_BASE_MAX:
                        font_base = min(FONT_BASE_MAX, font_base + FONT_STEP)
                        fonts = _make_fonts(font_base)

            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                elif event.key == pygame.K_r:
                    reset()
                elif state == STATE_PLAYER:
                    if event.key == pygame.K_BACKSPACE:
                        input_buf = input_buf[:-1]
                    elif event.key == pygame.K_RETURN:
                        coord = _parse_input(input_buf)
                        if coord is None:
                            if input_buf:
                                log.append(
                                    (f"'{input_buf}' not valid — type a letter A–{_row_label(GRID-1)}"
                                     f" then a number 1–{GRID}.",
                                     C_LOG_BAD))
                        else:
                            r, c   = coord
                            result = ai_board.shoot(r, c)
                            label  = f"{_row_label(r)}{_col_label(c)}"
                            if result == "already":
                                log.append(("Already fired there — pick another square.", C_LOG_BAD))
                            else:
                                input_buf = ""
                                if result == "miss":
                                    log.append((f"You fire at {label} — miss.", C_LOG_TEXT))
                                elif result == "hit":
                                    log.append((f"You fire at {label} — HIT!", C_LOG_GOOD))
                                elif result == "sunk":
                                    ship = ai_board.grid[r][c]
                                    log.append((f"You fire at {label} — SUNK the {ship.name}!",
                                                C_LOG_SUNK))
                                if ai_board.all_sunk():
                                    state  = STATE_OVER
                                    winner = "player"
                                    log.append(
                                        ("ALL ENEMY SHIPS DESTROYED — YOU WIN!  Press R to play again.",
                                         C_LOG_GOOD))
                                    # ts ("last played") LAST so the HA automation
                                    # sees updated result/shots. Ordered delivery.
                                    mqtt_publish_many([
                                        ("battleship/result", "win"),
                                        ("battleship/shots", len(ai_board.shots)),
                                        ("battleship/ts", int(time.time())),
                                    ])
                                else:
                                    state    = STATE_AI
                                    ai_timer = AI_DELAY
                    else:
                        input_buf = _handle_char(input_buf, event.unicode)

            status_bar.handle_event(event)

        # ── AI turn ───────────────────────────────────────────────────────────
        if state == STATE_AI:
            ai_timer -= 1
            if ai_timer <= 0:
                r, c   = ai_agent.choose(player_board)
                result = player_board.shoot(r, c)
                ai_agent.record(r, c, result)
                label  = f"{_row_label(r)}{_col_label(c)}"
                if result == "miss":
                    log.append((f"Enemy fires at {label} — miss.", C_LOG_TEXT))
                elif result == "hit":
                    log.append((f"Enemy fires at {label} — hit your ship!", C_LOG_BAD))
                elif result == "sunk":
                    ship = player_board.grid[r][c]
                    log.append((f"Enemy fires at {label} — sunk your {ship.name}!", C_LOG_SUNK))
                if player_board.all_sunk():
                    state  = STATE_OVER
                    winner = "ai"
                    log.append(
                        ("ALL YOUR SHIPS SUNK — GAME OVER.  Press R to play again.", C_LOG_BAD))
                    # ts ("last played") LAST so the HA automation sees updated
                    # result/shots. One connection, ordered delivery.
                    mqtt_publish_many([
                        ("battleship/result", "loss"),
                        ("battleship/shots", len(ai_board.shots)),
                        ("battleship/ts", int(time.time())),
                    ])
                else:
                    state = STATE_PLAYER

        # ── Draw ──────────────────────────────────────────────────────────────
        screen.fill(C_BG)

        # Fleet panel label
        pf = fonts["pan"]
        fl_title = pf.render("YOUR FLEET", True, C_FL_PAN)
        screen.blit(fl_title, (fl_ox + LABEL_SZ, HUD_H + 4))

        # Fleet board
        _draw_fleet(screen, player_board, fl_cell, fl_ox, fl_oy, fonts)
        _draw_fleet_status(screen, player_board, fl_ox, fl_status_y, fl_cell, fonts)

        # Enemy status (left column, below fleet)
        if en_status_y + 10 < log_y - 10:
            _draw_enemy_status(screen, ai_board, fl_ox + LABEL_SZ, en_status_y, fonts)

        # Radar panel label
        rd_title_s = pf.render("ENEMY WATERS", True, C_RD_PAN)
        rd_title_x = rd_ox + LABEL_SZ + (rd_px - rd_title_s.get_width()) // 2
        screen.blit(rd_title_s, (rd_title_x, rd_oy - PAN_LABEL_H + 2))

        # Radar board
        _draw_radar(screen, ai_board, rd_cell, rd_ox, rd_oy,
                    cur_row, cur_col, tick, fonts)

        # HUD strip
        hf = fonts["hud"]
        if state == STATE_OVER:
            hud_str = "Game over — press R to play again"
        elif state == STATE_AI:
            hud_str = "Enemy is targeting…"
        else:
            buf_disp = input_buf if input_buf else "?"
            hud_str  = f"Your turn — target: {buf_disp}  · Enter to fire · R = restart"
        hud_s = hf.render(hud_str, True, C_HUD)
        screen.blit(hud_s, (PANEL_GAP, HUD_H // 2 - hud_s.get_height() // 2))

        _draw_font_btns(screen, minus_rect, plus_rect, font_base, fonts)

        # Input display (left column, above log, in radar green)
        if state == STATE_PLAYER:
            blink    = (pygame.time.get_ticks() // 500) % 2 == 0
            disp_buf = input_buf + ("▌" if blink else " ")
            inp_s    = fonts["inp"].render(f"► {disp_buf}", True, C_INP)
            inp_x    = rd_ox // 2 - inp_s.get_width() // 2
            inp_y    = log_y - inp_s.get_height() - 6
            screen.blit(inp_s, (max(PANEL_GAP, inp_x), inp_y))

        # Log
        _draw_log(screen, log, log_y, LOG_H, sw, fonts)

        # Game-over overlay
        if state == STATE_OVER:
            ov_color = C_LOG_GOOD if winner == "player" else C_LOG_BAD
            ov_text  = "YOU WIN!" if winner == "player" else "YOU LOSE!"
            ov_s     = fonts["over"].render(ov_text, True, ov_color)
            ox_ov    = sw // 2 - ov_s.get_width() // 2
            oy_ov    = sh // 2 - ov_s.get_height()
            bg_r     = pygame.Rect(ox_ov - 28, oy_ov - 14,
                                   ov_s.get_width() + 56, ov_s.get_height() + 28)
            pygame.draw.rect(screen, (6, 12, 26), bg_r, border_radius=14)
            screen.blit(ov_s, (ox_ov, oy_ov))
            sub_s = hf.render("Press R to play again", True, C_HUD)
            screen.blit(sub_s, (sw // 2 - sub_s.get_width() // 2,
                                oy_ov + ov_s.get_height() + 6))

        status_bar.draw(screen)
        pygame.display.flip()
        clock.tick(FPS)

    pygame.quit()
    sys.exit()


if __name__ == "__main__":
    main()
