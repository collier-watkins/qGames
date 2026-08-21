extends SceneTree
var _n := 0
func _initialize() -> void:
	root.add_child(load("res://src/main.tscn").instantiate())
func _process(_d: float) -> bool:
	_n += 1
	return _n >= 700
