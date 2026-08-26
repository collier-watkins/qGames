#!/usr/bin/env bash
# Build on this machine for whatever the target actually is, copy it there, and
# install it. One command, no toolchain on the target.
#
#   tools/deploy.sh pi@raspberrypi.local
#   tools/deploy.sh pi@192.168.1.50 notes          just one game
#   tools/deploy.sh pi@host --dry-run              show the plan, change nothing
#
# The target needs only ssh and a shell. It does NOT need Godot, a compiler, or
# any runtime package: Godot ships prebuilt export templates for every
# architecture, so an ARM binary is produced here on x86_64 with no
# cross-compiler involved.
#
# The architecture is READ FROM THE TARGET rather than guessed, because getting
# it wrong is the single most likely way this fails: Raspberry Pi OS still ships
# a 32-bit image, and an arm64 binary on it does not run at all.
#
# SSH and RSYNC are overridable so this can be exercised without a real target.
set -euo pipefail
cd "$(dirname "$0")/.."

SSH="${QGAMES_SSH:-ssh}"
RSYNC="${QGAMES_RSYNC:-rsync}"
REMOTE_DIR="${QGAMES_REMOTE_DIR:-qgames-dist}"

TARGET="${1:-}"
if [[ -z "$TARGET" || "$TARGET" == -* ]]; then
    echo "usage: $(basename "$0") <user@host> [game...] [--dry-run]" >&2
    exit 1
fi
shift

DRY=0
GAMES=()
for a in "$@"; do
    if [[ "$a" == "--dry-run" ]]; then DRY=1; else GAMES+=("$a"); fi
done

# ── what is on the other end ────────────────────────────────────────────────
echo "== asking $TARGET what it is"
UNAME="$($SSH "$TARGET" 'uname -m' 2>/dev/null || true)"
if [[ -z "$UNAME" ]]; then
    echo "error: could not reach $TARGET over ssh." >&2
    echo "       Check the host, and that key-based login works: ssh $TARGET true" >&2
    exit 1
fi

case "$UNAME" in
    x86_64|amd64)        ARCH=x86_64 ;;
    aarch64|arm64)       ARCH=arm64 ;;
    armv7l|armv6l|armhf) ARCH=arm32 ;;
    i686|i386)           ARCH=x86_32 ;;
    *) echo "error: target reports '$UNAME', which has no build here." >&2; exit 1 ;;
esac
echo "   $UNAME -> building $ARCH only"

if [[ $DRY -eq 1 ]]; then
    echo ""
    echo "would run:"
    echo "  make dist ARCHES=\"$ARCH\""
    echo "  copy dist/ -> $TARGET:~/$REMOTE_DIR/"
    echo "  $SSH $TARGET '~/$REMOTE_DIR/install.sh ${GAMES[*]}'"
    exit 0
fi

# ── build just that architecture ────────────────────────────────────────────
make dist ARCHES="$ARCH"

# ── copy ────────────────────────────────────────────────────────────────────
echo "== copying to $TARGET:~/$REMOTE_DIR"
$SSH "$TARGET" "mkdir -p '$REMOTE_DIR'"
if command -v "$RSYNC" >/dev/null 2>&1 && $SSH "$TARGET" 'command -v rsync' >/dev/null 2>&1; then
    # --delete so a game removed from dist/ does not linger on the target and
    # get reinstalled by a later bare install.sh run.
    $RSYNC -a --delete --info=progress2 -e "$SSH" dist/ "$TARGET:$REMOTE_DIR/"
else
    echo "   (rsync unavailable on one end — streaming a tar instead)"
    tar -C dist -cz . | $SSH "$TARGET" "tar -C '$REMOTE_DIR' -xz"
fi

# ── install ─────────────────────────────────────────────────────────────────
echo "== installing on $TARGET"
$SSH "$TARGET" "chmod +x '$REMOTE_DIR/install.sh' && '$REMOTE_DIR/install.sh' ${GAMES[*]:-}"

echo ""
echo "done — $TARGET has $(cat dist/VERSION)"
echo "to remove later:  $SSH $TARGET '~/$REMOTE_DIR/install.sh --uninstall'"
