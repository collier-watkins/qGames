import ctypes
import ctypes.util
import os
import sys

_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


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
