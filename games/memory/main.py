import math
import os
import secrets
import sys
import time

import pygame

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from shared.mqtt_stats import publish as mqtt_publish
from shared.status_bar import StatusBar
from shared.util import maximize_window, resource_path

GAME_DIR = os.path.dirname(os.path.abspath(__file__))

TITLE       = "Memory Match"
FPS         = 30
COLS, ROWS  = 4, 4
CARD_GAP    = 12
TOTAL_PAIRS = COLS * ROWS // 2

# Tuned for 30 FPS (halved from original 60-FPS values to keep same real-time duration)
FLIP_BACK_TTL  = 38   # ~1.25 s before unmatched pair flips back
MATCH_ANIM_TTL = 28   # ~0.93 s of match-celebration ripple

C_BG          = (25,  35,  60)
C_BACK        = (50,  80, 160)
C_BACK_BORDER = (80, 115, 200)
C_FRONT       = (240, 242, 248)
C_MATCHED     = ( 60, 170,  80)
C_MATCHED_SYM = (255, 255, 255)
C_HUD         = (160, 185, 230)

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
    pairs = list(range(TOTAL_PAIRS)) * 2
    for i in range(len(pairs) - 1, 0, -1):
        j = secrets.randbelow(i + 1)
        pairs[i], pairs[j] = pairs[j], pairs[i]
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
        cx, cy = r.centerx, r.centery
        hw = r.width // 5
        pts = [(cx - hw, cy), (cx - hw // 3, cy + hw * 2 // 3), (cx + hw, cy - hw // 2)]
        pygame.draw.lines(screen, C_MATCHED_SYM, False, pts, max(3, r.width // 12))
    elif card.face_up:
        pygame.draw.rect(screen, C_FRONT, r, border_radius=br)
        pygame.draw.circle(screen, PAIR_COLORS[card.pair], r.center, max(8, r.width // 3))
    else:
        pygame.draw.rect(screen, C_BACK, r, border_radius=br)
        pygame.draw.rect(screen, C_BACK_BORDER, r, border_radius=br, width=3)
        inner = r.inflate(-r.width // 4, -r.height // 4)
        pygame.draw.rect(screen, C_BACK_BORDER, inner, border_radius=max(3, br - 4), width=2)


def _draw_match_anim(screen: pygame.Surface, card: Card, ttl: int):
    color    = PAIR_COLORS[card.pair]
    progress = 1.0 - ttl / MATCH_ANIM_TTL
    max_r    = math.hypot(card.rect.width, card.rect.height) * 0.65

    for lag in (0.0, 0.35):
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
    maximize_window()
    pygame.display.set_caption(TITLE)
    clock      = pygame.time.Clock()
    status_bar = StatusBar()
    hud_font   = pygame.font.SysFont("sans", 20, bold=True)
    win_font   = pygame.font.SysFont("sans", 36, bold=True)

    hud_surf = None
    hud_key  = None   # (moves, matches, sw) — invalidate cache when any changes

    cards    = []
    flipped  = []
    pending  = []
    wait_ttl = 0
    moves    = 0
    matches  = 0
    dirty    = True
    last_sw = last_sh = last_status_h = 0

    def reset():
        nonlocal cards, flipped, pending, wait_ttl, moves, matches
        nonlocal dirty, last_sw, last_sh, last_status_h
        cards    = _new_deck()
        flipped  = []
        pending  = []
        wait_ttl = 0
        moves    = 0
        matches  = 0
        dirty    = True
        last_sw = last_sh = last_status_h = 0  # force layout recalc

    def try_flip(idx: int):
        nonlocal moves, matches, wait_ttl, dirty
        if wait_ttl or matches == TOTAL_PAIRS:
            return
        card = cards[idx]
        animating = {i for e in pending for i in (e[0], e[1])}
        if card.face_up or card.matched or idx in animating:
            return
        card.face_up = True
        flipped.append(idx)
        dirty = True
        if len(flipped) == 2:
            moves += 1
            a, b = cards[flipped[0]], cards[flipped[1]]
            if a.pair == b.pair:
                matches += 1
                pending.append([flipped[0], flipped[1], MATCH_ANIM_TTL])
                flipped.clear()
                if matches == TOTAL_PAIRS:
                    mqtt_publish("memory", {"moves": moves, "result": "win", "ts": int(time.time())})
            else:
                wait_ttl = FLIP_BACK_TTL

    reset()

    running = True
    while running:
        sw, sh   = screen.get_size()
        status_h = status_bar.height

        # Recompute card positions only when the window or status bar changes.
        if sw != last_sw or sh != last_sh or status_h != last_status_h:
            _layout(cards, sw, sh, status_h)
            last_sw, last_sh, last_status_h = sw, sh, status_h
            dirty = True

        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                elif event.key == pygame.K_r:
                    reset()
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
                dirty = True

        for entry in pending[:]:
            entry[2] -= 1
            if entry[2] <= 0:
                cards[entry[0]].matched = True
                cards[entry[1]].matched = True
                pending.remove(entry)
                dirty = True  # one more frame to show matched state

        if pending:
            dirty = True  # ripple animation still in progress

        # Skip rendering entirely when nothing has changed.
        if dirty:
            screen.fill(C_BG)

            hud_k = (moves, matches, sw)
            if hud_k != hud_key:
                hud_surf = hud_font.render(
                    f"Memory Match   ·   moves: {moves}   ·   "
                    f"matched: {matches} / {TOTAL_PAIRS}   ·   R to restart",
                    True, C_HUD,
                )
                hud_key = hud_k
            screen.blit(hud_surf, (sw // 2 - hud_surf.get_width() // 2, 16))

            for card in cards:
                _draw_card(screen, card)

            for entry in pending:
                for idx in (entry[0], entry[1]):
                    _draw_match_anim(screen, cards[idx], entry[2])

            if matches == TOTAL_PAIRS:
                msg = win_font.render(
                    f"You won in {moves} moves!  —  press R to play again",
                    True, (120, 240, 130),
                )
                screen.blit(msg, (sw // 2 - msg.get_width() // 2,
                                   sh // 2 - msg.get_height() // 2))

            status_bar.draw(screen)
            pygame.display.flip()
            dirty = False

        clock.tick(FPS)

    pygame.quit()
    sys.exit()


if __name__ == "__main__":
    main()
