class_name ChessPieceArt
extends RefCounted

## Where the pieces come from, and how they get onto the board.
##
## Three sources, in order:
##   1. `user://pieces/*.svg`  — the player's own set, editable WITHOUT a
##      rebuild. On Linux that is
##      ~/.local/share/godot/app_userdata/Chess/pieces/.
##   2. `res://assets/pieces/*.svg` — a set shipped inside the game, if one is
##      ever added. Nothing ships there today.
##   3. the built-in drawn set in src/pieces.gd.
##
## Resolution is PER PIECE, not per set: replacing only wN.svg gives you your
## knight and the built-in everything else. A set that is half finished is a
## normal state to be in while drawing one.
##
## Filenames are the universal convention — wK, wQ, wR, wB, wN, wP and the b*
## equivalents — so any standard set drops in unrenamed.

const USER_DIR: String = "user://pieces"
const RES_DIR: String = "res://assets/pieces"

## Rasterisation sizes. An SVG has no pixels until something asks for some, and
## asking again on every resize would re-rasterise twelve files for a
## one-pixel change. Buckets mean it happens a handful of times ever.
const BUCKETS: Array[int] = [48, 64, 96, 128, 192, 256, 384]

var source: String = "built-in"

var _svg: Dictionary = {}        ## key -> svg source text
var _textures: Dictionary = {}   ## key -> ImageTexture at _bucket
var _bucket: int = 0


static func key_of(piece: int) -> String:
	return ChessPieces.file_name(absi(piece), piece > 0)


func load_set(user_dir: String = USER_DIR, res_dir: String = RES_DIR) -> void:
	## Reads whatever SVG files exist. Cheap and safe to call again; a file
	## that fails to parse is skipped rather than fatal, because the fallback
	## is a working piece and a broken game is not.
	_svg.clear()
	_textures.clear()
	_bucket = 0
	var found_user: int = _read_dir(user_dir)
	var found_res: int = 0
	if found_user == 0:
		found_res = _read_dir(res_dir)
	if found_user > 0:
		source = "%s (%d of 12)" % [user_dir, found_user]
	elif found_res > 0:
		source = "%s (%d of 12)" % [res_dir, found_res]
	else:
		source = "built-in"


func _read_dir(path: String) -> int:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return 0
	var count: int = 0
	for type: int in [ChessPieces.KING, ChessPieces.QUEEN, ChessPieces.ROOK,
			ChessPieces.BISHOP, ChessPieces.KNIGHT, ChessPieces.PAWN]:
		for white: bool in [true, false]:
			var name: String = ChessPieces.file_name(type, white)
			var full: String = path.path_join(name)
			if not FileAccess.file_exists(full):
				continue
			var f: FileAccess = FileAccess.open(full, FileAccess.READ)
			if f == null:
				continue
			var text: String = f.get_as_text()
			f.close()
			if text.strip_edges() == "":
				continue
			_svg[name] = text
			count += 1
	return count


func set_square_size(px: float) -> void:
	## Picks a raster size at or above the size actually drawn, so a piece is
	## downscaled rather than up — upscaling a rasterised SVG is the one thing
	## that would look worse than not using SVGs at all.
	if _svg.is_empty():
		return
	var want: int = BUCKETS[BUCKETS.size() - 1]
	for b: int in BUCKETS:
		if float(b) >= px:
			want = b
			break
	if want == _bucket:
		return
	_bucket = want
	_textures.clear()


func draw(ci: CanvasItem, piece: int, rect: Rect2, fill: Color, edge: Color) -> void:
	var name: String = key_of(piece)
	if _svg.has(name):
		var tex: Texture2D = _texture(name)
		if tex != null:
			# Aspect is preserved and the piece is centred: a replacement drawn
			# on a different canvas shape must not be stretched to fit.
			var ts: Vector2 = tex.get_size()
			var s: float = minf(rect.size.x / ts.x, rect.size.y / ts.y)
			var out := Rect2(rect.position + (rect.size - ts * s) * 0.5, ts * s)
			ci.draw_texture_rect(tex, out, false)
			return
	ChessPieces.draw_piece(ci, absi(piece), rect, fill, edge)


func _texture(name: String) -> Texture2D:
	if _textures.has(name):
		return _textures[name]
	if _bucket <= 0:
		_bucket = BUCKETS[BUCKETS.size() - 2]
	var img := Image.new()
	# The scale multiplies the file's OWN intrinsic size, so it has to be read
	# first — the same trap that made the boot splash blend a quarter of a
	# 512px icon into its canvas.
	if img.load_svg_from_string(_svg[name], 1.0) != OK:
		_svg.erase(name)
		return null
	var natural: float = float(maxi(img.get_width(), img.get_height()))
	if natural <= 0.0 or img.load_svg_from_string(_svg[name], _bucket / natural) != OK:
		_svg.erase(name)
		return null
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_textures[name] = tex
	return tex


# ---------------------------------------------------------------- exporting

static func dump_builtin(path: String = USER_DIR) -> String:
	## Writes the built-in set out as twelve editable SVG files plus a note
	## saying what they are. Returns the absolute directory, or "" on failure.
	##
	## This is deliberately NOT done automatically on first run: the files
	## would then shadow the built-in art forever, and a later improvement to
	## the drawn set would never reach anyone who had launched the game once.
	if DirAccess.make_dir_recursive_absolute(path) != OK:
		return ""
	for type: int in [ChessPieces.KING, ChessPieces.QUEEN, ChessPieces.ROOK,
			ChessPieces.BISHOP, ChessPieces.KNIGHT, ChessPieces.PAWN]:
		for white: bool in [true, false]:
			var name: String = ChessPieces.file_name(type, white)
			var f: FileAccess = FileAccess.open(path.path_join(name), FileAccess.WRITE)
			if f == null:
				return ""
			f.store_string(ChessPieces.to_svg(type, white))
			f.close()
	var readme: FileAccess = FileAccess.open(path.path_join("README.txt"), FileAccess.WRITE)
	if readme != null:
		readme.store_string(README)
		readme.close()
	return ProjectSettings.globalize_path(path)


const README: String = """qGames Chess — piece set
========================

These twelve SVG files are the pieces. Edit them in any vector editor and
restart the game; there is nothing to rebuild and nothing to install.

  wK wQ wR wB wN wP   white king, queen, rook, bishop, knight, pawn
  bK bQ bR bB bN bP   the same in black

Delete a file and that piece falls back to the one drawn in code, so you can
replace them one at a time. Delete all of them and you get the built-in set
back. Re-run with --dump-pieces to start over from the built-in artwork.

The viewBox is the box the built-in art occupies. Anything you draw is fitted
to the square with its aspect preserved and centred, so a different canvas
shape is safe — it will not be stretched.

These names are the convention every chess program uses, so a set downloaded
from elsewhere can be dropped in here unrenamed.
"""
