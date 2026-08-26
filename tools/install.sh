#!/usr/bin/env bash
# Install qGames for the current user. No sudo, no package manager, no runtime
# dependencies to fetch — each game is one self-contained executable.
#
#   ./install.sh                 install every game found beside this script
#   ./install.sh notes memory    install just those
#   ./install.sh --uninstall     remove everything this script installed
#   ./install.sh --list          show what is available and what is installed
#
# Everything lands under $HOME, in the XDG locations a desktop already watches:
#
#   ~/.local/share/qgames/<id>/<id>      the executable
#   ~/.local/bin/qgames-<id>             a launcher on PATH
#   ~/.local/share/applications/...      the menu entry
#   ~/.local/share/icons/hicolor/...     the icon
#
# WHY StartupWMClass: it is how a running window gets matched back to the
# launcher that owns it, and without it the taskbar shows a generic placeholder
# instead of the game's icon while the game is open. The value must be the
# Wayland app_id, and Godot sets that to `application/config/name` VERBATIM —
# measured, not assumed: `WAYLAND_DEBUG=1` on the Pi shows
# `xdg_toplevel.set_app_id("Chess")`. That is exactly the `name` in meta, capital
# letter, space in "Memory Match" and all, which is why this uses $name and not
# $id.
#
# WHY NO WRAPPER SCRIPT: the broker settings are baked into the executable at
# build time (tools/bake_config.sh), so the game needs no environment. That
# matters because a .desktop launcher does NOT inherit your shell environment —
# a game started from the menu would otherwise reach no broker and publish
# nothing, which looks identical to everything working.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/share/qgames"
APP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"

# ── which binary does this machine need ─────────────────────────────────────
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)          echo x86_64 ;;
        aarch64|arm64)         echo arm64 ;;
        armv7l|armv6l|armhf)   echo arm32 ;;
        i686|i386)             echo x86_32 ;;
        *)                     echo "" ;;
    esac
}

# Games are whatever directories sit beside this script with a meta file, so a
# dist/ with two games installs two games and nothing needs a list kept in sync.
available() {
    local d
    for d in "$HERE"/*/meta; do
        [[ -e "$d" ]] || continue
        basename "$(dirname "$d")"
    done
}

meta_get() { sed -n "s/^$2=//p" "$HERE/$1/meta"; }

uninstall_all() {
    local removed=0 id
    for id in $(available); do
        rm -rf "${LIB_DIR:?}/$id" && :
        rm -f "$BIN_DIR/qgames-$id" "$APP_DIR/qgames-$id.desktop" \
              "$ICON_DIR/qgames-$id.svg"
        removed=1
    done
    # Also sweep anything installed by an older dist that this one lacks.
    rm -f "$BIN_DIR"/qgames-* "$APP_DIR"/qgames-*.desktop "$ICON_DIR"/qgames-*.svg 2>/dev/null || true
    rmdir "$LIB_DIR" 2>/dev/null || true
    [[ $removed -eq 1 ]] && echo "removed qGames from $HOME" || echo "nothing to remove"
    refresh_desktop
    echo "NOTE: saved notes and settings were left alone, in"
    echo "      ~/.local/share/godot/app_userdata/"
}

refresh_desktop() {
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
        && gtk-update-icon-cache -qtf "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
}

case "${1:-}" in
    --uninstall) uninstall_all; exit 0 ;;
    --list)
        echo "arch: $(uname -m) -> $(detect_arch)"
        for id in $(available); do
            printf '  %-10s %-16s %s\n' "$id" "$(meta_get "$id" name)" \
                "$([[ -x "$LIB_DIR/$id/$id" ]] && echo installed || echo -)"
        done
        exit 0 ;;
esac

ARCH="$(detect_arch)"
if [[ -z "$ARCH" ]]; then
    echo "error: unsupported CPU architecture '$(uname -m)'." >&2
    echo "       Builds exist for x86_64, arm64, x86_32 and arm32." >&2
    exit 1
fi

TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    mapfile -t TARGETS < <(available)
fi
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "error: no games found beside $0 — is this a built dist/ directory?" >&2
    exit 1
fi

# Validate every name before installing any, so a typo cannot leave a half-done
# install behind.
for id in "${TARGETS[@]}"; do
    if [[ ! -f "$HERE/$id/meta" ]]; then
        echo "error: unknown game '$id'. Available: $(available | tr '\n' ' ')" >&2
        exit 1
    fi
    if [[ ! -f "$HERE/$id/$id-$ARCH" ]]; then
        echo "error: '$id' has no $ARCH build in this dist." >&2
        echo "       Present: $(ls "$HERE/$id" | grep "^$id-" | sed "s/^$id-//" | tr '\n' ' ')" >&2
        exit 1
    fi
done

mkdir -p "$BIN_DIR" "$LIB_DIR" "$APP_DIR" "$ICON_DIR"

for id in "${TARGETS[@]}"; do
    name="$(meta_get "$id" name)"
    version="$(meta_get "$id" version)"

    mkdir -p "$LIB_DIR/$id"
    install -m 755 "$HERE/$id/$id-$ARCH" "$LIB_DIR/$id/$id"
    [[ -f "$HERE/$id/icon.svg" ]] && install -m 644 "$HERE/$id/icon.svg" "$ICON_DIR/qgames-$id.svg"

    ln -sf "$LIB_DIR/$id/$id" "$BIN_DIR/qgames-$id"

    cat > "$APP_DIR/qgames-$id.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=$name
Comment=qGames — $name ($version)
Exec=$LIB_DIR/$id/$id
Icon=qgames-$id
Terminal=false
Categories=Game;
StartupNotify=true
StartupWMClass=$name
DESKTOP
    chmod 644 "$APP_DIR/qgames-$id.desktop"
    echo "installed $name  ($id, $ARCH, $version)"
done

refresh_desktop

echo ""
echo "Launchers are in your applications menu. From a terminal:"
for id in "${TARGETS[@]}"; do echo "  qgames-$id"; done
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo ""
       echo "NOTE: $BIN_DIR is not on your PATH, so the terminal commands above"
       echo "      will not resolve until you add it. The menu entries work regardless." ;;
esac
