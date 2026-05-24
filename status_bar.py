import pygame

_BG = (15, 22, 42)
_TEXT = (160, 185, 235)
_BTN = (35, 52, 88)
_BTN_HOV = (55, 78, 128)
_FONT_MIN = 8
_FONT_MAX = 28
_PAD = 4
_BTN_GAP = 4


class StatusBar:
    def __init__(self, font_size=12):
        self._font_size = font_size
        self._minus_rect = pygame.Rect(0, 0, 0, 0)
        self._plus_rect = pygame.Rect(0, 0, 0, 0)
        self._rebuild()

    # ── public ──────────────────────────────────────────────────────────────

    @property
    def height(self):
        return self._height

    def handle_event(self, event):
        if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            if self._minus_rect.collidepoint(event.pos):
                self._set_font_size(self._font_size - 1)
            elif self._plus_rect.collidepoint(event.pos):
                self._set_font_size(self._font_size + 1)

    def draw(self, screen):
        sw, sh = screen.get_size()
        bar_y = sh - self._height
        mouse = pygame.mouse.get_pos()

        pygame.draw.rect(screen, _BG, (0, bar_y, sw, self._height))

        label = self._font.render(f"{sw} × {sh}", True, _TEXT)
        screen.blit(label, (_PAD, bar_y + (self._height - label.get_height()) // 2))

        self._draw_btn(screen, self._plus_rect, mouse, bar_y, "+")
        self._draw_btn(screen, self._minus_rect, mouse, bar_y, "−")

    # ── private ─────────────────────────────────────────────────────────────

    def _set_font_size(self, size):
        self._font_size = max(_FONT_MIN, min(_FONT_MAX, size))
        self._rebuild()

    def _rebuild(self):
        self._font = pygame.font.SysFont("monospace", self._font_size)
        self._height = self._font_size + 8
        # Lay out button rects lazily — real positions set in draw()
        self._plus_rect = pygame.Rect(0, 0, self._height - 4, self._height - 4)
        self._minus_rect = pygame.Rect(0, 0, self._height - 4, self._height - 4)

    def _draw_btn(self, screen, rect, mouse, bar_y, symbol):
        sw = screen.get_width()
        btn_side = self._height - 4

        # Position buttons from the right edge each frame
        if symbol == "+":
            rect.topleft = (sw - btn_side - _BTN_GAP, bar_y + 2)
        else:
            rect.topleft = (sw - 2 * (btn_side + _BTN_GAP), bar_y + 2)
        rect.size = (btn_side, btn_side)

        color = _BTN_HOV if rect.collidepoint(mouse) else _BTN
        pygame.draw.rect(screen, color, rect, border_radius=3)

        surf = self._font.render(symbol, True, _TEXT)
        screen.blit(surf, (
            rect.centerx - surf.get_width() // 2,
            rect.centery - surf.get_height() // 2,
        ))
