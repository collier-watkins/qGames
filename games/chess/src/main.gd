class_name ChessView
extends QGameRoot

## Chess — code-first UI over the model in src/. The view draws and dispatches;
## every rule, every score and every string that describes an outcome comes
## from src/game.gd and src/board.gd.
##
## Layout is computed rather than composed: a wide window puts the panel beside
## the board, a tall one puts it underneath. That is not a nicety — the reading
## size (Ctrl +/-) shrinks the logical viewport, and paint has already been
## bitten once by a toolbar that could not fit the row it was given.

const B := preload("res://src/board.gd")
const G := preload("res://src/game.gd")
const O := preload("res://src/opponent.gd")

## "Gentle" — index 5 since "Child" was inserted at the bottom of the ladder.
const DEFAULT_LEVEL: int = 5

## Bumped whenever an insertion renumbers ChessOpponent.LEVELS, so a remembered
## `chess/level` can be moved with it. Scale 1 is the original eight levels;
## scale 2 added "Child" below them, shifting every stored number up by one.
const LEVEL_SCALE: int = 2

const C_BG: Color = Color(0.0980, 0.1373, 0.2353)
const C_PANEL: Color = Color(0.1451, 0.1922, 0.3059)
const C_PANEL_LINE: Color = Color(0.2353, 0.3059, 0.4706)
const C_TEXT: Color = Color(0.8784, 0.9098, 0.9647)
const C_DIM: Color = Color(0.5490, 0.6471, 0.8235)
const C_ACCENT: Color = Color(0.9412, 0.7647, 0.1765)
const C_GOOD: Color = Color(0.2157, 0.7647, 0.3137)
const C_BAD: Color = Color(0.8039, 0.2157, 0.1765)
const C_CLOCK_LOW: Color = Color(0.8627, 0.3216, 0.2431)

const PAD: float = 12.0
const PANEL_MIN: float = 268.0
const PANEL_MAX: float = 400.0
## Below this the clock is drawn in the warning colour. Ten seconds is where a
## clock stops being information and starts being the game.
const CLOCK_WARN_MS: int = 10000

var _game: ChessGame = null
var _opponent: ChessOpponent = null
var _board_view: ChessBoardView = null

var _panel: PanelContainer = null
var _panel_box: VBoxContainer = null
var _top_name: Label = null
var _top_clock: Label = null
var _bottom_name: Label = null
var _bottom_clock: Label = null

## Which colour each clock is currently showing: -1 unknown, 0 normal, 1 low.
## `Label.set_text` already early-outs on an identical string, but
## `add_theme_color_override` does not — it fires a theme-changed notification
## that dirties the label and walks its parents. _refresh_clocks() runs every
## frame and the clock changes about once a second, so writing both overrides
## unconditionally meant 120 of those notifications a second to say nothing.
var _top_clock_low: int = -1
var _bottom_clock_low: int = -1
var _status: Label = null
var _moves_list: ItemList = null
var _btn_hint: Button = null
var _btn_takeback: Button = null
var _btn_resign: Button = null
var _btn_live: Button = null
var _btn_sound: Button = null
var _buttons: HFlowContainer = null

var _setup: Control = null
var _setup_scroll: ScrollContainer = null
var _setup_box: VBoxContainer = null
var _setup_groups: HFlowContainer = null
var _promo: Control = null
var _endcard: Control = null

## -1 means "live". Any other value is a ply index being reviewed, during which
## the board is read-only.
var _review_ply: int = -1
var _promo_from: int = -1
var _promo_to: int = -1

var _pref_side: int = 1          ## +1 white, -1 black, 0 random
var _pref_level: int = DEFAULT_LEVEL
var _pref_base: int = 600
var _pref_increment: int = 0
var _thinking_dots: float = 0.0
var _audio: ChessAudio = null
var _pref_sound: bool = true


## Command-line switch, honoured in an exported build as well as in the editor.
## A menu entry for this would be a developer control in a child's game; a flag
## is discoverable by exactly the person who wants it.
const DUMP_PIECES_FLAG: String = "--dump-pieces"

## Skips the New-game card and deals a game immediately. Purely a measuring
## tool: the Pi has no way to inject a click, so without this the only screen
## that can be benchmarked is the modal dialog — which is the one screen that is
## NOT representative, because it lays a full-screen dimmer over everything. It
## is what established that chess holds a flat 60 fps in play while the setup
## card sits at 59.
const BENCH_FLAG: String = "--bench"


func _game_ready() -> void:
	var dump_to: String = _flag_value(DUMP_PIECES_FLAG)
	if dump_to != "":
		# A set written into the repository needs the .import stubs; one
		# written to user:// does not and should not have them.
		var repo: bool = dump_to.begins_with("res://")
		# Report which set is CURRENTLY in use as well. It is the question
		# anyone running this flag is about to ask, and it is the only way to
		# see the answer from an exported build: stdout is flushed on exit, so
		# a game killed mid-run prints nothing at all.
		var current := ChessPieceArt.new()
		current.load_set()
		print("chess: pieces currently from ", current.source)
		var where: String = ChessPieceArt.dump_builtin(dump_to, repo)
		if where == "":
			push_error("chess: could not write the piece set")
		else:
			print("chess: wrote the piece set to ", where)
			print("chess: edit the .svg files there and restart — nothing to rebuild")
			# The icon is the knight, so it belongs to the same artwork and is
			# rewritten in the same breath. Only for a REPOSITORY dump: a set
			# written to user:// is somebody's own set, and nothing they do to
			# it should reach into res:// and change the game's icon.
			if repo:
				var icon: FileAccess = FileAccess.open("res://icon.svg", FileAccess.WRITE)
				if icon == null:
					push_error("chess: could not write res://icon.svg")
				else:
					icon.store_string(ChessPieces.to_icon_svg())
					icon.close()
					print("chess: wrote res://icon.svg from the same knight")
		quit_game()
		return
	_load_prefs()
	_game = G.new()
	_opponent = O.new()
	_opponent.level = _pref_level
	if bool(QConfig.get_value("chess/external_engine", false)):
		# Opt-in only. Nothing is bundled; this finds an engine the machine
		# already has and is silent when there is none.
		if _opponent.try_external(str(QConfig.get_value("chess/engine_path", ""))):
			print("chess: external engine ", _opponent.external_name)

	_audio = ChessAudio.new()
	_audio.enabled = _pref_sound
	add_child(_audio)

	_build_ui()
	resized.connect(_relayout)
	_relayout()
	if _flag_value(BENCH_FLAG) != "":
		_start_game()
	else:
		_show_setup()


func _flag_value(flag: String) -> String:
	## Returns the flag's argument, the default when the bare flag is given, or
	## "" when it is absent. Both `--flag` and `--flag=value` are accepted, and
	## both the engine's argument list and the user's are searched — an
	## exported binary puts them in different places.
	var args: PackedStringArray = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for a: String in args:
		if a == flag:
			return ChessPieceArt.USER_DIR
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""


func _exit_tree() -> void:
	if _opponent != null:
		_opponent.shutdown()


func quit_game() -> void:
	## Escape, the Android back button and the window close all land here. A
	## game abandoned in progress is still reported — how far it got is the
	## interesting part — but it is reported as a quit, not as a result.
	if _game != null and not _game.over and not _game.records.is_empty():
		_game.abandon()
		_publish(_game)
	if _opponent != null:
		_opponent.shutdown()
	super()


# --------------------------------------------------------------- preferences

func _load_prefs() -> void:
	_pref_side = int(QConfig.get_value("chess/side", 1))
	# A stored level is a POSITION in the ladder, not a strength, so inserting a
	# level below it silently makes the machine one notch easier. Move it once and
	# record that it was moved; 0 means nothing was ever stored, which is the only
	# case that should land on the default.
	var stored_level: int = int(QConfig.get_value("chess/level", 0))
	if stored_level > 0 and int(QConfig.get_value("chess/level_scale", 1)) < LEVEL_SCALE:
		stored_level += 1
	_pref_level = clampi(stored_level if stored_level > 0 else DEFAULT_LEVEL, 1, O.LEVELS.size())
	_pref_base = int(QConfig.get_value("chess/base_seconds", 600))
	_pref_increment = int(QConfig.get_value("chess/increment_seconds", 0))
	_pref_sound = bool(QConfig.get_value("chess/sound", true))


func _save_prefs() -> void:
	## Only keys passed through set_value are written, which is why the MQTT
	## password never ends up in user://config.cfg. See QConfig.
	QConfig.set_value("chess/side", _pref_side)
	QConfig.set_value("chess/level", _pref_level)
	QConfig.set_value("chess/level_scale", LEVEL_SCALE)
	QConfig.set_value("chess/base_seconds", _pref_base)
	QConfig.set_value("chess/increment_seconds", _pref_increment)
	QConfig.set_value("chess/sound", _pref_sound)
	QConfig.save()


# ------------------------------------------------------------------ build UI

func _build_ui() -> void:
	# The background is the viewport's CLEAR COLOUR, not a full-screen ColorRect.
	#
	# They look identical and cost wildly different amounts. A ColorRect is a
	# canvas item: every frame the GPU rasterises and alpha-blends one quad over
	# the whole window. A clear is free on a tile-based GPU — it just marks the
	# tile buffer, with no memory read at all. MEASURED on the Pi 4 (V3D 4.2,
	# 1920x1053 maximized, gl_compatibility): one full-screen quad was costing
	# 9 ms of a 38 ms frame, a third of the budget, to draw a flat colour.
	#
	# project.godot sets the same colour so the frames before _ready() match.
	RenderingServer.set_default_clear_color(C_BG)

	_board_view = ChessBoardView.new()
	# Which artwork is in use is the first thing to establish about a
	# screenshot, so it is said out loud rather than left to be worked out.
	print("chess: pieces from ", _board_view.art.source)
	_board_view.move_attempted.connect(_on_move_attempted)
	_board_view.square_touched.connect(_on_square_touched)
	add_child(_board_view)

	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(12)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	_panel_box = VBoxContainer.new()
	_panel_box.add_theme_constant_override("separation", 8)
	_panel.add_child(_panel_box)

	_top_name = _make_label("Computer", 18, C_TEXT)
	_top_clock = _make_label("10:00", 26, C_TEXT)
	_panel_box.add_child(_player_row(_top_name, _top_clock))

	_status = _make_label("", 15, C_DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_box.add_child(_status)

	_moves_list = ItemList.new()
	_moves_list.max_columns = 2
	_moves_list.same_column_width = true
	_moves_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_moves_list.custom_minimum_size = Vector2(0, 60)
	_moves_list.add_theme_font_size_override("font_size", 16)
	_moves_list.item_selected.connect(_on_move_selected)
	_panel_box.add_child(_moves_list)

	_btn_live = Button.new()
	_btn_live.text = "Back to the game"
	_btn_live.visible = false
	_btn_live.pressed.connect(_go_live)
	_panel_box.add_child(_btn_live)

	_bottom_name = _make_label("You", 18, C_TEXT)
	_bottom_clock = _make_label("10:00", 26, C_TEXT)
	_panel_box.add_child(_player_row(_bottom_name, _bottom_clock))

	var buttons := HFlowContainer.new()
	buttons.add_theme_constant_override("h_separation", 6)
	buttons.add_theme_constant_override("v_separation", 6)
	_panel_box.add_child(buttons)
	_buttons = buttons

	_btn_hint = _make_button("Hint", _on_hint)
	_btn_takeback = _make_button("Take back", _on_takeback)
	_btn_resign = _make_button("Resign", _on_resign)
	buttons.add_child(_btn_hint)
	buttons.add_child(_btn_takeback)
	buttons.add_child(_make_button("Flip", _on_flip))
	buttons.add_child(_btn_resign)
	buttons.add_child(_make_button("New game", _show_setup))
	_btn_sound = Button.new()
	_btn_sound.text = "Sound"
	_btn_sound.toggle_mode = true
	_btn_sound.button_pressed = _pref_sound
	_btn_sound.add_theme_font_size_override("font_size", 16)
	_btn_sound.custom_minimum_size = Vector2(0, 38)
	_btn_sound.toggled.connect(_on_sound_toggled)
	buttons.add_child(_btn_sound)


func _player_row(name_label: Label, clock_label: Label) -> Control:
	var row := HBoxContainer.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	row.add_child(clock_label)
	return row


func _make_label(text: String, font_size: int, colour: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", colour)
	return l


func _make_button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 16)
	b.custom_minimum_size = Vector2(0, 38)
	b.pressed.connect(handler)
	return b


## The one button a child has to find. Everything else on the setup card is the
## engine's default grey, so colour is the whole signal — a four-year-old who
## cannot read "Start" can still be told to press the green one.
##
## The label is C_BG — the dark navy — and NOT white. That is the part worth
## writing down, because white is the intuitive choice and it is the worst of
## the three on offer. MEASURED, WCAG 2.x contrast against C_GOOD: navy 6.74:1
## (AA pass), white 2.31:1 (fail), and C_TEXT — the colour every other label on
## the card uses — 1.88:1, worse still. C_GOOD is a bright mid-green, and bright
## backgrounds want dark text.
##
## There is no automated guard on those numbers. main.gd names the QConfig
## autoload, so the headless suite cannot load it at all (the same constraint
## src/uci.gd documents), which puts ChessView's palette out of reach of
## tests/run.gd. Moving the colours into a dependency-free src/palette.gd would
## fix that and is the obvious next step if the palette starts moving.
##
## `focus` is a transparent box with a border rather than a filled one, because
## Godot draws the focus style OVER the normal style: filling it would repaint
## the green flat and lose the pressed/hover shading underneath.
func _make_primary_button(text: String, handler: Callable) -> Button:
	var b := _make_button(text, handler)
	for spec: Array in [["normal", C_GOOD], ["hover", C_GOOD.lightened(0.12)],
			["pressed", C_GOOD.darkened(0.18)]]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = spec[1]
		sb.set_corner_radius_all(10)
		sb.set_content_margin_all(10)
		b.add_theme_stylebox_override(str(spec[0]), sb)

	var focus := StyleBoxFlat.new()
	focus.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	focus.set_corner_radius_all(10)
	focus.set_content_margin_all(10)
	focus.border_color = C_TEXT
	focus.set_border_width_all(2)
	b.add_theme_stylebox_override("focus", focus)

	for key: String in ["font_color", "font_hover_color", "font_pressed_color",
			"font_focus_color"]:
		b.add_theme_color_override(key, C_BG)
	return b


# --------------------------------------------------------------------- layout

func _relayout() -> void:
	if _board_view == null:
		return
	var wide: bool = size.x > size.y * 1.18
	if wide:
		var pw: float = clampf(size.x * 0.30, PANEL_MIN, PANEL_MAX)
		_board_view.position = Vector2(PAD, PAD)
		_board_view.size = Vector2(size.x - pw - PAD * 3.0, size.y - PAD * 2.0)
		_panel.position = Vector2(size.x - pw - PAD, PAD)
		_panel.size = Vector2(pw, size.y - PAD * 2.0)
	else:
		var ph: float = clampf(size.y * 0.34, 168.0, 300.0)
		_board_view.position = Vector2(PAD, PAD)
		_board_view.size = Vector2(size.x - PAD * 2.0, size.y - ph - PAD * 3.0)
		_panel.position = Vector2(PAD, size.y - ph - PAD)
		_panel.size = Vector2(size.x - PAD * 2.0, ph)
	_arm_layout()
	_fit_setup()
	_fit_buttons.call_deferred()
	queue_redraw()


# ------------------------------------------------------------------ new game

func _show_setup() -> void:
	_arm_layout()
	if _setup != null:
		_setup.queue_free()
	_setup = _build_setup()
	add_child(_setup)
	_fade_in(_setup)


func _build_setup() -> Control:
	var veil := _make_veil(0.88)
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.border_color = C_PANEL_LINE
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(20)
	card.add_theme_stylebox_override("panel", sb)
	veil.get_child(0).add_child(card)

	# The card scrolls rather than overflowing. At 1280x720 with the reading
	# size at 1.6x the logical viewport is only 800x450, and the dialog is
	# taller than that — the Start button simply went off the bottom of the
	# screen, unreachable, with nothing to say so. Same failure mode as paint's
	# toolbar, and found the same way: by turning the reading size up.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card.add_child(scroll)
	_setup_scroll = scroll

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	_setup_box = box

	var title := _make_label("New game", 26, C_TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	# The three choices sit side by side when there is width for it and stack
	# when there is not. One HFlowContainer does both — which is the whole
	# reason it is used here rather than a Box: at 1280x720 with the reading
	# size at 1.6x the logical viewport is 800x450, wide but short, and a
	# single stacked column does not fit in 450px.
	var groups := HFlowContainer.new()
	groups.add_theme_constant_override("h_separation", 18)
	groups.add_theme_constant_override("v_separation", 10)
	box.add_child(groups)
	_setup_groups = groups

	var g_side := _group("Play as")
	groups.add_child(g_side)
	var sides := HBoxContainer.new()
	sides.add_theme_constant_override("separation", 6)
	g_side.add_child(sides)
	var side_group := ButtonGroup.new()
	for spec: Array in [["White", 1], ["Black", -1], ["Random", 0]]:
		var b := _toggle(str(spec[0]), side_group, _pref_side == int(spec[1]))
		b.pressed.connect(func() -> void: _pref_side = int(spec[1]))
		sides.add_child(b)

	var g_level := _group("Difficulty")
	groups.add_child(g_level)
	var level_name := _make_label(O.LEVELS[_pref_level - 1]["name"], 17, C_ACCENT)
	var levels := HFlowContainer.new()
	levels.add_theme_constant_override("h_separation", 5)
	levels.add_theme_constant_override("v_separation", 5)
	# Three to a row, deliberately: nine in a line makes the card too wide to
	# sit beside the other two groups, which is what buys the height back. Three
	# rather than the old four because nine buttons divide evenly by it — four
	# leaves a single orphan on a third row.
	levels.custom_minimum_size = Vector2(3 * 42 + 2 * 5, 0)
	g_level.add_child(levels)
	var level_group := ButtonGroup.new()
	for i in O.LEVELS.size():
		var b := _toggle(str(i + 1), level_group, _pref_level == i + 1)
		b.custom_minimum_size = Vector2(42, 42)
		b.pressed.connect(func() -> void:
			_pref_level = i + 1
			level_name.text = str(O.LEVELS[i]["name"]))
		levels.add_child(b)
	g_level.add_child(level_name)

	var g_time := _group("Time")
	groups.add_child(g_time)
	var times := HFlowContainer.new()
	times.add_theme_constant_override("h_separation", 5)
	times.add_theme_constant_override("v_separation", 5)
	times.custom_minimum_size = Vector2(196, 0)
	g_time.add_child(times)
	var time_group := ButtonGroup.new()
	for spec: Array in [["No clock", 0, 0], ["5 min", 300, 0], ["10 min", 600, 0], ["10 | 5", 600, 5]]:
		var chosen: bool = _pref_base == int(spec[1]) and _pref_increment == int(spec[2])
		var b := _toggle(str(spec[0]), time_group, chosen)
		b.custom_minimum_size = Vector2(92, 40)
		b.pressed.connect(func() -> void:
			_pref_base = int(spec[1])
			_pref_increment = int(spec[2]))
		times.add_child(b)

	var start := _make_primary_button("Start", _start_game)
	start.custom_minimum_size = Vector2(0, 48)
	start.add_theme_font_size_override("font_size", 20)
	box.add_child(start)
	start.call_deferred("grab_focus")
	_fit_setup.call_deferred()
	return veil


## Height of one button row and the gap between rows, mirrored from the values
## _make_button and the container are built with.
const BUTTON_ROW_H: float = 38.0
const BUTTON_ROW_GAP: float = 6.0


## Layout refits used to run on EVERY frame, for ever, for the reasons given in
## _fit_setup() and _fit_buttons(): a container's combined minimum size is not
## final until its children have been laid out, so a single deferred call after
## building one reads a stale answer. Running for ever is a big hammer for a
## problem that lasts a few frames.
##
## They now run until they SETTLE. Each pass reports whether it changed anything
## and refills the budget if it did, and anything that can invalidate a layout —
## a resize, a new setup card — refills it too. That is strictly more robust than
## the single deferred call this replaces, because it keeps going until the
## answer stops moving instead of guessing how long that takes.
##
## MEASURED on the Pi 4: worth about 1 fps on the New-game screen and it lifts
## the floor from 56 to 58. Small — chess is already a flat 60 in play — but it
## is pure waste otherwise.
const LAYOUT_SETTLE_FRAMES: int = 4

var _layout_settle: int = LAYOUT_SETTLE_FRAMES


func _arm_layout() -> void:
	_layout_settle = LAYOUT_SETTLE_FRAMES


func _fit_buttons() -> bool:
	## An HFlowContainer reports the height of ONE row as its minimum, whatever
	## it actually wraps to — width is not known when minimum sizes are asked
	## for. So the VBox above it hands out one row's worth of space and the
	## second row is drawn outside the panel: at 1.6x reading size the "New
	## game" button was half off the bottom edge. get_line_count() knows the
	## answer once the layout has run, so the minimum is corrected afterwards.
	if _buttons == null:
		return false
	var lines: int = maxi(_buttons.get_line_count(), 1)
	var wanted: float = lines * BUTTON_ROW_H + (lines - 1) * BUTTON_ROW_GAP
	if is_equal_approx(_buttons.custom_minimum_size.y, wanted):
		return false
	_buttons.custom_minimum_size.y = wanted
	return true


func _group(title: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.add_child(_make_label(title, 15, C_DIM))
	return v


## Widths the three setting groups occupy at one, two and three columns.
## An HFlowContainer's own minimum width is its WIDEST CHILD, so left alone it
## always reports one column and always wraps to one — it will use extra width
## but never ask for it. Asking is what this does.
const SETUP_COLUMN_WIDTHS: Array[float] = [630.0, 411.0, 0.0]
## Below this much height the card does not fit stacked, so it is worth
## spending width to buy height back.
const SETUP_SHORT_HEIGHT: float = 640.0


func _fit_setup() -> bool:
	## A ScrollContainer reports no minimum height of its own, so the card
	## would collapse inside a CenterContainer. Give it exactly the height its
	## content wants, capped at what the screen has — and lay the groups out in
	## as many columns as the width allows first, so that height is smaller.
	if _setup_scroll == null or _setup_box == null:
		return false
	var moved: bool = false
	if _setup_groups != null:
		var want_columns: float = 0.0
		if size.y < SETUP_SHORT_HEIGHT:
			for w: float in SETUP_COLUMN_WIDTHS:
				if w <= size.x - 96.0:
					want_columns = w
					break
		if _setup_groups.custom_minimum_size.x != want_columns:
			_setup_groups.custom_minimum_size.x = want_columns
			moved = true
	var wanted: Vector2 = _setup_box.get_combined_minimum_size()
	var target := Vector2(wanted.x, minf(wanted.y, maxf(size.y - 96.0, 160.0)))
	if not _setup_scroll.custom_minimum_size.is_equal_approx(target):
		_setup_scroll.custom_minimum_size = target
		moved = true
	return moved


## How long an overlay takes to appear. Long enough to read as a panel arriving
## rather than a screen changing, short enough that nobody waits for it.
const OVERLAY_FADE_SEC: float = 0.14


func _fade_in(overlay: Control) -> void:
	## A dialog that snaps in is read as a fault — something went wrong and the
	## screen changed. Fading it, and lifting the card the last few pixels,
	## says the same thing calmly.
	overlay.modulate.a = 0.0
	var card: Control = overlay.get_child(0) as Control
	var tween: Tween = overlay.create_tween()
	tween.set_parallel(true)
	tween.tween_property(overlay, "modulate:a", 1.0, OVERLAY_FADE_SEC)
	if card != null:
		card.position.y += 12.0
		tween.tween_property(card, "position:y", card.position.y - 12.0,
				OVERLAY_FADE_SEC).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _make_veil(alpha: float) -> ColorRect:
	## A full-rect dimmer with a CenterContainer inside it. The container is
	## what centres the card: it asks the card for its minimum size and places
	## it, which anchors alone cannot do before the card has been laid out.
	var veil := ColorRect.new()
	veil.color = Color(0.0392, 0.0588, 0.1176, alpha)
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.add_child(centre)
	return veil


func _toggle(text: String, group: ButtonGroup, pressed_now: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = group
	b.button_pressed = pressed_now
	b.add_theme_font_size_override("font_size", 16)
	b.custom_minimum_size = Vector2(0, 40)
	return b


func _start_game() -> void:
	var side: int = _pref_side
	if side == 0:
		# The RNG is the opponent's, seeded once at launch, so a random colour
		# is random rather than whatever the global RNG happened to be at.
		side = 1 if (randi() % 2) == 0 else -1
	_save_prefs()
	_opponent.level = _pref_level
	_game.start(side, _pref_base, _pref_increment, _pref_level, _opponent.level_name())
	_board_view.flipped = side == B.BLACK
	_board_view.show_position(_game.board)
	_board_view.skip_animations()
	_board_view.interactive = true
	_review_ply = -1
	_setup_scroll = null
	_setup_box = null
	_setup_groups = null
	_clear_overlay("_setup")
	_clear_overlay("_endcard")
	_clear_overlay("_promo")
	_refresh_moves()
	_refresh_names()
	_update_status()
	_maybe_think()


func _clear_overlay(field: String) -> void:
	var node: Control = get(field)
	if node != null:
		node.queue_free()
		set(field, null)


# ---------------------------------------------------------------- game loop

func _process(delta: float) -> void:
	# The setup card is refitted every frame it is open. A single deferred call
	# after building it is not enough — a container's combined minimum size is
	# not final until its children have been laid out, and the first answer
	# came back short enough to hide the Start button behind a scrollbar.
	if _layout_settle > 0:
		var moved: bool = false
		if _setup != null:
			moved = _fit_setup()
		# Same reason as the setup card: get_line_count() is only right after a
		# layout pass, and a single deferred call after a resize can still read
		# the pre-wrap answer.
		if _fit_buttons():
			moved = true
		_layout_settle = LAYOUT_SETTLE_FRAMES if moved else _layout_settle - 1
	if _game == null:
		return
	if not _game.over and _game.clock.tick(delta):
		_game.on_flag(_game.clock.flagged_side)
		_on_game_over()
	_refresh_clocks()

	if _opponent.is_thinking():
		_thinking_dots = fmod(_thinking_dots + delta, 1.5)
		var move: int = _opponent.poll()
		if move != 0:
			_apply_move(move)
		else:
			_update_status()


func _maybe_think() -> void:
	if _game.over or _game.is_human_turn():
		_update_status()
		return
	_board_view.clear_hint()
	_opponent.think(_game.board, _game.board.repetition_counts())
	_update_status()


func _on_move_attempted(from_sq: int, to_sq: int) -> void:
	if _review_ply >= 0:
		_go_live()
		return
	if not _game.is_human_turn():
		return
	var candidates: Array[int] = []
	for m in _game.board.legal_moves():
		if B.move_from(m) == from_sq and B.move_to(m) == to_sq:
			candidates.append(m)
	if candidates.is_empty():
		_audio.play(ChessAudio.ILLEGAL)
		return
	if candidates.size() > 1:
		# The only move that generates four candidates is a promotion, and the
		# player has to say which piece. Asking is not optional: auto-queening
		# takes away the one moment where underpromotion decides a game.
		_promo_from = from_sq
		_promo_to = to_sq
		_show_promotion()
		return
	_apply_move(candidates[0])


func _apply_move(m: int) -> void:
	_board_view.clear_hint()
	var from: int = B.move_from(m)
	var to: int = B.move_to(m)
	# What is about to be taken has to be read BEFORE the move is made — after
	# it, the piece is simply gone and there is nothing left to fade out. En
	# passant takes a piece that is not on the destination square, which is the
	# case a naive "board[to]" misses.
	var capture_sq: int = to
	if B.move_flag(m) == B.FLAG_EP:
		capture_sq = to - 16 * _game.board.side
	var captured: int = _game.board.board[capture_sq]
	var moved: int = _game.board.board[from]
	if not _game.apply(m):
		return
	_board_view.show_position(_game.board, from, to)
	_board_view.animate_move(m, moved,
			[[capture_sq, captured]] if captured != 0 else [])
	_play_move_cues(m, captured != 0)
	_refresh_moves()
	if _game.over:
		_on_game_over()
	else:
		_maybe_think()
	_update_status()


## Cues that follow another cue are delayed rather than layered. Two sounds at
## the same instant are heard as one confused sound; a beat apart, they are
## heard as a move and then its consequence, which is the order the events
## actually happened in.
const CHECK_CUE_DELAY: float = 0.18
const RESULT_CUE_DELAY: float = 0.30


func _play_move_cues(m: int, was_capture: bool) -> void:
	if B.move_promo(m) != 0:
		_audio.play(ChessAudio.PROMOTE)
	elif B.move_flag(m) == B.FLAG_CASTLE:
		_audio.play(ChessAudio.CASTLE)
	elif was_capture:
		_audio.play(ChessAudio.CAPTURE)
	else:
		_audio.play(ChessAudio.MOVE)
	if not _game.over and _game.board.in_check():
		_cue_after(CHECK_CUE_DELAY, ChessAudio.CHECK)


func _cue_after(seconds: float, cue: String) -> void:
	var timer: SceneTreeTimer = get_tree().create_timer(seconds)
	timer.timeout.connect(func() -> void: _audio.play(cue))


func _on_game_over() -> void:
	_board_view.interactive = false
	match _game.telemetry_result():
		"win": _cue_after(RESULT_CUE_DELAY, ChessAudio.WIN)
		"loss": _cue_after(RESULT_CUE_DELAY, ChessAudio.LOSS)
		"draw": _cue_after(RESULT_CUE_DELAY, ChessAudio.DRAW)
	_publish(_game)
	_show_endcard()
	_update_status()


# --------------------------------------------------------------- promotion

func _show_promotion() -> void:
	_clear_overlay("_promo")
	var veil := _make_veil(0.82)
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(16)
	card.add_theme_stylebox_override("panel", sb)
	veil.get_child(0).add_child(card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	card.add_child(box)
	var title := _make_label("Choose a piece", 20, C_TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var white: bool = _game.board.side == B.WHITE
	for type: int in [B.QUEEN, B.ROOK, B.BISHOP, B.KNIGHT]:
		var b := Button.new()
		b.custom_minimum_size = Vector2(84, 84)
		b.tooltip_text = ChessBoard.PIECE_LETTER[type]
		# The pieces are drawn, not lettered: a child choosing a promotion has
		# to recognise the shape, and "N" means nothing to them.
		b.draw.connect(func() -> void:
			_board_view.art.draw(b, type if white else -type,
					Rect2(Vector2.ZERO, b.size).grow(-10),
					ChessBoardView.C_PIECE_WHITE if white else ChessBoardView.C_PIECE_BLACK,
					ChessBoardView.C_PIECE_BLACK if white else ChessBoardView.C_PIECE_WHITE))
		b.pressed.connect(func() -> void: _finish_promotion(type))
		row.add_child(b)
		if type == B.QUEEN:
			b.call_deferred("grab_focus")

	_promo = veil
	add_child(_promo)
	_fade_in(_promo)


func _finish_promotion(type: int) -> void:
	_clear_overlay("_promo")
	for m in _game.board.legal_moves():
		if B.move_from(m) == _promo_from and B.move_to(m) == _promo_to and B.move_promo(m) == type:
			_apply_move(m)
			return


# ------------------------------------------------------------------ actions

func _on_hint() -> void:
	## Shows the move the CURRENT difficulty would play, not the best move on
	## the board. A hint from a stronger engine than the one you are playing is
	## advice you cannot act on and cannot learn from.
	if _game.over or not _game.is_human_turn() or _opponent.is_thinking():
		return
	var s := ChessSearch.new()
	var cfg: Dictionary = _opponent.level_config()
	var r: Dictionary = s.search(_game.board, maxi(int(cfg["depth"]), 3), 600)
	if int(r["move"]) != 0:
		_board_view.set_hint(B.move_from(int(r["move"])), B.move_to(int(r["move"])))
		_status.text = "Try %s" % _game.board.san(int(r["move"]))


func _on_takeback() -> void:
	if _game.over or _opponent.is_thinking():
		return
	if _game.takeback():
		_review_ply = -1
		var from_sq: int = -1
		var to_sq: int = -1
		if not _game.records.is_empty():
			var last: Dictionary = _game.records[-1]
			var uci: String = str(last["uci"])
			from_sq = B.square_from_name(uci.substr(0, 2))
			to_sq = B.square_from_name(uci.substr(2, 2))
		_board_view.show_position(_game.board, from_sq, to_sq)
		_board_view.skip_animations()
		_board_view.interactive = true
		_refresh_moves()
		_update_status()


func _on_resign() -> void:
	if _game.over:
		return
	_game.resign(_game.human_side)
	_on_game_over()


func _on_sound_toggled(on: bool) -> void:
	_pref_sound = on
	_audio.set_enabled(on)
	_save_prefs()
	if on:
		# Play the cue you just turned back on, so the button proves itself.
		_audio.play(ChessAudio.MOVE)


func _on_square_touched(sq: int) -> void:
	## The pick-up tick, and only for a piece that can actually be picked up —
	## a tick on every tap anywhere would be noise rather than feedback.
	if _game == null or _game.over or not _game.is_human_turn():
		return
	var p: int = _game.board.board[sq]
	if p != 0 and (p > 0) == (_game.board.side > 0):
		_audio.play(ChessAudio.SELECT)


func _on_flip() -> void:
	## Every piece changes square at once, so there is nothing to slide — a
	## flip is a different view of the same position, not a move. It fades
	## instead, which reads as the board turning over rather than as thirty-two
	## pieces teleporting.
	_board_view.flipped = not _board_view.flipped
	_board_view.skip_animations()
	_board_view.modulate.a = 0.35
	_board_view.create_tween().tween_property(_board_view, "modulate:a", 1.0, 0.18)
	_board_view.queue_redraw()


func _on_move_selected(index: int) -> void:
	## Reviewing an earlier position. The board goes read-only: a move played
	## from a past position would be a different game, and silently discarding
	## it is worse than not accepting it.
	if index < 0 or index >= _game.records.size():
		return
	_review_ply = index
	var b: ChessBoard = _replay_to(index)
	var uci: String = str(_game.records[index]["uci"])
	_board_view.show_position(b, B.square_from_name(uci.substr(0, 2)),
			B.square_from_name(uci.substr(2, 2)))
	_board_view.skip_animations()
	_board_view.interactive = false
	_btn_live.visible = true
	_update_status()


func _replay_to(ply_index: int) -> ChessBoard:
	## The position AFTER ply `ply_index`. Each record carries the FEN of the
	## position it was played in, so the answer is the next record's FEN — or,
	## for the last move, the live board.
	if ply_index + 1 < _game.records.size():
		return B.new(str(_game.records[ply_index + 1]["fen_before"]))
	return _game.board


func _go_live() -> void:
	_review_ply = -1
	_btn_live.visible = false
	var from_sq: int = -1
	var to_sq: int = -1
	if not _game.records.is_empty():
		var uci: String = str(_game.records[-1]["uci"])
		from_sq = B.square_from_name(uci.substr(0, 2))
		to_sq = B.square_from_name(uci.substr(2, 2))
	_board_view.show_position(_game.board, from_sq, to_sq)
	_board_view.skip_animations()
	_board_view.interactive = not _game.over
	_moves_list.deselect_all()
	_update_status()


# ------------------------------------------------------------------ refresh

func _refresh_names() -> void:
	_top_name.text = "Computer — %s" % _game.level_name
	_bottom_name.text = "You (%s)" % ("White" if _game.human_side == B.WHITE else "Black")


func _refresh_clocks() -> void:
	if _game.clock.is_unlimited():
		_top_clock.text = "—"
		_bottom_clock.text = "—"
		_set_clock_low(_top_clock, false, true)
		_set_clock_low(_bottom_clock, false, false)
		return
	var computer_ms: int = _game.clock.ms_left(_game.computer_side())
	var human_ms: int = _game.clock.ms_left(_game.human_side)
	_top_clock.text = ChessClock.format(computer_ms)
	_bottom_clock.text = ChessClock.format(human_ms)
	_set_clock_low(_top_clock, computer_ms < CLOCK_WARN_MS, true)
	_set_clock_low(_bottom_clock, human_ms < CLOCK_WARN_MS, false)


func _set_clock_low(label: Label, low: bool, top: bool) -> void:
	## Only touches the theme when the state actually flips. -1 means "not set
	## yet", so the first call always paints and the label never starts life
	## with whatever colour it was built with by accident.
	var want: int = 1 if low else 0
	if top:
		if _top_clock_low == want:
			return
		_top_clock_low = want
	else:
		if _bottom_clock_low == want:
			return
		_bottom_clock_low = want
	label.add_theme_color_override("font_color", C_CLOCK_LOW if low else C_TEXT)


func _refresh_moves() -> void:
	_moves_list.clear()
	for i in range(_game.records.size()):
		var r: Dictionary = _game.records[i]
		var prefix: String = "%d. " % [i / 2 + 1] if i % 2 == 0 else ""
		_moves_list.add_item(prefix + str(r["san"]))
	if _moves_list.item_count > 0:
		_moves_list.ensure_current_is_visible()
	_btn_takeback.disabled = _game.over or _game.records.is_empty()
	_btn_hint.disabled = _game.over or not _game.is_human_turn()
	_btn_resign.disabled = _game.over


func _update_status() -> void:
	if _game == null:
		return
	if _review_ply >= 0:
		_status.text = "Looking back at move %d" % [_review_ply / 2 + 1]
		return
	if _game.over:
		_status.text = _game.termination
		return
	if _opponent.is_thinking():
		_status.text = "Thinking" + ".".repeat(1 + int(_thinking_dots / 0.5))
		return
	if _game.board.in_check():
		_status.text = "Check!" if _game.is_human_turn() else "You have given check"
		return
	_status.text = "Your move" if _game.is_human_turn() else "Computer's move"


# ----------------------------------------------------------------- end card

func _show_endcard() -> void:
	_clear_overlay("_endcard")
	var veil := _make_veil(0.78)
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.border_color = C_PANEL_LINE
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(22)
	card.add_theme_stylebox_override("panel", sb)
	veil.get_child(0).add_child(card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	card.add_child(box)

	var outcome: String = _game.telemetry_result()
	var headline: String = {"win": "You won!", "loss": "Computer won", "draw": "Draw"}.get(outcome, "Game over")
	var colour: Color = {"win": C_GOOD, "loss": C_BAD, "draw": C_ACCENT}.get(outcome, C_TEXT)
	var h := _make_label(headline, 32, colour)
	h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(h)

	# The plain-language reason, not the PGN token. "Game drawn by the 50-move
	# rule" is something a child can be told; "1/2-1/2" is not.
	var why := _make_label(_game.termination, 17, C_DIM)
	why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(why)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var again := _make_button("Play again", _show_setup)
	again.custom_minimum_size = Vector2(150, 46)
	row.add_child(again)
	var look := _make_button("Look at the game", func() -> void: _clear_overlay("_endcard"))
	look.custom_minimum_size = Vector2(150, 46)
	row.add_child(look)
	again.call_deferred("grab_focus")

	_endcard = veil
	add_child(_endcard)
	_fade_in(_endcard)


# ---------------------------------------------------------------- telemetry

func _publish(game: ChessGame) -> void:
	## The PGN goes out RETAINED and FIRST, then the scalars, with ts last —
	## the same shape notes uses for a saved document. Retained because the
	## point of putting a game on a broker is that a dashboard which restarts
	## an hour later still has the last game; a scalar reading would be stale,
	## but the last game played is the last game played until another one is.
	var score: int = int(ceil(game.records.size() / 2.0))
	Telemetry.report_result(
		game.telemetry_result(), score, "moves",
		game.telemetry_extra(),
		[["pgn", game.pgn()], ["fen", game.board.fen()]])
