extends QGameRoot

## Paint — a drawing pad that saves PNGs.
##
## Simple on purpose: three tools, a fixed palette, undo, clear, save. No
## layers, no shapes, no text. A child should be able to use all of it without
## being shown.
##
## THE CONSTRAINT THAT SHAPED IT is memory. The previous generation crashed a
## Raspberry Pi after a long session because its undo and redo stacks each held
## twenty full-resolution surface copies — bounded by count, roughly 240 MB at
## 1080p. canvas.gd caps history in BYTES and stores PNGs; this file's job is
## not to undo that discipline, which means:
##
##   * ONE Image and ONE ImageTexture for the life of the game. The texture is
##     update()d in place. Building an ImageTexture per frame is the standard
##     way to leak in Godot and would put the crash straight back.
##   * The canvas is a FIXED size, scaled to fit the pane. Reallocating the
##     image on every window resize would churn megabytes for nothing.

const MARGIN: int = 12
const GAP: int = 8

## Fixed working resolution. Every saved PNG is this size, whatever the window
## is doing, so a picture drawn on a laptop and one drawn on a Pi are the same
## picture.
const CANVAS_W: int = 1280
const CANVAS_H: int = 720

const C_CHROME: Color = Color("#e9eaee")
const C_INK: Color = Color("#23262b")
const C_DIM: Color = Color("#6b7280")
const C_LINE: Color = Color("#c3c7ce")
const C_ACCENT: Color = Color("#2f6fd0")
const C_PAPER: Color = Color.WHITE
const C_SHADOW: Color = Color(0, 0, 0, 0.10)

## Twelve colours and no more. A palette a child can learn beats a picker they
## have to operate. Red, yellow and blue are the plain primaries rather than
## the muted designer versions — a child asking for "blue" means blue.
const PALETTE: Array = [
	Color("#000000"),  # black
	Color("#7f8c8d"),  # grey
	Color("#ffffff"),  # white
	Color("#e02020"),  # red      — primary
	Color("#f57c00"),  # orange
	Color("#ffd400"),  # yellow   — primary
	Color("#2eb872"),  # green
	Color("#00a3c4"),  # cyan
	Color("#1746d1"),  # blue     — primary
	Color("#8e44ad"),  # purple
	Color("#ff7bac"),  # pink
	Color("#8b5a2b"),  # brown
]

## Tool artwork. SVG so it stays crisp at any size — the fill cursor is drawn
## far larger than the toolbar button uses.
const ICON_UNDO := preload("res://assets/undo.svg")
const ICON_REDO := preload("res://assets/redo.svg")
const ICON_BUCKET := preload("res://assets/bucket.svg")
const ICON_ERASER := preload("res://assets/eraser.svg")

## Toolbar artwork, authored at button size so it needs no scaling — the
## earlier attempt reused the 64px cursor art and it simply never appeared.
const ICON_TOOL: Array = [
	preload("res://assets/tool_brush.svg"),
	preload("res://assets/tool_eraser.svg"),
	preload("res://assets/tool_fill.svg"),
]

const BRUSH_SIZES: Array = [3, 8, 18, 34]

enum Tool { BRUSH, ERASER, FILL }

var _canvas: PaintCanvas
var _view: CanvasView
var _status: Label

var _tool: int = Tool.BRUSH
var _colour_index: int = 0
var _size_index: int = 1
var _strokes: int = 0
var _saves: int = 0

var _swatches: Array = []
var _size_buttons: Array = []
var _tool_buttons: Array = []
var _undo_button: Button
var _redo_button: Button


func _game_ready() -> void:
	_canvas = PaintCanvas.new(CANVAS_W, CANVAS_H, C_PAPER)
	_build_ui()
	_view.canvas = _canvas
	_view.attach()
	_refresh()
	_view.grab_focus()
	# --paintdrag: drive a drag through the real drawing path, so the framerate
	# the HUD reports is the framerate WHILE DRAWING. The Pi has no way to
	# inject a pointer event, and drawing is the only thing this game does that
	# is expensive — measuring it at rest says nothing. It is what caught the
	# renderer's texture-upload cost; see the note in project.godot.
	if "--paintdrag" in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		_drag_bench.call_deferred()


## Drives a realistic drag through the REAL drawing path — _begin/_apply/_end on
## the view — so the framerate the HUD reports is the framerate while drawing.
## Two motion steps per frame is about what a 125 Hz mouse delivers at 60 fps.
var _drag_n: int = 0
var _drag_at: Vector2i = Vector2i(40, 40)
var _drag_dir: Vector2i = Vector2i(9, 5)


func _drag_bench() -> void:
	_view._begin(_drag_at)
	_drag_n = 1200
	set_process(true)


func _process(_delta: float) -> void:
	if _drag_n <= 0:
		return
	for i in 2:
		var nxt: Vector2i = _drag_at + _drag_dir
		if nxt.x < 4 or nxt.x > CANVAS_W - 5:
			_drag_dir.x = -_drag_dir.x
			nxt = _drag_at + _drag_dir
		if nxt.y < 4 or nxt.y > CANVAS_H - 5:
			_drag_dir.y = -_drag_dir.y
			nxt = _drag_at + _drag_dir
		_view._apply(nxt, _drag_at, true)
		_drag_at = nxt
	_drag_n -= 1
	# Lift the pen every 90 frames and start again. A real session is many
	# short strokes, and the stroke END is where the one full upload happens —
	# a bench that never lifts the pen never measures it.
	if _drag_n % 90 == 0:
		_view._end()
		_view._begin(_drag_at)
	if _drag_n == 0:
		_view._end()
		print("[bench] drag finished")


func colour() -> Color:
	return PALETTE[_colour_index]


func brush_radius() -> int:
	return int(BRUSH_SIZES[_size_index])


# ── Construction ────────────────────────────────────────────────────────────


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
	RenderingServer.set_default_clear_color(C_CHROME)

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

	shell.add_child(_build_toolbar())

	_view = CanvasView.new()
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.owner_game = self
	_view.stroke_finished.connect(_on_stroke_finished)
	shell.add_child(_view)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 14)
	_status.add_theme_color_override("font_color", C_DIM)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	shell.add_child(_status)


func _build_toolbar() -> Control:
	# An HFlowContainer, not an HBox: three tools, four sizes, twelve colours
	# and four actions do not fit one row on a narrow window — and they REALLY
	# do not once the reading size is turned up, which shrinks the logical
	# viewport. An HBox would simply overflow and shove the paper off screen.
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 6)
	bar.add_theme_constant_override("v_separation", 6)

	_tool_buttons = []
	for tool in [Tool.BRUSH, Tool.ERASER, Tool.FILL]:
		var label: String = ["Brush", "Eraser", "Fill"][tool]
		var b := _make_button(label, func() -> void: _choose_tool(tool), true)
		# The picture matters more than the word: a four-year-old who cannot
		# read still knows which one is the brush.
		b.icon = ICON_TOOL[tool]

		_tool_buttons.append(b)
		bar.add_child(b)

	bar.add_child(_separator())

	_size_buttons = []
	for i in BRUSH_SIZES.size():
		var b := SizeButton.new()
		b.radius = int(BRUSH_SIZES[i])
		b.custom_minimum_size = Vector2(38, 34)
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_ALL
		_style_button(b)
		b.pressed.connect(func() -> void: _choose_size(i))
		_size_buttons.append(b)
		bar.add_child(b)

	bar.add_child(_separator())

	_swatches = []
	for i in PALETTE.size():
		var s := Swatch.new()
		s.colour = PALETTE[i]
		s.custom_minimum_size = Vector2(30, 34)
		s.focus_mode = Control.FOCUS_ALL
		s.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		s.chosen.connect(func() -> void: _choose_colour(i))
		_swatches.append(s)
		bar.add_child(s)

	bar.add_child(_separator())

	_undo_button = _make_icon_button(ICON_UNDO, _on_undo, "Undo  (Ctrl+Z)")
	_redo_button = _make_icon_button(ICON_REDO, _on_redo, "Redo  (Ctrl+Shift+Z)")
	bar.add_child(_undo_button)
	bar.add_child(_redo_button)
	bar.add_child(_make_button("Clear", _on_clear, false))
	bar.add_child(_make_button("Save", _on_save, false))
	return bar


func _separator() -> Control:
	var wrap := MarginContainer.new()
	for side in ["left", "right"]:
		wrap.add_theme_constant_override("margin_" + side, 4)
	var line := ColorRect.new()
	line.color = C_LINE
	line.custom_minimum_size = Vector2(1, 26)
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(line)
	return wrap


## A button that is only an icon. Undo and redo are the two actions with a
## picture everybody already knows, so the words were costing width for nothing.
func _make_icon_button(art: Texture2D, on_press: Callable, tip: String) -> Button:
	var b := Button.new()
	b.icon = art
	b.tooltip_text = tip
	b.expand_icon = true
	b.add_theme_constant_override("icon_max_width", 20)
	b.custom_minimum_size = Vector2(40, 34)
	b.focus_mode = Control.FOCUS_ALL
	_style_button(b)
	b.pressed.connect(on_press)
	return b


func _make_button(text: String, on_press: Callable, toggle: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = toggle
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_size_override("font_size", 15)
	_style_button(b)
	b.pressed.connect(on_press)
	return b


func _style_button(b: Button) -> void:
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(7)
		sb.content_margin_left = 11.0
		sb.content_margin_right = 11.0
		sb.content_margin_top = 6.0
		sb.content_margin_bottom = 6.0
		sb.bg_color = Color.WHITE
		sb.border_color = C_LINE
		sb.set_border_width_all(1)
		match state:
			"hover":
				sb.bg_color = Color("#f2f6fd")
			"pressed":
				sb.bg_color = Color("#dce8fb")
				sb.border_color = C_ACCENT
				sb.set_border_width_all(2)
			"focus":
				sb.border_color = C_ACCENT
				sb.set_border_width_all(2)
			"disabled":
				sb.bg_color = Color("#eceef1")
				sb.border_color = Color("#dcdfe4")
		b.add_theme_stylebox_override(state, sb)
	for key in ["font_color", "font_hover_color", "font_focus_color"]:
		b.add_theme_color_override(key, C_INK)
	b.add_theme_color_override("font_pressed_color", C_ACCENT)
	b.add_theme_color_override("font_disabled_color", Color("#a9aeb6"))


# ── Actions ─────────────────────────────────────────────────────────────────


func _choose_tool(tool: int) -> void:
	_tool = tool
	_refresh()
	_view.grab_focus()


func _choose_size(index: int) -> void:
	_size_index = clampi(index, 0, BRUSH_SIZES.size() - 1)
	_refresh()
	_view.grab_focus()


func _choose_colour(index: int) -> void:
	_colour_index = clampi(index, 0, PALETTE.size() - 1)
	# Picking a colour means you want to draw with it, not rub it out.
	if _tool == Tool.ERASER:
		_tool = Tool.BRUSH
	_refresh()
	_view.grab_focus()


func _on_stroke_finished() -> void:
	_strokes += 1
	_refresh()


func _on_undo() -> void:
	_canvas.undo()
	_view.refresh_texture()
	_refresh()
	_view.grab_focus()


func _on_redo() -> void:
	_canvas.redo()
	_view.refresh_texture()
	_refresh()
	_view.grab_focus()


func _on_clear() -> void:
	_canvas.clear(C_PAPER)
	_view.refresh_texture()
	_refresh()
	_view.grab_focus()


## Write a PNG and tell the house about it.
func _on_save() -> void:
	var folder: String = "user://paintings"
	var stamp: String = Time.get_datetime_string_from_system(false, false) \
			.replace(":", "-").replace("T", "_")
	var name: String = "painting_%s.png" % stamp
	var path: String = "%s/%s" % [folder, name]

	if not _canvas.save_png(path):
		_status.add_theme_color_override("font_color", Color("#c0453c"))
		_status.text = "Could not save: %s" % _canvas.last_error
		return

	_saves += 1
	_status.add_theme_color_override("font_color", C_DIM)
	_status.text = "Saved %s  (%s)" % [name, ProjectSettings.globalize_path(folder)]

	# The picture itself goes out RETAINED and first, then the round's scalars,
	# with ts last — so anything reacting to ts already has the image. Retained
	# because the point of putting a painting on a broker is that a dashboard
	# restarting an hour later still shows it.
	var png: PackedByteArray = _canvas.publish_png()
	Telemetry.report_image("image", png, [
		["result", Telemetry.RESULT_DONE],
		["score", _strokes],
		["score_unit", "strokes"],
		["duration_s", 0],
		["saved", name],
		["image_bytes", png.size()],
		["image_w", _canvas.width],
		["image_h", _canvas.height],
	])


# ── Chrome ──────────────────────────────────────────────────────────────────


func _refresh() -> void:
	for i in _tool_buttons.size():
		(_tool_buttons[i] as Button).set_pressed_no_signal(i == _tool)
	for i in _size_buttons.size():
		var b: Button = _size_buttons[i]
		b.set_pressed_no_signal(i == _size_index)
		b.queue_redraw()
	for i in _swatches.size():
		var s = _swatches[i]
		s.selected = i == _colour_index and _tool != Tool.ERASER
		s.queue_redraw()

	_undo_button.disabled = not _canvas.can_undo()
	_redo_button.disabled = not _canvas.can_redo()

	if not _status.text.begins_with("Saved") and not _status.text.begins_with("Could"):
		_status.add_theme_color_override("font_color", C_DIM)
		_status.text = "%d strokes · history %.1f MB of %d · arrows move, space draws" % [
			_strokes, _canvas.history_bytes() / 1048576.0,
			PaintCanvas.MAX_BYTES / 1048576]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed:
		var key: InputEventKey = event
		if key.ctrl_pressed:
			match key.keycode:
				KEY_Z:
					get_viewport().set_input_as_handled()
					if key.shift_pressed:
						_on_redo()
					else:
						_on_undo()
					return
				KEY_Y:
					get_viewport().set_input_as_handled()
					_on_redo()
					return
				KEY_S:
					get_viewport().set_input_as_handled()
					_on_save()
					return
		match key.keycode:
			KEY_BRACKETLEFT:
				get_viewport().set_input_as_handled()
				_choose_size(_size_index - 1)
				return
			KEY_BRACKETRIGHT:
				get_viewport().set_input_as_handled()
				_choose_size(_size_index + 1)
				return
	super._unhandled_input(event)


# ── The paper ───────────────────────────────────────────────────────────────


## Shows the canvas and turns pointer movement into strokes.
##
## ONE ImageTexture, updated in place. Creating a texture per change is the
## standard way to leak in Godot, and this game exists because the last one
## ran out of memory.
class CanvasView extends Control:
	signal stroke_finished()

	var canvas: PaintCanvas
	var owner_game: Node

	var _drawing: bool = false
	var _last: Vector2i = Vector2i.ZERO
	## Where a KEYBOARD user is pointing, in canvas pixels. Only drawn when
	## somebody is actually driving with keys or a pad — a crosshair parked in
	## the middle of the paper for a mouse user is just a smudge they cannot
	## rub out.
	var _cursor: Vector2i = Vector2i(CANVAS_W / 2, CANVAS_H / 2)
	var _pen_down: bool = false
	## Pointer position in this control's coordinates, and whether it is over
	## the paper. The OS cursor is hidden there and the tool drawn instead.
	var _pointer: Vector2 = Vector2.ZERO
	var _pointer_on_paper: bool = false
	## The keyboard pointer stays hidden until somebody actually steers it.
	## QInput reports "key" before ANY input has happened, so trusting that
	## alone parks a crosshair in the middle of a fresh window for every mouse
	## user — which is exactly the thing it was removed for.
	var _keys_used: bool = false
	var _scale: float = 1.0
	var _offset: Vector2 = Vector2.ZERO
	## Set when the picture changed; the upload happens once in _process.
	var _stale: bool = false

	func _ready() -> void:
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)
		mouse_exited.connect(_on_mouse_exited)

	## Restore the pointer on the way out, and be careful to restore it however
	## the mouse leaves — a hidden cursor that escapes onto the desktop is a
	## genuinely alarming bug.
	func _on_mouse_exited() -> void:
		_pointer_on_paper = false
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		queue_redraw()

	func _exit_tree() -> void:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	func _notification(what: int) -> void:
		# Losing focus to another window counts as leaving.
		if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_MOUSE_EXIT:
			_on_mouse_exited()

	func attach() -> void:
		_build_tiles()
		canvas.changed.connect(_on_canvas_changed)
		set_process(true)
		queue_redraw()

	## The picture reaches the GPU as a GRID OF TILES, not as one texture.
	##
	## Godot cannot update part of a texture — ImageTexture.update() always
	## sends the whole thing — so one texture for the whole canvas means
	## re-sending 3.6 MB on every frame a stroke moves. MEASURED on a Pi 4 that
	## is 190 ms per frame on Vulkan: five frames a second, unusable. The same
	## drag sending a 256 KB region instead holds a locked 60, so the cost
	## scales with BYTES and this is worth doing.
	##
	## A tile grid makes that saving STRUCTURAL: a dab dirties one or two tiles
	## and only those are re-sent, no matter what the stroke does afterwards.
	##
	## The obvious cheaper-looking alternative — keep one big texture and upload
	## the region changed since the last full refresh as a patch drawn over the
	## top — was built first and MEASURED at 29 fps with a floor of 14. It
	## degenerates: that region is a bounding box, it grows as the stroke
	## travels, and once it passes about a third of the canvas a full upload is
	## cheaper again — so every later frame of a long stroke pays for one. A
	## tile's cost does not depend on how far the stroke has gone, which is the
	## whole point.
	##
	## 256px tiles are 256 KB each. Smaller means more draw calls for no gain;
	## much larger and one dab starts costing what it used to.
	const TILE: int = 256

	var _tiles: Array[ImageTexture] = []
	var _tile_rects: Array[Rect2i] = []
	var _tile_dirty: Array[bool] = []

	func _build_tiles() -> void:
		_tiles.clear()
		_tile_rects.clear()
		_tile_dirty.clear()
		for y in range(0, canvas.height, TILE):
			for x in range(0, canvas.width, TILE):
				var r := Rect2i(x, y, mini(TILE, canvas.width - x),
						mini(TILE, canvas.height - y))
				_tile_rects.append(r)
				_tiles.append(ImageTexture.create_from_image(canvas.image.get_region(r)))
				_tile_dirty.append(false)
		_stale = false

	## Mark the picture stale. The actual upload waits for _process.
	##
	## A stroke is dozens of dabs and each one reports a change, so uploading on
	## every report meant pushing a texture to the GPU dozens of times for one
	## drag of the mouse. The screen can only show one of those anyway.
	func refresh_texture() -> void:
		for i in _tile_dirty.size():
			_tile_dirty[i] = true
		_stale = true

	func _on_canvas_changed(region: Rect2i) -> void:
		if _tiles.is_empty() or _tile_rects.size() != _expected_tiles():
			_build_tiles()
			queue_redraw()
			return
		_stale = true
		if region.size.x <= 0 or region.size.y <= 0:
			refresh_texture()
			return
		for i in _tile_rects.size():
			if _tile_rects[i].intersects(region):
				_tile_dirty[i] = true

	func _expected_tiles() -> int:
		return int(ceil(float(canvas.width) / TILE)) * int(ceil(float(canvas.height) / TILE))

	func _process(_delta: float) -> void:
		if not _stale:
			return
		_stale = false
		for i in _tiles.size():
			if not _tile_dirty[i]:
				continue
			_tile_dirty[i] = false
			_tiles[i].update(canvas.image.get_region(_tile_rects[i]))
		queue_redraw()

	## Fit the fixed-size canvas into whatever pane it has, letterboxed. The
	## image is never reallocated to match the window.
	func _measure() -> void:
		if canvas == null:
			return
		_scale = minf(size.x / float(canvas.width), size.y / float(canvas.height))
		_scale = maxf(_scale, 0.05)
		_offset = (size - Vector2(canvas.width, canvas.height) * _scale) * 0.5

	func paper_rect() -> Rect2:
		return Rect2(_offset, Vector2(canvas.width, canvas.height) * _scale)

	func to_canvas(point: Vector2) -> Vector2i:
		return Vector2i(((point - _offset) / _scale).floor())

	func _draw() -> void:
		if canvas == null or _tiles.is_empty():
			return
		_measure()
		var paper: Rect2 = paper_rect()
		draw_rect(paper.grow(3.0), C_SHADOW, true)
		# Adjacent tiles are placed from the same integer canvas coordinates, so
		# one tile's right edge lands on exactly the float its neighbour starts
		# at and the grid cannot show a seam.
		for i in _tiles.size():
			var r: Rect2i = _tile_rects[i]
			draw_texture_rect(_tiles[i], Rect2(
					_offset + Vector2(r.position) * _scale,
					Vector2(r.size) * _scale), false)
		draw_rect(paper, C_LINE, false, 1.0)

		# The keyboard pointer, only for somebody actually driving with keys or
		# a pad. A mouse user gets the tool drawn under their pointer instead.
		# Exactly one pointer is ever drawn. The mouse wins when it is over
		# the paper, because that is plainly where the child is looking.
		if _pointer_on_paper:
			_draw_tool(_pointer, false)
		elif _keys_used and has_focus() and QInput.wants_focus_ui():
			_draw_tool(_offset + Vector2(_cursor) * _scale, _pen_down)

	## The pointer IS the tool: a circle the size of the brush, a white block
	## for the eraser, a tipped bucket for fill. Drawn at the on-screen scale,
	## so what is outlined is exactly what will be marked — which is the whole
	## point of doing this rather than setting an OS cursor, since the canvas
	## is scaled to fit the window.
	func _draw_tool(at: Vector2, active: bool) -> void:
		var game = owner_game
		match game._tool:
			game.Tool.FILL:
				var art: Texture2D = game.ICON_BUCKET
				var side: float = 54.0
				# The bucket is drawn above-left of the hotspot so the point it
				# pours from sits on the pixel that will be filled.
				draw_texture_rect(art,
						Rect2(at - Vector2(side * 0.72, side * 0.86),
								Vector2(side, side)), false)
				# A drop of the chosen colour where the paint will land.
				draw_circle(at, 5.0, game.colour(), true)
				draw_arc(at, 5.0, 0.0, TAU, 14, C_INK, 1.6, true)
			game.Tool.ERASER:
				var half: float = maxf(5.0, float(game.brush_radius()) * _scale)
				var box := Rect2(at - Vector2(half, half), Vector2(half, half) * 2.0)
				# White fill with a dark outline: white alone vanishes on the
				# paper, which is the only place it is ever used.
				draw_rect(box, Color(1, 1, 1, 0.85), true)
				draw_rect(box, C_INK, false, 2.0, true)
			_:
				var r: float = maxf(2.0, float(game.brush_radius()) * _scale)
				# Two rings, light over dark, so the outline stays visible on
				# both a white page and a colour the child just laid down.
				draw_arc(at, r, 0.0, TAU, 32, Color(0, 0, 0, 0.75), 2.0, true)
				draw_arc(at, r - 1.5, 0.0, TAU, 32, Color(1, 1, 1, 0.75), 1.5, true)
				if active:
					draw_circle(at, maxf(2.0, r * 0.25), game.colour(), true)

	func _apply(at: Vector2i, from: Vector2i, joined: bool) -> void:
		var game = owner_game
		match game._tool:
			game.Tool.FILL:
				canvas.fill(at, game.colour())
			game.Tool.ERASER:
				# Square, matching the block drawn under the pointer.
				if joined:
					canvas.stroke(from, at, game.brush_radius(), C_PAPER, true)
				else:
					canvas.dab(at, game.brush_radius(), C_PAPER, true)
			_:
				if joined:
					canvas.stroke(from, at, game.brush_radius(), game.colour())
				else:
					canvas.dab(at, game.brush_radius(), game.colour())

	func _begin(at: Vector2i) -> void:
		canvas.begin_stroke()
		_drawing = true
		_last = at
		_apply(at, at, false)

	func _end() -> void:
		if not _drawing:
			return
		_drawing = false
		canvas.end_stroke()
		# NOTHING to refresh: every dab marked the tiles it touched and they
		# were uploaded on the frame it happened, so the GPU is already current.
		# An earlier design refreshed everything here and it cost 16 fps off the
		# floor for no reason at all.
		stroke_finished.emit()

	func _gui_input(event: InputEvent) -> void:
		if canvas == null:
			return
		if event is InputEventMouseButton:
			var mb: InputEventMouseButton = event
			if mb.button_index != MOUSE_BUTTON_LEFT:
				return
			var at: Vector2i = to_canvas(mb.position)
			if mb.pressed:
				grab_focus()
				if _inside(at):
					_begin(at)
				accept_event()
			else:
				_end()
				accept_event()
		elif event is InputEventMouseMotion:
			_track_pointer((event as InputEventMouseMotion).position)
			if not _drawing:
				accept_event()
				return
			var at: Vector2i = to_canvas((event as InputEventMouseMotion).position)
			# Clamp rather than drop: a drag that leaves the paper and comes
			# back should not tear the line in two.
			at = Vector2i(clampi(at.x, 0, canvas.width - 1),
					clampi(at.y, 0, canvas.height - 1))
			_apply(at, _last, true)
			_last = at
			accept_event()
		elif event is InputEventKey and (event as InputEventKey).pressed:
			_key(event as InputEventKey)

	## Follow the pointer and swap the OS cursor for the tool over the paper.
	func _track_pointer(where: Vector2) -> void:
		_pointer = where
		var over: bool = paper_rect().has_point(where)
		if over != _pointer_on_paper:
			_pointer_on_paper = over
			Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN if over
					else Input.MOUSE_MODE_VISIBLE)
		queue_redraw()

	func _inside(at: Vector2i) -> bool:
		return at.x >= 0 and at.y >= 0 and at.x < canvas.width and at.y < canvas.height

	## Keypad drawing: arrows move the crosshair, space puts the pen down and
	## lifts it. Holding a direction while the pen is down draws a line, which
	## is the only way this is usable without a pointer.
	func _key(key: InputEventKey) -> void:
		var step := Vector2i.ZERO
		match key.keycode:
			KEY_LEFT: step = Vector2i(-1, 0)
			KEY_RIGHT: step = Vector2i(1, 0)
			KEY_UP: step = Vector2i(0, -1)
			KEY_DOWN: step = Vector2i(0, 1)
			KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
				_keys_used = true
				if _pen_down:
					_pen_down = false
					_end()
				else:
					_pen_down = true
					_begin(_cursor)
				queue_redraw()
				accept_event()
				return
		if step == Vector2i.ZERO:
			return
		_keys_used = true
		# A brush-sized step, so crossing the canvas does not take all day.
		var jump: int = maxi(2, owner_game.brush_radius())
		if key.shift_pressed:
			jump *= 4
		var moved := Vector2i(
				clampi(_cursor.x + step.x * jump, 0, canvas.width - 1),
				clampi(_cursor.y + step.y * jump, 0, canvas.height - 1))
		if _pen_down:
			_apply(moved, _cursor, true)
		_cursor = moved
		queue_redraw()
		accept_event()


# ── Toolbar widgets ─────────────────────────────────────────────────────────


## A colour chip. A Button with a themed background would fight the theme for
## control of its own colour, which is the one thing it has to get right.
class Swatch extends Control:
	signal chosen()

	var colour: Color = Color.BLACK
	var selected: bool = false
	## One shared style box, mutated per draw. Allocating a StyleBoxFlat per
	## rounded rectangle doubled this platform's idle CPU once already.
	static var _box: StyleBoxFlat = null

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)

	func _draw() -> void:
		var r := Rect2(Vector2(2, 4), size - Vector2(4, 8))
		if _box == null:
			_box = StyleBoxFlat.new()
			_box.set_corner_radius_all(6)
		_box.bg_color = colour
		draw_style_box(_box, r)
		draw_rect(r, C_LINE, false, 1.0, true)
		if selected:
			draw_rect(r.grow(3.0), C_ACCENT, false, 3.0, true)
		elif has_focus():
			draw_rect(r.grow(3.0), Color(C_ACCENT, 0.5), false, 2.0, true)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
				and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			grab_focus()
			chosen.emit()
			accept_event()
		elif event is InputEventKey and (event as InputEventKey).pressed:
			match (event as InputEventKey).keycode:
				KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
					chosen.emit()
					accept_event()


## A brush-size button that shows the size rather than naming it.
class SizeButton extends Button:
	var radius: int = 4

	func _draw() -> void:
		var shown: float = clampf(float(radius) * 0.42, 2.0, 12.0)
		draw_circle(size * 0.5, shown, C_INK if not button_pressed else C_ACCENT, true)
