extends SceneTree

## Developer tool: runs the --demo game in this window and saves a screenshot
## at the moments it exists to show. Needs a display.
##   godot --path games/chess --resolution 1280x720 --script res://tests/demo_shots.gd

const AT: Dictionary = {9.5: "demo_1_check_received", 13.0: "demo_2_pointed",
		26.5: "demo_3_mate_trap", 29.0: "demo_4_mate_show", 36.0: "demo_5_card"}
var _main: Node
var _t0: int = 0
var _taken: Dictionary = {}
var _frames: int = 0


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DirAccess.make_dir_recursive_absolute("user://shots")
	_main = load("res://src/main.tscn").instantiate()
	root.add_child(_main)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 5:
		return false
	if _t0 == 0:
		_t0 = Time.get_ticks_msec()
		_main.set("_demo", load("res://src/demo.gd").new(_main))
		_main.add_child(_main.get("_demo"))
		return false
	var t: float = (Time.get_ticks_msec() - _t0) / 1000.0
	for at: float in AT:
		if t >= at and not _taken.has(at):
			_taken[at] = true
			root.get_texture().get_image().save_png("user://shots/%s.png" % AT[at])
			print("%.1f %s  status=%s" % [t, AT[at], (_main.get("_status") as Label).text])
	return t > 37.0
