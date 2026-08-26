extends QGameRoot

## Memory Match — code-first UI over MemoryBoard (src/board.gd).
## Both input paths work: tap/click a card, or move focus with
## ui_up/down/left/right and flip with ui_accept.

const COLS: int = MemoryBoard.COLS
const ROWS: int = MemoryBoard.ROWS
const CARD_GAP: float = 12.0
const HUD_MARGIN: float = 14.0
const HUD_FONT_SIZE: int = 20
const HUD_FONT_MIN: int = 11
const FLIP_BACK_DELAY_SEC: float = 1.2

const C_BG: Color = Color(0.0980, 0.1373, 0.2353)
const C_HUD: Color = Color(0.6275, 0.7255, 0.9020)
const C_WIN: Color = Color(0.4706, 0.9412, 0.5098)
const C_PANEL_BG: Color = Color(0.0588, 0.0863, 0.1569, 0.9216)
const C_PANEL_LINE: Color = Color(0.2353, 0.3059, 0.4706)
const C_WIN_BG: Color = Color(0.0588, 0.1569, 0.1020, 0.9608)


## One card's view + interaction. Owns all colours needed to draw itself so
## nothing here depends on GDScript's outer-class-constant lookup rules.
class CardView:
	extends Control

	const C_BACK: Color = Color(0.1961, 0.3137, 0.6275)
	const C_BACK_BORDER: Color = Color(0.3137, 0.4510, 0.7843)
	const C_FRONT: Color = Color(0.9412, 0.9490, 0.9725)
	const C_MATCHED: Color = Color(0.2353, 0.6667, 0.3137)
	const C_MATCHED_SYM: Color = Color(1.0000, 1.0000, 1.0000)
	const FOCUS_RING: Color = Color(1.0000, 0.8824, 0.4706)
	const PAIR_COLORS: Array[Color] = [
		Color(0.8627, 0.2353, 0.2353), Color(0.2353, 0.5098, 0.8627), Color(0.2353, 0.7255, 0.3137), Color(0.9412, 0.7843, 0.1961),
		Color(0.8627, 0.4902, 0.1765), Color(0.6078, 0.2549, 0.8627), Color(0.1765, 0.7647, 0.7843), Color(0.8824, 0.3137, 0.6275),
	]

	signal flip_requested(index: int)

	var index: int = -1
	var pair: int = -1
	var face_up: bool = false
	var matched: bool = false
	var celebrate_t: float = -1.0


	func _ready() -> void:
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_entered.connect(func() -> void: queue_redraw())
		focus_exited.connect(func() -> void: queue_redraw())


	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
				accept_event()
				flip_requested.emit(index)
		elif event is InputEventScreenTouch:
			if event.pressed:
				accept_event()
				flip_requested.emit(index)
		elif event.is_action_pressed("ui_accept"):
			accept_event()
			flip_requested.emit(index)


	## Animate this card flipping face up (calm squash-flip).
	func reveal() -> void:
		var tw := create_tween()
		tw.tween_property(self, "scale", Vector2(0.05, 1.0), 0.09) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tw.tween_callback(func() -> void:
			face_up = true
			queue_redraw()
		)
		tw.tween_property(self, "scale", Vector2(1.0, 1.0), 0.09) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


	## Animate this card flipping back face down.
	func play_flip_back_anim() -> void:
		var tw := create_tween()
		tw.tween_property(self, "scale", Vector2(0.05, 1.0), 0.09) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tw.tween_callback(func() -> void:
			face_up = false
			queue_redraw()
		)
		tw.tween_property(self, "scale", Vector2(1.0, 1.0), 0.09) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


	## Soft celebration ripple once a pair is matched. Card is already face up.
	func play_match_anim() -> void:
		matched = true
		face_up = true
		celebrate_t = 0.0
		queue_redraw()
		var tw := create_tween()
		tw.tween_method(_set_celebrate_t, 0.0, 1.0, 0.9)
		tw.tween_callback(func() -> void:
			celebrate_t = -1.0
			queue_redraw()
		)


	func _set_celebrate_t(v: float) -> void:
		celebrate_t = v
		queue_redraw()


	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var br: float = maxf(6.0, size.x / 8.0)

		if matched:
			_draw_round_rect(r, br, C_MATCHED)
			var c: Vector2 = size / 2.0
			var hw: float = size.x / 5.0
			var pts := PackedVector2Array([
				Vector2(c.x - hw, c.y),
				Vector2(c.x - hw / 3.0, c.y + hw * 2.0 / 3.0),
				Vector2(c.x + hw, c.y - hw / 2.0),
			])
			draw_polyline(pts, C_MATCHED_SYM, maxf(3.0, size.x / 12.0), true)
		elif face_up:
			_draw_round_rect(r, br, C_FRONT)
			var col: Color = C_FRONT
			if pair >= 0 and pair < PAIR_COLORS.size():
				col = PAIR_COLORS[pair]
			draw_circle(size / 2.0, maxf(8.0, size.x / 3.0), col)
		else:
			_draw_round_rect(r, br, C_BACK)
			_draw_round_rect_border(r, br, C_BACK_BORDER, 3.0)
			var inner: Rect2 = r.grow(-size.x / 8.0)
			_draw_round_rect_border(inner, maxf(3.0, br - 4.0), C_BACK_BORDER, 2.0)

		if celebrate_t >= 0.0 and pair >= 0 and pair < PAIR_COLORS.size():
			var color: Color = PAIR_COLORS[pair]
			var max_r: float = size.length() * 0.65
			for lag in [0.0, 0.35]:
				var p: float = (celebrate_t - lag) / (1.0 - lag)
				if p <= 0.0:
					continue
				p = minf(p, 1.0)
				var ring_r: float = max_r * p
				var ring_w: float = maxf(1.0, 6.0 * (1.0 - p))
				if ring_r > 0.0:
					var ring_color := color
					ring_color.a = 1.0 - p * 0.6
					draw_circle(size / 2.0, ring_r, ring_color, false, ring_w, true)

		if has_focus() and QInput.wants_focus_ui():
			draw_rect(r.grow(4.0), FOCUS_RING, false, 3.0)


	func _draw_round_rect(rect: Rect2, radius: float, color: Color) -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = color
		sb.set_corner_radius_all(int(radius))
		draw_style_box(sb, rect)


	func _draw_round_rect_border(rect: Rect2, radius: float, color: Color, width: float) -> void:
		var sb := StyleBoxFlat.new()
		sb.draw_center = false
		sb.border_color = color
		sb.set_border_width_all(int(width))
		sb.set_corner_radius_all(int(radius))
		draw_style_box(sb, rect)


var board: MemoryBoard
var card_views: Array[CardView] = []
var hud_label: Label
var win_label: Label

var _first_index: int = -1
var _mismatch_gen: int = 0


func _game_ready() -> void:
	_build_ui()
	QInput.device_changed.connect(_on_device_changed)
	resized.connect(_on_resized)
	_restart()


func _build_ui() -> void:
	# The background is the viewport's CLEAR COLOUR, not a full-screen ColorRect.
	#
	# They look identical and cost wildly different amounts. A ColorRect is a
	# canvas item: every frame the GPU rasterises and alpha-blends one quad over
	# the whole window. A clear is free on a tile-based GPU — it just marks the
	# tile buffer, with no memory read at all. MEASURED on the Pi 4 (V3D 4.2,
	# 1920x1053 maximized, gl_compatibility): 38 ms/frame with the ColorRect,
	# 29 ms/frame with the clear colour. One full-screen quad was costing 9 ms,
	# a third of the frame, to draw a flat colour.
	#
	# project.godot sets the same colour so the frames before _ready() match.
	RenderingServer.set_default_clear_color(C_BG)

	for i in range(COLS * ROWS):
		var cv := CardView.new()
		cv.index = i
		cv.flip_requested.connect(_on_card_flip_requested)
		add_child(cv)
		card_views.append(cv)

	_wire_focus_neighbors()

	# Text is added AFTER the cards on purpose. Sibling order is draw order for
	# Controls, so the labels used to be painted first and then covered by any
	# card that overlapped them. Both also carry a filled StyleBox so they stay
	# readable over whatever they land on.
	hud_label = Label.new()
	hud_label.add_theme_color_override("font_color", C_HUD)
	hud_label.add_theme_font_size_override("font_size", HUD_FONT_SIZE)
	hud_label.add_theme_stylebox_override("normal", _panel_box(C_PANEL_BG, C_PANEL_LINE))
	hud_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud_label)

	win_label = Label.new()
	win_label.add_theme_color_override("font_color", C_WIN)
	win_label.add_theme_font_size_override("font_size", 36)
	win_label.add_theme_stylebox_override("normal", _panel_box(C_WIN_BG, C_WIN))
	win_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	win_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	win_label.visible = false
	win_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(win_label)


## Filled, rounded backing box so a label reads over cards rather than through
## them. Labels take a StyleBox under the "normal" theme item.
static func _panel_box(fill: Color, line: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = line
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb


## 4x4 grid, wrapped at the edges — ui_up/down/left/right always lands on
## another card, no dead ends.
func _wire_focus_neighbors() -> void:
	for r in range(ROWS):
		for c in range(COLS):
			var idx: int = r * COLS + c
			var cv: CardView = card_views[idx]
			var up_idx: int = ((r - 1 + ROWS) % ROWS) * COLS + c
			var down_idx: int = ((r + 1) % ROWS) * COLS + c
			var left_idx: int = r * COLS + ((c - 1 + COLS) % COLS)
			var right_idx: int = r * COLS + ((c + 1) % COLS)
			cv.focus_neighbor_top = cv.get_path_to(card_views[up_idx])
			cv.focus_neighbor_bottom = cv.get_path_to(card_views[down_idx])
			cv.focus_neighbor_left = cv.get_path_to(card_views[left_idx])
			cv.focus_neighbor_right = cv.get_path_to(card_views[right_idx])


func _restart() -> void:
	_mismatch_gen += 1  # invalidate any pending mismatch-resolve await
	_first_index = -1
	board = MemoryBoard.new()  # seed 0 -> random deal
	win_label.visible = false

	for i in range(card_views.size()):
		var cv: CardView = card_views[i]
		cv.pair = board.cards[i].pair
		cv.face_up = false
		cv.matched = false
		cv.celebrate_t = -1.0
		cv.scale = Vector2.ONE
		cv.queue_redraw()

	_update_hud()
	_layout()
	if card_views.size() > 0:
		card_views[0].grab_focus()


func _on_resized() -> void:
	_layout()


func _layout() -> void:
	var sw: float = size.x
	var sh: float = size.y
	if sw <= 0.0 or sh <= 0.0:
		return

	var header_h: float = _layout_hud()

	var usable_w: float = sw - CARD_GAP * 2.0
	var usable_h: float = sh - header_h - CARD_GAP * 2.0
	var cw: float = (usable_w - CARD_GAP * (COLS - 1)) / COLS
	var ch: float = (usable_h - CARD_GAP * (ROWS - 1)) / ROWS
	var side: float = maxf(8.0, minf(cw, ch))

	var grid_w: float = side * COLS + CARD_GAP * (COLS - 1)
	var grid_h: float = side * ROWS + CARD_GAP * (ROWS - 1)
	var ox: float = (sw - grid_w) / 2.0
	var oy: float = header_h + (sh - header_h - grid_h) / 2.0

	for i in range(card_views.size()):
		var col: int = i % COLS
		var row: int = i / COLS
		var cv: CardView = card_views[i]
		cv.position = Vector2(ox + col * (side + CARD_GAP), oy + row * (side + CARD_GAP))
		cv.size = Vector2(side, side)
		cv.pivot_offset = cv.size / 2.0

	_layout_win()


## Size the HUD to its own text and centre it, so the backing box hugs the
## words instead of being a full-width bar. Returns the height the board must
## keep clear. Re-run whenever the text changes, not just on resize — the
## string grows as the move counter does.
func _layout_hud() -> float:
	var sw: float = size.x
	var avail: float = sw - HUD_MARGIN * 2.0
	var box: StyleBox = hud_label.get_theme_stylebox("normal")
	var pad: float = box.content_margin_left + box.content_margin_right
	var font: Font = hud_label.get_theme_font("font")

	# Measure the string directly and shrink the font until it fits. Asking a
	# Label for its minimum size while also driving its width is a feedback
	# loop; measuring the font is not.
	var fs: int = HUD_FONT_SIZE
	while fs > HUD_FONT_MIN and font.get_string_size(
			hud_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + pad > avail:
		fs -= 1
	hud_label.add_theme_font_size_override("font_size", fs)

	var want: Vector2 = hud_label.get_combined_minimum_size()
	want.x = minf(want.x, avail)
	hud_label.size = want
	hud_label.position = Vector2(roundf((sw - want.x) / 2.0), HUD_MARGIN)
	return HUD_MARGIN + want.y + HUD_MARGIN


func _layout_win() -> void:
	if win_label == null:
		return
	var want: Vector2 = win_label.get_combined_minimum_size()
	want.x = minf(want.x, maxf(64.0, size.x - HUD_MARGIN * 2.0))
	win_label.size = want
	win_label.position = ((size - want) / 2.0).round()


func _update_hud() -> void:
	hud_label.text = "Memory Match   ·   moves: %d   ·   matched: %d / %d   ·   R to restart" % [
		board.moves, board.matched_pairs, MemoryBoard.TOTAL_PAIRS,
	]
	if size.x > 0.0:
		_layout_hud()


func _on_device_changed(_device: String) -> void:
	for cv in card_views:
		if cv.has_focus():
			cv.queue_redraw()


func _on_card_flip_requested(idx: int) -> void:
	var result: String = board.flip(idx)
	match result:
		"ignored":
			pass
		"flipped":
			_first_index = idx
			card_views[idx].reveal()
		"match":
			var a: int = _first_index
			var b: int = idx
			_first_index = -1
			card_views[b].reveal()
			card_views[a].play_match_anim()
			card_views[b].play_match_anim()
			_update_hud()
			if board.is_won():
				_on_win()
		"mismatch":
			var a: int = _first_index
			var b: int = idx
			_first_index = -1
			card_views[b].reveal()
			_update_hud()
			_await_mismatch_resolve(a, b)


func _await_mismatch_resolve(a: int, b: int) -> void:
	var gen: int = _mismatch_gen
	await get_tree().create_timer(FLIP_BACK_DELAY_SEC).timeout
	if gen != _mismatch_gen:
		return  # a restart happened while we were waiting
	board.resolve_mismatch()
	card_views[a].play_flip_back_anim()
	card_views[b].play_flip_back_anim()


func _on_win() -> void:
	win_label.text = "You won in %d moves!  —  press R to play again" % board.moves
	win_label.visible = true
	_layout_win()
	# Common schema (result/score/score_unit/duration_s/ts) plus this game's
	# historical "moves" topic, which existing Home Assistant sensors read.
	Telemetry.report_result(Telemetry.RESULT_WIN, board.moves, "moves",
			[["moves", board.moves]])


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_restart()
