extends SceneTree

## Interactive test: drives the REAL game with real input events.
##
##   godot --path games/chess --resolution 1280x720 --script res://tests/interactive.gd
##
## Deliberately NOT part of `make test-all`, which is headless — this one needs
## a display and a GPU. tests/run.gd calls the model directly; this pushes
## clicks and keys through the viewport into _gui_input, the panel buttons and
## the opponent thread, and it is the only thing that would notice if the board
## stopped accepting a tap at all.
##
## Screenshots go to user://shots. Under Wayland an external x11grab returns
## black, but the viewport texture is always correct — the same finding that
## made this the house pattern for looking at a layout.

const SHOT_DIR := "user://shots"

var _game: Node
var _view: Control
var _board: Control
var _fail := 0
var _frame := 0
var _steps: Array = []
var _step := 0
var _wait_until_ms := 0


func _initialize() -> void:
	# Vsync off, and this is not a nicety. Under XWayland with nothing actually
	# on screen the buffer swap blocks for about a second, which turns the
	# whole run into one frame per second and every wait into a hang. With it
	# off the same run measures over a thousand frames a second.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_game = load("res://src/main.tscn").instantiate()
	root.add_child(_game)
	_view = _game as Control
	# One action per stage, with a wait between: a screenshot taken in the
	# same frame as the click that caused it shows the PREVIOUS frame, which is
	# how the first version of this test produced a "selected" shot with
	# nothing selected in it.
	_steps = [
		_stage_setup,
		_stage_scroll_to_start,
		_stage_start,
		_stage_board,
		_stage_selected,
		_stage_midslide,
		_stage_played,
		_stage_keyboard,
		_stage_keyboard_played,
		_stage_sound,
		_stage_review,
		_stage_live,
		_stage_promotion_setup,
		_stage_promotion_shown,
		_stage_promotion_done,
		_stage_resign,
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


func _click(pos: Vector2) -> void:
	## A real press and release through the viewport, which is the only path
	## that proves the board is reachable by a finger.
	##
	## `pos` is in VIEWPORT space, where the controls live; Input wants WINDOW
	## pixels. The two are the same only when the stretch scale happens to be
	## 1:1 — at 1280x720 they coincided and the conversion looked unnecessary,
	## and every click missed the moment the window was made portrait.
	pos = get_root().get_screen_transform() * pos
	for down: bool in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = down
		e.position = pos
		e.global_position = pos
		Input.parse_input_event(e)
	Input.flush_buffered_events()


func _key(code: Key) -> void:
	for down: bool in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = down
		Input.parse_input_event(e)
	Input.flush_buffered_events()


func _square_pos(name: String) -> Vector2:
	var sq: int = ChessBoard.square_from_name(name)
	var r: Rect2 = _board.call("square_rect", sq)
	return _board.get_global_transform() * r.get_center()


func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node
	for child in node.get_children():
		var found: Button = _find_button(child, text)
		if found != null:
			return found
	return null


# ------------------------------------------------------------------- stages

func _stage_setup() -> bool:
	_shot("00_setup")
	_ck_true("the new-game dialog opens on launch", _view.get("_setup") != null)
	_ck_true("Start is reachable", _find_button(_view, "Start") != null)
	# Level 1 so the opponent answers quickly, and White so we move first.
	_view.set("_pref_level", 1)
	_view.set("_pref_side", 1)
	_wait(120)
	return false


func _stage_scroll_to_start() -> bool:
	# On a viewport too small for the whole dialog the card scrolls, so bring
	# the button into view before clicking it — which is what a person does,
	# and what makes this test meaningful at every reading size rather than
	# only at 1.0. The scroll lands on the NEXT frame, so the click cannot be
	# in this one.
	var scroll: ScrollContainer = _view.get("_setup_scroll")
	if scroll != null:
		scroll.ensure_control_visible(_find_button(_view, "Start"))
	_wait(150)
	return false


func _stage_start() -> bool:
	var start: Button = _find_button(_view, "Start")
	_click(start.get_global_transform() * (start.size * 0.5))
	_wait(200)
	return false


func _stage_board() -> bool:
	_board = _view.get("_board_view")
	_ck_true("the board took the position", _board.get("board") != null)
	_ck_true("the setup overlay closed", _view.get("_setup") == null)
	_shot("01_board")
	_click(_square_pos("e2"))
	_wait(150)
	return false


func _stage_selected() -> bool:
	_ck("tapping a pawn selects it", _board.get("selected"),
			ChessBoard.square_from_name("e2"))
	_ck("...and offers both of its moves",
			(_board.get("targets") as PackedInt32Array).size(), 2)
	_shot("02_selected")
	_click(_square_pos("e4"))
	# Deliberately shorter than MOVE_SEC, so the next stage catches the piece
	# in flight rather than after it has landed.
	_wait(70)
	return false


func _stage_midslide() -> bool:
	_ck_true("the piece is still travelling a moment after the move",
			bool(_board.call("is_animating")))
	_shot("02b_midslide")
	# The opponent thinks on a worker thread behind a minimum thinking time;
	# give it real time rather than assuming it has finished.
	_wait(2500)
	return false


func _stage_played() -> bool:
	var game = _view.get("_game")
	_ck("tapping the destination plays the move", str(game.records[0]["san"]), "e4")
	_ck_true("the move reached the move list", _view.get("_moves_list").item_count >= 1)
	_ck_true("the computer answered", game.records.size() >= 2)
	_ck_true("the animation finishes on its own",
			not bool(_board.call("is_animating")))
	_shot("03_after_reply")
	return false


func _stage_keyboard() -> bool:
	# The keypad path: put the cursor on d2 and play d2-d4 with ui_accept.
	_board.call("grab_focus")
	_board.set("cursor", ChessBoard.square_from_name("d2"))
	_board.set("show_cursor", true)
	_key(KEY_ENTER)
	_wait(150)
	return false


func _stage_keyboard_played() -> bool:
	var game = _view.get("_game")
	_ck("Enter on a pawn selects it", _board.get("selected"),
			ChessBoard.square_from_name("d2"))
	_shot("04_keyboard_cursor")
	_key(KEY_UP)
	_key(KEY_UP)
	_key(KEY_ENTER)
	_wait(2500)
	_ck("...and Enter on the target plays it", str(game.records[2]["san"]), "d4")
	return false


func _stage_sound() -> bool:
	## The audio node only exists in a real run — tests/run.gd deliberately
	## never builds a player, because one under --headless hangs the process.
	var audio: Node = _view.get("_audio")
	_ck_true("the game has a sound engine", audio != null)
	_ck_true("...with every cue built", audio.get("_streams").size() >= 10)
	var button: Button = _find_button(_view, "Sound")
	_ck_true("sound can be switched off from the panel", button != null)
	_ck_true("...and starts on", button.button_pressed)
	button.button_pressed = false
	_ck_true("turning it off silences the engine", not bool(audio.get("enabled")))
	button.button_pressed = true
	_ck_true("...and turning it back on restores it", bool(audio.get("enabled")))
	_wait(120)
	return false


func _stage_review() -> bool:
	var moves: ItemList = _view.get("_moves_list")
	moves.select(0)
	moves.item_selected.emit(0)
	_wait(150)
	return false


func _stage_live() -> bool:
	_ck_true("selecting a move enters review", int(_view.get("_review_ply")) == 0)
	_ck_true("the board goes read-only while reviewing", not bool(_board.get("interactive")))
	_shot("05_review")
	_find_button(_view, "Back to the game").pressed.emit()
	_wait(150)
	_ck_true("going live re-enables the board", bool(_board.get("interactive")))
	return false


func _stage_promotion_setup() -> bool:
	## Promotion is unreachable in four moves, so the position is set directly.
	## Everything after this point still goes through the real UI — the point
	## is to exercise the picker, not to play a whole game to reach it.
	var game = _view.get("_game")
	game.board = ChessBoard.new("7k/4P3/8/8/8/8/8/4K3 w - - 0 1")
	_board.call("show_position", game.board)
	_click(_square_pos("e7"))
	_wait(150)
	_click(_square_pos("e8"))
	_wait(150)
	return false


func _stage_promotion_shown() -> bool:
	_ck_true("pushing a pawn to the last rank opens the picker",
			_view.get("_promo") != null)
	_shot("07_promotion")
	var buttons: Array = []
	_collect_buttons(_view.get("_promo"), buttons)
	_ck("the picker offers four pieces", buttons.size(), 4)
	(buttons[0] as Button).pressed.emit()
	_wait(150)
	return false


func _stage_promotion_done() -> bool:
	var game = _view.get("_game")
	_ck("choosing the queen promotes to a queen",
			game.board.board[ChessBoard.square_from_name("e8")], ChessBoard.QUEEN)
	_ck_true("the picker closed", _view.get("_promo") == null)
	_shot("08_promoted")
	return false


func _stage_resign() -> bool:
	_find_button(_view, "Resign").pressed.emit()
	# Long enough for the telemetry queue to connect, publish and disconnect —
	# QMqttClient is a non-blocking state machine polled once a frame, so a
	# publish needs frames, not just a call.
	_wait(1500)
	return false


func _stage_done() -> bool:
	var game = _view.get("_game")
	_ck_true("resigning ends the game", bool(game.over))
	_ck("...with a plain-language reason", game.termination, "Computer won by resignation")
	_ck_true("the end card is shown", _view.get("_endcard") != null)
	_shot("09_endcard")
	print("")
	print("interactive: %s" % ("all checks passed" if _fail == 0 else "%d FAILED" % _fail))
	print("shots in ", ProjectSettings.globalize_path(SHOT_DIR))
	return true


func _collect_buttons(node: Node, out: Array) -> void:
	if node is Button:
		out.append(node)
	for child in node.get_children():
		_collect_buttons(child, out)
