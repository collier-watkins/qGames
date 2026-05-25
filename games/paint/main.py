import datetime
import math
import os
import sys

import pygame

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from shared.status_bar import StatusBar
from shared.util import resource_path

GAME_DIR = os.path.dirname(os.path.abspath(__file__))

TITLE      = "Paint"
FPS        = 60
BG         = (45, 45, 45)
CANVAS_BG  = (255, 255, 255)
TOOLBAR_H  = 80
MIN_BRUSH  = 1
MAX_BRUSH  = 80
DEF_BRUSH  = 8

TOOL_BRUSH  = "brush"
TOOL_BUCKET = "bucket"

PALETTE = [
    ( 20,  20,  20),   # 1 black
    (220,  50,  50),   # 2 red
    (240, 130,  40),   # 3 orange
    (240, 210,  40),   # 4 yellow
    ( 60, 180,  60),   # 5 green
    ( 40, 190, 190),   # 6 teal
    ( 60, 100, 220),   # 7 blue
    (150,  60, 220),   # 8 purple
    (230,  80, 160),   # 9 pink
    (255, 255, 255),   # 0 white / eraser
]

_KEY_COLOR = {
    pygame.K_1: 0, pygame.K_2: 1, pygame.K_3: 2, pygame.K_4: 3,
    pygame.K_5: 4, pygame.K_6: 5, pygame.K_7: 6, pygame.K_8: 7,
    pygame.K_9: 8, pygame.K_0: 9,
}

_CB    = (38,  38,  38)
_CBTN  = (60,  60,  60)
_CBTNH = (88,  88,  88)
_CACT  = (55,  90, 160)
_CTXT  = (210, 210, 210)
_SW    = 46
_PAD   = 8
_BW, _BH = 84, 40


def _flood_fill(surface: pygame.Surface, pos: tuple, new_color: tuple):
    x0, y0 = int(pos[0]), int(pos[1])
    w, h   = surface.get_size()
    if not (0 <= x0 < w and 0 <= y0 < h):
        return
    old_color = surface.get_at((x0, y0))[:3]
    if old_color == new_color[:3]:
        return

    filled = bytearray(w * h)

    def can_fill(x, y):
        return (0 <= x < w and 0 <= y < h
                and not filled[y * w + x]
                and surface.get_at((x, y))[:3] == old_color)

    stack = [(x0, y0)]
    while stack:
        x, y = stack.pop()
        if not can_fill(x, y):
            continue
        lx = x
        while lx > 0 and can_fill(lx - 1, y):
            lx -= 1
        rx = x
        while rx < w - 1 and can_fill(rx + 1, y):
            rx += 1
        pygame.draw.line(surface, new_color, (lx, y), (rx, y))
        for nx in range(lx, rx + 1):
            filled[y * w + nx] = 1
        for ny in (y - 1, y + 1):
            if 0 <= ny < h:
                in_run = False
                for nx in range(lx, rx + 1):
                    cf = can_fill(nx, ny)
                    if cf and not in_run:
                        stack.append((nx, ny))
                    in_run = cf


class Toolbar:
    def __init__(self):
        self.color_idx   = 0
        self.brush       = DEF_BRUSH
        self.tool        = TOOL_BRUSH
        self._swatches   = []
        self._tool_rects = {}
        self._size_minus = pygame.Rect(0, 0, 0, 0)
        self._size_plus  = pygame.Rect(0, 0, 0, 0)
        self._clear      = pygame.Rect(0, 0, 0, 0)
        self._save       = pygame.Rect(0, 0, 0, 0)
        self._font       = pygame.font.SysFont("sans", 15)

    @property
    def color(self):
        return PALETTE[self.color_idx]

    def handle_event(self, event):
        """Return 'clear', 'save', or None."""
        if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            for i, r in enumerate(self._swatches):
                if r.collidepoint(event.pos):
                    self.color_idx = i
                    return None
            for tool_id, r in self._tool_rects.items():
                if r.collidepoint(event.pos):
                    self.tool = tool_id
                    return None
            if self._size_minus.collidepoint(event.pos):
                self.brush = max(MIN_BRUSH, self.brush - 1)
                return None
            if self._size_plus.collidepoint(event.pos):
                self.brush = min(MAX_BRUSH, self.brush + 1)
                return None
            if self._clear.collidepoint(event.pos):
                return "clear"
            if self._save.collidepoint(event.pos):
                return "save"
        if event.type == pygame.KEYDOWN:
            if event.key in _KEY_COLOR:
                self.color_idx = _KEY_COLOR[event.key]
                self.tool      = TOOL_BRUSH
            elif event.key == pygame.K_p:
                self.tool = TOOL_BRUSH
            elif event.key == pygame.K_b:
                self.tool = TOOL_BUCKET
            elif event.key == pygame.K_LEFTBRACKET:
                self.brush = max(MIN_BRUSH, self.brush - 1)
            elif event.key == pygame.K_RIGHTBRACKET:
                self.brush = min(MAX_BRUSH, self.brush + 1)
        if event.type == pygame.MOUSEWHEEL:
            self.brush = max(MIN_BRUSH, min(MAX_BRUSH, self.brush + event.y))
        return None

    def draw(self, screen):
        sw = screen.get_width()
        pygame.draw.rect(screen, _CB, (0, 0, sw, TOOLBAR_H))
        mouse = pygame.mouse.get_pos()
        cy = TOOLBAR_H // 2

        x  = _PAD
        sy = (TOOLBAR_H - _SW) // 2

        # ── Colour swatches ───────────────────────────────────────────────────
        self._swatches = []
        for i, color in enumerate(PALETTE):
            r = pygame.Rect(x, sy, _SW, _SW)
            self._swatches.append(r)
            pygame.draw.rect(screen, color, r, border_radius=6)
            if i == self.color_idx:
                pygame.draw.rect(screen, (255, 255, 255), r, width=3, border_radius=6)
            elif r.collidepoint(mouse):
                pygame.draw.rect(screen, (180, 180, 180), r, width=2, border_radius=6)
            x += _SW + _PAD
        x += 14

        # ── Tool buttons ──────────────────────────────────────────────────────
        TW, TH = 88, 36
        ty = (TOOLBAR_H - TH) // 2
        self._tool_rects = {}
        for tool_id, label in ((TOOL_BRUSH, "P  Brush"), (TOOL_BUCKET, "B  Fill")):
            r = pygame.Rect(x, ty, TW, TH)
            self._tool_rects[tool_id] = r
            active = self.tool == tool_id
            bg = _CACT if active else (_CBTNH if r.collidepoint(mouse) else _CBTN)
            pygame.draw.rect(screen, bg, r, border_radius=6)
            if active:
                pygame.draw.rect(screen, (120, 160, 230), r, width=2, border_radius=6)
            lbl = self._font.render(label, True, _CTXT)
            screen.blit(lbl, (r.centerx - lbl.get_width() // 2,
                               r.centery - lbl.get_height() // 2))
            x += TW + _PAD
        x += 14

        # ── Brush size: [−]  N px  [+] ───────────────────────────────────────
        SBW = 32
        sby = (TOOLBAR_H - SBW) // 2
        self._size_minus = pygame.Rect(x, sby, SBW, SBW)
        c = _CBTNH if self._size_minus.collidepoint(mouse) else _CBTN
        pygame.draw.rect(screen, c, self._size_minus, border_radius=4)
        lbl = self._font.render("−", True, _CTXT)
        screen.blit(lbl, (self._size_minus.centerx - lbl.get_width() // 2,
                           self._size_minus.centery - lbl.get_height() // 2))
        x += SBW + 4

        sz_lbl = self._font.render(f"{self.brush} px", True, (170, 170, 170))
        screen.blit(sz_lbl, (x, cy - sz_lbl.get_height() // 2))
        x += 56 + 4

        self._size_plus = pygame.Rect(x, sby, SBW, SBW)
        c = _CBTNH if self._size_plus.collidepoint(mouse) else _CBTN
        pygame.draw.rect(screen, c, self._size_plus, border_radius=4)
        lbl = self._font.render("+", True, _CTXT)
        screen.blit(lbl, (self._size_plus.centerx - lbl.get_width() // 2,
                           self._size_plus.centery - lbl.get_height() // 2))
        x += SBW + 18

        # ── Brush preview circle ──────────────────────────────────────────────
        pr = min(self.brush, cy - 6)
        pygame.draw.circle(screen, self.color, (x + pr, cy), pr)
        pygame.draw.circle(screen, (110, 110, 110), (x + pr, cy), pr, 1)

        # ── Clear / Save (right-aligned) ──────────────────────────────────────
        by2 = (TOOLBAR_H - _BH) // 2
        self._save  = pygame.Rect(sw - _BW - _PAD,           by2, _BW, _BH)
        self._clear = pygame.Rect(sw - 2 * _BW - 2 * _PAD,   by2, _BW, _BH)
        for rect, label in ((self._clear, "Clear  C"), (self._save, "Save  ⌃S")):
            c = _CBTNH if rect.collidepoint(mouse) else _CBTN
            pygame.draw.rect(screen, c, rect, border_radius=6)
            lbl = self._font.render(label, True, _CTXT)
            screen.blit(lbl, (rect.centerx - lbl.get_width() // 2,
                               rect.centery - lbl.get_height() // 2))


class Canvas:
    def __init__(self, rect: pygame.Rect):
        self.rect    = rect
        self.surface = pygame.Surface(rect.size)
        self.surface.fill(CANVAS_BG)
        self._prev   = None

    def resize(self, new_rect: pygame.Rect):
        new_surf = pygame.Surface(new_rect.size)
        new_surf.fill(CANVAS_BG)
        new_surf.blit(self.surface, (0, 0))
        self.surface = new_surf
        self.rect    = new_rect

    def start(self, screen_pos, color, radius):
        if not self.rect.collidepoint(screen_pos):
            return
        cp = self._to_canvas(screen_pos)
        pygame.draw.circle(self.surface, color, cp, radius)
        self._prev = cp

    def stroke(self, screen_pos, color, radius):
        if self._prev is None:
            return
        cp = self._to_canvas(screen_pos)
        dx, dy = cp[0] - self._prev[0], cp[1] - self._prev[1]
        steps  = max(1, int(math.hypot(dx, dy)))
        for i in range(steps + 1):
            x = round(self._prev[0] + dx * i / steps)
            y = round(self._prev[1] + dy * i / steps)
            pygame.draw.circle(self.surface, color, (x, y), radius)
        self._prev = cp

    def stop(self):
        self._prev = None

    def clear(self):
        self.surface.fill(CANVAS_BG)

    def flood_fill(self, screen_pos: tuple, color: tuple):
        _flood_fill(self.surface, self._to_canvas(screen_pos), color)

    def save(self) -> str:
        ts     = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        folder = os.path.expanduser("~/Pictures/qGames")
        os.makedirs(folder, exist_ok=True)
        path   = os.path.join(folder, f"painting_{ts}.png")
        pygame.image.save(self.surface, path)
        return path

    def draw(self, screen):
        screen.blit(self.surface, self.rect)

    def _to_canvas(self, screen_pos):
        return (screen_pos[0] - self.rect.x, screen_pos[1] - self.rect.y)


def _canvas_rect(screen, status_h):
    w, h = screen.get_size()
    return pygame.Rect(0, TOOLBAR_H, w, h - TOOLBAR_H - status_h)


def _draw_confirm_dialog(screen, dlg_font, yes_rect: pygame.Rect, no_rect: pygame.Rect):
    sw, sh = screen.get_size()

    overlay = pygame.Surface((sw, sh), pygame.SRCALPHA)
    overlay.fill((0, 0, 0, 150))
    screen.blit(overlay, (0, 0))

    bw, bh = 420, 158
    bx = (sw - bw) // 2
    by = (sh - bh) // 2
    box = pygame.Rect(bx, by, bw, bh)
    pygame.draw.rect(screen, (48, 48, 62), box, border_radius=12)
    pygame.draw.rect(screen, (100, 100, 124), box, width=2, border_radius=12)

    msg = dlg_font.render("Clear the canvas?  This cannot be undone.", True, (220, 220, 232))
    screen.blit(msg, (bx + (bw - msg.get_width()) // 2, by + 26))

    mouse  = pygame.mouse.get_pos()
    btn_w, btn_h = 124, 40
    yes_rect.update(bx + bw // 2 - btn_w - 12, by + bh - 60, btn_w, btn_h)
    no_rect.update( bx + bw // 2 + 12,          by + bh - 60, btn_w, btn_h)
    for rect, label, base in (
        (yes_rect, "Yes, clear", (148, 42, 42)),
        (no_rect,  "Cancel",     (58,  58, 70)),
    ):
        c = tuple(min(255, v + 30) for v in base) if rect.collidepoint(mouse) else base
        pygame.draw.rect(screen, c, rect, border_radius=6)
        lbl = dlg_font.render(label, True, (240, 240, 240))
        screen.blit(lbl, (rect.centerx - lbl.get_width() // 2,
                           rect.centery - lbl.get_height() // 2))


def main():
    pygame.init()

    icon = pygame.image.load(resource_path("assets/icons/paint.png", GAME_DIR))
    pygame.display.set_icon(icon)

    screen = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
    pygame.display.set_caption(TITLE)
    clock      = pygame.time.Clock()
    status_bar = StatusBar()
    toolbar    = Toolbar()
    canvas     = Canvas(_canvas_rect(screen, status_bar.height))
    msg_font   = pygame.font.SysFont("sans", 14)
    dlg_font   = pygame.font.SysFont("sans", 16, bold=True)

    drawing       = False
    save_msg      = ""
    save_msg_ttl  = 0
    confirm_clear = False
    dlg_yes       = pygame.Rect(0, 0, 0, 0)
    dlg_no        = pygame.Rect(0, 0, 0, 0)

    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
                continue

            if confirm_clear:
                if event.type == pygame.KEYDOWN:
                    if event.key in (pygame.K_RETURN, pygame.K_y):
                        canvas.clear()
                        confirm_clear = False
                    elif event.key in (pygame.K_ESCAPE, pygame.K_n):
                        confirm_clear = False
                elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                    if dlg_yes.collidepoint(event.pos):
                        canvas.clear()
                    confirm_clear = False
                continue

            if event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                elif event.key == pygame.K_c:
                    confirm_clear = True
                elif event.key == pygame.K_s and (event.mod & pygame.KMOD_CTRL):
                    save_msg     = f"Saved → {canvas.save()}"
                    save_msg_ttl = FPS * 4

            action = toolbar.handle_event(event)
            if action == "clear":
                confirm_clear = True
            elif action == "save":
                save_msg     = f"Saved → {canvas.save()}"
                save_msg_ttl = FPS * 4

            if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                if canvas.rect.collidepoint(event.pos):
                    if toolbar.tool == TOOL_BUCKET:
                        canvas.flood_fill(event.pos, toolbar.color)
                    else:
                        drawing = True
                        canvas.start(event.pos, toolbar.color, toolbar.brush)
            elif event.type == pygame.MOUSEBUTTONUP and event.button == 1:
                drawing = False
                canvas.stop()
            elif event.type == pygame.MOUSEMOTION and drawing:
                canvas.stroke(event.pos, toolbar.color, toolbar.brush)

            status_bar.handle_event(event)

        cr = _canvas_rect(screen, status_bar.height)
        if cr != canvas.rect:
            canvas.resize(cr)

        screen.fill(BG)
        toolbar.draw(screen)
        canvas.draw(screen)
        status_bar.draw(screen)

        if save_msg_ttl > 0:
            save_msg_ttl -= 1
            lbl = msg_font.render(save_msg, True, (100, 230, 120))
            screen.blit(lbl, (8, TOOLBAR_H + 6))

        if confirm_clear:
            _draw_confirm_dialog(screen, dlg_font, dlg_yes, dlg_no)

        pygame.display.flip()
        clock.tick(FPS)

    pygame.quit()
    sys.exit()


if __name__ == "__main__":
    main()
