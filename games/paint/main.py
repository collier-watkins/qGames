import datetime
import math
import os
import sys
import time
from collections import deque

import pygame

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from shared.mqtt_stats import publish as mqtt_publish
from shared.status_bar import StatusBar
from shared.util import draw_splash, maximize_window, resource_path, single_instance

GAME_DIR = os.path.dirname(os.path.abspath(__file__))

TITLE      = "Paint"
FPS        = 60
BG         = (45, 45, 45)
CANVAS_BG  = (255, 255, 255)
MIN_BRUSH  = 1
MAX_BRUSH  = 80
DEF_BRUSH  = 8
TOOL_BRUSH  = "brush"
TOOL_BUCKET = "bucket"
UNDO_LIMIT  = 20
TB_DEF = 84
TB_MIN = 52
TB_MAX = 120

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
_CTXTD = (88,  88,  88)

# Fixed horizontal dimensions — only heights scale with toolbar size
_SW  = 46   # swatch square
_PAD = 6    # gap between elements
_TBW = 80   # tool button width
_MBW = 76   # main button width (undo/redo/clear/save)


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


def _icon_brush(surf, cx, cy, sz, color):
    hs = sz // 2
    lw = max(2, sz // 6)
    x0, y0 = cx + hs // 3,  cy - hs + 2
    x1, y1 = cx - hs // 4,  cy + hs // 3
    pygame.draw.line(surf, color, (x0, y0), (x1, y1), lw)
    pygame.draw.polygon(surf, color, [
        (x1 - lw + 1, y1),
        (x1 + lw - 1, y1),
        (x1, cy + hs),
    ])


def _icon_bucket(surf, cx, cy, sz, color):
    hs  = sz // 2
    lw  = max(2, sz // 7)
    top = cy - hs // 4
    mg  = sz // 6
    pygame.draw.polygon(surf, color, [
        (cx - hs + mg, top),
        (cx + hs - mg, top),
        (cx + hs,      cy + hs),
        (cx - hs,      cy + hs),
    ])
    arc_r = pygame.Rect(cx - hs // 2, cy - hs, hs, sz // 2)
    pygame.draw.arc(surf, color, arc_r, math.pi, 2 * math.pi, lw)


class Toolbar:
    def __init__(self):
        self.height    = TB_DEF
        self.color_idx = 0
        self.brush     = DEF_BRUSH
        self.tool      = TOOL_BRUSH

        self._swatches   = []
        self._tool_rects = {}
        self._size_minus = pygame.Rect(0, 0, 0, 0)
        self._size_plus  = pygame.Rect(0, 0, 0, 0)
        self._undo_btn   = pygame.Rect(0, 0, 0, 0)
        self._redo_btn   = pygame.Rect(0, 0, 0, 0)
        self._clear      = pygame.Rect(0, 0, 0, 0)
        self._save       = pygame.Rect(0, 0, 0, 0)
        self._tb_minus   = pygame.Rect(0, 0, 0, 0)
        self._tb_plus    = pygame.Rect(0, 0, 0, 0)

        self._font_sz = 0
        self._font    = None
        self._txt     = {}          # pre-rendered static label surfaces
        self._brush_px_surf = None  # cached f"{brush}px" surface
        self._brush_px_val  = -1
        self._refresh_font()

    def _refresh_font(self):
        sz = max(11, min(22, self.height // 5))
        if sz != self._font_sz:
            self._font    = pygame.font.SysFont("sans", sz)
            self._font_sz = sz
            f = self._font
            # Pre-render every static label — these never change at runtime.
            self._txt = {
                "P":      f.render("P",        True, (148, 148, 162)),
                "B":      f.render("B",        True, (148, 148, 162)),
                "minus":  f.render("−",        True, _CTXT),
                "plus":   f.render("+",        True, _CTXT),
                "tbp":    f.render("+",        True, (148, 148, 165)),
                "tbm":    f.render("−",        True, (148, 148, 165)),
                "save":   f.render("Save ⌃S",  True, _CTXT),
                "clear":  f.render("Clear C",  True, _CTXT),
                "undo_e": f.render("Undo",     True, _CTXT),
                "undo_d": f.render("Undo",     True, _CTXTD),
                "redo_e": f.render("Redo",     True, _CTXT),
                "redo_d": f.render("Redo",     True, _CTXTD),
            }
            self._brush_px_val = -1  # invalidate brush size cache

    def _brush_px(self):
        if self.brush != self._brush_px_val:
            self._brush_px_surf = self._font.render(
                f"{self.brush}px", True, (165, 165, 165))
            self._brush_px_val = self.brush
        return self._brush_px_surf

    @property
    def color(self):
        return PALETTE[self.color_idx]

    def handle_event(self, event):
        """Return 'clear', 'save', 'undo', 'redo', or None."""
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
            if self._tb_minus.collidepoint(event.pos):
                self.height = max(TB_MIN, self.height - 4)
                self._refresh_font()
                return None
            if self._tb_plus.collidepoint(event.pos):
                self.height = min(TB_MAX, self.height + 4)
                self._refresh_font()
                return None
            if self._undo_btn.collidepoint(event.pos):
                return "undo"
            if self._redo_btn.collidepoint(event.pos):
                return "redo"
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

    def draw(self, screen, can_undo=False, can_redo=False):
        H     = self.height
        sw    = screen.get_width()
        t     = self._txt
        mouse = pygame.mouse.get_pos()
        cy    = H // 2

        pygame.draw.rect(screen, _CB, (0, 0, sw, H))

        TBH    = max(28, H - 22)
        SBW    = max(20, min(44, H - 48))
        MBH    = max(26, H - 26)
        TBSZ   = max(18, min(28, H // 4))
        icon_sz = max(14, min(34, TBH - 18))
        br6    = 6
        sy     = (H - _SW) // 2

        x = _PAD

        # ── Colour swatches ───────────────────────────────────────────────
        self._swatches = []
        for i, color in enumerate(PALETTE):
            r   = pygame.Rect(x, sy, _SW, _SW)
            br  = max(3, _SW // 7)
            self._swatches.append(r)
            pygame.draw.rect(screen, color, r, border_radius=br)
            if i == self.color_idx:
                pygame.draw.rect(screen, (255, 255, 255), r, width=3, border_radius=br)
            elif r.collidepoint(mouse):
                pygame.draw.rect(screen, (180, 180, 180), r, width=2, border_radius=br)
            x += _SW + _PAD
        x += _PAD

        # ── Tool buttons with icons ───────────────────────────────────────
        ty = (H - TBH) // 2
        self._tool_rects = {}
        for tool_id, draw_fn, lbl_surf in (
            (TOOL_BRUSH,  _icon_brush,  t["P"]),
            (TOOL_BUCKET, _icon_bucket, t["B"]),
        ):
            r      = pygame.Rect(x, ty, _TBW, TBH)
            active = self.tool == tool_id
            bg     = _CACT if active else (_CBTNH if r.collidepoint(mouse) else _CBTN)
            self._tool_rects[tool_id] = r
            pygame.draw.rect(screen, bg, r, border_radius=br6)
            if active:
                pygame.draw.rect(screen, (120, 160, 230), r, width=2, border_radius=br6)
            icon_cx = r.x + icon_sz // 2 + 5
            draw_fn(screen, icon_cx, r.centery, icon_sz, _CTXT)
            screen.blit(lbl_surf, (r.right - lbl_surf.get_width() - 5,
                                   r.centery - lbl_surf.get_height() // 2))
            x += _TBW + _PAD
        x += _PAD

        # ── Brush size: [−] N px [+] ──────────────────────────────────────
        sby = (H - SBW) // 2
        self._size_minus = pygame.Rect(x, sby, SBW, SBW)
        c = _CBTNH if self._size_minus.collidepoint(mouse) else _CBTN
        pygame.draw.rect(screen, c, self._size_minus, border_radius=4)
        m = t["minus"]
        screen.blit(m, (self._size_minus.centerx - m.get_width() // 2,
                        self._size_minus.centery - m.get_height() // 2))
        x += SBW + 4

        sz_t = self._brush_px()
        screen.blit(sz_t, (x, cy - sz_t.get_height() // 2))
        x += max(36, sz_t.get_width() + 4)

        self._size_plus = pygame.Rect(x, sby, SBW, SBW)
        c = _CBTNH if self._size_plus.collidepoint(mouse) else _CBTN
        pygame.draw.rect(screen, c, self._size_plus, border_radius=4)
        p = t["plus"]
        screen.blit(p, (self._size_plus.centerx - p.get_width() // 2,
                        self._size_plus.centery - p.get_height() // 2))
        x += SBW + _PAD

        # ── Brush preview circle ──────────────────────────────────────────
        pr = min(self.brush, cy - 6)
        pygame.draw.circle(screen, self.color, (x + pr, cy), pr)
        pygame.draw.circle(screen, (110, 110, 110), (x + pr, cy), pr, 1)

        # ── Right-aligned: [TB−][TB+]  [Undo][Redo][Clear][Save] ─────────
        by2        = (H - MBH) // 2
        right_edge = sw - _PAD

        self._tb_plus  = pygame.Rect(right_edge - TBSZ, cy - TBSZ - 2, TBSZ, TBSZ)
        self._tb_minus = pygame.Rect(right_edge - TBSZ, cy + 2,         TBSZ, TBSZ)
        for r, sym in ((self._tb_plus, t["tbp"]), (self._tb_minus, t["tbm"])):
            c = _CBTNH if r.collidepoint(mouse) else (50, 50, 62)
            pygame.draw.rect(screen, c, r, border_radius=3)
            screen.blit(sym, (r.centerx - sym.get_width() // 2,
                              r.centery - sym.get_height() // 2))

        rx = right_edge - TBSZ - _PAD

        self._save     = pygame.Rect(rx - _MBW, by2, _MBW, MBH); rx -= _MBW + _PAD
        self._clear    = pygame.Rect(rx - _MBW, by2, _MBW, MBH); rx -= _MBW + _PAD
        self._redo_btn = pygame.Rect(rx - _MBW, by2, _MBW, MBH); rx -= _MBW + _PAD
        self._undo_btn = pygame.Rect(rx - _MBW, by2, _MBW, MBH)

        for rect, lbl in ((self._save, t["save"]), (self._clear, t["clear"])):
            c = _CBTNH if rect.collidepoint(mouse) else _CBTN
            pygame.draw.rect(screen, c, rect, border_radius=br6)
            screen.blit(lbl, (rect.centerx - lbl.get_width() // 2,
                              rect.centery - lbl.get_height() // 2))

        for rect, lbl_e, lbl_d, enabled in (
            (self._undo_btn, t["undo_e"], t["undo_d"], can_undo),
            (self._redo_btn, t["redo_e"], t["redo_d"], can_redo),
        ):
            bg = (_CBTNH if (rect.collidepoint(mouse) and enabled)
                  else _CBTN if enabled else (48, 48, 48))
            pygame.draw.rect(screen, bg, rect, border_radius=br6)
            lbl = lbl_e if enabled else lbl_d
            screen.blit(lbl, (rect.centerx - lbl.get_width() // 2,
                              rect.centery - lbl.get_height() // 2))


class Canvas:
    def __init__(self, rect: pygame.Rect):
        self.rect    = rect
        self.surface = pygame.Surface(rect.size)
        self.surface.fill(CANVAS_BG)
        self._prev = None
        self._undo: deque = deque(maxlen=UNDO_LIMIT)
        self._redo: deque = deque(maxlen=UNDO_LIMIT)

    def _snapshot(self):
        self._undo.append(self.surface.copy())
        self._redo.clear()

    def resize(self, new_rect: pygame.Rect):
        new_surf = pygame.Surface(new_rect.size)
        new_surf.fill(CANVAS_BG)
        new_surf.blit(self.surface, (0, 0))
        self.surface = new_surf
        self.rect    = new_rect

    def start(self, screen_pos, color, radius):
        if not self.rect.collidepoint(screen_pos):
            return
        self._snapshot()
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
        self._snapshot()
        self.surface.fill(CANVAS_BG)

    def flood_fill(self, screen_pos: tuple, color: tuple):
        self._snapshot()
        _flood_fill(self.surface, self._to_canvas(screen_pos), color)

    def undo(self):
        if self._undo:
            self._redo.append(self.surface.copy())
            snap = self._undo.pop()
            self.surface.fill(CANVAS_BG)
            self.surface.blit(snap, (0, 0))

    def redo(self):
        if self._redo:
            self._undo.append(self.surface.copy())
            snap = self._redo.pop()
            self.surface.fill(CANVAS_BG)
            self.surface.blit(snap, (0, 0))

    @property
    def can_undo(self):
        return bool(self._undo)

    @property
    def can_redo(self):
        return bool(self._redo)

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


def _canvas_rect(screen, toolbar_h: int, status_h: int) -> pygame.Rect:
    w, h = screen.get_size()
    return pygame.Rect(0, toolbar_h, w, h - toolbar_h - status_h)


def _draw_confirm_dialog(screen, dlg_font, yes_rect: pygame.Rect, no_rect: pygame.Rect):
    sw, sh = screen.get_size()
    overlay = pygame.Surface((sw, sh), pygame.SRCALPHA)
    overlay.fill((0, 0, 0, 150))
    screen.blit(overlay, (0, 0))

    bw, bh = 380, 150
    bx = (sw - bw) // 2
    by = (sh - bh) // 2
    box = pygame.Rect(bx, by, bw, bh)
    pygame.draw.rect(screen, (48, 48, 62), box, border_radius=12)
    pygame.draw.rect(screen, (100, 100, 124), box, width=2, border_radius=12)

    msg = dlg_font.render("Clear the canvas?", True, (220, 220, 232))
    screen.blit(msg, (bx + (bw - msg.get_width()) // 2, by + 24))

    mouse      = pygame.mouse.get_pos()
    btn_w, btn_h = 118, 38
    yes_rect.update(bx + bw // 2 - btn_w - 10, by + bh - 56, btn_w, btn_h)
    no_rect.update( bx + bw // 2 + 10,          by + bh - 56, btn_w, btn_h)
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
    single_instance("paint")
    pygame.init()

    icon = pygame.image.load(resource_path("assets/icons/paint.png", GAME_DIR))
    pygame.display.set_icon(icon)

    screen = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
    maximize_window()
    pygame.display.set_caption(TITLE)
    draw_splash(screen, TITLE)
    clock      = pygame.time.Clock()
    status_bar = StatusBar()
    toolbar    = Toolbar()
    canvas     = Canvas(_canvas_rect(screen, toolbar.height, status_bar.height))
    msg_font   = pygame.font.SysFont("sans", 14)
    dlg_font   = pygame.font.SysFont("sans", 16, bold=True)

    drawing       = False
    save_msg      = ""
    save_msg_ttl  = 0
    confirm_clear = False
    dlg_yes       = pygame.Rect(0, 0, 0, 0)
    dlg_no        = pygame.Rect(0, 0, 0, 0)
    last_tool     = None
    dirty         = True
    last_mouse    = (-1, -1)

    running = True
    while running:
        sw, sh = screen.get_size()
        mouse  = pygame.mouse.get_pos()

        # Hover effects only exist in the toolbar and confirm dialog — moving
        # the mouse elsewhere (canvas while not drawing) needs no redraw.
        if mouse != last_mouse:
            in_canvas_idle = (
                toolbar.height <= mouse[1] <= sh - status_bar.height
                and not drawing and not confirm_clear
            )
            if not in_canvas_idle:
                dirty = True
            last_mouse = mouse

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
                dirty = True
                continue

            if event.type == pygame.KEYDOWN:
                dirty = True
                if event.key == pygame.K_ESCAPE:
                    running = False
                elif event.key == pygame.K_c:
                    confirm_clear = True
                elif event.key == pygame.K_z and (event.mod & pygame.KMOD_CTRL):
                    if event.mod & pygame.KMOD_SHIFT:
                        canvas.redo()
                    else:
                        canvas.undo()
                elif event.key == pygame.K_y and (event.mod & pygame.KMOD_CTRL):
                    canvas.redo()
                elif event.key == pygame.K_s and (event.mod & pygame.KMOD_CTRL):
                    _path        = canvas.save()
                    save_msg     = f"Saved → {_path}"
                    save_msg_ttl = FPS * 4
                    mqtt_publish("paint/saved", os.path.basename(_path))
                    mqtt_publish("paint/ts", int(time.time()))

            action = toolbar.handle_event(event)
            if action == "clear":
                confirm_clear = True
                dirty = True
            elif action == "save":
                _path        = canvas.save()
                save_msg     = f"Saved → {_path}"
                save_msg_ttl = FPS * 4
                mqtt_publish("paint/saved", os.path.basename(_path))
                mqtt_publish("paint/ts", int(time.time()))
                dirty = True
            elif action == "undo":
                canvas.undo()
                dirty = True
            elif action == "redo":
                canvas.redo()
                dirty = True
            elif action is None and event.type in (
                pygame.MOUSEBUTTONDOWN, pygame.KEYDOWN, pygame.MOUSEWHEEL,
            ):
                dirty = True  # toolbar state may have changed (color, tool, brush)

            if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                if canvas.rect.collidepoint(event.pos):
                    if toolbar.tool == TOOL_BUCKET:
                        canvas.flood_fill(event.pos, toolbar.color)
                        dirty = True
                    else:
                        drawing = True
                        canvas.start(event.pos, toolbar.color, toolbar.brush)
                        dirty = True
            elif event.type == pygame.MOUSEBUTTONUP and event.button == 1:
                drawing = False
                canvas.stop()
                dirty = True
            elif event.type == pygame.MOUSEMOTION and drawing:
                canvas.stroke(event.pos, toolbar.color, toolbar.brush)
                dirty = True

            status_bar.handle_event(event)

        if toolbar.tool != last_tool:
            try:
                if toolbar.tool == TOOL_BUCKET:
                    pygame.mouse.set_cursor(pygame.SYSTEM_CURSOR_ARROW)
                else:
                    pygame.mouse.set_cursor(pygame.SYSTEM_CURSOR_CROSSHAIR)
            except pygame.error:
                pass   # system cursor unavailable on this display server
            last_tool = toolbar.tool

        cr = _canvas_rect(screen, toolbar.height, status_bar.height)
        if cr != canvas.rect:
            canvas.resize(cr)
            dirty = True

        if save_msg_ttl > 0:
            save_msg_ttl -= 1
            dirty = True

        if dirty:
            screen.fill(BG)
            toolbar.draw(screen, can_undo=canvas.can_undo, can_redo=canvas.can_redo)
            canvas.draw(screen)
            status_bar.draw(screen)

            if save_msg_ttl > 0:
                lbl = msg_font.render(save_msg, True, (100, 230, 120))
                screen.blit(lbl, (8, toolbar.height + 6))

            if confirm_clear:
                _draw_confirm_dialog(screen, dlg_font, dlg_yes, dlg_no)

            pygame.display.flip()
            dirty = False

        clock.tick(FPS)

    pygame.quit()
    sys.exit()


if __name__ == "__main__":
    main()
