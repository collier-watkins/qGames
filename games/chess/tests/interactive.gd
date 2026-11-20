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
## The player's own training prefs, put back when the run ends: it writes the
## real user://config.cfg.
var _saved_training: Array = []


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
		_stage_training_open,
		_stage_training_on,
		_stage_training_done,
		_stage_training_board,
		_stage_training_hover,
		_stage_point_computer,
		_stage_point_mine,
		_stage_point_chain,
		_stage_point_done,
		_stage_check_shown,
		_stage_check_answered,
		_stage_check_received,
		_stage_mate_trap,
		_stage_mate_party,
		_stage_mate_card,
		_stage_mate_again,
		_stage_mate_skip,
		_stage_mate_skipped,
		_stage_training_off,
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


func _stage_training_open() -> bool:
	# By field, not by text: the label reads "Training: on" when the saved
	# prefs from a real game already have it switched on.
	_saved_training = [_view.get("_pref_training"), _view.get("_pref_train_danger"),
			_view.get("_pref_train_attack"), _view.get("_pref_train_hover"),
			_view.get("_pref_train_chains"), _view.get("_pref_train_checks")]
	var button: Button = _view.get("_btn_training")
	_ck_true("training mode is reachable from the panel", button != null)
	_click(button.get_global_transform() * (button.size * 0.5))
	_wait(250)
	return false


func _stage_training_on() -> bool:
	_ck_true("the training card opens", _view.get("_training_card") != null)
	var master: Button = _find_button(_view, "Training mode")
	var danger: Button = _find_button(_view, "Danger squares")
	var attack: Button = _find_button(_view, "Attack squares")
	var hover: Button = _find_button(_view, "Only the piece I point at")
	_ck_true("...and the point-at-a-piece switch", hover != null)
	_ck_true("...with a master switch and the danger- and attack-squares switches",
			master != null and danger != null and attack != null)
	# Start from off whatever the saved prefs say, so the disabled state is
	# actually exercised.
	master.button_pressed = false
	_ck_true("an aid cannot be switched while training is off", danger.disabled)
	master.button_pressed = true
	danger.button_pressed = true
	attack.button_pressed = true
	# The whole-board maps first; pointing at a piece is the next stage.
	hover.button_pressed = false
	_ck_true("switching training on enables its aids", not danger.disabled)
	_shot("06a_training_card")
	# The card scrolls when it is taller than the screen; bring Done into view
	# the way a person would before pressing it. Lands next frame.
	var scroll: ScrollContainer = _view.get("_training_scroll")
	if scroll != null:
		scroll.ensure_control_visible(_find_button(_view, "Done"))
	_wait(150)
	return false


func _stage_training_done() -> bool:
	var done: Button = _find_button(_view, "Done")
	_click(done.get_global_transform() * (done.size * 0.5))
	_wait(200)
	return false


func _stage_training_board() -> bool:
	## A set position: the knights on e4 (a light square) and g5 (dark) are
	## attacked by the d5 and h6 pawns, and the bishop's a3 is covered by b4.
	## Every pawn's and the king's empty take squares are shaded as well.
	_ck_true("Done closes the card", _view.get("_training_card") == null)
	var game = _view.get("_game")
	_ck("the board watches the human's pieces", _board.get("danger_for"), game.human_side)
	game.board = ChessBoard.new("4k3/8/7p/3p2N1/1p2N3/8/8/2B1K3 w - - 0 1")
	_board.call("show_position", game.board)
	var danger: Array = []
	for s in _board.get("_danger"):
		danger.append(ChessBoard.square_name(s))
	danger.sort()
	_ck("the take squares are shaded: knights on light and dark, empty squares too",
			danger, ["a3", "c3", "c4", "d7", "d8", "e4", "e7", "f8", "g5"])
	_ck_true("...but not f7: the king cannot take there, the g5 knight protects it",
			not danger.has("f7"))
	var attack: Array = []
	for s in _board.get("_attack"):
		attack.append(ChessBoard.square_name(s))
	_ck_true("attack squares are shaded: the knights' and the bishop's take squares",
			attack.has("d6") and attack.has("h7") and attack.has("f4") and not attack.has("d5"))
	_ck_true("...and e4, which both sides can take on, is in both — drawn split",
			attack.has("e4") and danger.has("e4"))
	_click(_square_pos("c1"))
	_wait(200)
	return false


func _stage_training_hover() -> bool:
	_ck("selecting the bishop marks the one move that hangs it", _board.get("_hanging"),
			PackedInt32Array([ChessBoard.square_from_name("a3")]))
	_shot("06b_training_board")
	_board.call("clear_selection")
	_view.set("_pref_train_hover", true)
	_view.call("_apply_training")
	_board.set("show_cursor", false)
	_hover(Vector2(-50, -50))
	_ck("pointing at nothing shows nothing", (_board.get("_danger") as PackedInt32Array).size()
			+ (_board.get("_attack") as PackedInt32Array).size(), 0)
	_hover(_square_pos("d5"))
	_wait(150)
	return false


func _stage_point_computer() -> bool:
	_ck("pointing at the computer's d5 pawn shows ITS take squares, red",
			_names(_board.get("_danger")), ["c4", "e4"])
	_ck("...and no blue", (_board.get("_attack") as PackedInt32Array).size(), 0)
	_shot("06c_point_computer")
	_hover(_square_pos("g5"))
	_wait(150)
	return false


func _stage_point_mine() -> bool:
	var blue: Array = _names(_board.get("_attack"))
	_ck_true("pointing at my g5 knight shows its take squares, blue",
			blue.has("h7") and blue.has("f7") and blue.has("e6") and not blue.has("d5"))
	_ck("...and no red", (_board.get("_danger") as PackedInt32Array).size(), 0)
	_shot("06d_point_mine")
	var badged: Array = []
	for s: int in (_board.get("_in_danger") as Dictionary):
		badged.append(ChessBoard.square_name(s))
	badged.sort()
	_ck("both knights carry a danger badge: each is attacked by a pawn", badged, ["e4", "g5"])
	_hover(_square_pos("e4"))
	_wait(150)
	return false


func _stage_point_chain() -> bool:
	var chain: Dictionary = _board.get("_chain")
	_ck("pointing at the e4 knight shows its take chain: two steps",
			(chain.get("steps", []) as Array).size(), 2)
	_ck("...worth a knight for a pawn to them", int(chain.get("worth", 0)), 2)
	var explain: Label = _view.get("_explain")
	_ck_true("...and the panel says it in words", explain.visible and explain.text.contains("pawn"))
	print("      panel: ", explain.text)
	_shot("06e_take_chain")
	_hover(Vector2(-50, -50))
	_wait(120)
	return false


func _stage_point_done() -> bool:
	_ck("moving off the board clears it", (_board.get("_attack") as PackedInt32Array).size(), 0)
	# Why check: the player gives one through the real board, Ra1-a8+.
	_view.set("_pref_train_checks", true)
	_view.call("_apply_training")
	var game = _view.get("_game")
	_ck("the player is white here", game.human_side, ChessBoard.WHITE)
	game.board = ChessBoard.new("3k4/8/8/8/8/8/8/R3K3 w - - 0 1")
	_board.call("show_position", game.board)
	_click(_square_pos("a1"))
	_wait(120)
	_click(_square_pos("a8"))
	# Long enough for the slide to land, well inside the computer's hold.
	_wait(1200)
	return false


func _stage_check_shown() -> bool:
	var check: Dictionary = _board.get("_check")
	_ck_true("giving check shows why", not check.is_empty())
	if not check.is_empty():
		_ck("...the checker is the rook", ChessBoard.square_name(int(check["checkers"][0]["from"])), "a8")
		_ck("...its line runs to the king", _names(check["checkers"][0]["line"]), ["b8", "c8"])
	_ck_true("the computer holds its reply so it can be seen",
			(_view.get("_opponent") as RefCounted).call("is_thinking"))
	var status: Label = _view.get("_status")
	_ck("...and the status says so", status.text, "You have given check")
	var explain: Label = _view.get("_explain")
	_ck_true("the panel says why", explain.visible and explain.text.begins_with(
			"Your rook on a8 attacks their king straight along the row."))
	print("      panel: ", explain.text)
	_shot("06f_check_given")
	_wait(3200)
	return false


func _stage_check_answered() -> bool:
	_ck_true("the computer has answered the check",
			not (_view.get("_opponent") as RefCounted).call("is_thinking"))
	var game = _view.get("_game")
	_ck_true("...and the check, with its picture, is gone",
			not game.board.in_check() and (_board.get("_check") as Dictionary).is_empty())
	# Now the player is in check: the b4 bishop on e1, blockable on c3 or d2.
	game.board = ChessBoard.new("4k3/8/8/8/1b6/P7/8/1N2K3 w - - 0 1")
	_board.call("show_position", game.board)
	_view.call("_update_status")
	_wait(150)
	return false


func _stage_check_received() -> bool:
	var explain: Label = _view.get("_explain")
	_ck_true("being in check shows the ways out", explain.visible and explain.text.begins_with(
			"Their bishop on b4 attacks your king along the diagonal. Ways out:"))
	_ck("...the status says check", (_view.get("_status") as Label).text, "Check!")
	_shot("06g_check_received")
	# Escapes in green: e2 and the others for the king, c3/d2 blocks, a3 takes.
	var check: Dictionary = _board.get("_check")
	_ck("...and its ways out are on the board", [_names(check["blocks"]), _names(check["takers"])],
			[["c3", "d2"], ["a3"]])
	# On the board only the pieces that can answer glow (a3 pawn, b1 knight,
	# the king); each one's squares wait to be pointed at.
	var answers: Array = (_board.get("_answers") as Dictionary).keys()
	answers.sort()
	_ck("...the pieces that can answer are marked", _names(PackedInt32Array(answers)), ["a3", "b1", "e1"])
	_play_mate()
	_wait(1000)
	return false


func _play_mate() -> void:
	## Back-rank mate through the real board: Ra1-a8#.
	var game = _view.get("_game")
	game.board = ChessBoard.new("6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1")
	_board.call("show_position", game.board)
	_click(_square_pos("a1"))
	_click(_square_pos("a8"))


func _stage_mate_trap() -> bool:
	var game = _view.get("_game")
	_ck_true("the mate ends the game", bool(game.over))
	_ck_true("...but the end card waits while the mate is shown", _view.get("_endcard") == null)
	var trap: Array = _board.get("_trap")
	_ck("every square round the king is part of the trap", trap.size(), 5)
	var explain: Label = _view.get("_explain")
	_ck_true("the panel says how the trap is made", explain.text.begins_with(
			"Checkmate! Your rook on a8 attacks their king straight along the row. It is a trap:"))
	print("      panel: ", explain.text)
	_shot("06h_mate_trap")
	_wait(1000)
	return false


func _stage_mate_party() -> bool:
	_ck_true("a mate the player gave is celebrated", (_board.get("_confetti") as Array).size() > 0)
	_ck_true("...still before the end card", _view.get("_endcard") == null)
	_shot("06i_mate_celebration")
	_wait(4500)
	return false


func _stage_mate_card() -> bool:
	_ck_true("after the dwell, the end card", _view.get("_endcard") != null)
	_shot("06j_mate_card")
	# The card's veil is freed at the end of the frame and would swallow a
	# click made now: the next mate is played in the next stage.
	_view.call("_start_game")
	_wait(200)
	return false


func _stage_mate_again() -> bool:
	_play_mate()
	# Past MATE_SKIP_AFTER, which counts from when the move LANDS.
	_wait(1400)
	return false


func _stage_mate_skip() -> bool:
	_ck_true("a second mate: no card yet", _view.get("_endcard") == null)
	_click(_square_pos("d4"))
	_wait(200)
	return false


func _stage_mate_skipped() -> bool:
	_ck_true("a tap skips straight to the end card", _view.get("_endcard") != null)
	_view.call("_start_game")
	_wait(200)
	return false


func _hover(pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = get_root().get_screen_transform() * pos
	e.global_position = e.position
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _names(squares: PackedInt32Array) -> Array:
	var out: Array = []
	for s in squares:
		out.append(ChessBoard.square_name(s))
	out.sort()
	return out


func _stage_training_off() -> bool:
	_view.set("_pref_training", false)
	_view.call("_apply_training")
	_ck("switching training off clears the shading", (_board.get("_danger") as PackedInt32Array).size(), 0)
	# Put the player's own setting back: the run writes the real config.
	_view.set("_pref_training", _saved_training[0])
	_view.set("_pref_train_danger", _saved_training[1])
	_view.set("_pref_train_attack", _saved_training[2])
	_view.set("_pref_train_hover", _saved_training[3])
	_view.set("_pref_train_chains", _saved_training[4])
	_view.set("_pref_train_checks", _saved_training[5])
	_view.call("_save_prefs")
	_board.call("clear_selection")
	_wait(120)
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
