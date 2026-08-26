@tool
extends EditorPlugin

## qcore is consumed as an addon symlinked into each game project.
## The editor plugin itself does nothing at runtime — the useful parts are the
## autoloads (QConfig, Telemetry) registered in each game's project.godot.

func _enter_tree() -> void:
	pass

func _exit_tree() -> void:
	pass
