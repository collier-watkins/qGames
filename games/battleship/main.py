import os
import random
import sys

import pygame

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from shared.status_bar import StatusBar
from shared.util import resource_path

GAME_DIR = os.path.dirname(os.path.abspath(__file__))

TITLE     = "Battleship"
FPS       = 60
GRID      = 10
AI_DELAY  = 75   # frames between player's shot and AI's response

SHIP_DEFS = [
    ("Carrier",    5, ( 90, 185, 235)),
    ("Battleship", 4, (220, 140,  50)),
    ("Cruiser",    3, ( 80, 205, 105)),
    ("Submarine",  3, (175, 100, 225)),
    ("Destroyer",  2, (235, 210,  50)),
]

C_BG         = ( 12,  22,  42)
C_WATER      = ( 18,  46,  90)
C_GRID_LINE  = ( 30,  62, 118)
C_LABEL      = (130, 162, 210)
C_SHIP       = (142, 155, 170)
C_SHIP_SUNK  = ( 72,  78,  88)
C_HIT        = (218,  62,  42)
C_MISS       = ( 55,  95, 162)
C_CURSOR_ROW = (180, 155,  30)
C_CURSOR_CEL = (245, 215,  50)
C_HUD        = (128, 162, 212)
C_LOG_BG     = ( 14,  26,  50)
C_LOG_TEXT   = (172, 198, 238)
C_LOG_GOOD   = ( 95, 225, 115)
C_LOG_BAD    = (225,  95,  85)
C_LOG_SUNK   = (235, 162,  42)
C_PAN_LABEL  = (195, 218, 255)

STATE_PLAYER = "player"
STATE_AI     = "ai"
STATE_OVER   = "over"

PANEL_GAP  = 20
LABEL_SZ   = 22
PAN_LABEL_H = 24
LOG_LINES  = 6


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
        self.grid:  list[list]          = [[None] * GRID for _ in range(GRID)]
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
        """Returns 'already', 'miss', 'hit', or 'sunk'."""
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
    """Hunt / target AI: checkerboard hunt + axis-focused targeting."""

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
            r1, c1 = self._hit_run[1]
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


def _parse_input(text: str) -> tuple[int, int] | None:
    text = text.strip().upper()
    if len(text) < 2:
        return None
    letter = text[0]
    if not ('A' <= letter <= 'J'):
        return None
    try:
        num = int(text[1:])
    except ValueError:
        return None
    if not (1 <= num <= 10):
        return None
    return (ord(letter) - ord('A'), num - 1)


def _row_label(r: int) -> str:
    return chr(ord('A') + r)


def _col_label(c: int) -> str:
    return str(c + 1)


# ── Drawing ───────────────────────────────────────────────────────────────────

def _draw_board(screen: pygame.Surface, board: Board, cell: int,
                ox: int, oy: int, show_ships: bool,
                cursor_row: int | None, cursor_col: int | None,
                fonts: dict):
    """Draw a 10×10 grid.  ox/oy = top-left of label area."""
    lf      = fonts["label"]
    grid_px = cell * GRID

    # Ocean
    pygame.draw.rect(screen, C_WATER,
                     (ox + LABEL_SZ, oy + LABEL_SZ, grid_px, grid_px))

    # Axis labels
    for c in range(GRID):
        s = lf.render(_col_label(c), True, C_LABEL)
        screen.blit(s, (ox + LABEL_SZ + c * cell + cell // 2 - s.get_width() // 2,
                        oy + LABEL_SZ // 2 - s.get_height() // 2))
    for r in range(GRID):
        s = lf.render(_row_label(r), True, C_LABEL)
        screen.blit(s, (ox + LABEL_SZ // 2 - s.get_width() // 2,
                        oy + LABEL_SZ + r * cell + cell // 2 - s.get_height() // 2))

    # Ships
    for ship in board.ships:
        if not show_ships and not ship.sunk:
            continue
        color = C_SHIP_SUNK if ship.sunk else ship.color
        for (r, c) in ship.cells:
            cr = pygame.Rect(ox + LABEL_SZ + c * cell + 1,
                             oy + LABEL_SZ + r * cell + 1,
                             cell - 2, cell - 2)
            pygame.draw.rect(screen, color, cr, border_radius=max(2, cell // 8))

    # Shots
    for (r, c) in board.shots:
        ship = board.grid[r][c]
        cx   = ox + LABEL_SZ + c * cell + cell // 2
        cy   = oy + LABEL_SZ + r * cell + cell // 2
        if ship is not None:
            rad = max(3, cell // 3)
            pygame.draw.circle(screen, C_HIT, (cx, cy), rad)
            d  = max(2, cell // 5)
            lw = max(1, cell // 10)
            pygame.draw.line(screen, (255, 195, 185),
                             (cx - d, cy - d), (cx + d, cy + d), lw)
            pygame.draw.line(screen, (255, 195, 185),
                             (cx + d, cy - d), (cx - d, cy + d), lw)
        else:
            rad = max(2, cell // 6)
            pygame.draw.circle(screen, C_MISS, (cx, cy), rad, max(1, rad // 2 + 1))

    # Grid lines
    for i in range(GRID + 1):
        pygame.draw.line(screen, C_GRID_LINE,
                         (ox + LABEL_SZ + i * cell, oy + LABEL_SZ),
                         (ox + LABEL_SZ + i * cell, oy + LABEL_SZ + grid_px))
        pygame.draw.line(screen, C_GRID_LINE,
                         (ox + LABEL_SZ, oy + LABEL_SZ + i * cell),
                         (ox + LABEL_SZ + grid_px, oy + LABEL_SZ + i * cell))

    # Cursor
    if cursor_row is not None:
        if cursor_col is not None:
            # Full cell highlight
            cx = ox + LABEL_SZ + cursor_col * cell
            cy = oy + LABEL_SZ + cursor_row * cell
            pygame.draw.rect(screen, C_CURSOR_CEL,
                             (cx + 1, cy + 1, cell - 2, cell - 2),
                             width=max(2, cell // 10))
        else:
            # Row highlight (only letter typed so far)
            cy = oy + LABEL_SZ + cursor_row * cell
            pygame.draw.rect(screen, C_CURSOR_ROW,
                             (ox + LABEL_SZ + 1, cy + 1, grid_px - 2, cell - 2),
                             width=max(1, cell // 14))


def _draw_ship_status(screen: pygame.Surface, board: Board,
                      ox: int, oy: int, cell: int, fonts: dict):
    sf     = fonts["ship"]
    box_w  = max(10, min(16, cell - 4))
    gap    = 3
    row_h  = max(18, box_w + 7)

    for ship in board.ships:
        name_s = sf.render(ship.name, True,
                           C_SHIP_SUNK if ship.sunk else ship.color)
        screen.blit(name_s, (ox + LABEL_SZ, oy))
        bx = ox + LABEL_SZ + 86
        for i, cell_pos in enumerate(ship.cells):
            color = C_HIT if cell_pos in ship.hits else (
                C_SHIP_SUNK if ship.sunk else ship.color)
            br = pygame.Rect(bx + i * (box_w + gap), oy + 2, box_w, box_w)
            pygame.draw.rect(screen, color, br, border_radius=2)
            pygame.draw.rect(screen, C_GRID_LINE, br, 1, border_radius=2)
        oy += row_h


def _draw_log(screen: pygame.Surface, log: list, y: int, h: int, sw: int,
              fonts: dict):
    pygame.draw.rect(screen, C_LOG_BG, (0, y, sw, h))
    pygame.draw.line(screen, C_GRID_LINE, (0, y), (sw, y), 1)
    lf  = fonts["log"]
    lh  = lf.get_height() + 3
    row = y + h - lh - 4
    for text, color in reversed(log[-LOG_LINES:]):
        s = lf.render(text, True, color)
        screen.blit(s, (14, row))
        row -= lh


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    pygame.init()

    icon = pygame.image.load(resource_path("assets/icons/battleship.png", GAME_DIR))
    pygame.display.set_icon(icon)

    screen     = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
    pygame.display.set_caption(TITLE)
    clock      = pygame.time.Clock()
    status_bar = StatusBar()

    hud_font  = pygame.font.SysFont("sans", 17, bold=True)
    lbl_font  = pygame.font.SysFont("sans", 13, bold=True)
    log_font  = pygame.font.SysFont("sans", 15)
    ship_font = pygame.font.SysFont("sans", 13)
    pan_font  = pygame.font.SysFont("sans", 16, bold=True)
    inp_font  = pygame.font.SysFont("sans", 19, bold=True)
    over_font = pygame.font.SysFont("sans", 44, bold=True)

    fonts = {"label": lbl_font, "log": log_font, "ship": ship_font}

    player_board: Board
    ai_board:     Board
    ai_agent:     AI
    log:          list
    state:        str
    ai_timer:     int
    input_buf:    str
    winner:       str

    def reset():
        nonlocal player_board, ai_board, ai_agent, log, state, ai_timer, input_buf, winner
        player_board = Board()
        ai_board     = Board()
        ai_agent     = AI()
        player_board.place_random()
        ai_board.place_random()
        log       = [("Game start! Type a coordinate (e.g. B3 or J10) then press Enter to fire.",
                      C_LOG_TEXT)]
        state     = STATE_PLAYER
        ai_timer  = 0
        input_buf = ""
        winner    = ""

    reset()

    running = True
    while running:
        sw, sh   = screen.get_size()
        status_h = status_bar.height

        # ── Layout ────────────────────────────────────────────────────────────
        HUD_H       = 42
        LOG_H       = max(80, min(125, sh // 6))
        SHIP_INFO_H = len(SHIP_DEFS) * 21 + 10

        avail_h = sh - status_h - HUD_H - PAN_LABEL_H - LOG_H - 18
        panel_w = (sw - PANEL_GAP * 3) // 2

        max_cell_w = max(6, (panel_w - LABEL_SZ - 4) // GRID)
        max_cell_h = max(6, (avail_h - SHIP_INFO_H - LABEL_SZ) // GRID)
        cell    = min(max_cell_w, max_cell_h)
        grid_px = cell * GRID

        ox_L = PANEL_GAP
        ox_R = PANEL_GAP * 2 + panel_w
        oy   = HUD_H + 4               # panel label top
        b_oy = oy + PAN_LABEL_H        # board top (col/row label origin)

        ship_oy = b_oy + LABEL_SZ + grid_px + 6
        log_y   = sh - status_h - LOG_H

        # ── Cursor from input buffer ───────────────────────────────────────────
        cur_row: int | None = None
        cur_col: int | None = None
        if input_buf and state == STATE_PLAYER:
            ch = input_buf[0].upper()
            if 'A' <= ch <= 'J':
                cur_row = ord(ch) - ord('A')
                if len(input_buf) >= 2:
                    try:
                        num = int(input_buf[1:])
                        if 1 <= num <= 10:
                            cur_col = num - 1
                    except ValueError:
                        pass

        # ── Events ────────────────────────────────────────────────────────────
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False

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
                                    (f"'{input_buf}' is not valid — enter letter A–J then number 1–10.",
                                     C_LOG_BAD))
                        else:
                            r, c   = coord
                            result = ai_board.shoot(r, c)
                            label  = f"{_row_label(r)}{_col_label(c)}"
                            if result == "already":
                                log.append(("You already fired there!", C_LOG_BAD))
                            else:
                                input_buf = ""
                                if result == "miss":
                                    log.append((f"You fired at {label} — miss.", C_LOG_TEXT))
                                elif result == "hit":
                                    log.append((f"You fired at {label} — HIT!", C_LOG_GOOD))
                                elif result == "sunk":
                                    ship = ai_board.grid[r][c]
                                    log.append((f"You sank the enemy {ship.name}!", C_LOG_SUNK))

                                if ai_board.all_sunk():
                                    state  = STATE_OVER
                                    winner = "player"
                                    log.append(
                                        ("YOU WIN! All enemy ships destroyed. Press R to play again.",
                                         C_LOG_GOOD))
                                else:
                                    state    = STATE_AI
                                    ai_timer = AI_DELAY
                    else:
                        ch = event.unicode.upper()
                        if len(input_buf) == 0 and 'A' <= ch <= 'J':
                            input_buf = ch
                        elif len(input_buf) == 1 and ch.isdigit():
                            input_buf += ch
                        elif len(input_buf) == 2 and ch == '0' and input_buf[1] == '1':
                            input_buf += ch   # "10"

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
                    log.append((f"Enemy sank your {ship.name}!", C_LOG_SUNK))

                if player_board.all_sunk():
                    state  = STATE_OVER
                    winner = "ai"
                    log.append(
                        ("GAME OVER — all your ships were sunk. Press R to play again.",
                         C_LOG_BAD))
                else:
                    state = STATE_PLAYER

        # ── Draw ──────────────────────────────────────────────────────────────
        screen.fill(C_BG)

        # HUD
        if state == STATE_OVER:
            hud_str = "Game over — press R to play again"
        elif state == STATE_AI:
            hud_str = "Battleship  ·  Enemy is thinking…  ·  R = restart"
        else:
            buf_disp = input_buf if input_buf else "?"
            hud_str = (f"Battleship  ·  Your turn: type coordinate ({buf_disp})"
                       f" + Enter  ·  Backspace = clear  ·  R = restart")
        hud_s = hud_font.render(hud_str, True, C_HUD)
        screen.blit(hud_s, (sw // 2 - hud_s.get_width() // 2, 12))

        # Panel labels
        for label_str, ox in (("YOUR FLEET", ox_L), ("ENEMY WATERS", ox_R)):
            s = pan_font.render(label_str, True, C_PAN_LABEL)
            screen.blit(s, (ox + LABEL_SZ + (grid_px - s.get_width()) // 2, oy))

        # Boards
        _draw_board(screen, player_board, cell, ox_L, b_oy,
                    show_ships=True, cursor_row=None, cursor_col=None, fonts=fonts)
        _draw_board(screen, ai_board, cell, ox_R, b_oy,
                    show_ships=False, cursor_row=cur_row, cursor_col=cur_col, fonts=fonts)

        # Ship status
        _draw_ship_status(screen, player_board, ox_L, ship_oy, cell, fonts)
        _draw_ship_status(screen, ai_board,     ox_R, ship_oy, cell, fonts)

        # Input display (above log, centered)
        if state == STATE_PLAYER:
            cursor_blink = (pygame.time.get_ticks() // 500) % 2 == 0
            display_buf  = input_buf + ("_" if cursor_blink else " ")
            inp_s = inp_font.render(f"Target: {display_buf}", True, C_CURSOR_CEL)
            screen.blit(inp_s,
                        (sw // 2 - inp_s.get_width() // 2,
                         log_y - inp_s.get_height() - 5))

        # Log
        _draw_log(screen, log, log_y, LOG_H, sw, fonts)

        # Game-over overlay
        if state == STATE_OVER:
            ov_color = C_LOG_GOOD if winner == "player" else C_LOG_BAD
            ov_text  = "YOU WIN!" if winner == "player" else "YOU LOSE!"
            ov_s     = over_font.render(ov_text, True, ov_color)
            ox_ov    = sw // 2 - ov_s.get_width() // 2
            oy_ov    = sh // 2 - ov_s.get_height()
            bg_r     = pygame.Rect(ox_ov - 24, oy_ov - 12,
                                   ov_s.get_width() + 48, ov_s.get_height() + 24)
            pygame.draw.rect(screen, (8, 14, 32), bg_r, border_radius=12)
            screen.blit(ov_s, (ox_ov, oy_ov))
            sub_s = hud_font.render("Press R to play again", True, C_HUD)
            screen.blit(sub_s, (sw // 2 - sub_s.get_width() // 2,
                                oy_ov + ov_s.get_height() + 4))

        status_bar.draw(screen)
        pygame.display.flip()
        clock.tick(FPS)

    pygame.quit()
    sys.exit()


if __name__ == "__main__":
    main()
