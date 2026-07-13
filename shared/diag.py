"""Opt-in resource diagnostic — helps pin down slow leaks over long uptimes.

Disabled by default and completely free unless the QGAMES_DIAG environment
variable is set. When enabled, a daemon thread appends a line every 30 s with
the process's resident memory, open file-descriptor count, and thread count:

    QGAMES_DIAG=1 ./run.sh paint

Leave the game open for a few hours/days, then inspect the log — a climbing
RSS points at a memory leak, a climbing FD/thread count at a socket/thread
leak (e.g. a stuck network publish), and flat numbers rule the app out.

Log path: $QGAMES_DIAG_LOG, or ~/.cache/qgames/diag-<game>.log by default.
No third-party dependencies — reads /proc, which is always present on the Pi.
"""
import os
import threading
import time

_INTERVAL = 30.0  # seconds between samples
_PAGE = os.sysconf("SC_PAGE_SIZE") if hasattr(os, "sysconf") else 4096


def _rss_bytes() -> int:
    # /proc/self/statm field 2 is resident set size in pages.
    with open("/proc/self/statm") as f:
        return int(f.read().split()[1]) * _PAGE


def _fd_count() -> int:
    return len(os.listdir("/proc/self/fd"))


def _sample_line() -> str:
    rss_mb = _rss_bytes() / (1024 * 1024)
    return (f"{time.strftime('%Y-%m-%d %H:%M:%S')}  "
            f"rss={rss_mb:8.1f}MB  fds={_fd_count():4d}  "
            f"threads={threading.active_count():3d}")


def maybe_start(game_name: str) -> None:
    """Start the diagnostic logger iff QGAMES_DIAG is set. Safe no-op otherwise."""
    if not os.environ.get("QGAMES_DIAG"):
        return

    log_path = os.environ.get("QGAMES_DIAG_LOG")
    if not log_path:
        folder = os.path.expanduser("~/.cache/qgames")
        os.makedirs(folder, exist_ok=True)
        log_path = os.path.join(folder, f"diag-{game_name}.log")

    def _loop():
        try:
            with open(log_path, "a", buffering=1) as f:
                f.write(f"# diag start: {game_name} pid={os.getpid()}\n")
                while True:
                    try:
                        f.write(_sample_line() + "\n")
                    except Exception:
                        pass
                    time.sleep(_INTERVAL)
        except Exception:
            pass  # never let diagnostics affect the game

    threading.Thread(target=_loop, daemon=True).start()
