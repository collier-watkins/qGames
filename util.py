import os
import sys


def resource_path(relative: str) -> str:
    """Return absolute path to a bundled asset, works for dev and PyInstaller."""
    if hasattr(sys, "_MEIPASS"):
        return os.path.join(sys._MEIPASS, relative)
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), relative)
