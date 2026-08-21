extends QGameRoot

## Pips — place every domino so each coloured region obeys its rule.
##
## The rules are the New York Times' Pips, and the thing to hold on to is that
## TOUCHING ENDS DO NOT HAVE TO MATCH. This is not the chain game; a domino may
## straddle two regions and each half then answers to its own region's rule.
##
## Code-first per the house rule: main.tscn is a bare Control and everything
## below is built here. The rules live in puzzle.gd and know nothing about
## drawing; this file knows nothing about legality — it asks.
##
## Interaction is tap-tap rather than drag. A drag is fiddly with a finger on a
## small board and impossible with a d-pad, and this platform treats touch and
## keypad as equally first-class: pick a domino, turn it, tap where it goes.

const MARGIN: int = 16
const GAP: int = 10

# A light, papery palette. Pips is a newspaper puzzle, not a game screen.
const C_PAGE: Color = Color("#f7f5f0")
const C_INK: Color = Color("#22252a")
const C_DIM: Color = Color("#6b7280")
const C_LINE: Color = Color("#ddd8cf")
const C_ACCENT: Color = Color("#2f6fd0")
const C_GOOD: Color = Color("#3f9c58")
const C_BAD: Color = Color("#c0453c")
const C_BONE: Color = Color("#ffffff")
const C_BONE_EDGE: Color = Color("#c9c4bb")
const C_PIP: Color = Color("#22252a")
const C_SCRIM: Color = Color(0.13, 0.14, 0.16, 0.72)

## Region fills, chosen to stay distinguishable side by side and to keep dark
## pips readable on every one of them.
const REGION_COLOURS: Array = [
	Color("#cfe0f4"), Color("#d8ecd3"), Color("#f8e7b4"), Color("#f6d8dc"),
	Color("#e3daf4"), Color("#fbe2c9"), Color("#cfe8e4"), Color("#e9e4da"),
	Color("#dfeaf8"), Color("#e7f0d6"), Color("#f9ded1"), Color("#dcdff0"),
]

const LEVEL_NAMES: Array = ["Easy", "Medium", "Hard"]

var _library: PipsLibrary
var _puzzle: PipsPuzzle
var _level: int = PipsGenerator.Level.EASY
var _pack_index: int = 0
var _moves: int = 0
var _started_msec: int = 0

## Which tray bone is in hand, and how it is turned. `_facing` is the direction
## the SECOND half points: 0 right, 1 down, 2 left, 3 up. Four turns rather than
## two, because a 3-5 laid left-to-right is a different placement from a 5-3 and
## a solver needs both.
var _held: int = -1
var _facing: int = 0

var _board: BoardView
var _tray: TrayView
var _title: Label
var _hint: Label
var _rule_line: Label
var _level_buttons: Array = []
var _overlay: Control
var _overlay_text: Label


func _game_ready() -> void:
	_library = PipsLibrary.new()
	_build_ui()
	resized.connect(func() -> void:
		_board.queue_redraw()
		_tray.queue_redraw())
	QInput.device_changed.connect(func(_d: String) -> void: _refresh())
	_pack_index = randi()
	_new_puzzle()


# ── Construction ────────────────────────────────────────────────────────────


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = C_PAGE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Children may anchor full-rect even though the root must not: QGameRoot
	# guarantees the root's `size` is already the viewport in _game_ready().
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, MARGIN)
	add_child(margin)

	var shell := VBoxContainer.new()
	shell.add_theme_constant_override("separation", GAP)
	margin.add_child(shell)

	shell.add_child(_build_header())

	_board = BoardView.new()
	_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board.cell_activated.connect(_on_cell_activated)
	_board.cursor_moved.connect(func() -> void: _refresh_rule_line())
	shell.add_child(_board)

	_rule_line = Label.new()
	_rule_line.add_theme_font_size_override("font_size", 15)
	_rule_line.add_theme_color_override("font_color", C_DIM)
	_rule_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	shell.add_child(_rule_line)

	_tray = TrayView.new()
	_tray.custom_minimum_size = Vector2(0, 96)
	_tray.bone_chosen.connect(_on_tray_chosen)
	shell.add_child(_tray)

	shell.add_child(_build_controls())

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 14)
	_hint.add_theme_color_override("font_color", C_DIM)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	shell.add_child(_hint)

	# Added last: sibling order is draw order for Controls, so the overlay is
	# only guaranteed to cover the board if it is the root's last child.
	_overlay = _build_overlay()
	add_child(_overlay)


func _build_header() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 22)
	_title.add_theme_color_override("font_color", C_INK)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_title)

	_level_buttons = []
	for level in LEVEL_NAMES.size():
		var button := _make_button(str(LEVEL_NAMES[level]),
				func() -> void: _choose_level(level), true)
		_level_buttons.append(button)
		bar.add_child(button)

	bar.add_child(_make_button("New", _new_puzzle, false))
	return bar


func _build_controls() -> Control:
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 10)
	bar.add_child(_make_button("Turn  (R)", _rotate_held, false))
	bar.add_child(_make_button("Take back  (Backspace)", _lift_at_cursor, false))
	bar.add_child(_make_button("Clear", _clear_board, false))
	return bar


func _make_button(text: String, on_press: Callable, toggle: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = toggle
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_size_override("font_size", 15)
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(8)
		sb.content_margin_left = 12.0
		sb.content_margin_right = 12.0
		sb.content_margin_top = 7.0
		sb.content_margin_bottom = 7.0
		sb.bg_color = Color(1, 1, 1, 1)
		sb.border_color = C_LINE
		sb.set_border_width_all(1)
		match state:
			"hover":
				sb.bg_color = Color("#eef2f8")
			"pressed":
				sb.bg_color = Color("#dbe7fa")
				sb.border_color = C_ACCENT
			"focus":
				sb.border_color = C_ACCENT
				sb.set_border_width_all(2)
		b.add_theme_stylebox_override(state, sb)
	for key in ["font_color", "font_hover_color", "font_focus_color"]:
		b.add_theme_color_override(key, C_INK)
	b.add_theme_color_override("font_pressed_color", C_ACCENT)
	b.pressed.connect(on_press)
	return b


func _build_overlay() -> Control:
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.visible = false

	var scrim := ColorRect.new()
	scrim.color = C_SCRIM
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(scrim)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(centre)

	var panel := PanelContainer.new()
	var box_style := StyleBoxFlat.new()
	box_style.bg_color = C_PAGE
	box_style.set_corner_radius_all(16)
	box_style.content_margin_left = 34.0
	box_style.content_margin_right = 34.0
	box_style.content_margin_top = 26.0
	box_style.content_margin_bottom = 26.0
	panel.add_theme_stylebox_override("panel", box_style)
	centre.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)

	_overlay_text = Label.new()
	_overlay_text.add_theme_font_size_override("font_size", 30)
	_overlay_text.add_theme_color_override("font_color", C_INK)
	_overlay_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_overlay_text)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(_make_button("Next puzzle", _new_puzzle, false))
	box.add_child(row)
	return layer


# ── Puzzle flow ─────────────────────────────────────────────────────────────


func _new_puzzle() -> void:
	_pack_index += 1
	_puzzle = _library.take(_level, _pack_index)
	if _puzzle == null:
		# No pack, or none for this level. A live build is slower and not
		# guaranteed to have a single answer, but a game that starts beats a
		# blank screen.
		_puzzle = PipsGenerator.new(randi()).build(_level)
	_held = -1
	_facing = 0
	_moves = 0
	_started_msec = Time.get_ticks_msec()
	_overlay.visible = false
	_board.puzzle = _puzzle
	_board.reset_cursor()
	_tray.puzzle = _puzzle
	_refresh()
	_board.grab_focus()


func _choose_level(level: int) -> void:
	if level == _level:
		_refresh()
		return
	_level = level
	_new_puzzle()


func _clear_board() -> void:
	if _puzzle == null:
		return
	_puzzle.clear_board()
	_held = -1
	_refresh()
	_board.grab_focus()


func _rotate_held() -> void:
	_facing = (_facing + 1) % 4
	_refresh()
	_board.grab_focus()


func _on_tray_chosen(index: int) -> void:
	if _puzzle == null or index < 0 or index >= _puzzle.tray.size():
		return
	# Tapping the bone already in hand turns it, which is how Pips behaves and
	# saves a trip to the Turn button.
	if _held == index:
		_facing = (_facing + 1) % 4
	else:
		_held = index
	_refresh()


## A tap on the board: place what is in hand, or take back what is already there.
func _on_cell_activated(cell: Vector2i) -> void:
	if _puzzle == null:
		return
	if _puzzle.placed.has(cell):
		_lift(cell)
		return
	if _held < 0:
		_say("Pick a domino from below first.")
		return
	_place_at(cell)


func _place_at(cell: Vector2i) -> void:
	var target: Vector2i = cell + _step()
	if not _puzzle.can_place(cell, target):
		# Turning it for them would be worse: a domino that silently faces
		# somewhere other than the preview is how a child loses track of what
		# they are holding.
		_say("It will not fit that way — press R to turn it.")
		return
	var bone: Vector2i = _puzzle.tray[_held]
	# `_facing` 2 and 3 point back the way, which place() expresses as a flip.
	var flipped: bool = _facing >= 2
	if _puzzle.place(bone, cell, target, flipped) == 0:
		return
	_moves += 1
	_held = mini(_held, _puzzle.tray.size() - 1)
	if _puzzle.tray.is_empty():
		_held = -1
	_after_change()


func _lift_at_cursor() -> void:
	if _puzzle != null:
		_lift(_board.cursor)


func _lift(cell: Vector2i) -> void:
	if not _puzzle.placed.has(cell):
		return
	_puzzle.lift(cell)
	_moves += 1
	_after_change()


func _after_change() -> void:
	_refresh()
	if _puzzle.is_solved():
		_finish()


func _step() -> Vector2i:
	match _facing:
		0: return Vector2i(1, 0)
		1: return Vector2i(0, 1)
		2: return Vector2i(-1, 0)
		_: return Vector2i(0, -1)


func _finish() -> void:
	var seconds: int = int(round(float(Time.get_ticks_msec() - _started_msec) / 1000.0))
	_overlay_text.text = "Solved!\n\n%s · %d moves · %ds" % [
			LEVEL_NAMES[_level], _moves, seconds]
	_overlay.visible = true
	for child in _overlay.get_children():
		if child is CenterContainer:
			_focus_first(child)

	# The common schema: score is the number of dominoes placed, which is the
	# size of the puzzle solved. Moves and difficulty ride along.
	Telemetry.report_result(Telemetry.RESULT_WIN, _puzzle.placements.size(), "dominoes", [
		["moves", _moves],
		["level", str(LEVEL_NAMES[_level]).to_lower()],
	])


func _focus_first(node: Node) -> void:
	for child in node.get_children():
		if child is Button:
			(child as Button).grab_focus()
			return
		_focus_first(child)


# ── Chrome ──────────────────────────────────────────────────────────────────


func _say(message: String) -> void:
	_hint.text = message


func _refresh() -> void:
	if _puzzle == null:
		return
	for level in _level_buttons.size():
		(_level_buttons[level] as Button).set_pressed_no_signal(level == _level)

	var left: int = _puzzle.tray.size()
	_title.text = "Pips — %s   ·   %d to place" % [LEVEL_NAMES[_level], left]

	_board.held_bone = Vector2i(-1, -1) if _held < 0 else _puzzle.tray[_held]
	_board.held_step = _step()
	_board.held_flipped = _facing >= 2
	_tray.held = _held
	_tray.facing = _facing
	_board.queue_redraw()
	_tray.queue_redraw()
	_refresh_rule_line()

	if _hint.text == "" or left == 0:
		_say("Fill every square. Each colour must obey its rule — ends need not match.")


## Spell out the rule under the cursor. The symbol on the board is terse by
## design; this is where a child finds out what "≠" means without being told
## once at the start and expected to remember.
func _refresh_rule_line() -> void:
	if _puzzle == null:
		return
	var index: int = _puzzle.region_of(_board.cursor)
	if index < 0:
		_rule_line.text = ""
		return
	var region: Dictionary = _puzzle.regions[index]
	var text: String = PipsPuzzle.rule_help(int(region["rule"]), int(region["value"]))
	var status: int = _puzzle.region_status(index)
	var mark: String = ""
	if status == PipsPuzzle.Status.SATISFIED:
		mark = "  ✓"
	elif status == PipsPuzzle.Status.VIOLATED:
		mark = "  ✗"
	_rule_line.text = "This colour %s%s" % [text, mark]


func _unhandled_input(event: InputEvent) -> void:
	if _puzzle != null and event is InputEventKey and (event as InputEventKey).pressed:
		match (event as InputEventKey).keycode:
			KEY_R:
				get_viewport().set_input_as_handled()
				_rotate_held()
				return
			KEY_BACKSPACE, KEY_DELETE:
				get_viewport().set_input_as_handled()
				_lift_at_cursor()
				return
			KEY_TAB:
				# Cycle the held bone without leaving the board.
				if not _puzzle.tray.is_empty():
					get_viewport().set_input_as_handled()
					_held = posmod(_held + 1, _puzzle.tray.size())
					_refresh()
					return
	super._unhandled_input(event)


# ── The board ───────────────────────────────────────────────────────────────


## Regions, placed dominoes, and the cursor. Draw and input only: every
## question of legality goes to the puzzle.
class BoardView extends Control:
	signal cell_activated(cell: Vector2i)
	signal cursor_moved()

	var puzzle: PipsPuzzle
	var cursor: Vector2i = Vector2i.ZERO
	var held_bone: Vector2i = Vector2i(-1, -1)
	var held_step: Vector2i = Vector2i(1, 0)
	var held_flipped: bool = false

	var _cell: float = 0.0
	var _origin: Vector2 = Vector2.ZERO
	var _min: Vector2i = Vector2i.ZERO
	var _max: Vector2i = Vector2i.ZERO
	## Colour per region, chosen so no two touching regions share one.
	var _colours: Array = []
	var _coloured_for: int = -1

	func _ready() -> void:
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)

	## Greedy graph colouring, so neighbouring regions never come out the same
	## shade. Without it the palette repeats at random and two touching regions
	## can look like one — hiding the very boundary the player is reading.
	func _assign_colours() -> void:
		if puzzle == null or _coloured_for == puzzle.regions.size():
			return
		_coloured_for = puzzle.regions.size()
		var neighbours: Array = []
		for i in puzzle.regions.size():
			neighbours.append({})
		for cell in puzzle.cells.keys():
			var here: int = puzzle.region_of(cell)
			for step in [Vector2i(1, 0), Vector2i(0, 1)]:
				var other: int = puzzle.region_of(cell + step)
				if other >= 0 and other != here:
					(neighbours[here] as Dictionary)[other] = true
					(neighbours[other] as Dictionary)[here] = true

		_colours.clear()
		_colours.resize(puzzle.regions.size())
		for i in puzzle.regions.size():
			_colours[i] = -1
		for i in puzzle.regions.size():
			var taken := {}
			for other in (neighbours[i] as Dictionary).keys():
				if int(_colours[other]) >= 0:
					taken[int(_colours[other])] = true
			var pick: int = 0
			while taken.has(pick) and pick < REGION_COLOURS.size() - 1:
				pick += 1
			_colours[i] = pick

	func colour_of(index: int) -> Color:
		if index < 0 or index >= _colours.size():
			return REGION_COLOURS[0]
		return REGION_COLOURS[int(_colours[index]) % REGION_COLOURS.size()]

	func reset_cursor() -> void:
		if puzzle == null or puzzle.cells.is_empty():
			return
		var best: Vector2i = puzzle.cells.keys()[0]
		for c in puzzle.cells.keys():
			if c.y < best.y or (c.y == best.y and c.x < best.x):
				best = c
		cursor = best
		cursor_moved.emit()

	## Fit the board to the pane. Recomputed per draw, which is cheap — the
	## board is a couple of dozen cells, not a chain of laid dominoes.
	func _measure() -> void:
		if puzzle == null or puzzle.cells.is_empty():
			return
		var first: bool = true
		for c in puzzle.cells.keys():
			if first:
				_min = c
				_max = c
				first = false
				continue
			_min = Vector2i(mini(_min.x, c.x), mini(_min.y, c.y))
			_max = Vector2i(maxi(_max.x, c.x), maxi(_max.y, c.y))
		var cols: int = _max.x - _min.x + 1
		var rows: int = _max.y - _min.y + 1
		# A little air, so the outer border is not flush with the pane.
		_cell = minf((size.x - 8.0) / float(cols), (size.y - 8.0) / float(rows))
		_cell = minf(_cell, 132.0)
		_origin = Vector2((size.x - _cell * float(cols)) * 0.5,
				(size.y - _cell * float(rows)) * 0.5)

	func rect_of(cell: Vector2i) -> Rect2:
		return Rect2(_origin + Vector2(float(cell.x - _min.x) * _cell,
				float(cell.y - _min.y) * _cell), Vector2(_cell, _cell))

	func cell_at(point: Vector2) -> Vector2i:
		if _cell <= 0.0:
			return Vector2i(-9999, -9999)
		var local: Vector2 = point - _origin
		return Vector2i(int(floor(local.x / _cell)) + _min.x,
				int(floor(local.y / _cell)) + _min.y)

	func _draw() -> void:
		if puzzle == null:
			return
		_measure()
		_assign_colours()
		_draw_regions()
		_draw_placed()
		# Rules are drawn AFTER the dominoes. A covered region still has to say
		# what it wants — that is what the player is checking their arithmetic
		# against, and hiding it once a cell is filled is exactly backwards.
		_draw_rules()
		_draw_preview()
		_draw_cursor()

	## Each region is a flat colour with its rule printed once, in the corner
	## of its top-left cell — the same place Pips prints it. A satisfied region
	## is tinted green and a broken one red, so the board answers "is this bit
	## right?" without the player checking arithmetic.
	func _draw_regions() -> void:
		for index in puzzle.regions.size():
			var region: Dictionary = puzzle.regions[index]
			var status: int = puzzle.region_status(index)
			var base: Color = colour_of(index)
			if status == PipsPuzzle.Status.SATISFIED:
				base = base.lerp(C_GOOD, 0.30)
			elif status == PipsPuzzle.Status.VIOLATED:
				base = base.lerp(C_BAD, 0.34)

			var members: Array = region["cells"]
			for cell in members:
				draw_rect(rect_of(cell), base, true)
			# Draw only the edges that face OUT of the region, so a region reads
			# as one shape rather than a grid of separate squares.
			for cell in members:
				var r: Rect2 = rect_of(cell)
				for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if puzzle.region_of(cell + step) == index:
						continue
					var a: Vector2 = r.position
					var b: Vector2 = r.position
					if step == Vector2i(1, 0):
						a = Vector2(r.end.x, r.position.y); b = r.end
					elif step == Vector2i(-1, 0):
						a = r.position; b = Vector2(r.position.x, r.end.y)
					elif step == Vector2i(0, 1):
						a = Vector2(r.position.x, r.end.y); b = r.end
					else:
						a = r.position; b = Vector2(r.end.x, r.position.y)
					draw_line(a, b, base.darkened(0.34), 2.0, true)



	func _draw_rules() -> void:
		for index in puzzle.regions.size():
			_draw_rule(index)

	func _draw_rule(index: int) -> void:
		var region: Dictionary = puzzle.regions[index]
		var members: Array = region["cells"]
		var status: int = puzzle.region_status(index)
		var text: String = PipsPuzzle.rule_text(int(region["rule"]), int(region["value"]))
		if text == "":
			return
		var anchor: Vector2i = members[0]
		for cell in members:
			if cell.y < anchor.y or (cell.y == anchor.y and cell.x < anchor.x):
				anchor = cell
		var font: Font = get_theme_default_font()
		if font == null:
			font = ThemeDB.fallback_font
		var fs: int = int(clampf(_cell * 0.30, 11.0, 26.0))
		var r: Rect2 = rect_of(anchor)
		var colour: Color = C_INK
		if status == PipsPuzzle.Status.VIOLATED:
			colour = C_BAD.darkened(0.15)
		elif status == PipsPuzzle.Status.SATISFIED:
			colour = C_GOOD.darkened(0.35)

		# A chip behind it, because the label now sits over white dominoes as
		# well as over the region's own colour.
		var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var chip := Rect2(r.position + Vector2(3.0, 3.0),
				Vector2(width + 9.0, float(fs) + 6.0))
		var back: Color = colour_of(index)
		if status == PipsPuzzle.Status.SATISFIED:
			back = back.lerp(C_GOOD, 0.30)
		elif status == PipsPuzzle.Status.VIOLATED:
			back = back.lerp(C_BAD, 0.34)
		DominoPainter.fill_round(self, chip, 5.0, Color(back, 0.94))
		draw_string(font, chip.position + Vector2(5.0, float(fs) + 1.0), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, colour)

	func _draw_placed() -> void:
		var drawn := {}
		for cell in puzzle.placed.keys():
			var entry: Dictionary = puzzle.placed[cell]
			var id: int = int(entry["id"])
			if drawn.has(id):
				continue
			drawn[id] = true
			var partner: Vector2i = entry["partner"]
			var a: Rect2 = rect_of(cell)
			var b: Rect2 = rect_of(partner)
			var span: Rect2 = a.merge(b)
			var inset: float = _cell * 0.07
			span = span.grow(-inset)
			var vertical: bool = partner.x == cell.x
			# merge() loses which half is which, so pass the values in the
			# order they lie: top/left first.
			var first: Vector2i = cell if (cell.y < partner.y or cell.x < partner.x) else partner
			var second: Vector2i = partner if first == cell else cell
			DominoPainter.draw_bone(self, span, puzzle.value_at(first),
					puzzle.value_at(second), vertical, C_BONE, C_PIP, C_BONE_EDGE, 2.0)

	## A ghost of what tapping here would do. Green when it fits, red when it
	## does not, so the answer is visible before the tap rather than after it.
	func _draw_preview() -> void:
		if not puzzle.has_cell(cursor):
			return
		# Over a domino already down, a tap TAKES IT BACK — so saying "cannot
		# place here" in red would describe the wrong action entirely.
		if puzzle.placed.has(cursor):
			var entry: Dictionary = puzzle.placed[cursor]
			var span: Rect2 = rect_of(cursor).merge(rect_of(entry["partner"]))
			draw_rect(span.grow(-_cell * 0.05), Color(C_ACCENT, 0.16), true)
			draw_rect(span.grow(-_cell * 0.05), C_ACCENT, false, 2.0, true)
			return
		if held_bone.x < 0:
			return
		var target: Vector2i = cursor + held_step
		var fits: bool = puzzle.can_place(cursor, target)
		var a: Rect2 = rect_of(cursor)
		if not fits:
			draw_rect(a.grow(-3.0), Color(C_BAD, 0.30), true)
			draw_rect(a.grow(-3.0), C_BAD, false, 2.0, true)
			return
		var span: Rect2 = a.merge(rect_of(target)).grow(-_cell * 0.07)
		var vertical: bool = target.x == cursor.x
		var low: int = held_bone.y if held_flipped else held_bone.x
		var high: int = held_bone.x if held_flipped else held_bone.y
		# The painter draws top/left first, so swap when pointing back.
		if held_step.x < 0 or held_step.y < 0:
			var t: int = low
			low = high
			high = t
		DominoPainter.draw_bone(self, span, low, high, vertical,
				Color(C_BONE, 0.72), Color(C_PIP, 0.65), C_ACCENT, 2.0)
		draw_rect(span, C_ACCENT, false, 2.0, true)

	func _draw_cursor() -> void:
		if not has_focus() or not puzzle.has_cell(cursor):
			return
		draw_rect(rect_of(cursor).grow(-2.0), C_ACCENT, false, 3.0, true)

	func _gui_input(event: InputEvent) -> void:
		if puzzle == null:
			return
		if event is InputEventMouseButton:
			var mb: InputEventMouseButton = event
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				var cell: Vector2i = cell_at(mb.position)
				if puzzle.has_cell(cell):
					cursor = cell
					grab_focus()
					cursor_moved.emit()
					cell_activated.emit(cell)
					accept_event()
		elif event is InputEventMouseMotion:
			var hovered: Vector2i = cell_at((event as InputEventMouseMotion).position)
			if puzzle.has_cell(hovered) and hovered != cursor:
				cursor = hovered
				cursor_moved.emit()
				queue_redraw()
		elif event is InputEventKey and (event as InputEventKey).pressed:
			var step := Vector2i.ZERO
			match (event as InputEventKey).keycode:
				KEY_LEFT: step = Vector2i(-1, 0)
				KEY_RIGHT: step = Vector2i(1, 0)
				KEY_UP: step = Vector2i(0, -1)
				KEY_DOWN: step = Vector2i(0, 1)
				KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
					cell_activated.emit(cursor)
					accept_event()
					return
			if step != Vector2i.ZERO:
				# Skip over holes, so an irregular board still steers sensibly.
				var probe: Vector2i = cursor + step
				for _i in 8:
					if puzzle.has_cell(probe):
						cursor = probe
						cursor_moved.emit()
						queue_redraw()
						break
					probe += step
				accept_event()


# ── The tray ────────────────────────────────────────────────────────────────


## The dominoes still to place. Pips keeps them under the board, and so does
## this; the one in hand is lifted and outlined.
class TrayView extends Control:
	signal bone_chosen(index: int)

	var puzzle: PipsPuzzle
	var held: int = -1
	var facing: int = 0
	var _rects: Array = []

	func _ready() -> void:
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)

	func _layout() -> void:
		_rects.clear()
		if puzzle == null or puzzle.tray.is_empty():
			return
		var count: int = puzzle.tray.size()
		var gap: float = 8.0
		# Wrap into rows rather than shrinking to nothing: sixteen bones on a
		# narrow screen would otherwise become unreadable slivers.
		var per_row: int = count
		var long: float = 0.0
		while per_row > 0:
			long = minf(110.0, (size.x - gap * float(per_row - 1)) / float(per_row))
			var rows: int = int(ceil(float(count) / float(per_row)))
			var row_h: float = long / DominoPainter.ASPECT + gap
			if long >= 46.0 and float(rows) * row_h <= size.y:
				break
			per_row -= 1
		if per_row <= 0:
			per_row = count
			long = maxf(30.0, (size.x - gap * float(count - 1)) / float(count))
		var short: float = long / DominoPainter.ASPECT
		var rows2: int = int(ceil(float(count) / float(per_row)))
		var total_h: float = float(rows2) * (short + gap) - gap
		var top: float = (size.y - total_h) * 0.5
		for i in count:
			var row: int = i / per_row
			var col: int = i % per_row
			var in_row: int = mini(per_row, count - row * per_row)
			var row_w: float = float(in_row) * long + gap * float(in_row - 1)
			var x: float = (size.x - row_w) * 0.5 + float(col) * (long + gap)
			_rects.append(Rect2(Vector2(x, top + float(row) * (short + gap)),
					Vector2(long, short)))

	func _draw() -> void:
		_layout()
		if puzzle == null:
			return
		for i in _rects.size():
			var bone: Vector2i = puzzle.tray[i]
			var rect: Rect2 = _rects[i]
			var chosen: bool = i == held
			if chosen:
				rect.position.y -= 5.0
			var vertical: bool = facing % 2 == 1 and chosen
			var low: int = bone.x
			var high: int = bone.y
			if chosen and facing >= 2:
				low = bone.y
				high = bone.x
			# Show the bone the way it will land, so the tray and the ghost on
			# the board never disagree about which half goes where.
			var draw_rect_for: Rect2 = rect
			if vertical:
				var side: float = rect.size.y
				draw_rect_for = Rect2(rect.position + Vector2((rect.size.x - side) * 0.5, 0.0),
						Vector2(side, rect.size.y))
			DominoPainter.draw_bone(self, draw_rect_for, low, high, false,
					C_BONE, C_PIP, C_BONE_EDGE, 2.0)
			if chosen:
				draw_rect(rect.grow(4.0), C_ACCENT, false, 3.0, true)
			elif has_focus() and held < 0 and i == 0:
				draw_rect(rect.grow(4.0), Color(C_ACCENT, 0.4), false, 2.0, true)

	func _gui_input(event: InputEvent) -> void:
		if puzzle == null:
			return
		if event is InputEventMouseButton:
			var mb: InputEventMouseButton = event
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				for i in _rects.size():
					if (_rects[i] as Rect2).grow(5.0).has_point(mb.position):
						grab_focus()
						bone_chosen.emit(i)
						accept_event()
						return
		elif event is InputEventKey and (event as InputEventKey).pressed:
			var count: int = puzzle.tray.size()
			if count == 0:
				return
			match (event as InputEventKey).keycode:
				KEY_LEFT:
					bone_chosen.emit(posmod(maxi(held, 0) - 1, count))
					accept_event()
				KEY_RIGHT:
					bone_chosen.emit(posmod(maxi(held, 0) + 1, count))
					accept_event()
				KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
					bone_chosen.emit(maxi(held, 0))
					accept_event()
