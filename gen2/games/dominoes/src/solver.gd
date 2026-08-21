class_name PipsSolver
extends RefCounted

## Backtracking solver for a Pips board.
##
## It exists for three jobs, and the third is the important one:
##   1. the generator uses it to keep puzzles from having a hundred answers,
##   2. the hint button uses it to fill one correct cell,
##   3. the TESTS use it to prove a generated puzzle is solvable WITHOUT
##      trusting the generator — which is the only way to catch a generator
##      that quietly emits impossible boards.
##
## The search always extends from the first empty cell in a fixed order. Every
## tiling of the board is therefore reached exactly once, so counting solutions
## really counts them rather than counting orderings of the same one.

## Ceiling on search steps, so a pathological board cannot hang the game. A
## solve that needs more than this is reported as "not found" rather than being
## allowed to freeze a child's screen.
const MAX_STEPS: int = 400000

var steps: int = 0
## True when the search hit its step ceiling, so its answer is a lower bound
## rather than the truth. Callers that care must check it.
var exhausted: bool = false
## Value grids already recorded, so the same answer reached by a different
## tiling is not counted twice.
var _seen_grids: Dictionary = {}
## Where find_placement() collects the arrangement of the first solution.
var _capture: Array = []


## First solution as {cell: value}, or {} if there is none within the budget.
func solve(puzzle: PipsPuzzle) -> Dictionary:
	var found: Array = _search(puzzle, 1)
	return found[0] if not found.is_empty() else {}


## How many DISTINCT ANSWERS there are, stopping at `limit`.
##
## "Distinct" means a different grid of pip values, not a different arrangement
## of bones. Two tilings can cover the board with different dominoes and leave
## every cell showing the same number; to a solver reasoning about the rules
## those are the same answer, and counting them separately made the generator
## chase a difference that did not exist.
func count_solutions(puzzle: PipsPuzzle, limit: int = 2) -> int:
	return _search(puzzle, limit).size()


## The arrangement of a first solution: [{bone, a, b, flipped}], ready to feed
## straight back into PipsPuzzle.place(). The value grid alone is not enough to
## reproduce a solution, because it does not say which cells share a domino —
## which is what a hint has to know.
func find_placement(puzzle: PipsPuzzle) -> Array:
	var out: Array = []
	var found: Array = _search(puzzle, 1, out)
	return out


## The first `limit` solutions, each as {cell: value}. The generator needs the
## solutions themselves, not the count: two of them differing at some cell is
## precisely the evidence it uses to decide which region to tighten.
func find_solutions(puzzle: PipsPuzzle, limit: int = 2) -> Array:
	return _search(puzzle, limit)


func _search(puzzle: PipsPuzzle, limit: int, capture: Array = []) -> Array:
	steps = 0
	exhausted = false
	# Work on the board as handed over: a partly filled board is a legitimate
	# starting point, which is what makes the hint button possible.
	var order: Array = puzzle.cells.keys()
	order.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y if a.y != b.y else a.x < b.x)
	var out: Array = []
	_seen_grids.clear()
	_capture = capture
	_recurse(puzzle, order, out, limit)
	_capture = []
	return out


func _recurse(puzzle: PipsPuzzle, order: Array, out: Array, limit: int) -> bool:
	if out.size() >= limit:
		return true
	steps += 1
	if steps > MAX_STEPS:
		exhausted = true
		return true

	var cell: Vector2i = Vector2i(-9999, -9999)
	for c in order:
		if not puzzle.placed.has(c):
			cell = c
			break

	if cell.x == -9999:
		if puzzle.is_solved():
			var snapshot := {}
			var key: String = ""
			for c in order:
				var v: int = puzzle.value_at(c)
				snapshot[c] = v
				key += str(v)
			if not _seen_grids.has(key):
				_seen_grids[key] = true
				out.append(snapshot)
				if _capture.is_empty():
					for id in puzzle.placements.keys():
						var pl: Dictionary = puzzle.placements[id]
						_capture.append({"bone": pl["bone"], "a": pl["a"],
								"b": pl["b"], "flipped": pl["flipped"]})
		return out.size() >= limit

	# Only forward neighbours need trying: the cell behind has already been
	# filled by the time this cell is the first empty one.
	# A copy, because placing mutates the tray underneath the iteration. Taken
	# once per node: the tray cannot change between the four directions.
	# No duplicate check is needed — a Pips tray holds distinct bones.
	var candidates: Array = puzzle.tray.duplicate()
	for step in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
		var other: Vector2i = cell + step
		if not puzzle.is_empty_cell(other):
			continue
		for bone in candidates:
			# A double reads the same either way round, so trying both would
			# double the search and count every solution twice.
			var flips: Array = [false] if bone.x == bone.y else [false, true]
			for flipped in flips:
				var id: int = puzzle.place(bone, cell, other, flipped)
				if id == 0:
					continue
				if not _hurts(puzzle, cell, other):
					if _recurse(puzzle, order, out, limit):
						puzzle.lift(cell)
						return true
				puzzle.lift(cell)
	return false


## Would either touched cell's region now be impossible? Checking only those
## two regions rather than all of them is what keeps the search usable.
func _hurts(puzzle: PipsPuzzle, a: Vector2i, b: Vector2i) -> bool:
	var ra: int = puzzle.region_of(a)
	var rb: int = puzzle.region_of(b)
	if ra >= 0 and puzzle.region_status(ra) == PipsPuzzle.Status.VIOLATED:
		return true
	if rb >= 0 and rb != ra and puzzle.region_status(rb) == PipsPuzzle.Status.VIOLATED:
		return true
	return false
