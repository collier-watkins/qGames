import math
import os
import random
import sys

import pygame

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from shared.status_bar import StatusBar
from shared.util import resource_path

GAME_DIR = os.path.dirname(os.path.abspath(__file__))

TITLE = "Memory Match"
FPS   = 60
COLS, ROWS    = 4, 4
CARD_GAP      = 12
FLIP_BACK_TTL  = 75  # frames before unmatched pair flips back
MATCH_ANIM_TTL = 55  # frames of match celebration before going green

C_BG          = (25,  35,  60)
C_BACK        = (50,  80, 160)
C_BACK_BORDER = (80, 115, 200)
C_FRONT       = (240, 242, 248)
C_MATCHED     = ( 60, 170,  80)
C_MATCHED_SYM = (255, 255, 255)
C_HUD         = (160, 185, 230)

# 8 distinct colours, one per pair
PAIR_COLORS = [
    (220,  60,  60),
    ( 60, 130, 220),
    ( 60, 185,  80),
    (240, 200,  50),
    (220, 125,  45),
    (155,  65, 220),
    ( 45, 195, 200),
    (225,  80, 160),
]


class Card:
    __slots__ = ("pair", "face_up", "matched", "rect")

    def __init__(self, pair: int):
        self.pair    = pair
        self.face_up = False
        self.matched = False
        self.rect    = pygame.Rect(0, 0, 0, 0)


def _new_deck() -> list[Card]:
    pairs = list(range(COLS * ROWS // 2)) * 2
    random.shuffle(pairs)
    return [Card(p) for p in pairs]


def _layout(cards: list[Card], sw: int, sh: int, status_h: int):
    header   = 54
    usable_w = sw - CARD_GAP * 2
    usable_h = sh - header - status_h - CARD_GAP * 2
    cw = (usable_w - CARD_GAP * (COLS - 1)) // COLS
    ch = (usable_h - CARD_GAP * (ROWS - 1)) // ROWS
    side = min(cw, ch)

    grid_w = side * COLS + CARD_GAP * (COLS - 1)
    grid_h = side * ROWS + CARD_GAP * (ROWS - 1)
    ox = (sw - grid_w) // 2
    oy = header + (sh - header - status_h - grid_h) // 2

    for i, card in enumerate(cards):
        col, row = i % COLS, i // COLS
        card.rect = pygame.Rect(
            ox + col * (side + CARD_GAP),
            oy + row * (side + CARD_GAP),
            side, side,
        )


def _draw_card(screen: pygame.Surface, card: Card):
    r  = card.rect
    br = max(6, r.width // 8)

    if card.matched:
        pygame.draw.rect(screen, C_MATCHED, r, border_radius=br)
        # tick mark
        cx, cy = r.centerx, r.centery
        hw = r.width // 5
        pts = [(cx - hw, cy), (cx - hw // 3, cy + hw * 2 // 3), (cx + hw, cy - hw // 2)]
        pygame.draw.lines(screen, C_MATCHED_SYM, False, pts, max(3, r.width // 12))

    elif card.face_up:
        pygame.draw.rect(screen, C_FRONT, r, border_radius=br)
        cr = max(8, r.width // 3)
        pygame.draw.circle(screen, PAIR_COLORS[card.pair], r.center, cr)

    else:
        pygame.draw.rect(screen, C_BACK, r, border_radius=br)
        pygame.draw.rect(screen, C_BACK_BORDER, r, border_radius=br, width=3)
        inner = r.inflate(-r.width // 4, -r.height // 4)
        pygame.draw.rect(screen, C_BACK_BORDER, inner, border_radius=max(3, br - 4), width=2)


def _draw_match_anim(screen: pygame.Surface, card: Card, ttl: int):
    """Two expanding ripple rings in the pair's colour, fading outward."""
    color    = PAIR_COLORS[card.pair]
    progress = 1.0 - ttl / MATCH_ANIM_TTL          # 0 → 1
    max_r    = math.hypot(card.rect.width, card.rect.height) * 0.65

    for lag in (0.0, 0.35):                         # second ring starts at 35 %
        p = (progress - lag) / (1.0 - lag)
        if p <= 0:
            continue
        p      = min(p, 1.0)
        ring_r = int(max_r * p)
        ring_w = max(1, int(6 * (1.0 - p)))
        if ring_r > 0:
            pygame.draw.circle(screen, color, card.rect.center, ring_r, ring_w)


def main():
    pygame.init()

    icon = pygame.image.load(resource_path("assets/icons/memory.png", GAME_DIR))
    pygame.display.set_icon(icon)

    screen = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
    pygame.display.set_caption(TITLE)
    clock      = pygame.time.Clock()
    status_bar = StatusBar()
    hud_font   = pygame.font.SysFont("sans", 20, bold=True)
    win_font   = pygame.font.SysFont("sans", 36, bold=True)

    def reset():
        nonlocal cards, flipped, pending, wait_ttl, moves, matches
        cards    = _new_deck()
        flipped  = []
        pending  = []   # [[idx_a, idx_b, ttl], ...]  — matched, animating
        wait_ttl = 0
        moves    = 0
        matches  = 0

    def try_flip(idx: int):
        """Flip the card at grid index idx (shared by mouse and keyboard)."""
        nonlocal moves, matches, wait_ttl
        animating = {i for e in pending for i in (e[0], e[1])}
        card = cards[idx]
        if (wait_ttl != 0 or all(c.matched for c in cards)
                or card.face_up or card.matched or idx in animating):
            return
        card.face_up = True
        flipped.append(idx)
        if len(flipped) == 2:
            moves += 1
            a, b = cards[flipped[0]], cards[flipped[1]]
            if a.pair == b.pair:
                matches += 1
                pending.append([flipped[0], flipped[1], MATCH_ANIM_TTL])
                flipped.clear()
            else:
                wait_ttl = FLIP_BACK_TTL

    cards    = []
    flipped  = []
    pending  = []
    wait_ttl = 0
    moves    = 0
    matches  = 0
    cursor   = [0, 0]   # [row, col]
    reset()

    running = True
    while running:
        sw, sh = screen.get_size()
        _layout(cards, sw, sh, status_bar.height)

        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                elif event.key == pygame.K_r:
                    cursor[:] = [0, 0]
                    reset()
                # elif event.key == pygame.K_UP:
                #     cursor[0] = max(0, cursor[0] - 1)
                # elif event.key == pygame.K_DOWN:
                #     cursor[0] = min(ROWS - 1, cursor[0] + 1)
                # elif event.key == pygame.K_LEFT:
                #     cursor[1] = max(0, cursor[1] - 1)
                # elif event.key == pygame.K_RIGHT:
                #     cursor[1] = min(COLS - 1, cursor[1] + 1)
                # elif event.key in (pygame.K_RETURN, pygame.K_SPACE):
                #     try_flip(cursor[0] * COLS + cursor[1])

            elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                for i, card in enumerate(cards):
                    if card.rect.collidepoint(event.pos):
                        try_flip(i)
                        break

            status_bar.handle_event(event)

        if wait_ttl > 0:
            wait_ttl -= 1
            if wait_ttl == 0:
                for i in flipped:
                    cards[i].face_up = False
                flipped = []

        for entry in pending[:]:
            entry[2] -= 1
            if entry[2] <= 0:
                cards[entry[0]].matched = True
                cards[entry[1]].matched = True
                pending.remove(entry)

        # ── draw ──────────────────────────────────────────────────────────────
        screen.fill(C_BG)

        hud = hud_font.render(
            f"Memory Match   ·   moves: {moves}   ·   "
            f"matched: {matches} / {COLS * ROWS // 2}   ·   R to restart",
            True, C_HUD,
        )
        screen.blit(hud, (sw // 2 - hud.get_width() // 2, 16))

        for card in cards:
            _draw_card(screen, card)

        for entry in pending:
            for idx in (entry[0], entry[1]):
                _draw_match_anim(screen, cards[idx], entry[2])

        # keyboard cursor highlight (disabled)
        # cur_card = cards[cursor[0] * COLS + cursor[1]]
        # br = max(6, cur_card.rect.width // 8)
        # pygame.draw.rect(screen, (255, 240, 80),
        #                  cur_card.rect.inflate(8, 8),
        #                  width=4, border_radius=br + 4)

        if all(c.matched for c in cards):
            msg = win_font.render(
                f"You won in {moves} moves!  —  press R to play again", True, (120, 240, 130)
            )
            screen.blit(msg, (sw // 2 - msg.get_width() // 2,
                               sh // 2 - msg.get_height() // 2))

        status_bar.draw(screen)
        pygame.display.flip()
        clock.tick(FPS)

    pygame.quit()
    sys.exit()


if __name__ == "__main__":
    main()
