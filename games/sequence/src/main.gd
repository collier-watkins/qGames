class_name SequenceView
extends QGameRoot

## Sequence — code-first UI over SequenceRound (src/round.gd).
## Both input paths work: tap an option, or move focus with ui_left/right/up/
## down and choose with ui_accept.

const ROUND_SIZE: int = SequenceRound.ROUND_SIZE
const FEEDBACK_SEC: float = 1.4
const BTN_GAP: float = 18.0
## Redraw rate for the idle breathing animations. Fast enough to look smooth
## on a slow pulse, slow enough that a Pi is not repainting the board 60 times
## a second for it.
const PULSE_HZ: float = 20.0
const HUD_MARGIN: float = 14.0
const HUD_FONT_SIZE: int = 20
const HUD_FONT_MIN: int = 11

const C_BG: Color = Color(0.0863, 0.1176, 0.2039)
const C_CELL_BG: Color = Color(0.1490, 0.1961, 0.3216)
const C_CELL_BDR: Color = Color(0.2549, 0.3451, 0.5412)
const C_Q: Color = Color(0.7843, 0.8627, 0.2745)
const C_HUD: Color = Color(0.6275, 0.7255, 0.9020)
const C_PROMPT: Color = Color(0.5490, 0.6471, 0.8235)
const C_CORRECT: Color = Color(0.2157, 0.7647, 0.3137)
const C_WRONG: Color = Color(0.8039, 0.2157, 0.1765)
const C_STAR: Color = Color(0.9412, 0.7647, 0.1765)
const C_STAR_EMPTY: Color = Color(0.2157, 0.2667, 0.4118)
const C_PANEL_BG: Color = Color(0.0588, 0.0863, 0.1569, 0.9216)
const C_PANEL_LINE: Color = Color(0.2353, 0.3059, 0.4706)
const C_FOCUS: Color = Color(1.0000, 0.8824, 0.4706)

const ELEM_COLORS: Dictionary = {
	"red": Color(0.8627, 0.2353, 0.2353),
	"blue": Color(0.2353, 0.5098, 0.8627),
	"green": Color(0.2353, 0.7255, 0.3137),
	"yellow": Color(0.9412, 0.7843, 0.1961),
	"orange": Color(0.8627, 0.4902, 0.1765),
	"purple": Color(0.6078, 0.2549, 0.8627),
	"teal": Color(0.1765, 0.7647, 0.7843),
	"pink": Color(0.8824, 0.3137, 0.6275),
}


## Equal bounding boxes do NOT look equal. For a box of side S a square fills
## all of it, a circle 79%, an equilateral triangle 43%, a five-point star
## about 30% — so a star drawn "the same size" as a square reads as much
## smaller and a child stops treating them as the same kind of thing. These
## factors compensate part of the way: full compensation would make triangles
## and stars overflow their cells, so they are tuned by eye, not by area.
const SHAPE_SCALE: Dictionary = {
	"circle": 1.00,
	"square": 0.94,
	"triangle": 1.16,
	"star": 1.22,
}

## Fraction of a cell or button given over to the shape. One constant, used
## everywhere, so an element is the same size in the row and in the answer.
const SHAPE_FILL: float = 0.62


## Draws one [shape, colour] element. Shared by the sequence row, the option
## buttons and the answer reveal, so a shape looks identical everywhere.
static func draw_element(ci: CanvasItem, shape: String, colour: Color,
		centre: Vector2, size: float) -> void:
	size *= float(SHAPE_SCALE.get(shape, 1.0))
	var r: float = size / 2.0
	match shape:
		"circle":
			ci.draw_circle(centre, r, colour)
		"square":
			var sb := StyleBoxFlat.new()
			sb.bg_color = colour
			sb.set_corner_radius_all(int(maxf(2.0, size / 10.0)))
			ci.draw_style_box(sb, Rect2(centre - Vector2(r, r), Vector2(size, size)))
		"triangle":
			# Nudged down by an eighth of the height: an equilateral triangle
			# centred on its bounding box looks top-light and sits high next to
			# a circle, because its mass is in the lower half.
			var h: float = size * 0.866
			var c: Vector2 = centre + Vector2(0.0, h * 0.06)
			ci.draw_colored_polygon(PackedVector2Array([
				c + Vector2(0.0, -h / 2.0),
				c + Vector2(-r, h / 2.0),
				c + Vector2(r, h / 2.0),
			]), colour)
		"star":
			var inner: float = r * 0.42
			var pts := PackedVector2Array()
			for i in range(10):
				var a: float = -PI / 2.0 + i * PI / 5.0
				var rr: float = r if i % 2 == 0 else inner
				pts.append(centre + Vector2(cos(a) * rr, sin(a) * rr))
			ci.draw_colored_polygon(pts, colour)
		_:
			ci.draw_circle(centre, r, colour)


## Two shared StyleBoxFlat instances, mutated in place rather than allocated
## per call. The sequence row alone draws ~20 rounded rects a frame, and at 60
## fps that was ~1200 Resource allocations a second showing up as object churn
## in QDebug — for boxes that live only until draw_style_box() has read them.
static var _fill_box: StyleBoxFlat = null
static var _stroke_box: StyleBoxFlat = null


static func fill_round_rect(ci: CanvasItem, rect: Rect2, radius: float, colour: Color) -> void:
	if _fill_box == null:
		_fill_box = StyleBoxFlat.new()
	_fill_box.bg_color = colour
	_fill_box.set_corner_radius_all(int(radius))
	ci.draw_style_box(_fill_box, rect)


static func stroke_round_rect(ci: CanvasItem, rect: Rect2, radius: float,
		colour: Color, width: float) -> void:
	if _stroke_box == null:
		_stroke_box = StyleBoxFlat.new()
		_stroke_box.draw_center = false
	_stroke_box.border_color = colour
	_stroke_box.set_border_width_all(int(width))
	_stroke_box.set_corner_radius_all(int(radius))
	ci.draw_style_box(_stroke_box, rect)


## The visible run plus a trailing "?" cell. Pure drawing; no interaction.
class SequenceStrip:
	extends Control

	var elements: Array = []
	var reveal: Array = []          ## non-empty once answered — fills the ? cell
	var reveal_correct: bool = false
	var cell: float = 80.0
	var entrance: float = 1.0       ## 0 = just appeared, 1 = fully settled
	var reveal_t: float = 1.0       ## the answer dropping into the ? cell

	var _pulse: float = 0.0
	var _redraw_accum: float = 0.0

	## The ? cell breathes so the eye goes there first. Slow and shallow —
	## anything faster reads as urgency, which is the opposite of the mood.
	##
	## Redrawn at PULSE_HZ, not every frame. A 0.5 Hz breath does not need 60
	## redraws a second, and this whole row repaints on every one of them —
	## measured on this box, redrawing it per-frame doubled process CPU for an
	## animation nobody can see moving faster.
	func _process(delta: float) -> void:
		if not reveal.is_empty():
			return
		_pulse = fmod(_pulse + delta, TAU)
		_redraw_accum += delta
		if _redraw_accum >= 1.0 / SequenceView.PULSE_HZ:
			_redraw_accum = 0.0
			queue_redraw()

	## The answer landing in the ? cell. Ties the button that was pressed to
	## the place the sequence was leading, which is the thing being taught.
	func play_reveal() -> void:
		reveal_t = 0.0
		var tw := create_tween()
		tw.tween_method(func(v: float) -> void:
			reveal_t = v
			queue_redraw()
		, 0.0, 1.0, 0.30).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


	func play_entrance() -> void:
		entrance = 0.0
		var tw := create_tween()
		tw.tween_method(func(v: float) -> void:
			entrance = v
			queue_redraw()
		, 0.0, 1.0, 0.32).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	func _draw() -> void:
		var n: int = elements.size() + 1
		if n <= 1:
			return
		var gap: float = maxf(5.0, minf(14.0, size.x / maxf(1.0, float(n) * 9.0)))
		var total: float = n * cell + (n - 1) * gap
		var x: float = (size.x - total) / 2.0
		var cy: float = size.y / 2.0
		var br: float = maxf(4.0, cell / 8.0)

		for i in range(elements.size()):
			# Each cell lands slightly after the one before it, left to right,
			# which draws the eye along the sequence in reading order — the
			# order you have to read it in to spot the pattern.
			var lag: float = float(i) / maxf(1.0, float(n) * 1.6)
			var t: float = clampf((entrance - lag) / maxf(0.05, 1.0 - lag), 0.0, 1.0)
			if t <= 0.0:
				x += cell + gap
				continue
			var grow: float = 0.86 + 0.14 * t
			var c: float = cell * grow
			var rect := Rect2(Vector2(x + (cell - c) / 2.0, cy - c / 2.0), Vector2(c, c))
			var fade: Color = SequenceView.C_CELL_BG
			fade.a = t
			SequenceView.fill_round_rect(self, rect, br, fade)
			var edge: Color = SequenceView.C_CELL_BDR
			edge.a = t
			SequenceView.stroke_round_rect(self, rect, br, edge, maxf(2.0, c / 24.0))
			var tint: Color = SequenceView.ELEM_COLORS[elements[i][1]]
			tint.a = t
			SequenceView.draw_element(self, elements[i][0], tint,
					rect.get_center(), c * SequenceView.SHAPE_FILL)
			x += cell + gap

		# The question cell, or the answer once the round has moved on.
		var q_rect := Rect2(Vector2(x, cy - cell / 2.0), Vector2(cell, cell))
		SequenceView.fill_round_rect(self, q_rect, br, SequenceView.C_CELL_BG)
		if reveal.is_empty():
			var breathe: float = 0.5 + 0.5 * sin(_pulse * 2.0)
			var q_edge: Color = SequenceView.C_Q
			q_edge.a = 0.62 + 0.38 * breathe
			SequenceView.stroke_round_rect(self, q_rect, br, q_edge,
					maxf(3.0, cell / 16.0) * (0.9 + 0.2 * breathe))
			var font: Font = get_theme_default_font()
			var fs: int = int(clampf(cell * 0.62, 14.0, 52.0))
			var text := "?"
			var tw: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			draw_string(font, q_rect.get_center() + Vector2(-tw.x / 2.0, tw.y / 3.0),
					text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, SequenceView.C_Q)
		else:
			var edge: Color = SequenceView.C_CORRECT if reveal_correct else SequenceView.C_WRONG
			SequenceView.stroke_round_rect(self, q_rect, br, edge, maxf(3.0, cell / 16.0))
			var pop: float = 0.55 + 0.45 * reveal_t
			SequenceView.draw_element(self, reveal[0], SequenceView.ELEM_COLORS[reveal[1]],
					q_rect.get_center(), cell * SequenceView.SHAPE_FILL * pop)


## One tappable answer. Focusable, so the d-pad path is free.
##
## Every state change is animated, because the whole point of the game is
## cause and effect: a three year old needs to see that their tap did
## something, immediately, before the answer is even judged.
class AnswerButton:
	extends Control

	signal chosen(index: int)

	var index: int = -1
	var element: Array = []
	var state: String = "idle"      ## "idle" | "correct" | "wrong" | "missed"
	var locked: bool = false

	var _hovered: bool = false
	var _held: bool = false
	var _ring_t: float = -1.0       ## celebration ring progress, -1 = inactive
	var _home: Vector2 = Vector2.ZERO
	var _shake: float = 0.0
	var _anim: Tween = null

	func _ready() -> void:
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)
		mouse_entered.connect(_on_hover.bind(true))
		mouse_exited.connect(_on_hover.bind(false))

	func _on_hover(inside: bool) -> void:
		_hovered = inside
		if not locked:
			_scale_to(1.04 if inside else 1.0, 0.12)
		queue_redraw()

	## Cancels any in-flight tween first. Without this a fast tap during the
	## hover tween leaves two tweens fighting over `scale` and the button ends
	## up stuck at some arbitrary size.
	func _scale_to(target: float, secs: float) -> void:
		if _anim != null and _anim.is_valid():
			_anim.kill()
		pivot_offset = size / 2.0
		_anim = create_tween()
		_anim.tween_property(self, "scale", Vector2(target, target), secs) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

	func _gui_input(event: InputEvent) -> void:
		if locked:
			return
		var down: bool = false
		var up: bool = false
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			down = event.pressed
			up = not event.pressed
		elif event is InputEventScreenTouch:
			down = event.pressed
			up = not event.pressed
		elif event.is_action_pressed("ui_accept"):
			accept_event()
			_press_and_choose()
			return

		if down:
			accept_event()
			_held = true
			_scale_to(0.92, 0.07)
			queue_redraw()
		elif up and _held:
			accept_event()
			_held = false
			_press_and_choose()

	## Springs back past 1.0 before settling, so the release reads as a bounce
	## rather than a snap.
	func _press_and_choose() -> void:
		if _anim != null and _anim.is_valid():
			_anim.kill()
		pivot_offset = size / 2.0
		_anim = create_tween()
		_anim.tween_property(self, "scale", Vector2(1.10, 1.10), 0.09) \
				.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_anim.tween_property(self, "scale", Vector2.ONE, 0.11) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		chosen.emit(index)

	## Correct: a pop plus an expanding ring. The ring is drawn rather than
	## scaled so it can spill outside the button's own rect.
	func play_correct() -> void:
		if _anim != null and _anim.is_valid():
			_anim.kill()
		pivot_offset = size / 2.0
		_anim = create_tween()
		_anim.tween_property(self, "scale", Vector2(1.16, 1.16), 0.13) \
				.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_anim.tween_property(self, "scale", Vector2.ONE, 0.20) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		var ring := create_tween()
		ring.tween_method(_set_ring, 0.0, 1.0, 0.55)
		ring.tween_callback(func() -> void:
			_ring_t = -1.0
			queue_redraw()
		)

	## Wrong: a short horizontal shake. Deliberately small and quick — this is
	## a calm game, and a four year old getting one wrong should not feel
	## punished.
	func play_wrong() -> void:
		if _anim != null and _anim.is_valid():
			_anim.kill()
		var amp: float = maxf(4.0, size.x * 0.055)
		_anim = create_tween()
		# Tweening `position` directly would strand the button if the window
		# were resized mid-shake: the tween would keep driving toward a home
		# captured before the relayout. Offsetting from the live `_home`, which
		# _layout() keeps current, means a resize just moves the shake with it.
		for offset in [amp, -amp * 0.8, amp * 0.5, -amp * 0.25, 0.0]:
			_anim.tween_method(_set_shake, _shake, offset, 0.055) \
					.set_trans(Tween.TRANS_SINE)

	func _set_shake(v: float) -> void:
		_shake = v
		position = _home + Vector2(_shake, 0.0)

	func _set_ring(v: float) -> void:
		_ring_t = v
		queue_redraw()

	func _draw() -> void:
		if element.is_empty():
			return
		var rect := Rect2(Vector2.ZERO, size)
		var br: float = maxf(4.0, size.x / 8.0)

		var bg: Color = SequenceView.C_CELL_BG
		if _held:
			bg = SequenceView.C_CELL_BG.darkened(0.15)
		elif _hovered and not locked:
			bg = SequenceView.C_CELL_BG.lightened(0.12)
		SequenceView.fill_round_rect(self, rect, br, bg)

		var edge: Color = SequenceView.C_CELL_BDR
		var w: float = maxf(2.0, size.x / 24.0)
		match state:
			"correct":
				edge = SequenceView.C_CORRECT
				w = maxf(4.0, size.x / 12.0)
			"wrong":
				edge = SequenceView.C_WRONG
				w = maxf(4.0, size.x / 12.0)
			"missed":
				# The right answer, shown after a wrong pick — dimmer than a win
				# so it reads as "this was it", not "you got it".
				edge = SequenceView.C_CORRECT.darkened(0.35)
				w = maxf(3.0, size.x / 16.0)
		SequenceView.stroke_round_rect(self, rect, br, edge, w)

		var tint: Color = SequenceView.ELEM_COLORS[element[1]]
		if state == "missed":
			tint = tint.darkened(0.15)
		SequenceView.draw_element(self, element[0], tint,
				size / 2.0, size.x * SequenceView.SHAPE_FILL)

		if _ring_t >= 0.0:
			# Starts at the button's own edge and travels outward. Starting at
			# zero draws a shrinking-looking disc over the shape for the first
			# few frames, which reads as a second object rather than a pulse.
			var ring_r: float = lerpf(size.x * 0.5, size.length() * 0.62, _ring_t)
			var ring_c: Color = SequenceView.C_CORRECT
			ring_c.a = 1.0 - _ring_t * 0.85
			draw_circle(size / 2.0, ring_r, ring_c, false,
					maxf(1.5, 7.0 * (1.0 - _ring_t)), true)

		# A square ring around a rounded button is the kind of detail that reads
		# as "unfinished" without anyone being able to say why.
		if has_focus() and QInput.wants_focus_ui():
			SequenceView.stroke_round_rect(self, rect.grow(5.0), br + 5.0,
					SequenceView.C_FOCUS, 3.0)


## Ten segments: answered ones green/red, the current one outlined and
## breathing in time with the question cell.
class ProgressStrip:
	extends Control

	var results: Array[bool] = []
	var current: int = 0
	var finished: bool = false

	var _pulse: float = 0.0
	var _redraw_accum: float = 0.0
	var _landing: int = -1       ## index of the segment currently animating in
	var _land_t: float = 1.0

	func _process(delta: float) -> void:
		if finished:
			return
		_pulse = fmod(_pulse + delta, TAU)
		_redraw_accum += delta
		if _redraw_accum >= 1.0 / SequenceView.PULSE_HZ:
			_redraw_accum = 0.0
			queue_redraw()

	## Call after appending a result: the new segment drops in at double size
	## so the player sees where their answer went.
	func play_land(index: int) -> void:
		_landing = index
		_land_t = 0.0
		var tw := create_tween()
		tw.tween_method(func(v: float) -> void:
			_land_t = v
			queue_redraw()
		, 0.0, 1.0, 0.34).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	func _draw() -> void:
		# Bigger than the old 22 px cap: this is the only record of how the
		# round is going, and at 22 px the red/green is a smear from sofa
		# distance on a TV.
		var seg: float = clampf((size.x - 9.0 * 6.0) / float(ROUND_SIZE), 12.0, 30.0)
		var gap: float = clampf((size.x - ROUND_SIZE * seg) / float(ROUND_SIZE - 1), 4.0, 9.0)
		var total: float = ROUND_SIZE * seg + (ROUND_SIZE - 1) * gap
		var x: float = (size.x - total) / 2.0
		var cy: float = size.y / 2.0
		var br: float = maxf(2.0, seg / 4.0)
		for i in range(ROUND_SIZE):
			var s: float = seg
			if i == _landing and _land_t < 1.0:
				s = seg * (1.0 + 0.55 * (1.0 - _land_t))
			var rect := Rect2(Vector2(x + (seg - s) / 2.0, cy - s / 2.0), Vector2(s, s))
			if i < results.size():
				SequenceView.fill_round_rect(self, rect, br,
						SequenceView.C_CORRECT if results[i] else SequenceView.C_WRONG)
			elif i == current and not finished:
				var breathe: float = 0.5 + 0.5 * sin(_pulse * 2.0)
				var edge: Color = SequenceView.C_Q
				edge.a = 0.55 + 0.45 * breathe
				SequenceView.fill_round_rect(self, rect, br, SequenceView.C_CELL_BG)
				SequenceView.stroke_round_rect(self, rect, br, edge, maxf(1.5, seg / 7.0))
			else:
				SequenceView.fill_round_rect(self, rect, br, SequenceView.C_CELL_BG)
				SequenceView.stroke_round_rect(self, rect, br, SequenceView.C_CELL_BDR, 1.0)
			x += seg + gap


## Three stars, filled by score.
class StarRow:
	extends Control

	var filled: int = 0

	func _draw() -> void:
		var r: float = minf(size.y / 2.0, size.x / 7.0)
		var gap: float = r * 0.6
		var total: float = 3.0 * (r * 2.0) + 2.0 * gap
		var x: float = (size.x - total) / 2.0 + r
		for i in range(3):
			SequenceView.draw_element(self, "star",
					SequenceView.C_STAR if i < filled else SequenceView.C_STAR_EMPTY,
					Vector2(x, size.y / 2.0), r * 2.0)
			x += r * 2.0 + gap


var round_model: SequenceRound
var strip: SequenceStrip
var progress: ProgressStrip
var options: Array[AnswerButton] = []
var hud_label: Label
var prompt_label: Label
var over_panel: PanelContainer
var over_message: Label
var over_score: Label
var stars_row: StarRow
var play_again: Button

var _feedback_gen: int = 0


func _game_ready() -> void:
	_build_ui()
	QInput.device_changed.connect(_on_device_changed)
	resized.connect(_layout)
	_restart()


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

	strip = SequenceStrip.new()
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(strip)

	progress = ProgressStrip.new()
	progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(progress)

	for i in range(SequenceRound.OPTION_COUNT):
		var ob := AnswerButton.new()
		ob.index = i
		ob.chosen.connect(_on_option_chosen)
		add_child(ob)
		options.append(ob)
	_wire_focus_neighbors()

	prompt_label = Label.new()
	prompt_label.text = "What comes next?"
	prompt_label.add_theme_color_override("font_color", C_PROMPT)
	prompt_label.add_theme_font_size_override("font_size", 18)
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(prompt_label)

	# Text last so it draws in front of the cells, with a backing box — the
	# same defect the memory game had.
	hud_label = Label.new()
	hud_label.add_theme_color_override("font_color", C_HUD)
	hud_label.add_theme_font_size_override("font_size", HUD_FONT_SIZE)
	hud_label.add_theme_stylebox_override("normal", _panel_box(C_PANEL_BG, C_PANEL_LINE))
	hud_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud_label)

	_build_over_panel()


func _build_over_panel() -> void:
	over_panel = PanelContainer.new()
	over_panel.add_theme_stylebox_override("panel", _panel_box(Color(0.0588, 0.0863, 0.1569), C_STAR))
	over_panel.visible = false
	add_child(over_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	over_panel.add_child(box)

	over_message = Label.new()
	over_message.add_theme_color_override("font_color", C_STAR)
	over_message.add_theme_font_size_override("font_size", 34)
	over_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(over_message)

	stars_row = StarRow.new()
	stars_row.custom_minimum_size = Vector2(220.0, 64.0)
	box.add_child(stars_row)

	over_score = Label.new()
	over_score.add_theme_color_override("font_color", C_HUD)
	over_score.add_theme_font_size_override("font_size", 20)
	over_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(over_score)

	play_again = Button.new()
	play_again.text = "Play again"
	play_again.add_theme_font_size_override("font_size", 22)
	play_again.pressed.connect(_restart)
	box.add_child(play_again)


static func _panel_box(fill: Color, line: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = line
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	return sb


## 2x2 grid, wrapped, so the d-pad never lands on a dead end.
func _wire_focus_neighbors() -> void:
	for i in range(options.size()):
		var col: int = i % 2
		var row: int = i / 2
		var left: int = row * 2 + (1 - col)
		var up: int = ((row + 1) % 2) * 2 + col
		options[i].focus_neighbor_left = options[i].get_path_to(options[left])
		options[i].focus_neighbor_right = options[i].get_path_to(options[left])
		options[i].focus_neighbor_top = options[i].get_path_to(options[up])
		options[i].focus_neighbor_bottom = options[i].get_path_to(options[up])


func _restart() -> void:
	_feedback_gen += 1
	round_model = SequenceRound.new()
	over_panel.visible = false
	_show_question()


func _show_question() -> void:
	strip.elements = round_model.visible
	strip.reveal = []
	strip.queue_redraw()
	strip.play_entrance()
	progress.results = round_model.results
	progress.current = round_model.asked
	progress.finished = false
	progress.queue_redraw()
	prompt_label.visible = true
	strip.visible = true

	for i in range(options.size()):
		options[i].element = round_model.options[i]
		options[i].state = "idle"
		options[i].locked = false
		options[i].visible = true
		options[i].queue_redraw()

	_update_hud()
	_layout()
	if options.size() > 0:
		options[0].grab_focus()


func _update_hud() -> void:
	if round_model.is_over():
		hud_label.text = "Sequence   ·   R to play again"
	else:
		hud_label.text = "Sequence   ·   %d / %d   ·   R to restart" % [
			round_model.asked, ROUND_SIZE,
		]
	if size.x > 0.0:
		_layout_hud()


func _on_option_chosen(index: int) -> void:
	if round_model.is_over():
		return
	var chosen_elem: Array = round_model.options[index]
	var correct_elem: Array = round_model.answer
	var right: bool = round_model.answer_with(index)

	for ob in options:
		ob.locked = true
	options[index].state = "correct" if right else "wrong"
	if right:
		options[index].play_correct()
	else:
		options[index].play_wrong()
		for ob in options:
			if ob.index != index and SequenceRound._same(ob.element, correct_elem):
				ob.state = "missed"
				ob.play_correct()   # gently point at the one they wanted
	for ob in options:
		ob.queue_redraw()

	strip.reveal = chosen_elem
	strip.reveal_correct = right
	strip.play_reveal()
	strip.queue_redraw()

	progress.results = round_model.results
	progress.current = round_model.asked
	progress.play_land(round_model.results.size() - 1)
	progress.queue_redraw()
	_update_hud()

	_await_feedback()


func _await_feedback() -> void:
	var gen: int = _feedback_gen
	await get_tree().create_timer(FEEDBACK_SEC).timeout
	if gen != _feedback_gen:
		return  # a restart happened while the feedback was on screen
	if round_model.is_over():
		_on_round_over()
	else:
		round_model.next_question()
		_show_question()


func _on_round_over() -> void:
	progress.finished = true
	progress.queue_redraw()
	# Clear the question away rather than dimming it. A translucent panel over
	# a live board reads as a bug, and hiding the options also takes them out
	# of focus traversal, so the d-pad cannot land on a dead answer button.
	prompt_label.visible = false
	strip.visible = false
	for ob in options:
		ob.visible = false
	over_message.text = round_model.message()
	over_score.text = "%d out of %d correct" % [round_model.correct_total, ROUND_SIZE]
	stars_row.filled = round_model.stars()
	stars_row.queue_redraw()
	over_panel.visible = true
	_update_hud()
	_layout()
	play_again.grab_focus()

	# Common schema plus the historical "total" topic the old Home Assistant
	# sensors read. score/total match the original exactly.
	Telemetry.report_result(Telemetry.RESULT_DONE, round_model.correct_total,
			"correct", [["total", ROUND_SIZE]])


func _on_device_changed(_device: String) -> void:
	for ob in options:
		if ob.has_focus():
			ob.queue_redraw()
	if play_again.has_focus():
		play_again.queue_redraw()


func _layout_hud() -> float:
	var avail: float = size.x - HUD_MARGIN * 2.0
	var box: StyleBox = hud_label.get_theme_stylebox("normal")
	var pad: float = box.content_margin_left + box.content_margin_right
	var font: Font = hud_label.get_theme_font("font")
	var fs: int = HUD_FONT_SIZE
	while fs > HUD_FONT_MIN and font.get_string_size(
			hud_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + pad > avail:
		fs -= 1
	hud_label.add_theme_font_size_override("font_size", fs)
	var want: Vector2 = hud_label.get_combined_minimum_size()
	want.x = minf(want.x, avail)
	hud_label.size = want
	hud_label.position = Vector2(roundf((size.x - want.x) / 2.0), HUD_MARGIN)
	return HUD_MARGIN + want.y + HUD_MARGIN


func _layout() -> void:
	var sw: float = size.x
	var sh: float = size.y
	if sw <= 0.0 or sh <= 0.0:
		return

	var header_h: float = _layout_hud()
	var prog_h: float = 34.0
	progress.position = Vector2(40.0, header_h)
	progress.size = Vector2(maxf(1.0, sw - 80.0), prog_h)

	var top: float = header_h + prog_h + 8.0
	var avail_h: float = sh - top - 12.0
	var avail_w: float = sw - 80.0

	# Cells and buttons are both derived from the width first, then scaled down
	# together if the result is taller than the space left. Scaling both keeps
	# their relative sizes, so the layout looks the same on a phone and a TV.
	var n_cells: int = round_model.visible.size() + 1
	var gap: float = maxf(5.0, minf(14.0, avail_w / maxf(1.0, float(n_cells) * 9.0)))
	var cell: float = clampf((avail_w - gap * (n_cells - 1)) / float(n_cells), 28.0, 132.0)
	# The options are the only thing the player actually touches, so they get
	# to be as large as the sequence cells rather than half their size. The old
	# 95 px cap left a third of the screen empty and gave a three year old a
	# smaller target than the things they were only meant to look at.
	var btn: float = clampf((avail_w - BTN_GAP) / 2.0, 40.0, 128.0)

	var prompt_h: float = 30.0
	var vgap: float = 16.0
	var content_h: float = cell + vgap + prompt_h + vgap + (2.0 * btn + BTN_GAP)
	if content_h > avail_h:
		var scale: float = avail_h / content_h
		cell = maxf(28.0, cell * scale)
		btn = maxf(40.0, btn * scale)
		content_h = cell + vgap + prompt_h + vgap + (2.0 * btn + BTN_GAP)

	var content_top: float = top + maxf(0.0, (avail_h - content_h) / 2.0)

	strip.cell = cell
	strip.position = Vector2(0.0, content_top)
	strip.size = Vector2(sw, cell)

	prompt_label.position = Vector2(0.0, content_top + cell + vgap)
	prompt_label.size = Vector2(sw, prompt_h)

	var btn_top: float = content_top + cell + vgap + prompt_h + vgap
	var grid_w: float = 2.0 * btn + BTN_GAP
	var grid_x: float = (sw - grid_w) / 2.0
	for i in range(options.size()):
		options[i]._home = Vector2(
				grid_x + (i % 2) * (btn + BTN_GAP),
				btn_top + (i / 2) * (btn + BTN_GAP))
		options[i].position = options[i]._home + Vector2(options[i]._shake, 0.0)
		options[i].size = Vector2(btn, btn)
		# Tweens scale around the pivot, so it has to follow every resize or a
		# rotated-looking button pops out of place on the first animation.
		options[i].pivot_offset = options[i].size / 2.0
		options[i].queue_redraw()

	if over_panel.visible:
		var want: Vector2 = over_panel.get_combined_minimum_size()
		want.x = minf(want.x, maxf(120.0, sw - 40.0))
		over_panel.size = want
		over_panel.position = ((size - want) / 2.0).round()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_restart()
