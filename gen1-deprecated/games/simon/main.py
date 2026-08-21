import array
import math
import os
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

TITLE = "Simon"
FPS   = 60

# ── Colours ───────────────────────────────────────────────────────────────────
C_BG   = (10, 10, 14)       # near-black — distinct from memory/sequence navy
C_TEXT = (230, 230, 240)
C_SUBT = (130, 130, 150)
C_FAIL = (220,  80,  80)

# Button order: 0=green(TL), 1=red(TR), 2=yellow(BL), 3=blue(BR)
BTN_LIT  = [(55, 210, 85), (220, 55, 55), (240, 210, 50), (60, 130, 220)]
BTN_DIM  = [(12,  52, 20), ( 52, 12, 12), ( 58, 50,  12), (12,  32, 52)]

# Classic Simon-style tones (Hz)
BTN_FREQ = [415.3, 310.0, 252.0, 209.0]

GAP     = 8    # gap between quadrant buttons
OUTER_R = 36   # outer corner radius


# ── Speed schedule ────────────────────────────────────────────────────────────

def _timing(rnd: int) -> tuple:
    """(on_frames, gap_frames) for the given round number."""
    if rnd <= 4:  return (int(FPS * 0.90), int(FPS * 0.25))
    if rnd <= 8:  return (int(FPS * 0.70), int(FPS * 0.20))
    return            (int(FPS * 0.50), int(FPS * 0.17))


# ── Sound synthesis ───────────────────────────────────────────────────────────

def _make_tone(freq: float) -> pygame.mixer.Sound:
    sr = 44100
    n  = int(sr * 0.5)
    fade = int(n * 0.12)
    buf = array.array('h')
    for i in range(n):
        env = min(i, fade, n - i) / fade
        s = int(32767 * env * math.sin(2 * math.pi * freq * i / sr))
        buf.append(s); buf.append(s)   # stereo
    return pygame.mixer.Sound(buffer=buf)


def _make_fail() -> pygame.mixer.Sound:
    sr = 44100
    n  = int(sr * 0.7)
    buf = array.array('h')
    for i in range(n):
        freq = 200 - 80 * i / n
        env  = max(0.0, 1.0 - i / n)
        s = int(20000 * env * math.sin(2 * math.pi * freq * i / sr))
        buf.append(s); buf.append(s)
    return pygame.mixer.Sound(buffer=buf)


# ── Layout helpers ────────────────────────────────────────────────────────────

def _button_rects(sw: int, sh: int, sb_h: int) -> list:
    hw = sw // 2
    hh = (sh - sb_h) // 2
    g  = GAP // 2
    return [
        pygame.Rect(0,      0,       hw - g,          hh - g),           # TL green
        pygame.Rect(hw + g, 0,       sw - hw - g,     hh - g),           # TR red
        pygame.Rect(0,      hh + g,  hw - g,          sh - sb_h - hh - g),  # BL yellow
        pygame.Rect(hw + g, hh + g,  sw - hw - g,     sh - sb_h - hh - g),  # BR blue
    ]


def _draw_buttons(surf, rects: list, lit: set, hover: int = -1):
    for i, r in enumerate(rects):
        color = BTN_LIT[i] if i in lit else BTN_DIM[i]
        tl = OUTER_R if i == 0 else 0
        tr = OUTER_R if i == 1 else 0
        bl = OUTER_R if i == 2 else 0
        br = OUTER_R if i == 3 else 0
        pygame.draw.rect(surf, color, r,
                         border_top_left_radius=tl, border_top_right_radius=tr,
                         border_bottom_left_radius=bl, border_bottom_right_radius=br)
        if hover == i and i not in lit:
            hl = tuple(min(255, c + 30) for c in BTN_DIM[i])
            pygame.draw.rect(surf, hl, r, width=5,
                             border_top_left_radius=tl, border_top_right_radius=tr,
                             border_bottom_left_radius=bl, border_bottom_right_radius=br)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    single_instance("simon")
    pygame.mixer.pre_init(44100, -16, 2, 512)
    pygame.init()

    icon = pygame.image.load(resource_path("assets/icons/simon.png", GAME_DIR))
    pygame.display.set_icon(icon)
    screen = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
    maximize_window()
    pygame.display.set_caption(TITLE)
    draw_splash(screen, TITLE)

    clock      = pygame.time.Clock()
    status_bar = StatusBar()
    sounds     = [_make_tone(f) for f in BTN_FREQ]
    fail_snd   = _make_fail()

    big_font = pygame.font.SysFont("sans", 68, bold=True)
    med_font = pygame.font.SysFont("sans", 40, bold=True)
    sml_font = pygame.font.SysFont("sans", 26, bold=True)

    # ── Game state ────────────────────────────────────────────────────────────
    state      = "idle"   # idle | showing | input | win_flash | fail
    sequence   = []
    round_num  = 0        # = len(sequence) for the current round
    input_idx  = 0
    best       = 0

    show_idx   = 0
    show_phase = "gap"    # "gap" | "on"
    show_timer = 0

    flash_btn  = -1
    flash_ttl  = 0
    FLASH_DUR  = int(FPS * 0.18)

    overlay_ttl = 0
    WIN_FLASH   = int(FPS * 0.9)
    FAIL_WAIT   = int(FPS * 3.0)

    hover_btn = -1
    dirty     = True

    def _start_showing():
        nonlocal state, show_idx, show_phase, show_timer, flash_btn, flash_ttl
        show_idx   = 0
        show_phase = "gap"
        show_timer = int(FPS * 1.2)   # pause before first button lights up
        flash_btn  = -1               # clear any stale flash from previous round
        flash_ttl  = 0
        state      = "showing"

    while True:
        sw, sh = screen.get_size()
        sb_h   = status_bar.height
        rects  = _button_rects(sw, sh, sb_h)
        cx     = sw // 2
        cy     = (sh - sb_h) // 2
        hub_r  = min(cx, cy) * 9 // 20   # ~45% — large enough for fail text

        # ── Events ───────────────────────────────────────────────────────────
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                pygame.quit(); sys.exit()

            if event.type == pygame.VIDEORESIZE:
                dirty = True

            if event.type == pygame.MOUSEMOTION:
                mx, my    = event.pos
                new_hover = next((i for i, r in enumerate(rects) if r.collidepoint(mx, my)), -1)
                if new_hover != hover_btn:
                    hover_btn = new_hover
                    dirty     = True

            if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                mx, my  = event.pos
                clicked = next((i for i, r in enumerate(rects) if r.collidepoint(mx, my)), -1)

                if state == "idle":
                    sequence  = [secrets.randbelow(4)]
                    round_num = 1
                    _start_showing()
                    dirty = True

                elif state == "input" and clicked >= 0:
                    sounds[clicked].play()
                    flash_btn = clicked
                    flash_ttl = FLASH_DUR
                    dirty     = True
                    if clicked == sequence[input_idx]:
                        input_idx += 1
                        if input_idx >= len(sequence):
                            best        = max(best, round_num)
                            overlay_ttl = WIN_FLASH
                            state       = "win_flash"
                    else:
                        fail_snd.play()
                        # ts ("last played") LAST so the HA automation sees the
                        # updated rounds. One connection, ordered delivery.
                        mqtt_publish_many([
                            ("simon/rounds", round_num - 1),
                            ("simon/ts", int(time.time())),
                        ])
                        overlay_ttl = FAIL_WAIT
                        state       = "fail"

                elif state == "fail" and overlay_ttl < FAIL_WAIT // 2:
                    state = "idle"
                    dirty = True

            status_bar.handle_event(event)

        # ── Logic ─────────────────────────────────────────────────────────────
        if state == "showing":
            show_timer -= 1
            dirty       = True
            if show_timer <= 0:
                if show_phase == "gap":
                    on_f, _    = _timing(round_num)
                    show_phase = "on"
                    show_timer = on_f
                    sounds[sequence[show_idx]].play()
                else:
                    show_idx += 1
                    if show_idx >= len(sequence):
                        state     = "input"
                        input_idx = 0
                        flash_btn = -1   # clear stale flash so previous round's last press doesn't appear
                        flash_ttl = 0
                    else:
                        _, gp_f    = _timing(round_num)
                        show_phase = "gap"
                        show_timer = gp_f

        if state == "input" and flash_ttl > 0:
            flash_ttl -= 1
            dirty      = True

        if state in ("win_flash", "fail"):
            overlay_ttl -= 1
            dirty        = True
            if overlay_ttl <= 0:
                if state == "win_flash":
                    sequence.append(secrets.randbelow(4))
                    round_num += 1
                    _start_showing()
                else:
                    state     = "idle"
                    sequence  = []
                    round_num = 0

        # ── Draw ─────────────────────────────────────────────────────────────
        if not dirty:
            clock.tick(FPS)
            continue
        dirty = False

        screen.fill(C_BG)

        lit = set()
        if state == "showing" and show_phase == "on":
            lit.add(sequence[show_idx])
        if state == "input" and flash_ttl > 0:
            lit.add(flash_btn)
        if state == "win_flash":
            lit = {0, 1, 2, 3}

        _draw_buttons(screen, rects, lit, hover_btn if state == "input" else -1)

        # Dark hub circle covers the inner corners of the quadrants
        pygame.draw.circle(screen, C_BG, (cx, cy), hub_r)

        # Hub content
        if state == "idle":
            t1 = big_font.render("Simon", True, C_TEXT)
            t2 = sml_font.render("Tap to start", True, C_SUBT)
            gap = 6
            total = t1.get_height() + gap + t2.get_height()
            y = cy - total // 2
            screen.blit(t1, t1.get_rect(centerx=cx, top=y))
            screen.blit(t2, t2.get_rect(centerx=cx, top=y + t1.get_height() + gap))

        elif state in ("showing", "input"):
            lbl      = med_font.render(f"Round {round_num}", True, C_TEXT)
            sub_txt  = "Watch…" if state == "showing" else "Your turn!"
            sub_col  = C_SUBT  if state == "showing" else C_TEXT
            sub      = sml_font.render(sub_txt, True, sub_col)
            gap = 6
            total = lbl.get_height() + gap + sub.get_height()
            y = cy - total // 2
            screen.blit(lbl, lbl.get_rect(centerx=cx, top=y))
            screen.blit(sub, sub.get_rect(centerx=cx, top=y + lbl.get_height() + gap))

        elif state == "win_flash":
            lbl = med_font.render("Great job!", True, C_TEXT)
            screen.blit(lbl, lbl.get_rect(centerx=cx, centery=cy))

        elif state == "fail":
            score     = round_num - 1
            show_best = best > 1
            items = [
                big_font.render("Oops!",  True, C_FAIL),
                med_font.render(f"Score: {score}", True, C_TEXT),
            ]
            if show_best:
                items.append(sml_font.render(f"Best: {best}", True, C_SUBT))
            items.append(sml_font.render("Tap to play again", True, C_SUBT))
            gap   = 6
            total = sum(t.get_height() for t in items) + gap * (len(items) - 1)
            y     = cy - total // 2
            for t in items:
                screen.blit(t, t.get_rect(centerx=cx, top=y))
                y += t.get_height() + gap

        status_bar.draw(screen)
        pygame.display.flip()
        clock.tick(FPS)


if __name__ == "__main__":
    main()
