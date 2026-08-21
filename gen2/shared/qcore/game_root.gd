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
	_sync_to_viewport()
	get_viewport().size_changed.connect(_sync_to_viewport)
	_game_ready()


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
