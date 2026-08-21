extends Node

## Tracks which input device the player is actually using. Autoload as "QInput".
##
## Requirement: touch AND keypad are both first-class. The way that works is a
## single action layer (Godot's InputMap) driven by whichever device is in
## hand, plus a HUD that changes to match. Games ask QInput which HUD to show;
## they never branch on OS.

signal device_changed(device: String)

const DEVICE_KEY := "key"
const DEVICE_PAD := "pad"
const DEVICE_TOUCH := "touch"
const DEVICE_MOUSE := "mouse"

const _PAD_DEADZONE := 0.5

var last_device: String = DEVICE_KEY


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.has_feature("android"):
		last_device = DEVICE_TOUCH


func _input(event: InputEvent) -> void:
	var d := ""
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		d = DEVICE_TOUCH
	elif event is InputEventKey:
		d = DEVICE_KEY
	elif event is InputEventJoypadButton:
		d = DEVICE_PAD
	elif event is InputEventJoypadMotion:
		if absf(event.axis_value) < _PAD_DEADZONE:
			return
		d = DEVICE_PAD
	elif event is InputEventMouseButton:
		d = DEVICE_MOUSE

	if d != "" and d != last_device:
		last_device = d
		device_changed.emit(d)


func is_touch_primary() -> bool:
	return last_device == DEVICE_TOUCH


## True when the player is driving with keys or a gamepad, so focus rings and
## cursor highlights should be visible.
func wants_focus_ui() -> bool:
	return last_device == DEVICE_KEY or last_device == DEVICE_PAD
