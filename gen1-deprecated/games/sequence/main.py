import math
import os
import random
import secrets
import sys
import time

import pygame

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from shared.mqtt_stats import publish_many as mqtt_publish_many
from shared.status_bar import StatusBar
from shared.util import draw_splash, maximize_window, resource_path, single_instance

GAME_DIR = os.path.dirname(os.path.abspath(__file__))

TITLE        = "Sequence"
FPS          = 30
ROUND_SIZE   = 10
FEEDBACK_TTL = 42   # ~1.4 s at 30 FPS

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
C_STAR        = (240, 195,  45)
C_STAR_EMPTY  = (55,  68, 105)

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
# Kept simple for 3-4 year olds: only circle/square/triangle/star,
# only primary colours, only AB and AAB/ABB pattern types.

PATTERNS = [
    # AB colour, same shape (simplest — only one thing changes)
    [("circle",   "blue"),   ("circle",   "red")],
    [("circle",   "red"),    ("circle",   "yellow")],
    [("circle",   "green"),  ("circle",   "blue")],
    [("circle",   "yellow"), ("circle",   "green")],
    [("square",   "blue"),   ("square",   "red")],
    [("square",   "red"),    ("square",   "green")],
    [("square",   "yellow"), ("square",   "orange")],
    [("square",   "orange"), ("square",   "blue")],
    [("triangle", "red"),    ("triangle", "blue")],
    [("triangle", "green"),  ("triangle", "yellow")],
    [("triangle", "blue"),   ("triangle", "orange")],
    [("star",     "orange"), ("star",     "blue")],
    [("star",     "red"),    ("star",     "green")],
    [("star",     "yellow"), ("star",     "red")],
    # AB shape, same colour (one thing changes)
    [("circle",   "red"),    ("square",   "red")],
    [("circle",   "blue"),   ("triangle", "blue")],
    [("square",   "green"),  ("triangle", "green")],
    [("triangle", "yellow"), ("circle",   "yellow")],
    [("star",     "orange"), ("circle",   "orange")],
    [("square",   "red"),    ("star",     "red")],
    [("circle",   "blue"),   ("star",     "blue")],
    [("triangle", "green"),  ("square",   "green")],
    # AAB colour, same shape (two the same, then one different)
    [("circle",   "blue"),   ("circle",   "blue"),   ("circle",   "red")],
    [("circle",   "red"),    ("circle",   "red"),    ("circle",   "blue")],
    [("square",   "green"),  ("square",   "green"),  ("square",   "yellow")],
    [("square",   "yellow"), ("square",   "yellow"), ("square",   "orange")],
    [("triangle", "yellow"), ("triangle", "yellow"), ("triangle", "green")],
    [("triangle", "blue"),   ("triangle", "blue"),   ("triangle", "red")],
    [("star",     "orange"), ("star",     "orange"), ("star",     "blue")],
    # ABB colour, same shape (one, then two the same)
    [("circle",   "blue"),   ("circle",   "red"),    ("circle",   "red")],
    [("circle",   "yellow"), ("circle",   "green"),  ("circle",   "green")],
    [("square",   "green"),  ("square",   "yellow"), ("square",   "yellow")],
    [("square",   "orange"), ("square",   "blue"),   ("square",   "blue")],
    [("triangle", "red"),    ("triangle", "blue"),   ("triangle", "blue")],
    [("star",     "blue"),   ("star",     "orange"), ("star",     "orange")],
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
    r  = pygame.Rect(cx - cell // 2, cy - cell // 2, cell, cell)
    br = max(4, cell // 8)
    pygame.draw.rect(surf, C_CELL_BG, r, border_radius=br)
    bw = border_w or max(2, cell // 24)
    pygame.draw.rect(surf, border_color or C_CELL_BDR, r, border_radius=br, width=bw)
    _draw_shape(surf, elem[0], ELEM_COLORS[elem[1]], cx, cy, cell * 2 // 3)


def _draw_q_cell(surf: pygame.Surface, cx: int, cy: int, cell: int,
                 q_font: pygame.font.Font):
    r  = pygame.Rect(cx - cell // 2, cy - cell // 2, cell, cell)
    br = max(4, cell // 8)
    pygame.draw.rect(surf, C_CELL_BG, r, border_radius=br)
    pygame.draw.rect(surf, C_Q_BDR, r, border_radius=br, width=max(3, cell // 18))
    lbl = q_font.render("?", True, C_Q_TXT)
    surf.blit(lbl, (cx - lbl.get_width() // 2, cy - lbl.get_height() // 2))


# ── Question generation ────────────────────────────────────────────────────────

def _new_question() -> tuple:
    """Return (visible, answer, options, pattern)."""
    pattern = PATTERNS[secrets.randbelow(len(PATTERNS))]
    period  = len(pattern)

    min_show = 2 * period
    max_show = min(7, 3 * period + period - 1)
    n_shown  = secrets.randbelow(max(1, max_show - min_show + 1)) + min_show

    offset   = secrets.randbelow(period)
    sequence = [pattern[(i + offset) % period] for i in range(n_shown + 1)]
    visible  = sequence[:n_shown]
    answer   = sequence[n_shown]

    from_pat  = [e for e in pattern if e != answer]
    from_pool = [e for e in _ALL_ELEMENTS if e != answer and e not in from_pat]
    random.shuffle(from_pat)
    random.shuffle(from_pool)
    distractors = (from_pat + from_pool)[:3]

    options = [answer] + distractors
    random.shuffle(options)
    return visible, answer, options, pattern


def _star_count(correct: int) -> int:
    if correct == ROUND_SIZE: return 3
    if correct >  6:          return 2
    if correct >= 5:          return 1
    return 0


def _round_message(correct: int) -> str:
    if correct == ROUND_SIZE: return "Perfect score!"
    if correct >= 8:          return "Amazing!"
    if correct >= 5:          return "Good job!"
    if correct >= 2:          return "Keep trying!"
    return "Don't give up!"


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

    # Round state
    q_num            = 0          # questions answered this round (0–ROUND_SIZE)
    question_results = []         # True/False per question
    correct_total    = 0

    visible, answer, options, pattern = _new_question()

    state        = "asking"       # "asking" | "feedback" | "roundover"
    feedback_ttl = 0
    selected_idx = -1
    is_correct   = False

    # Layout cache — recompute font only when cell size changes
    btn_rects    = [pygame.Rect(0, 0, 1, 1)] * 4
    replay_rect  = pygame.Rect(0, 0, 0, 0)
    last_cell_sz = -1
    q_font       = pygame.font.SysFont("sans", 24, bold=True)

    dirty      = True
    last_mouse = (-1, -1)

    running = True
    while running:
        sw, sh   = screen.get_size()
        status_h = status_bar.height
        mouse    = pygame.mouse.get_pos()

        # ── Layout ────────────────────────────────────────────────────────────
        HUD_H    = 44
        PROG_H   = 20        # progress-bar strip height
        VGAP     = 12        # vertical gap between content zones
        PROMPT_H = 26
        avail_w  = sw - 80   # 40 px padding each side
        avail_h  = sh - HUD_H - PROG_H - status_h - 8

        n_cells  = len(visible) + 1
        cell_gap = max(5, min(14, avail_w // max(1, n_cells * 9)))

        # Width-constrained sizes
        cell_from_w = max(28, (avail_w - cell_gap * (n_cells - 1)) // n_cells)
        BTN_COL_GAP = 16
        BTN_ROW_GAP = 12
        btn_from_w  = max(40, (avail_w - BTN_COL_GAP) // 2)   # 2 columns

        cell_sz    = min(cell_from_w, 140)
        btn_sz     = min(btn_from_w,   95)
        btn_zone_h = 2 * btn_sz + BTN_ROW_GAP

        # Scale down proportionally if content exceeds available height
        content_h = cell_sz + VGAP + PROMPT_H + VGAP + btn_zone_h
        if content_h > avail_h - 8:
            scale      = (avail_h - 8) / content_h
            cell_sz    = max(28, int(cell_sz * scale))
            btn_sz     = max(40, int(btn_sz  * scale))
            btn_zone_h = 2 * btn_sz + BTN_ROW_GAP
            content_h  = cell_sz + VGAP + PROMPT_H + VGAP + btn_zone_h

        # Vertical centre of content block
        content_top = HUD_H + PROG_H + max(0, (avail_h - content_h) // 2)
        seq_cy      = content_top + cell_sz // 2
        prompt_y    = content_top + cell_sz + VGAP
        btn_top     = prompt_y + PROMPT_H + VGAP

        # Lazy q-font rebuild
        if cell_sz != last_cell_sz:
            q_font       = pygame.font.SysFont("sans",
                                               max(12, min(34, cell_sz // 2)), bold=True)
            last_cell_sz = cell_sz
            dirty        = True

        # Sequence horizontal layout
        total_seq_w = n_cells * cell_sz + (n_cells - 1) * cell_gap
        seq_ox      = (sw - total_seq_w) // 2 + cell_sz // 2

        # 2×2 button grid — centred horizontally
        grid_w    = 2 * btn_sz + BTN_COL_GAP
        grid_x    = (sw - grid_w) // 2
        btn_rects = [
            pygame.Rect(grid_x + (i % 2) * (btn_sz + BTN_COL_GAP),
                        btn_top + (i // 2) * (btn_sz + BTN_ROW_GAP),
                        btn_sz, btn_sz)
            for i in range(4)
        ]

        # Progress-bar segment geometry
        seg_sz  = max(10, min(22, (sw - 120 - 9 * 4) // ROUND_SIZE))
        seg_gap = max(3, min(6, (sw - 120 - ROUND_SIZE * seg_sz) // (ROUND_SIZE - 1)))
        seg_total_w = ROUND_SIZE * seg_sz + (ROUND_SIZE - 1) * seg_gap
        seg_x0  = (sw - seg_total_w) // 2
        seg_y   = HUD_H + (PROG_H - seg_sz) // 2

        # Round-over replay button geometry (used for click detection)
        ro_btn_w, ro_btn_h = min(220, sw // 4), 52
        replay_rect = pygame.Rect(sw // 2 - ro_btn_w // 2,
                                  sh // 2 + sh // 8, ro_btn_w, ro_btn_h)

        # ── Events ────────────────────────────────────────────────────────────
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False

            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                elif event.key == pygame.K_r:
                    q_num = 0; question_results = []; correct_total = 0
                    visible, answer, options, pattern = _new_question()
                    state = "asking"; feedback_ttl = 0; selected_idx = -1
                    last_cell_sz = -1; dirty = True

            elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                if state == "asking":
                    for i, rect in enumerate(btn_rects):
                        if rect.collidepoint(event.pos):
                            selected_idx  = i
                            is_correct    = (options[i] == answer)
                            correct_total += int(is_correct)
                            question_results.append(is_correct)
                            q_num        += 1
                            state         = "feedback"
                            feedback_ttl  = FEEDBACK_TTL
                            dirty = True
                            break

                elif state == "roundover":
                    if replay_rect.collidepoint(event.pos):
                        q_num = 0; question_results = []; correct_total = 0
                        visible, answer, options, pattern = _new_question()
                        state = "asking"; feedback_ttl = 0; selected_idx = -1
                        last_cell_sz = -1; dirty = True

            status_bar.handle_event(event)

        # ── Feedback countdown ─────────────────────────────────────────────────
        if feedback_ttl > 0:
            feedback_ttl -= 1
            dirty = True
            if feedback_ttl == 0:
                if q_num >= ROUND_SIZE:
                    state = "roundover"
                    # ts ("last played") LAST so the HA automation sees the
                    # updated score/total. One connection, ordered delivery.
                    mqtt_publish_many([
                        ("sequence/score", correct_total),
                        ("sequence/total", q_num),
                        ("sequence/ts",    int(time.time())),
                    ])
                else:
                    visible, answer, options, pattern = _new_question()
                    state        = "asking"
                    selected_idx = -1
                    last_cell_sz = -1

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
        if state == "roundover":
            hud_str = f"{TITLE}   ·   R to play again"
        else:
            hud_str = f"{TITLE}   ·   {q_num} / {ROUND_SIZE}   ·   R to restart"
        hud_s = hud_font.render(hud_str, True, C_HUD)
        screen.blit(hud_s, (sw // 2 - hud_s.get_width() // 2,
                             HUD_H // 2 - hud_s.get_height() // 2))

        # Progress bar
        for i in range(ROUND_SIZE):
            rx = seg_x0 + i * (seg_sz + seg_gap)
            br = max(2, seg_sz // 5)
            if i < len(question_results):
                color = C_CORRECT if question_results[i] else C_WRONG
                pygame.draw.rect(screen, color, (rx, seg_y, seg_sz, seg_sz),
                                 border_radius=br)
            elif i == len(question_results) and state != "roundover":
                # current question marker
                pygame.draw.rect(screen, C_CELL_BG, (rx, seg_y, seg_sz, seg_sz),
                                 border_radius=br)
                pygame.draw.rect(screen, C_Q_BDR, (rx, seg_y, seg_sz, seg_sz),
                                 border_radius=br, width=max(1, seg_sz // 8))
            else:
                pygame.draw.rect(screen, C_CELL_BG, (rx, seg_y, seg_sz, seg_sz),
                                 border_radius=br)
                pygame.draw.rect(screen, C_CELL_BDR, (rx, seg_y, seg_sz, seg_sz),
                                 border_radius=br, width=1)

        # ── Round-over screen ─────────────────────────────────────────────────
        if state == "roundover":
            stars    = _star_count(correct_total)
            msg      = _round_message(correct_total)
            mid_y    = HUD_H + PROG_H + (sh - HUD_H - PROG_H - status_h) // 2

            tf_sz = max(28, min(52, sh // 14))
            sf_sz = max(20, min(40, sh // 18))
            bf_sz = max(14, min(22, sh // 32))
            tf    = pygame.font.SysFont("sans", tf_sz, bold=True)
            sf    = pygame.font.SysFont("sans", sf_sz, bold=True)
            bf    = pygame.font.SysFont("sans", bf_sz, bold=True)

            # Title
            title_s = tf.render("Round Complete!", True, C_HUD)
            screen.blit(title_s, (sw // 2 - title_s.get_width() // 2,
                                   mid_y - tf_sz * 4))

            # Stars (3 total, filled or empty)
            star_sz  = max(32, min(64, sh // 11))
            star_gap = star_sz // 4
            n_stars  = 3
            star_row_w = n_stars * star_sz + (n_stars - 1) * star_gap
            star_x0    = sw // 2 - star_row_w // 2 + star_sz // 2
            star_cy    = mid_y - tf_sz * 4 + tf_sz + star_sz // 2 + 16
            for si in range(n_stars):
                color = C_STAR if si < stars else C_STAR_EMPTY
                _draw_shape(screen, "star", color,
                            star_x0 + si * (star_sz + star_gap), star_cy, star_sz)

            # Score
            score_s = sf.render(f"{correct_total}  /  {ROUND_SIZE}", True, (220, 225, 245))
            screen.blit(score_s, (sw // 2 - score_s.get_width() // 2,
                                   star_cy + star_sz // 2 + 18))

            # Message
            msg_s = sf.render(msg, True, C_PROMPT)
            screen.blit(msg_s, (sw // 2 - msg_s.get_width() // 2,
                                 star_cy + star_sz // 2 + 18 + sf_sz + 10))

            # Play Again button
            pa_bg = C_BTN_HOVER if replay_rect.collidepoint(mouse) else C_BTN_IDLE
            pygame.draw.rect(screen, pa_bg, replay_rect, border_radius=10)
            pygame.draw.rect(screen, C_BTN_BDR, replay_rect, border_radius=10, width=2)
            pa_s = bf.render("▶  Play Again", True, C_HUD)
            screen.blit(pa_s, (replay_rect.centerx - pa_s.get_width() // 2,
                                replay_rect.centery - pa_s.get_height() // 2))

        # ── Question screen ───────────────────────────────────────────────────
        else:
            # Sequence cells
            for i, elem in enumerate(visible):
                cx = seq_ox + i * (cell_sz + cell_gap)
                _draw_cell(screen, elem, cx, seq_cy, cell_sz)
                # Arrow chevron between cells
                if cell_gap >= 8:
                    ax = cx + cell_sz // 2 + cell_gap // 2
                    ah = max(4, cell_gap // 3)
                    aw = max(4, cell_gap // 2)
                    pygame.draw.polygon(screen, C_CELL_BDR, [
                        (ax - aw // 2, seq_cy - ah // 2),
                        (ax + aw // 2, seq_cy),
                        (ax - aw // 2, seq_cy + ah // 2),
                    ])

            # "?" cell
            qx = seq_ox + len(visible) * (cell_sz + cell_gap)
            if state == "feedback":
                blink_on = (feedback_ttl // 5) % 2 == 0
                border   = (C_CORRECT if is_correct else C_WRONG) if blink_on else C_CELL_BDR
                bw       = max(4, cell_sz // 14) if blink_on else max(2, cell_sz // 24)
                _draw_cell(screen, options[selected_idx], qx, seq_cy, cell_sz,
                           border_color=border, border_w=bw)
            else:
                _draw_q_cell(screen, qx, seq_cy, cell_sz, q_font)

            # Prompt
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
