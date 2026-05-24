import os
import sys

import pygame

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from shared.status_bar import StatusBar
from shared.util import resource_path

GAME_DIR = os.path.dirname(os.path.abspath(__file__))

TITLE = "Letter Sounds"
FPS   = 60


def main():
    pygame.init()

    icon = pygame.image.load(resource_path("assets/icons/letters.png", GAME_DIR))
    pygame.display.set_icon(icon)

    screen = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
    pygame.display.set_caption(TITLE)
    clock      = pygame.time.Clock()
    status_bar = StatusBar()
    font       = pygame.font.SysFont("sans", 42, bold=True)
    sub_font   = pygame.font.SysFont("sans", 22)

    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
                running = False
            status_bar.handle_event(event)

        screen.fill((25, 35, 60))
        sw, sh = screen.get_size()

        lbl = font.render("Letter Sounds", True, (240, 200, 60))
        sub = sub_font.render("Coming soon — press Escape to quit", True, (120, 140, 180))
        screen.blit(lbl, (sw // 2 - lbl.get_width() // 2, sh // 2 - 50))
        screen.blit(sub, (sw // 2 - sub.get_width() // 2, sh // 2 + 20))

        status_bar.draw(screen)
        pygame.display.flip()
        clock.tick(FPS)

    pygame.quit()
    sys.exit()


if __name__ == "__main__":
    main()
