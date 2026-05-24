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
