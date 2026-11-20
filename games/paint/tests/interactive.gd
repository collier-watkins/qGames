extends SceneTree

## Interactive test: drives the REAL game with real input events. Needs a
## display, so it is not part of the headless `make test`.
##
##   godot --path games/paint --resolution 1280x720 --script res://tests/interactive.gd
##
## Screenshots go to user://shots. It writes the real user://config.cfg (custom
## colours) and puts the player's own list back when it ends.

const SHOT_DIR := "user://shots"
const CUSTOM_KEY := "paint/custom_colours"

var _game: Control
var _view: Control
var _fail := 0
var _frame := 0
var _steps: Array = []
var _step := 0
var _wait_until_ms := 0
var _saved_custom: Variant = null
var _p: Vector2 = Vector2.ZERO


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_game = load("res://src/main.tscn").instantiate()
	root.add_child(_game)
	_steps = [
		_stage_toolbar,
		_stage_square_pick,
		_stage_square_drawn,
		_stage_picker_open,
		_stage_picker_added,
		_stage_mouse_on_paper,
		_stage_keys_take_over,
		_stage_keys_drew,
		_stage_mouse_back,
		_stage_done,
	]


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 4:
		return false
	if Time.get_ticks_msec() < _wait_until_ms:
		return false
	if _step >= _steps.size():
		return true
	var fn: Callable = _steps[_step]
	_step += 1
	return bool(fn.call())


func _wait(ms: int) -> void:
	_wait_until_ms = Time.get_ticks_msec() + ms


func _ck(label: String, got: Variant, want: Variant) -> void:
	var ok: bool = str(got) == str(want)
	if not ok:
		_fail += 1
	print(("PASS  " if ok else "FAIL  ") + label + ("" if ok
			else "   got=%s want=%s" % [str(got), str(want)]))


func _ck_true(label: String, ok: bool) -> void:
	_ck(label, ok, true)


func _shot(name: String) -> void:
	root.get_texture().get_image().save_png("%s/%s.png" % [SHOT_DIR, name])


func _window(pos: Vector2) -> Vector2:
	return get_root().get_screen_transform() * pos


func _click(pos: Vector2) -> void:
	pos = _window(pos)
	for down: bool in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = down
		e.position = pos
		e.global_position = pos
		Input.parse_input_event(e)


func _move(pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = _window(pos)
	e.global_position = e.position
	e.relative = Vector2(3, 2)
	Input.parse_input_event(e)


func _key(code: Key) -> void:
	for down: bool in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = down
		Input.parse_input_event(e)


func _centre(c: Control) -> Vector2:
	return c.get_global_rect().get_center()


func _paper_at(px: Vector2i) -> Vector2:
	## Viewport position of canvas pixel px's middle.
	var off: Vector2 = _view.get("_offset")
	var sc: float = _view.get("_scale")
	return _view.get_global_rect().position + off + (Vector2(px) + Vector2(0.5, 0.5)) * sc


func _pixel(px: Vector2i) -> Color:
	return (_game.get("_canvas").image as Image).get_pixelv(px)


func _stage_toolbar() -> bool:
	_view = _game.get("_view")
	_saved_custom = root.get_node("QConfig").get_value(CUSTOM_KEY, PackedStringArray())
	var bar: Control = _game.get("_bar")
	var clear_b: Button = null
	var save_b: Button = null
	for c in bar.find_children("*", "Button", true, false):
		if c is Button and (c as Button).text == "Clear":
			clear_b = c
		if c is Button and (c as Button).text == "Save":
			save_b = c
	_ck_true("Clear carries its X", clear_b != null and clear_b.icon != null)
	_ck_true("Save carries its floppy disk", save_b != null and save_b.icon != null)
	# One line at the design size: every bar child on the first row.
	var top: float = bar.get_child(0).position.y
	var one_line := true
	for c in bar.get_children():
		if (c as Control).position.y > top + 40.0:
			one_line = false
	_ck_true("the toolbar fits one line at 1024 wide", one_line)
	_ck("eight size buttons, four round and four square", (_game.get("_size_buttons") as Array).size(), 8)
	_shot("p1_toolbar")
	_wait(200)
	return false


func _stage_square_pick() -> bool:
	var sizes: Array = _game.get("_size_buttons")
	_click(_centre(sizes[7]))  # the largest square
	_wait(250)
	return false


func _stage_square_drawn() -> bool:
	_ck_true("a square size button makes the brush square", bool(_game.get("_square_brush")))
	_ck("...at its size", _game.call("brush_radius"), 34)
	_game.set("_colour_index", 3)  # red
	var at := Vector2i(200, 200)
	_click(_paper_at(at))
	_wait(250)
	return false


func _stage_picker_open() -> bool:
	# Corner of the square dab (+30,+30 from its centre) is painted; a round
	# dab of the same size would leave it white.
	_ck_true("a square brush paints into its corners", _pixel(Vector2i(230, 230)).r > 0.8
			and _pixel(Vector2i(230, 230)).g < 0.3)
	_click(_centre(_game.get("_add_colour")))
	_wait(300)
	return false


func _stage_picker_added() -> bool:
	var popup: PopupPanel = _game.get("_picker_popup")
	_ck_true("+ opens the colour picker", popup.visible)
	(_game.get("_picker") as ColorPicker).color = Color8(18, 200, 160)
	_shot("p2_picker")
	var before: int = (_game.get("_custom") as Array).size()
	_game.call("_on_add_colour")
	_ck("Add colour adds a slot", (_game.get("_custom") as Array).size(), before + 1)
	_ck("...and chooses it", (_game.call("colour") as Color).to_html(false), "12c8a0")
	_ck_true("...and the picker closes", not popup.visible)
	_wait(300)
	return false


func _stage_mouse_on_paper() -> bool:
	_shot("p3_added")
	var swatches: Array = _game.get("_swatches")
	_ck("the toolbar has a swatch for it", (swatches[swatches.size() - 1].get("colour") as Color).to_html(false), "12c8a0")
	_game.call("_choose_size", 1, false)  # small round brush
	_p = _paper_at(Vector2i(600, 400))
	_move(_p)
	_wait(200)
	return false


func _stage_keys_take_over() -> bool:
	_ck_true("the mouse over the paper owns the pointer", bool(_view.get("_pointer_on_paper"))
			and not bool(_view.get("_keys_active")))
	_key(KEY_RIGHT)
	_wait(200)
	return false


func _stage_keys_drew() -> bool:
	var jump: int = maxi(2, int(_game.call("brush_radius")))
	_ck_true("an arrow hands the pointer to the keys", bool(_view.get("_keys_active")))
	_ck("...starting from where the mouse was", _view.get("_cursor"), Vector2i(600 + jump, 400))
	_shot("p4_keys_cursor")
	_key(KEY_SPACE)
	_key(KEY_SPACE)
	_wait(250)
	return false


func _stage_mouse_back() -> bool:
	var jump: int = maxi(2, int(_game.call("brush_radius")))
	_ck("Space paints where the keys' pointer is", _pixel(Vector2i(600 + jump, 400)).to_html(false), "12c8a0")
	_move(_p + Vector2(40, 0))
	_wait(200)
	return false


func _stage_done() -> bool:
	_ck_true("moving the mouse takes the pointer back", not bool(_view.get("_keys_active")))
	root.get_node("QConfig").set_value(CUSTOM_KEY, _saved_custom)
	root.get_node("QConfig").save()
	print("interactive: " + ("all checks passed" if _fail == 0 else "%d FAILED" % _fail))
	return true
