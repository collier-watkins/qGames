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
    exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || usage

NAME="$1"
DISPLAY_NAME="${2:-$NAME}"

if [[ ! "$NAME" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "error: <name> must match ^[a-z][a-z0-9_]*\$ (got '$NAME')" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT_DIR/games/memory"
DEST="$ROOT_DIR/games/$NAME"

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

# export_presets.cfg: copy the template, rewrite "memory" path segments
# (export_path=".../dist/memory/memory.*") to the new game slug. $NAME is
# validated above to [a-z0-9_], so no sed-metacharacter escaping is needed.
if [ -f "$TEMPLATE/export_presets.cfg" ]; then
    sed "s/\bmemory\b/$NAME/g" "$TEMPLATE/export_presets.cfg" > "$DEST/export_presets.cfg"
else
    echo "warning: games/memory/export_presets.cfg not found — skipped, add export presets manually" >&2
fi

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
echo "  src/main.gd           stub, extends QGameRoot"
echo "  tests/run.gd          stub, exits 0 — add real assertions"
echo "  addons/qcore -> ../../../shared/qcore"
echo
echo "Next:"
echo "  make import GAME=$NAME"
echo "  make run    GAME=$NAME"
