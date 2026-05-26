import math
import os
import random
import secrets
import sys
import time

import pygame

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from shared.mqtt_stats import publish as mqtt_publish
from shared.status_bar import StatusBar
from shared.util import draw_splash, maximize_window, resource_path, single_instance

GAME_DIR = os.path.dirname(os.path.abspath(__file__))

TITLE        = "Sequence"
FPS          = 30
FEEDBACK_TTL = 45   # ~1.5 s at 30 FPS

# ── Colours ────────────────────────────────────────────────────────────────────

C_BG          = (22,  30,  52)
C_CELL_BG     = (38,  50,  82)
C_CELL_BDR    = (65,  88, 138)
C_Q_BDR       = (200, 220,  70)
C_Q_TXT       = (200, 220,  70)
C_HUD         = (160, 185, 230)
C_PROMPT      = (140, 165, 210)
C_BTN_IDLE    = (38,  50,  82)
C_BTN_HOVER   = (62,  82, 128)
C_BTN_BDR     = (65,  88, 138)
C_CORRECT     = (55, 195,  80)
C_WRONG       = (205,  55,  45)
C_CORRECT_DIM = (30, 110,  50)

ELEM_COLORS = {
    "red":    (220,  60,  60),
    "blue":   ( 60, 130, 220),
    "green":  ( 60, 185,  80),
    "yellow": (240, 200,  50),
    "orange": (220, 125,  45),
    "purple": (155,  65, 220),
    "teal":   ( 45, 195, 200),
    "pink":   (225,  80, 160),
}

# ── Pattern library ────────────────────────────────────────────────────────────
# Each entry is a list of (shape, color_name) tuples — the repeating period.
# Shapes: "circle"  "square"  "triangle"  "diamond"  "hexagon"  "star"

PATTERNS = [
    # AB colour, same shape
    [("circle",   "blue"),    ("circle",   "red")],
    [("circle",   "green"),   ("circle",   "yellow")],
    [("square",   "blue"),    ("square",   "orange")],
    [("square",   "red"),     ("square",   "purple")],
    [("triangle", "teal"),    ("triangle", "pink")],
    [("diamond",  "blue"),    ("diamond",  "green")],
    [("hexagon",  "purple"),  ("hexagon",  "yellow")],
    [("star",     "orange"),  ("star",     "teal")],
    # AAB colour, same shape
    [("circle",   "blue"),   ("circle",   "blue"),   ("circle",   "red")],
    [("square",   "green"),  ("square",   "green"),  ("square",   "yellow")],
    [("circle",   "orange"), ("circle",   "orange"), ("circle",   "purple")],
    [("triangle", "pink"),   ("triangle", "pink"),   ("triangle", "teal")],
    # ABB colour, same shape
    [("circle",   "blue"),   ("circle",   "red"),    ("circle",   "red")],
    [("square",   "orange"), ("square",   "purple"), ("square",   "purple")],
    [("triangle", "teal"),   ("triangle", "pink"),   ("triangle", "pink")],
    [("diamond",  "green"),  ("diamond",  "yellow"), ("diamond",  "yellow")],
    # ABC colour, same shape
    [("circle", "red"),    ("circle", "blue"),   ("circle",  "green")],
    [("square", "yellow"), ("square", "orange"), ("square",  "purple")],
    [("circle", "pink"),   ("circle", "teal"),   ("circle",  "blue")],
    [("star",   "red"),    ("star",   "green"),  ("star",    "yellow")],
    # ABBA colour, same shape
    [("circle", "red"),   ("circle", "blue"),   ("circle", "blue"),   ("circle", "red")],
    [("square", "green"), ("square", "yellow"), ("square", "yellow"), ("square", "green")],
    # AB shape, same colour
    [("circle",   "blue"),    ("square",   "blue")],
    [("triangle", "red"),     ("diamond",  "red")],
    [("hexagon",  "green"),   ("circle",   "green")],
    [("star",     "purple"),  ("square",   "purple")],
    [("triangle", "orange"),  ("hexagon",  "orange")],
    # ABC shape, same colour
    [("circle",   "red"),    ("triangle", "red"),    ("square",   "red")],
    [("diamond",  "blue"),   ("circle",   "blue"),   ("triangle", "blue")],
    [("hexagon",  "green"),  ("square",   "green"),  ("star",     "green")],
    [("star",     "yellow"), ("diamond",  "yellow"), ("circle",   "yellow")],
    # AB shape + AB colour
    [("circle",   "blue"),    ("square",   "red")],
    [("triangle", "orange"),  ("diamond",  "purple")],
    [("circle",   "teal"),    ("hexagon",  "pink")],
    [("star",     "green"),   ("triangle", "yellow")],
    # ABC mixed
    [("circle",   "red"),    ("square",   "blue"),   ("triangle", "green")],
    [("triangle", "orange"), ("circle",   "purple"), ("square",   "teal")],
    [("diamond",  "pink"),   ("circle",   "yellow"), ("hexagon",  "red")],
    [("star",     "blue"),   ("diamond",  "orange"), ("circle",   "pink")],
    # ABAC mixed
    [("circle",   "blue"),   ("square",   "red"),    ("circle",  "blue"),   ("triangle", "green")],
    [("star",     "purple"), ("circle",   "orange"), ("star",    "purple"), ("diamond",  "teal")],
    [("triangle", "teal"),   ("hexagon",  "pink"),   ("triangle","teal"),   ("circle",   "yellow")],
]

_ALL_ELEMENTS = list({elem for pat in PATTERNS for elem in pat})


# ── Shape drawing ──────────────────────────────────────────────────────────────

def _draw_shape(surf: pygame.Surface, shape: str, color: tuple,
                cx: int, cy: int, size: int):
    r = size // 2
    if shape == "circle":
        pygame.draw.circle(surf, color, (cx, cy), r)
    elif shape == "square":
        pygame.draw.rect(surf, color, (cx - r, cy - r, size, size),
                         border_radius=max(2, size // 10))
    elif shape == "triangle":
        h = int(size * 0.866)
        pygame.draw.polygon(surf, color, [
            (cx,     cy - h // 2),
            (cx - r, cy + h // 2),
            (cx + r, cy + h // 2),
        ])
    elif shape == "diamond":
        pygame.draw.polygon(surf, color, [
            (cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy),
        ])
    elif shape == "hexagon":
        pts = [(cx + int(r * math.cos(math.pi / 6 + i * math.pi / 3)),
                cy + int(r * math.sin(math.pi / 6 + i * math.pi / 3)))
               for i in range(6)]
        pygame.draw.polygon(surf, color, pts)
    elif shape == "star":
        inner = r * 0.42
        pts = []
        for i in range(10):
            angle = -math.pi / 2 + i * math.pi / 5
            rr = r if i % 2 == 0 else inner
            pts.append((cx + int(rr * math.cos(angle)),
                        cy + int(rr * math.sin(angle))))
        pygame.draw.polygon(surf, color, pts)


def _draw_cell(surf: pygame.Surface, elem: tuple, cx: int, cy: int, cell: int,
               border_color=None, border_w: int = 0):
    shape, cname = elem
    r  = pygame.Rect(cx - cell // 2, cy - cell // 2, cell, cell)
    br = max(4, cell // 8)
    pygame.draw.rect(surf, C_CELL_BG, r, border_radius=br)
    bw = border_w or max(2, cell // 24)
    pygame.draw.rect(surf, border_color or C_CELL_BDR, r,
                     border_radius=br, width=bw)
    _draw_shape(surf, shape, ELEM_COLORS[cname], cx, cy, cell * 2 // 3)


def _draw_q_cell(surf: pygame.Surface, cx: int, cy: int, cell: int,
                 q_font: pygame.font.Font):
    r  = pygame.Rect(cx - cell // 2, cy - cell // 2, cell, cell)
    br = max(4, cell // 8)
    pygame.draw.rect(surf, C_CELL_BG, r, border_radius=br)
    pygame.draw.rect(surf, C_Q_BDR, r, border_radius=br,
                     width=max(3, cell // 18))
    lbl = q_font.render("?", True, C_Q_TXT)
    surf.blit(lbl, (cx - lbl.get_width() // 2, cy - lbl.get_height() // 2))


# ── Question generation ────────────────────────────────────────────────────────

def _new_question() -> tuple:
    """Return (visible, answer, options, pattern)."""
    pattern = PATTERNS[secrets.randbelow(len(PATTERNS))]
    period  = len(pattern)

    min_show = 2 * period
    max_show = min(10, 3 * period + period - 1)
    n_shown  = secrets.randbelow(max(1, max_show - min_show + 1)) + min_show

    offset   = secrets.randbelow(period)
    sequence = [pattern[(i + offset) % period] for i in range(n_shown + 1)]
    visible  = sequence[:n_shown]
    answer   = sequence[n_shown]

    # Prefer elements from the current pattern as wrong-answer distractors
    from_pat  = [e for e in pattern if e != answer]
    from_pool = [e for e in _ALL_ELEMENTS if e != answer and e not in from_pat]
    random.shuffle(from_pat)
    random.shuffle(from_pool)
    distractors = (from_pat + from_pool)[:3]

    options = [answer] + distractors
    random.shuffle(options)
    return visible, answer, options, pattern


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    single_instance("sequence")
    pygame.init()

    icon = pygame.image.load(resource_path("assets/icons/sequence.png", GAME_DIR))
    pygame.display.set_icon(icon)

    screen     = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
    maximize_window()
    pygame.display.set_caption(TITLE)
    draw_splash(screen, TITLE)

    clock      = pygame.time.Clock()
    status_bar = StatusBar()
    hud_font   = pygame.font.SysFont("sans", 20, bold=True)
    prompt_font= pygame.font.SysFont("sans", 18, bold=True)

    correct_total  = 0
    answered_total = 0

    visible, answer, options, pattern = _new_question()

    state        = "asking"   # "asking" | "feedback"
    feedback_ttl = 0
    selected_idx = -1
    is_correct   = False

    # Layout vars (kept outside loop so click detection uses current frame's values)
    btn_rects   = [pygame.Rect(0, 0, 1, 1)] * 4
    last_cell_sz = -1
    q_font       = pygame.font.SysFont("sans", 24, bold=True)

    dirty      = True
    last_mouse = (-1, -1)

    running = True
    while running:
        sw, sh   = screen.get_size()
        status_h = status_bar.height
        mouse    = pygame.mouse.get_pos()

        # ── Layout (computed every frame — needed for click detection) ─────────
        HUD_H   = 50
        avail_h = sh - HUD_H - status_h
        seq_h   = int(avail_h * 0.44)
        prompt_h = 28
        btn_area_h = avail_h - seq_h - prompt_h - 20

        n_cells  = len(visible) + 1       # visible elements + "?" cell
        avail_w  = sw - 80
        cell_gap = max(6, min(16, avail_w // (n_cells * 8)))
        cell_w   = (avail_w - cell_gap * (n_cells - 1)) // n_cells
        cell_sz  = max(30, min(cell_w, seq_h - 24, 120))

        if cell_sz != last_cell_sz:
            q_font_sz   = max(14, min(36, cell_sz // 2))
            q_font      = pygame.font.SysFont("sans", q_font_sz, bold=True)
            last_cell_sz = cell_sz
            dirty = True

        total_seq_w = n_cells * cell_sz + (n_cells - 1) * cell_gap
        seq_ox      = (sw - total_seq_w) // 2 + cell_sz // 2
        seq_oy      = HUD_H + (seq_h - cell_sz) // 2 + cell_sz // 2

        btn_sz   = max(50, min((avail_w - 48) // 4, btn_area_h - 16, 160))
        btn_gap  = (avail_w - 4 * btn_sz) // 5
        btn_y    = HUD_H + seq_h + prompt_h + 10 + (btn_area_h - btn_sz) // 2

        btn_rects = [
            pygame.Rect(40 + btn_gap + i * (btn_sz + btn_gap), btn_y, btn_sz, btn_sz)
            for i in range(4)
        ]

        # ── Events ────────────────────────────────────────────────────────────
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                elif event.key == pygame.K_r:
                    correct_total  = 0
                    answered_total = 0
                    visible, answer, options, pattern = _new_question()
                    state        = "asking"
                    feedback_ttl = 0
                    selected_idx = -1
                    last_cell_sz = -1   # force font refresh for new question length
                    dirty        = True
            elif (event.type == pygame.MOUSEBUTTONDOWN
                  and event.button == 1
                  and state == "asking"):
                for i, rect in enumerate(btn_rects):
                    if rect.collidepoint(event.pos):
                        selected_idx    = i
                        is_correct      = (options[i] == answer)
                        answered_total += 1
                        if is_correct:
                            correct_total += 1
                        state        = "feedback"
                        feedback_ttl = FEEDBACK_TTL
                        mqtt_publish("sequence/result", "correct" if is_correct else "wrong")
                        mqtt_publish("sequence/score",  correct_total)
                        mqtt_publish("sequence/total",  answered_total)
                        mqtt_publish("sequence/ts",     int(time.time()))
                        dirty = True
                        break
            status_bar.handle_event(event)

        # ── Feedback countdown ─────────────────────────────────────────────────
        if feedback_ttl > 0:
            feedback_ttl -= 1
            dirty = True
            if feedback_ttl == 0:
                visible, answer, options, pattern = _new_question()
                state        = "asking"
                selected_idx = -1
                last_cell_sz = -1   # question length may change → recompute font

        # ── Hover → dirty ─────────────────────────────────────────────────────
        if mouse != last_mouse:
            dirty      = True
            last_mouse = mouse

        if not dirty:
            clock.tick(FPS)
            continue

        # ── Render ────────────────────────────────────────────────────────────
        screen.fill(C_BG)

        # HUD
        hud_str = (f"{TITLE}   ·   score: {correct_total} / {answered_total}"
                   f"   ·   R to restart")
        hud_s = hud_font.render(hud_str, True, C_HUD)
        screen.blit(hud_s, (sw // 2 - hud_s.get_width() // 2,
                             HUD_H // 2 - hud_s.get_height() // 2))

        # Sequence elements
        for i, elem in enumerate(visible):
            cx = seq_ox + i * (cell_sz + cell_gap)
            _draw_cell(screen, elem, cx, seq_oy, cell_sz)
            # Arrow between cells
            if i < len(visible) and cell_gap >= 8:
                ax = cx + cell_sz // 2 + cell_gap // 2
                ah = max(4, cell_gap // 3)
                aw = max(4, cell_gap // 2)
                pygame.draw.polygon(screen, C_CELL_BDR, [
                    (ax - aw // 2, seq_oy - ah // 2),
                    (ax + aw // 2, seq_oy),
                    (ax - aw // 2, seq_oy + ah // 2),
                ])

        # "?" cell
        qx = seq_ox + len(visible) * (cell_sz + cell_gap)
        _draw_q_cell(screen, qx, seq_oy, cell_sz, q_font)

        # Prompt
        prompt_y = HUD_H + seq_h + 4
        pr = prompt_font.render("What comes next?", True, C_PROMPT)
        screen.blit(pr, (sw // 2 - pr.get_width() // 2, prompt_y))

        # Answer buttons
        for i, rect in enumerate(btn_rects):
            elem = options[i]
            br   = max(4, btn_sz // 8)

            if state == "feedback":
                if i == selected_idx:
                    border = C_CORRECT if is_correct else C_WRONG
                    bw = max(4, btn_sz // 14)
                elif not is_correct and options[i] == answer:
                    border = C_CORRECT_DIM
                    bw = max(2, btn_sz // 20)
                else:
                    border = C_BTN_BDR
                    bw = max(2, btn_sz // 24)
                bg = C_BTN_IDLE
            else:
                border = C_BTN_BDR
                bw     = max(2, btn_sz // 24)
                bg     = C_BTN_HOVER if rect.collidepoint(mouse) else C_BTN_IDLE

            pygame.draw.rect(screen, bg, rect, border_radius=br)
            pygame.draw.rect(screen, border, rect, border_radius=br, width=bw)
            _draw_shape(screen, elem[0], ELEM_COLORS[elem[1]],
                        rect.centerx, rect.centery, btn_sz * 2 // 3)

        status_bar.draw(screen)
        pygame.display.flip()
        dirty = False

        clock.tick(FPS)

    pygame.quit()
    sys.exit()


if __name__ == "__main__":
    main()
