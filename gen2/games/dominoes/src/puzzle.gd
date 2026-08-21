class_name PipsPuzzle
extends RefCounted

## A Pips board: cells, coloured regions with constraints, and the dominoes
## waiting to fill them.
##
## The rules are the New York Times' Pips, not traditional dominoes, and the
## difference is the whole game: TOUCHING ENDS DO NOT HAVE TO MATCH. A domino
## may straddle two regions, and then each half answers to its own region's
## rule. The puzzle is solved when every cell is covered, every domino is used,
## and every region is satisfied.
##
## Constraints are evaluated on PARTIAL boards as well as full ones, because a
## player needs to be told they have already made a region impossible — not
## discover it at the end. VIOLATED therefore means "cannot come good", not
## merely "not yet right".

enum Rule { NONE, SUM, EQUAL, NOT_EQUAL, LESS, GREATER }
enum Status { PENDING, SATISFIED, VIOLATED }

const MAX_PIP: int = DominoBones.MAX_PIP

## Cells, as grid coordinates. Any shape: the board is a set, not a rectangle.
var cells: Dictionary = {}          ## Vector2i -> region index
## One entry per region: {"cells": Array[Vector2i], "rule": int, "value": int}
var regions: Array = []
## Bones still to place, and bones already down.
var tray: Array = []
## cell -> {"bone": Vector2i, "value": int, "id": int, "partner": Vector2i}
var placed: Dictionary = {}
## Placement id -> {"bone", "a", "b"} where a/b are cells.
var placements: Dictionary = {}
var _next_id: int = 1
## The answer the generator built the board around, as {cell: value}. Generator
## bookkeeping only — the player is never shown it, and a solved board need not
## match it when a puzzle admits more than one answer.
var intended: Dictionary = {}


func has_cell(cell: Vector2i) -> bool:
	return cells.has(cell)


func is_empty_cell(cell: Vector2i) -> bool:
	return cells.has(cell) and not placed.has(cell)


func cell_count() -> int:
	return cells.size()


func region_of(cell: Vector2i) -> int:
	return int(cells.get(cell, -1))


## Can this bone go on these two cells? The cells must both be on the board,
## both empty, and orthogonally adjacent. Pip values are NEVER consulted:
## nothing about a neighbouring bone can make a placement illegal, which is
## exactly what separates this from the matching game.
func can_place(a: Vector2i, b: Vector2i) -> bool:
	if not is_empty_cell(a) or not is_empty_cell(b):
		return false
	var d: Vector2i = b - a
	return absi(d.x) + absi(d.y) == 1


## Place `bone` across cells `a` and `b`. `flipped` swaps which half lands on
## which cell — the bone is the same piece either way, so orientation belongs
## here rather than being patched into `placed` by every caller.
## Returns the placement id, or 0 if the move was refused.
func place(bone: Vector2i, a: Vector2i, b: Vector2i, flipped: bool = false) -> int:
	if not can_place(a, b):
		return 0
	var index: int = tray.find(bone)
	if index < 0:
		return 0
	tray.remove_at(index)
	var id: int = _next_id
	_next_id += 1
	var first: int = bone.y if flipped else bone.x
	var second: int = bone.x if flipped else bone.y
	placed[a] = {"bone": bone, "value": first, "id": id, "partner": b}
	placed[b] = {"bone": bone, "value": second, "id": id, "partner": a}
	placements[id] = {"bone": bone, "a": a, "b": b, "flipped": flipped}
	return id


## Take a placed domino back to the tray. Returns the bone, or (-1,-1).
func lift(cell: Vector2i) -> Vector2i:
	if not placed.has(cell):
		return Vector2i(-1, -1)
	var id: int = int(placed[cell]["id"])
	var entry: Dictionary = placements[id]
	var bone: Vector2i = entry["bone"]
	placed.erase(entry["a"])
	placed.erase(entry["b"])
	placements.erase(id)
	tray.append(bone)
	return bone


func value_at(cell: Vector2i) -> int:
	if not placed.has(cell):
		return -1
	return int(placed[cell]["value"])


## How a region stands right now.
##
## Every rule reports VIOLATED as soon as it CANNOT come good, not merely when
## it is not yet right — a sum already overshot, a value that cannot be reached
## even with sixes in every remaining cell, two different pips under "=".
##
## Written without allocating: the solver calls this twice per search node, and
## an Array plus a Dictionary per call was most of the search's cost. Duplicate
## detection uses a 7-bit mask instead of a set, because pips are 0..6.
func region_status(index: int) -> int:
	var region: Dictionary = regions[index]
	var rule: int = int(region["rule"])
	var target: int = int(region["value"])
	var region_cells: Array = region["cells"]

	var empty: int = 0
	var sum: int = 0
	var first: int = -1
	var seen_mask: int = 0
	var duplicate: bool = false
	var mixed: bool = false

	for cell in region_cells:
		var entry = placed.get(cell)
		if entry == null:
			empty += 1
			continue
		var v: int = int(entry["value"])
		sum += v
		if first < 0:
			first = v
		elif v != first:
			mixed = true
		var bit: int = 1 << v
		if (seen_mask & bit) != 0:
			duplicate = true
		seen_mask |= bit

	var full: bool = empty == 0

	match rule:
		Rule.NONE:
			return Status.SATISFIED if full else Status.PENDING
		Rule.SUM:
			if sum > target:
				return Status.VIOLATED
			if sum + empty * MAX_PIP < target:
				return Status.VIOLATED
			return Status.SATISFIED if full and sum == target else Status.PENDING
		Rule.LESS:
			if sum >= target:
				return Status.VIOLATED
			return Status.SATISFIED if full else Status.PENDING
		Rule.GREATER:
			if sum + empty * MAX_PIP <= target:
				return Status.VIOLATED
			return Status.SATISFIED if full and sum > target else Status.PENDING
		Rule.EQUAL:
			if mixed:
				return Status.VIOLATED
			return Status.SATISFIED if full else Status.PENDING
		Rule.NOT_EQUAL:
			if duplicate:
				return Status.VIOLATED
			# More cells than distinct pip values can never all differ.
			if region_cells.size() > MAX_PIP + 1:
				return Status.VIOLATED
			return Status.SATISFIED if full else Status.PENDING
	return Status.PENDING


func is_solved() -> bool:
	if placed.size() != cells.size():
		return false
	for i in regions.size():
		if region_status(i) != Status.SATISFIED:
			return false
	return true


## True when some region has already been made impossible. The view uses this
## to colour a region red the moment it goes wrong.
func has_violation() -> bool:
	for i in regions.size():
		if region_status(i) == Status.VIOLATED:
			return true
	return false


func clear_board() -> void:
	for id in placements.keys():
		tray.append(placements[id]["bone"])
	placed.clear()
	placements.clear()


## The rule as it is written on the board. A sum shows only its number, which
## is how Pips prints it.
static func rule_text(rule: int, value: int) -> String:
	match rule:
		Rule.SUM:
			return str(value)
		Rule.EQUAL:
			return "="
		Rule.NOT_EQUAL:
			return "≠"
		Rule.LESS:
			return "<%d" % value
		Rule.GREATER:
			return ">%d" % value
	return ""


## Longhand, for the help line under the board.
static func rule_help(rule: int, value: int) -> String:
	match rule:
		Rule.SUM:
			return "must add up to %d" % value
		Rule.EQUAL:
			return "must all be the same"
		Rule.NOT_EQUAL:
			return "must all be different"
		Rule.LESS:
			return "must add up to less than %d" % value
		Rule.GREATER:
			return "must add up to more than %d" % value
	return "anything goes"
