extends SceneTree

## Developer tool, not a test: draws the Why-check aid over sixteen positions
## two to a page and writes user://shots/checks_<n>.png, with the panel's words
## printed beside each case. Needs a display.
##   godot --path games/chess --resolution 1024x512 --script res://tests/gallery_checks.gd

const B := preload("res://src/board.gd")
const CELL := 512.0

## [label, fen, last move "e2e4" or "", mate show time or -1, pointed-at square (optional)]
const CASES: Array = [
	["rook check, open", "4k3/8/8/8/8/8/3PP3/r3K3 w - - 0 1", "a8a1", -1.0],
	["bishop check, b4", "4k3/8/8/8/1b6/P7/8/1N2K3 w - - 0 1", "f8b4", -1.0],
	["knight check", "4k3/8/8/8/8/3n4/4PP2/4KB2 w - - 0 1", "b4d3", -1.0],
	["double check", "4k3/8/8/8/1b6/5n2/8/4K3 w - - 0 1", "d2f3", -1.0],
	["queen next to king", "4k3/8/8/8/8/8/4q3/4K3 w - - 0 1", "e7e2", -1.0],
	["opening Bb5+ (them)", "rnbqkbnr/ppp1pppp/3p4/1B6/4P3/8/PPPP1PPP/RNBQK1NR b KQkq - 1 2", "f1b5", -1.0],
	["middlegame check", "r1b2rk1/pp3ppp/2n5/3q4/1b1P4/5N2/PP3PPP/RNBQKB1R w KQ - 0 1", "e7b4", -1.0],
	["queen check, many", "r3k2r/ppp2ppp/2n5/8/8/2N5/PPPq1PPP/R2QKB1R w KQkq - 0 1", "d8d2", -1.0],
	["middlegame, point Nf3", "r1b2rk1/pp3ppp/2n5/3q4/1b1P4/5N2/PP3PPP/RNBQKB1R w KQ - 0 1", "e7b4", -1.0, "f3"],
	["middlegame, point king", "r1b2rk1/pp3ppp/2n5/3q4/1b1P4/5N2/PP3PPP/RNBQKB1R w KQ - 0 1", "e7b4", -1.0, "e1"],
	["back rank mate", "R5k1/5ppp/8/8/8/8/8/6K1 b - - 0 1", "a1a8", -1.0],
	["smothered mate", "6rk/5Npp/8/8/8/8/8/6K1 b - - 0 1", "e5f7", -1.0],
	["Qg7 mate, bishop", "6k1/6Q1/5B2/8/8/8/8/6K1 b - - 0 1", "g3g7", -1.0],
	["scholar's mate", "r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4", "h5f7", -1.0],
	["ladder mate", "R5k1/1R6/8/8/8/8/8/6K1 b - - 0 1", "a1a8", -1.0],
	["queen mate, king help", "3k4/3Q4/3K4/8/8/8/8/8 b - - 0 1", "d1d7", -1.0],
	["mate show 1.0s", "R5k1/5ppp/8/8/8/8/8/6K1 b - - 0 1", "a1a8", 1.0],
	["mate show 2.4s", "R5k1/5ppp/8/8/8/8/8/6K1 b - - 0 1", "a1a8", 2.4],
]

var _frames := 0
var _page := 0
var _views: Array = []


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DirAccess.make_dir_recursive_absolute("user://shots")
	_build_page()


func _build_page() -> void:
	for v: Node in _views:
		v.queue_free()
	_views.clear()
	var per: int = 2
	for i in per:
		var idx: int = _page * per + i
		if idx >= CASES.size():
			break
		var c: Array = CASES[idx]
		var b := ChessBoard.new()
		b.set_fen(c[1])
		var v := ChessBoardView.new()
		v.position = Vector2(i * CELL, 0)
		v.size = Vector2(CELL, CELL)
		v.show_coords = false
		root.add_child(v)
		_views.append(v)
		var mv: String = c[2]
		var f: int = B.square_from_name(mv.substr(0, 2)) if mv != "" else -1
		var t: int = B.square_from_name(mv.substr(2, 2)) if mv != "" else -1
		v.show_position(b, f, t)
		v.set_training(B.BLACK, B.WHITE, true, B.WHITE, true)
		if c.size() > 4:
			v.set_inspect(B.square_from_name(c[4]))
		if float(c[3]) >= 0.0:
			v.celebrate_mate(true)
			v._mate_t = float(c[3])
			if float(c[3]) > ChessBoardView.MATE_TOPPLE_AT:
				v._spawn_confetti()
				for k in 20:
					v._step_confetti(0.03)
			v.set_process(false)
		print("[%d] %s\n    %s\n" % [idx, c[0], v._explained])


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 4:
		return false
	root.get_texture().get_image().save_png("user://shots/checks_%d.png" % _page)
	_page += 1
	if _page * 2 >= CASES.size():
		return true
	_frames = 0
	_build_page()
	return false
