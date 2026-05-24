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
TOOLBAR_H  = 64
MIN_BRUSH  = 1
MAX_BRUSH  = 80
DEF_BRUSH  = 8

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

_CB    = (38,  38,  38)   # toolbar bg
_CBTN  = (60,  60,  60)   # button
_CBTNH = (88,  88,  88)   # button hover
_CTXT  = (210, 210, 210)
_SW    = 40               # swatch size
_PAD   = 8
_BW, _BH = 72, 36         # button width/height


class Toolbar:
    def __init__(self):
        self.color_idx = 0
        self.brush     = DEF_BRUSH
        self._swatches = []
        self._clear    = pygame.Rect(0, 0, 0, 0)
        self._save     = pygame.Rect(0, 0, 0, 0)
        self._font     = pygame.font.SysFont("sans", 13)

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
            if self._clear.collidepoint(event.pos):
                return "clear"
            if self._save.collidepoint(event.pos):
                return "save"
        if event.type == pygame.KEYDOWN and event.key in _KEY_COLOR:
            self.color_idx = _KEY_COLOR[event.key]
        if event.type == pygame.MOUSEWHEEL:
            self.brush = max(MIN_BRUSH, min(MAX_BRUSH, self.brush + event.y))
        return None

    def draw(self, screen):
        sw = screen.get_width()
        pygame.draw.rect(screen, _CB, (0, 0, sw, TOOLBAR_H))
        mouse = pygame.mouse.get_pos()

        # Swatches
        self._swatches = []
        x = _PAD
        sy = (TOOLBAR_H - _SW) // 2
        for i, color in enumerate(PALETTE):
            r = pygame.Rect(x, sy, _SW, _SW)
            self._swatches.append(r)
            pygame.draw.rect(screen, color, r, border_radius=6)
            if i == self.color_idx:
                pygame.draw.rect(screen, (255, 255, 255), r, width=3, border_radius=6)
            elif r.collidepoint(mouse):
                pygame.draw.rect(screen, (180, 180, 180), r, width=2, border_radius=6)
            x += _SW + _PAD

        # Brush preview circle
        x += 16
        pr = min(self.brush, TOOLBAR_H // 2 - 6)
        pygame.draw.circle(screen, self.color, (x + pr, TOOLBAR_H // 2), pr)
        pygame.draw.circle(screen, (110, 110, 110), (x + pr, TOOLBAR_H // 2), pr, 1)
        hint = self._font.render(f"brush {self.brush}px  (scroll ↕)", True, (140, 140, 140))
        screen.blit(hint, (x + pr * 2 + 10, TOOLBAR_H // 2 - hint.get_height() // 2))

        # Clear / Save buttons (right-aligned)
        by = (TOOLBAR_H - _BH) // 2
        self._save  = pygame.Rect(sw - _BW - _PAD,          by, _BW, _BH)
        self._clear = pygame.Rect(sw - 2 * _BW - 2 * _PAD,  by, _BW, _BH)
        for rect, label in [(self._clear, "Clear  C"), (self._save, "Save  ⌃S")]:
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
        new_surf.blit(self.surface, (0, 0))   # preserve existing drawing
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

    def save(self) -> str:
        ts      = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        folder  = os.path.expanduser("~/Pictures/qGames")
        os.makedirs(folder, exist_ok=True)
        path    = os.path.join(folder, f"painting_{ts}.png")
        pygame.image.save(self.surface, path)
        return path

    def draw(self, screen):
        screen.blit(self.surface, self.rect)

    def _to_canvas(self, screen_pos):
        return (screen_pos[0] - self.rect.x, screen_pos[1] - self.rect.y)


def _canvas_rect(screen, status_h):
    w, h = screen.get_size()
    return pygame.Rect(0, TOOLBAR_H, w, h - TOOLBAR_H - status_h)


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

    drawing       = False
    save_msg      = ""
    save_msg_ttl  = 0

    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                elif event.key == pygame.K_c:
                    canvas.clear()
                elif event.key == pygame.K_s and (event.mod & pygame.KMOD_CTRL):
                    save_msg     = f"Saved → {canvas.save()}"
                    save_msg_ttl = FPS * 4

            action = toolbar.handle_event(event)
            if action == "clear":
                canvas.clear()
            elif action == "save":
                save_msg     = f"Saved → {canvas.save()}"
                save_msg_ttl = FPS * 4

            if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                if canvas.rect.collidepoint(event.pos):
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

        pygame.display.flip()
        clock.tick(FPS)

    pygame.quit()
    sys.exit()


if __name__ == "__main__":
    main()
