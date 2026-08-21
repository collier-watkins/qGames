class_name QGameRoot
extends Control

## Base node every game's main scene extends. Owns the things that differ per
## platform so the games themselves never branch on OS:
##   - quit/back semantics (Escape on desktop, Android back button)
##   - safe-area insets on phones with notches
##   - a single "pointer" signal covering mouse and touch
##
## Games override _game_ready() and connect to pointer_down/pointer_up/pointer_move.

signal pointer_down(pos: Vector2)
signal pointer_up(pos: Vector2)
signal pointer_move(pos: Vector2)

var safe_area: Rect2i = Rect2i()

## How big everything is drawn, independent of the window size.
##
## Godot's `content_scale_factor` multiplies the stretch: at 1.5 the logical
## viewport shrinks, so every control, font and drawn pixel comes out half as
## big again. That is the honest knob for "this is too small on the telly and
## too big on the laptop" — it is the whole UI at once, not a font setting that
## leaves the artwork behind.
##
## Lives here rather than per game because every game inherits QGameRoot, and a
## reading size that only some games honoured would be worse than none.
const UI_SCALE_MIN: float = 0.6
const UI_SCALE_MAX: float = 2.4
const UI_SCALE_STEP: float = 0.1

var ui_scale: float = 1.0

var _scale_toast: CanvasLayer
var _scale_label: Label
var _scale_timer: Timer


func _ready() -> void:
	# Deliberately NOT full-rect anchors. A Control scene root is 0x0 during
	# _ready() — anchors are not applied until after it returns, so a game that
	# lays out here would size everything against a zero rect, draw nothing, and
	# never get a `resized` signal to recover. Waiting a frame instead just moves
	# the problem and costs a visible blank frame.
	#
	# Anchoring top-left (equal opposite anchors) lets us set `size` directly
	# without Godot overriding it — we own the size and track the viewport
	# ourselves. Explicit beats implicit here, and `resized` still fires for
	# games, so per-game layout code is unchanged.
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	safe_area = DisplayServer.get_display_safe_area()
	# Scale BEFORE the first sync, so a game lays out against the size it will
	# actually have rather than laying out twice and flashing.
	_load_ui_scale()
	_sync_to_viewport()
	get_viewport().size_changed.connect(_sync_to_viewport)
	_build_scale_toast()
	_game_ready()


func _load_ui_scale() -> void:
	ui_scale = clampf(float(QConfig.get_value("ui/scale", 1.0)),
			UI_SCALE_MIN, UI_SCALE_MAX)
	_apply_ui_scale()


func _apply_ui_scale() -> void:
	var window: Window = get_window()
	if window != null:
		window.content_scale_factor = ui_scale


## Change the reading size and remember it. `delta` of 0 resets to 1.
func nudge_ui_scale(delta: float) -> void:
	var wanted: float = 1.0 if is_zero_approx(delta) \
			else clampf(ui_scale + delta, UI_SCALE_MIN, UI_SCALE_MAX)
	if is_equal_approx(wanted, ui_scale):
		# Already at the end of the range: say so rather than silently doing
		# nothing, which reads as a broken key.
		_show_scale_toast("Size %d%%  (as %s as it goes)" % [
				int(round(ui_scale * 100.0)),
				"big" if delta > 0.0 else "small"])
		return
	ui_scale = wanted
	_apply_ui_scale()
	QConfig.set_value("ui/scale", ui_scale)
	QConfig.save()
	_show_scale_toast("Size %d%%" % int(round(ui_scale * 100.0)))


## A brief label, on its own layer so no game has to make room for it. Below
## the debug HUD's layer, which stays on top of everything.
func _build_scale_toast() -> void:
	_scale_toast = CanvasLayer.new()
	_scale_toast.layer = 100
	_scale_toast.visible = false
	add_child(_scale_toast)

	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_FULL_RECT)
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scale_toast.add_child(anchor)

	# A CenterContainer does the centring. Anchoring the panel itself and
	# nudging its position does not: a PanelContainer sizes to its content
	# AFTER anchors are applied, so it ends up offset by half its own width.
	var row := CenterContainer.new()
	row.set_anchors_preset(Control.PRESET_TOP_WIDE)
	row.offset_top = 24.0
	row.custom_minimum_size = Vector2(0, 56)
	row.offset_bottom = 80.0
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor.add_child(row)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.09, 0.10, 0.12, 0.90)
	box.set_corner_radius_all(10)
	box.content_margin_left = 18.0
	box.content_margin_right = 18.0
	box.content_margin_top = 10.0
	box.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", box)
	row.add_child(panel)

	_scale_label = Label.new()
	_scale_label.add_theme_font_size_override("font_size", 20)
	_scale_label.add_theme_color_override("font_color", Color(0.94, 0.96, 0.99))
	_scale_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_scale_label)

	_scale_timer = Timer.new()
	_scale_timer.one_shot = true
	_scale_timer.wait_time = 1.4
	_scale_timer.timeout.connect(func() -> void: _scale_toast.visible = false)
	add_child(_scale_timer)


func _show_scale_toast(text: String) -> void:
	if _scale_label == null:
		return
	_scale_label.text = text
	_scale_toast.visible = true
	_scale_timer.start()


## Ctrl and +/-/0, the combination every browser and editor already uses.
## Returns true when the event was a size change, so _unhandled_input can stop.
func _handle_ui_scale_key(key: InputEventKey) -> bool:
	if not (key.ctrl_pressed or key.meta_pressed):
		return false
	match key.keycode:
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
			nudge_ui_scale(UI_SCALE_STEP)
			return true
		KEY_MINUS, KEY_KP_SUBTRACT:
			nudge_ui_scale(-UI_SCALE_STEP)
			return true
		KEY_0, KEY_KP_0:
			nudge_ui_scale(0.0)
			return true
	return false


func _sync_to_viewport() -> void:
	var vp: Vector2 = get_viewport_rect().size
	if vp.x > 0.0 and vp.y > 0.0 and size != vp:
		size = vp


## Override in each game.
func _game_ready() -> void:
	pass


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST or what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_game()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if _handle_ui_scale_key(event as InputEventKey):
			get_viewport().set_input_as_handled()
			return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		quit_game()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			pointer_down.emit(event.position)
		else:
			pointer_up.emit(event.position)
	elif event is InputEventScreenTouch:
		if event.pressed:
			pointer_down.emit(event.position)
		else:
			pointer_up.emit(event.position)
	elif event is InputEventMouseMotion or event is InputEventScreenDrag:
		pointer_move.emit(event.position)


func quit_game() -> void:
	get_tree().quit()
