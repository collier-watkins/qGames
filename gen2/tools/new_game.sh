#!/usr/bin/env bash
#
# Scaffold a new game from the games/memory template.
#
# Usage: ./tools/new_game.sh <name> ["Display Name"]
#
#   <name>            lowercase snake_case — becomes games/<name>/ and (via
#                      QCORE_API.md's rule: lowercase, spaces->underscores)
#                      the telemetry game id.
#   "Display Name"    optional — application/config/name in project.godot.
#                      Defaults to <name>.
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <name> [\"Display Name\"]" >&2
    echo "       $(basename "$0") --regen-splash <name>" >&2
    exit 1
}

# --regen-splash <name>: rebuild games/<name>/boot_splash.png from its icon.svg
# without scaffolding anything. Used after hand-editing an icon.
REGEN_ONLY=0
if [[ "${1:-}" == "--regen-splash" ]]; then
    REGEN_ONLY=1
    shift
fi

[[ $# -ge 1 && $# -le 2 ]] || usage

NAME="$1"
DISPLAY_NAME="${2:-$NAME}"

if [[ ! "$NAME" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "error: <name> must match ^[a-z][a-z0-9_]*\$ (got '$NAME')" >&2
    exit 1
fi

# regen_splash <project-dir>: rasterise <dir>/icon.svg into <dir>/boot_splash.png.
# project.godot carries application/boot_splash/* (copied from the template) and
# its image key points at res://boot_splash.png — without that file the game
# boots to a missing splash. The generator is written to a temp .gd and run
# against the target project so it can read bg_color out of ProjectSettings,
# which is what keeps the image's padding and the colour field identical.
#
# Re-run this whenever you change a game's icon.svg:
#   ./tools/new_game.sh --regen-splash <name>
regen_splash() {
    local dir="$1"
    local gen
    gen="$(mktemp /tmp/qgames_splash_XXXXXX.gd)"
    # shellcheck disable=SC2064
    trap "rm -f '$gen'" RETURN
    cat > "$gen" <<'EOF'
extends SceneTree

## Rasterises res://icon.svg into res://boot_splash.png for the project given
## by --path. The icon is drawn at ICON px centred in a CANVAS px square whose
## surround is filled OPAQUE with application/boot_splash/bg_color.
##
## Why the padding: the splash uses stretch_mode=Keep, which fits the image to
## the window's smaller dimension. Padding pins the mark at ICON/CANVAS of the
## screen at any resolution instead of letting it fill edge to edge.
## Why opaque: a transparent pad leaves a visible seam where the icon's
## antialiased edge blends over the background.

const CANVAS := 864
const ICON := 512

func _initialize() -> void:
	var f := FileAccess.open("res://icon.svg", FileAccess.READ)
	if f == null:
		push_error("no res://icon.svg to rasterise")
		quit(1)
		return
	var svg := f.get_as_text()
	f.close()

	var icon := Image.new()
	if icon.load_svg_from_string(svg, float(ICON) / 256.0) != OK:
		push_error("could not rasterise res://icon.svg")
		quit(1)
		return
	icon.convert(Image.FORMAT_RGBA8)

	# Image.fill() TRUNCATES float channels to 8 bits, while the renderer's clear
	# of bg_color rounds — so filling with bg_color verbatim lands one value
	# below the colour actually drawn behind the splash, and the image's edge
	# becomes faintly visible. Quantise by rounding, then nudge half a step up so
	# fill()'s truncation lands back on the value we chose.
	var bg: Color = ProjectSettings.get_setting("application/boot_splash/bg_color")
	var pad := Color(
		(roundf(bg.r * 255.0) + 0.5) / 255.0,
		(roundf(bg.g * 255.0) + 0.5) / 255.0,
		(roundf(bg.b * 255.0) + 0.5) / 255.0,
		1.0,
	)
	var canvas := Image.create_empty(CANVAS, CANVAS, false, Image.FORMAT_RGBA8)
	canvas.fill(pad)
	var o := (CANVAS - ICON) / 2
	canvas.blend_rect(icon, Rect2i(0, 0, ICON, ICON), Vector2i(o, o))

	if canvas.save_png("res://boot_splash.png") != OK:
		push_error("could not write res://boot_splash.png")
		quit(1)
		return
	print("boot_splash.png: %dx%d, icon %dpx, bg #%s" % [CANVAS, CANVAS, ICON, canvas.get_pixel(0, 0).to_html(false)])
	quit(0)
EOF
    if ! command -v godot >/dev/null 2>&1; then
        echo "warning: 'godot' not on PATH — boot_splash.png not generated." >&2
        echo "         Run: ./tools/new_game.sh --regen-splash $(basename "$dir")" >&2
        return 0
    fi
    godot --headless --path "$dir" --script "$gen" >/dev/null 2>&1 \
        || { echo "warning: boot splash generation failed for $dir" >&2; return 0; }
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT_DIR/games/memory"
DEST="$ROOT_DIR/games/$NAME"

if [ "$REGEN_ONLY" = 1 ]; then
    [ -d "$DEST" ] || { echo "error: games/$NAME does not exist" >&2; exit 1; }
    regen_splash "$DEST"
    echo "Regenerated games/$NAME/boot_splash.png from icon.svg"
    exit 0
fi

if [ -e "$DEST" ]; then
    echo "error: games/$NAME already exists — refusing to overwrite" >&2
    exit 1
fi

if [ ! -f "$TEMPLATE/project.godot" ]; then
    echo "error: template games/memory/project.godot not found." >&2
    echo "       new_game.sh scaffolds from games/memory; it must exist first." >&2
    exit 1
fi

mkdir -p "$DEST/src" "$DEST/tests" "$DEST/addons"

# project.godot: copy the template, rename application/config/name AND the
# telemetry game_id. Missing the game_id would point every new game's MQTT
# topics at qGames/memory/ — silently, since nothing validates it.
awk -v name="$DISPLAY_NAME" -v gid="$NAME" '
    /^config\/name=/ { print "config/name=\"" name "\""; next }
    /^game_id=/       { print "game_id=\"" gid "\""; next }
    { print }
' "$TEMPLATE/project.godot" > "$DEST/project.godot"

if ! grep -q "^game_id=" "$DEST/project.godot"; then
    echo "error: games/memory/project.godot has no game_id= line to rewrite." >&2
    echo "       The new game would publish MQTT to the template's topics." >&2
    rm -rf "$DEST"
    exit 1
fi

if ! grep -q '^boot_splash/image=' "$DEST/project.godot"; then
    echo "error: games/memory/project.godot has no boot_splash/image= line." >&2
    echo "       The new game would boot with Godot's own logo on grey." >&2
    rm -rf "$DEST"
    exit 1
fi

# export_presets.cfg: copy the template, rewrite "memory" path segments
# (export_path=".../dist/memory/memory.*") to the new game slug. $NAME is
# validated above to [a-z0-9_], so no sed-metacharacter escaping is needed.
if [ -f "$TEMPLATE/export_presets.cfg" ]; then
    sed "s/\bmemory\b/$NAME/g" "$TEMPLATE/export_presets.cfg" > "$DEST/export_presets.cfg"
else
    echo "warning: games/memory/export_presets.cfg not found — skipped, add export presets manually" >&2
fi

# icon.svg: a deliberately blank placeholder, NOT a copy of the template's.
# Copying games/memory/icon.svg is how games/notes ended up shipping memory's
# card artwork as its own identity. A hollow frame is obviously unset, so it
# gets replaced. config/icon and the boot splash both read this file.
cat > "$DEST/icon.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">
  <rect width="256" height="256" rx="40" fill="#19233c"/>
  <rect x="52" y="52" width="152" height="152" rx="28" fill="none" stroke="#5073c8" stroke-width="8" stroke-dasharray="26 18"/>
  <circle cx="128" cy="128" r="26" fill="#3c4e78"/>
</svg>
EOF

regen_splash "$DEST"

# main.tscn: the root scene is already bare (one Control node + attached
# script) and its script path (res://src/main.gd) is identical for every
# game, so the scene file copies verbatim — no substitution needed.
if [ -f "$TEMPLATE/src/main.tscn" ]; then
    cp "$TEMPLATE/src/main.tscn" "$DEST/src/main.tscn"
else
    echo "warning: games/memory/src/main.tscn not found — skipped, create one manually" >&2
fi

# main.gd: fresh stub, NOT copied — memory's main.gd holds real game logic.
cat > "$DEST/src/main.gd" <<'EOF'
extends QGameRoot

## Entry point for this game.
## See QCORE_API.md for QGameRoot / QConfig / QInput / Telemetry.


func _game_ready() -> void:
	pass
EOF

# tests/run.gd: fresh headless test-runner stub.
cat > "$DEST/tests/run.gd" <<'EOF'
extends SceneTree

## Headless test entry point, run via:
##   godot --headless --path games/<name> --script res://tests/run.gd
## Must call quit(0) on success and quit(1) (or any nonzero code) on failure.


func _initialize() -> void:
	print("run.gd: no tests defined yet")
	quit(0)
EOF

# addons/qcore: relative symlink to the shared addon — survives clone.
ln -s ../../../shared/qcore "$DEST/addons/qcore"

echo "Created games/$NAME/:"
echo "  project.godot        config/name = \"$DISPLAY_NAME\", telemetry game_id = \"$NAME\""
[ -f "$DEST/export_presets.cfg" ] && echo "  export_presets.cfg   paths rewritten to dist/$NAME/..."
[ -f "$DEST/src/main.tscn" ]      && echo "  src/main.tscn        copied from games/memory"
echo "  icon.svg              placeholder mark — REPLACE THIS"
[ -f "$DEST/boot_splash.png" ] && echo "  boot_splash.png       864x864, generated from icon.svg"
echo "  src/main.gd           stub, extends QGameRoot"
echo "  tests/run.gd          stub, exits 0 — add real assertions"
echo "  addons/qcore -> ../../../shared/qcore"
echo
echo "Next:"
echo "  make import GAME=$NAME"
echo "  make run    GAME=$NAME"
echo
echo "After editing games/$NAME/icon.svg, also update the boot splash:"
echo "  edit games/$NAME/project.godot -> application/boot_splash/bg_color"
echo "  ./tools/new_game.sh --regen-splash $NAME"
