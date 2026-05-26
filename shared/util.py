import ctypes
import ctypes.util
import os
import socket as _socket
import sys

_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_LOCK_SOCK = None  # module-level ref keeps the socket open (prevents GC)


def resource_path(relative: str, base: str = None) -> str:
    """Return absolute path to an asset, works in dev and PyInstaller bundles.

    Pass the game's GAME_DIR as base so dev paths resolve from the game folder.
    In a PyInstaller bundle all assets live under sys._MEIPASS regardless.
    """
    if hasattr(sys, "_MEIPASS"):
        return os.path.join(sys._MEIPASS, relative)
    return os.path.join(base if base is not None else _PROJECT_ROOT, relative)


def maximize_window() -> None:
    """Maximize the current Pygame window via SDL2 (works on any Pygame version).

    Calls SDL_MaximizeWindow so the compositor sizes the window to the workarea,
    leaving the taskbar visible. Safe to call if SDL2 is unavailable — silently
    does nothing.
    """
    try:
        _lib = ctypes.util.find_library("SDL2") or "libSDL2-2.0.so.0"
        _sdl = ctypes.CDLL(_lib)
        _sdl.SDL_GetWindowFromID.restype = ctypes.c_void_p
        _sdl.SDL_MaximizeWindow.restype = None
        _sdl.SDL_MaximizeWindow.argtypes = [ctypes.c_void_p]
        _win = _sdl.SDL_GetWindowFromID(ctypes.c_uint(1))
        if _win:
            _sdl.SDL_MaximizeWindow(_win)
    except Exception:
        pass


def single_instance(game_name: str) -> None:
    """Exit immediately if another instance of this game is already running.

    Binds an abstract Linux Unix socket — automatically released when the
    process dies, so there are no stale lock files to clean up.
    """
    global _LOCK_SOCK
    _LOCK_SOCK = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
    try:
        _LOCK_SOCK.bind(f"\0qgames_{game_name}")
    except OSError:
        sys.exit(0)


def draw_splash(screen, title: str) -> None:
    """Fill the window with a loading message and flip immediately.

    Call right after set_mode/maximize so something appears on screen while
    the rest of the game initialises.
    """
    try:
        import pygame
        screen.fill((15, 20, 30))
        font = pygame.font.SysFont("sans", 32)
        surf = font.render(f"Loading {title}…", True, (130, 150, 180))
        sw, sh = screen.get_size()
        screen.blit(surf, (sw // 2 - surf.get_width() // 2,
                           sh // 2 - surf.get_height() // 2))
        pygame.display.flip()
    except Exception:
        pass
