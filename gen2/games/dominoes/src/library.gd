class_name PipsLibrary
extends RefCounted

## Reads the shipped puzzle pack.
##
## The pack is generated once by tools_gen_puzzles.gd and committed, because
## proving a puzzle has exactly one answer costs seconds even on this laptop —
## far too long to make a child wait, and several times worse on a Pi. Every
## puzzle in the pack was verified unique at the moment it was written.
##
## If the pack is missing or unreadable the game falls back to generating a
## puzzle live: slower and not guaranteed unique, but a game that still starts
## beats a blank screen.

const PACK_PATH := "res://puzzles.json"
const LEVEL_NAMES := ["easy", "medium", "hard"]

var _levels: Dictionary = {}
var loaded: bool = false
var load_error: String = ""


func _init() -> void:
	_load()


func _load() -> void:
	if not FileAccess.file_exists(PACK_PATH):
		load_error = "no puzzle pack at %s" % PACK_PATH
		return
	var file := FileAccess.open(PACK_PATH, FileAccess.READ)
	if file == null:
		load_error = "cannot open %s" % PACK_PATH
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("levels"):
		load_error = "puzzle pack is not readable"
		return
	_levels = parsed["levels"]
	loaded = true


func count(level: int) -> int:
	var name: String = LEVEL_NAMES[clampi(level, 0, LEVEL_NAMES.size() - 1)]
	var list = _levels.get(name, [])
	return (list as Array).size()


## One puzzle from the pack. `index` selects which, wrapping — so a caller can
## walk the pack in order or pick at random without bounds-checking.
func take(level: int, index: int) -> PipsPuzzle:
	var total: int = count(level)
	if total == 0:
		return null
	var name: String = LEVEL_NAMES[clampi(level, 0, LEVEL_NAMES.size() - 1)]
	var entry: Dictionary = (_levels[name] as Array)[posmod(index, total)]
	return decode(entry)


static func decode(entry: Dictionary) -> PipsPuzzle:
	var puzzle := PipsPuzzle.new()
	for region_data in entry.get("regions", []):
		var flat: Array = region_data["c"]
		var group: Array = []
		var region_index: int = puzzle.regions.size()
		var i: int = 0
		while i + 1 < flat.size():
			var cell := Vector2i(int(flat[i]), int(flat[i + 1]))
			group.append(cell)
			puzzle.cells[cell] = region_index
			i += 2
		puzzle.regions.append({
			"cells": group,
			"rule": int(region_data["r"]),
			"value": int(region_data["v"]),
		})
	var tray: Array = entry.get("tray", [])
	var j: int = 0
	while j + 1 < tray.size():
		puzzle.tray.append(Vector2i(int(tray[j]), int(tray[j + 1])))
		j += 2
	return puzzle
