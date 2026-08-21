extends SceneTree

## Interactive test: drives the REAL game with real input events.
##
##   godot --path games/dominoes --resolution 1000x760 --script res://tests/interactive.gd
##
## Deliberately NOT part of `make test-all`, which is headless — this needs a
## display. It covers the half tests/run.gd cannot reach: that a tap on the
## tray, a turn, and a tap on the board actually arrive through _gui_input and
## move the puzzle.
var _n := 0
var _g: Node
var _fail := 0
func _initialize() -> void:
	_g = load("res://src/main.tscn").instantiate()
	root.add_child(_g)
func _ck(label: String, got, want) -> void:
	var ok := str(got) == str(want)
	if not ok: _fail += 1
	print(("PASS  " if ok else "FAIL  ") + label + ("" if ok else "  got=%s want=%s" % [got, want]))
func _key(code: Key) -> void:
	for down in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code; e.physical_keycode = code; e.pressed = down
		Input.parse_input_event(e)
	Input.flush_buffered_events()
## Input.parse_input_event takes WINDOW coordinates, but a Control's
## global_position is in the logical viewport — and under this project's
## canvas_items stretch the two differ (1280-wide viewport in a smaller
## window). Without the final transform the clicks land off-screen.
func _click(ctrl: Control, at: Vector2) -> void:
	var to_window := root.get_final_transform()
	for down in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT; e.pressed = down
		e.position = to_window * (ctrl.global_position + at)
		Input.parse_input_event(e)
	Input.flush_buffered_events()
func _process(_d: float) -> bool:
	_n += 1
	match _n:
		6:
			var p = _g._puzzle
			_ck("a puzzle loaded with a full tray", p.tray.size() * 2, p.cell_count())
			_ck("nothing placed yet", p.placed.size(), 0)
			# tap the first tray bone
			_click(_g._tray, (_g._tray._rects[0] as Rect2).get_center())
		10:
			_ck("tapping the tray picks a bone up", _g._held, 0)
			_ck("facing starts to the right", _g._facing, 0)
			_key(KEY_R)
		14:
			_ck("R turns it", _g._facing, 1)
			_key(KEY_R); _key(KEY_R); _key(KEY_R)
		18:
			_ck("four turns come back round", _g._facing, 0)
			# place on the board at the cursor
			var b = _g._board
			_click(b, b.rect_of(b.cursor).get_center())
		22:
			var p = _g._puzzle
			_ck("clicking the board places it", p.placed.size(), 2)
			_ck("and the tray shrinks", p.tray.size() * 2 + 2, p.cell_count())
			# clicking a placed domino takes it back
			var b = _g._board
			_click(b, b.rect_of(b.cursor).get_center())
		26:
			_ck("clicking a placed domino takes it back", _g._puzzle.placed.size(), 0)
			_ck("and it returns to the tray",
				_g._puzzle.tray.size() * 2, _g._puzzle.cell_count())
			print("")
			print("live: %s" % ("all passed" if _fail == 0 else "%d FAILED" % _fail))
			return true
	return _n > 120
