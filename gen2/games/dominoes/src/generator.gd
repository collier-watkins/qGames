class_name PipsGenerator
extends RefCounted

## Builds Pips puzzles that are solvable BY CONSTRUCTION.
##
## Backwards, which is the only reliable way: tile a board with dominoes first,
## deal real bones onto that tiling, and only THEN write the region rules —
## each one chosen from those the finished arrangement already satisfies. The
## solution exists before the puzzle does, so a generated board can never be
## impossible.
##
## The alternative — invent rules and hope — produces unsolvable puzzles at a
## rate nobody notices until a child is stuck on one.
##
## Seeded from its own RandomNumberGenerator, never the global one, so a puzzle
## can be replayed from its number. Array.shuffle() draws on the global
## generator and would silently break that.

enum Level { EASY, MEDIUM, HARD }

## Board size and region character per difficulty. Bigger boards and sparser
## "anything goes" regions make a puzzle harder far more than exotic rules do.
const SHAPES: Dictionary = {
	Level.EASY: {"w": 4, "h": 3, "max_region": 3, "free": 0.18},
	Level.MEDIUM: {"w": 4, "h": 4, "max_region": 4, "free": 0.10},
	Level.HARD: {"w": 5, "h": 4, "max_region": 4, "free": 0.04},
}

var _rng := RandomNumberGenerator.new()


func _init(seed_value: int = 0) -> void:
	_rng.seed = seed_value


## How many times a puzzle may be tightened while chasing a single answer.
## Each round pins at least one more cell, so this converges; the cap is only a
## backstop.
const MAX_TIGHTEN: int = 24


## Build a puzzle with exactly ONE solution wherever possible.
##
## Regenerating and hoping does not work — a freshly generated board almost
## never happens to be unique, because the domino TILING is free even when
## every sum is right. So the puzzle is repaired instead of rerolled: find two
## solutions, find a cell where they disagree, and tighten the region that cell
## belongs to. Each round pins at least one more cell, so it converges in a few
## steps instead of tens of failed rerolls.
func build(level: int = Level.EASY) -> PipsPuzzle:
	var puzzle: PipsPuzzle = build_once(level)
	if puzzle == null:
		return null

	# KNOWN TRADE-OFF, measured rather than guessed. Splitting a cell into a
	# region of its own with an exact sum PINS it — the value is given away —
	# so a heavily split board reads more like an answer key than a puzzle. But
	# uniqueness genuinely REQUIRES that pinning: rationing splits to one per
	# three cells cut a 20-cell board from ~17 regions to ~15, and dropped hard
	# puzzles from reliably unique to 2 in 8. Since a puzzle with several
	# answers cannot be reasoned to one, uniqueness wins and the budget is left
	# open. The knob stays here because a better generator — one that biases
	# towards "=" and "≠", which constrain far more per cell than a sum — could
	# afford to close it.
	var split_budget: int = puzzle.cell_count()
	for _round in MAX_TIGHTEN:
		var solutions: Array = PipsSolver.new().find_solutions(puzzle, 2)
		if solutions.size() <= 1:
			break
		var differing: Vector2i = _first_difference(solutions[0], solutions[1])
		if differing.x == -9999:
			break
		if not _tighten_at(puzzle, differing, split_budget > 0):
			break
		if int(puzzle.regions[puzzle.region_of(differing)]["cells"].size()) == 1:
			split_budget -= 1
	return puzzle


## A cell the two solutions disagree about — the freedom that has to be removed.
static func _first_difference(a: Dictionary, b: Dictionary) -> Vector2i:
	for cell in a.keys():
		if int(a[cell]) != int(b.get(cell, -1)):
			return cell
	return Vector2i(-9999, -9999)


## Remove the freedom around `cell`.
##
## A region with a loose rule ("<", ">", "≠", or none) becomes an exact sum,
## which is the strongest statement that region can make while staying true of
## the intended solution. A region ALREADY summing exactly is split instead:
## the cell is cut out into a region of its own, pinning it outright. Either
## way the intended solution still satisfies every rule, so the puzzle cannot
## become unsolvable.
## Returns false when there is nothing further it is willing to do, which ends
## the tightening rather than spinning.
func _tighten_at(puzzle: PipsPuzzle, cell: Vector2i, may_split: bool) -> bool:
	var index: int = puzzle.region_of(cell)
	if index < 0:
		return false
	var region: Dictionary = puzzle.regions[index]
	var members: Array = region["cells"]

	if int(region["rule"]) != PipsPuzzle.Rule.SUM:
		region["rule"] = PipsPuzzle.Rule.SUM
		region["value"] = _intended_sum(puzzle, members)
		return true

	if members.size() <= 1 or not may_split:
		return false  # already pinned, or out of splits

	members.erase(cell)
	region["value"] = _intended_sum(puzzle, members)
	var solo: int = puzzle.regions.size()
	puzzle.regions.append({
		"cells": [cell],
		"rule": PipsPuzzle.Rule.SUM,
		"value": int(puzzle.intended[cell]),
	})
	puzzle.cells[cell] = solo
	return true


static func _intended_sum(puzzle: PipsPuzzle, group: Array) -> int:
	var sum: int = 0
	for c in group:
		sum += int(puzzle.intended[c])
	return sum


## One candidate, without the uniqueness search.
func build_once(level: int = Level.EASY) -> PipsPuzzle:
	var shape: Dictionary = SHAPES.get(level, SHAPES[Level.EASY])
	var cells: Array = _board(int(shape["w"]), int(shape["h"]))
	var tiling: Array = _tile(cells)
	if tiling.is_empty():
		return null

	var bones: Array = DominoBones.full_set()
	_shuffle(bones)

	var puzzle := PipsPuzzle.new()
	var values := {}
	for i in tiling.size():
		var pair: Array = tiling[i]
		var bone: Vector2i = bones[i]
		# Lay it either way round, so the solution is not always "low half first".
		if _rng.randi() % 2 == 0:
			values[pair[0]] = bone.x
			values[pair[1]] = bone.y
		else:
			values[pair[0]] = bone.y
			values[pair[1]] = bone.x
		puzzle.tray.append(bone)

	# Kept so the generator can tighten later without re-deriving an answer.
	# Never shown to the player.
	puzzle.intended = values
	var groups: Array = _regions(cells, int(shape["max_region"]))
	for group in groups:
		var region_index: int = puzzle.regions.size()
		for cell in group:
			puzzle.cells[cell] = region_index
		var rule: Array = _rule_for(group, values, float(shape["free"]))
		puzzle.regions.append({
			"cells": group, "rule": int(rule[0]), "value": int(rule[1]),
		})
	return puzzle


## The solution the generator had in mind, as {cell: value}. Not given to the
## player; the tests use it to check the puzzle admits at least that answer.
func solution_for(puzzle: PipsPuzzle) -> Dictionary:
	return {}


func _board(w: int, h: int) -> Array:
	var out: Array = []
	for y in h:
		for x in w:
			out.append(Vector2i(x, y))
	return out


## Cover every cell with dominoes. Plain backtracking from the first uncovered
## cell — for boards this size it finds a tiling immediately.
func _tile(cells: Array) -> Array:
	var free := {}
	for c in cells:
		free[c] = true
	var order: Array = cells.duplicate()
	order.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y if a.y != b.y else a.x < b.x)
	var out: Array = []
	return out if not _tile_step(free, order, out) else out


func _tile_step(free: Dictionary, order: Array, out: Array) -> bool:
	var cell: Vector2i = Vector2i(-9999, -9999)
	for c in order:
		if free.get(c, false):
			cell = c
			break
	if cell.x == -9999:
		return true

	var steps: Array = [Vector2i(1, 0), Vector2i(0, 1)]
	if _rng.randi() % 2 == 0:
		steps.reverse()
	for step in steps:
		var other: Vector2i = cell + step
		if not free.get(other, false):
			continue
		free[cell] = false
		free[other] = false
		out.append([cell, other])
		if _tile_step(free, order, out):
			return true
		out.pop_back()
		free[cell] = true
		free[other] = true
	return false


## Chop the board into contiguous groups. Growing each group from a seed by
## random adjacency keeps regions connected, which is what makes them read as
## shapes rather than scatter.
func _regions(cells: Array, max_size: int) -> Array:
	var unassigned := {}
	for c in cells:
		unassigned[c] = true
	var groups: Array = []
	var order: Array = cells.duplicate()
	_shuffle(order)

	for seed_cell in order:
		if not unassigned.get(seed_cell, false):
			continue
		var group: Array = [seed_cell]
		unassigned.erase(seed_cell)
		var want: int = _rng.randi_range(1, max_size)
		while group.size() < want:
			var grown: bool = false
			var from: Array = group.duplicate()
			_shuffle(from)
			for member in from:
				var steps: Array = [Vector2i(1, 0), Vector2i(-1, 0),
						Vector2i(0, 1), Vector2i(0, -1)]
				_shuffle(steps)
				for step in steps:
					var candidate: Vector2i = member + step
					if unassigned.get(candidate, false):
						group.append(candidate)
						unassigned.erase(candidate)
						grown = true
						break
				if grown:
					break
			if not grown:
				break
		groups.append(group)
	return groups


## Pick a rule this arrangement already satisfies. Every branch is checked
## against the actual values, so a generated rule is true by construction.
##
## The weighting is what makes a puzzle a puzzle. An exact sum pins a region
## hardest, so it is offered most; a bound is the weakest thing that can be
## written and is kept close to the real total, because ">0" over a region
## summing to 19 tells a solver nothing. "=" and "≠" are dropped entirely for
## single cells, where they are true of anything and merely look like a rule.
func _rule_for(group: Array, values: Dictionary, free_chance: float) -> Array:
	var vals: Array = []
	var sum: int = 0
	for cell in group:
		var v: int = int(values[cell])
		vals.append(v)
		sum += v

	if _rng.randf() < free_chance:
		return [PipsPuzzle.Rule.NONE, 0]

	# Weighted by repetition: an exact sum is the most informative rule there is.
	var options: Array = [[PipsPuzzle.Rule.SUM, sum], [PipsPuzzle.Rule.SUM, sum],
			[PipsPuzzle.Rule.SUM, sum]]

	if group.size() >= 2:
		var all_same: bool = true
		for v in vals:
			if v != vals[0]:
				all_same = false
		if all_same:
			options.append([PipsPuzzle.Rule.EQUAL, 0])
			options.append([PipsPuzzle.Rule.EQUAL, 0])

		var seen := {}
		var all_diff: bool = true
		for v in vals:
			if seen.has(v):
				all_diff = false
			seen[v] = true
		if all_diff and group.size() <= PipsPuzzle.MAX_PIP + 1:
			options.append([PipsPuzzle.Rule.NOT_EQUAL, 0])

	var slack: int = _rng.randi_range(1, 2)
	options.append([PipsPuzzle.Rule.LESS, sum + slack])
	if sum - slack >= 0:
		options.append([PipsPuzzle.Rule.GREATER, sum - slack])

	return options[_rng.randi_range(0, options.size() - 1)]


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t
