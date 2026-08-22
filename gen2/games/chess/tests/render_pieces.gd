extends SceneTree

## Developer tool, not a test: renders the whole piece set at three sizes onto
## both square colours and writes user://shots/pieces.png. Needs a display.
##   godot --path games/chess --resolution 700x400 --display-driver x11 \
##         --script res://tests/render_pieces.gd

var _frames := 0

class Sheet extends Control:
	func _draw() -> void:
		var light := Color(0.9255, 0.8863, 0.8118)
		var dark := Color(0.4627, 0.5882, 0.3373)
		var white_fill := Color(0.9843, 0.9765, 0.9569)
		var black_fill := Color(0.1373, 0.1373, 0.1569)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.098, 0.1373, 0.2353))
		var y := 12.0
		for sq: float in [96.0, 56.0, 32.0]:
			for row in 2:
				for i in 6:
					var type := 6 - i
					var r := Rect2(Vector2(12 + i * sq, y + row * sq), Vector2(sq, sq))
					draw_rect(r, light if (i + row) % 2 == 0 else dark)
					var f := white_fill if row == 0 else black_fill
					var e := black_fill if row == 0 else white_fill
					ChessPieces.draw_piece(self, type, r.grow(-sq * 0.06), f, e)
			y += sq * 2 + 10

func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DirAccess.make_dir_recursive_absolute("user://shots")
	var s := Sheet.new()
	s.size = Vector2(700, 400)
	root.add_child(s)

func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 4:
		return false
	root.get_texture().get_image().save_png("user://shots/pieces.png")
	print("saved ", ProjectSettings.globalize_path("user://shots/pieces.png"))
	return true
