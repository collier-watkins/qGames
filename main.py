import argparse
import pygame
import sys

from status_bar import StatusBar

DEFAULT_W = 1280
DEFAULT_H = 720
FPS = 60
TITLE = "qGames"
BG_COLOR = (25, 35, 60)


def parse_args():
    p = argparse.ArgumentParser(description=TITLE)
    p.add_argument("--fullscreen", action="store_true")
    p.add_argument("--width", type=int, default=DEFAULT_W, metavar="W")
    p.add_argument("--height", type=int, default=DEFAULT_H, metavar="H")
    return p.parse_args()


def main():
    args = parse_args()
    pygame.init()

    if args.fullscreen:
        screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
    else:
        screen = pygame.display.set_mode((args.width, args.height), pygame.RESIZABLE)

    pygame.display.set_caption(TITLE)
    clock = pygame.time.Clock()
    status_bar = StatusBar()

    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE:
                running = False
            status_bar.handle_event(event)

        screen.fill(BG_COLOR)
        status_bar.draw(screen)

        pygame.display.flip()
        clock.tick(FPS)

    pygame.quit()
    sys.exit()


if __name__ == "__main__":
    main()
