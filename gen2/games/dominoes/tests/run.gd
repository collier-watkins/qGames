extends SceneTree

## Headless tests for the Pips model:
##   godot --headless --path games/dominoes --script res://tests/run.gd
##
## Only autoload-free classes are exercised. An autoload identifier (QConfig,
## Telemetry, QInput) anywhere in a preload chain is not in scope while that
## chain compiles under --script: the whole script fails to compile and its
## statics silently cease to exist. That is why the model files never mention
## one, and why src/main.gd is not touched below.

const BonesT := preload("res://src/bones.gd")
const PuzzleT := preload("res://src/puzzle.gd")
const SolverT := preload("res://src/solver.gd")
const GeneratorT := preload("res://src/generator.gd")
const LibraryT := preload("res://src/library.gd")

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	_test_set()
	_test_placement()
	_test_ends_need_not_match()
	_test_orientation()
	_test_lift()
	_test_rule_sum()
	_test_rule_bounds()
	_test_rule_equal()
	_test_rule_not_equal()
	_test_rule_none()
	_test_solved()
	_test_solver_finds_placement()
	_test_solver_counts_grids_not_tilings()
	_test_generator()
	_test_library_roundtrip()
	_test_shipped_pack()

	print("")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(name: String, condition: bool) -> void:
	if condition:
		_pass += 1
		print("PASS  %s" % name)
	else:
		_fail += 1
		print("FAIL  %s" % name)


func _check_eq(name: String, got, want) -> void:
	if str(got) == str(want):
		_pass += 1
		print("PASS  %s" % name)
	else:
		_fail += 1
		print("FAIL  %s\n        got:  %s\n        want: %s" % [name, got, want])


## A strip of `n` cells in a row, all one region with the given rule.
func _strip(n: int, rule: int, value: int, bones: Array) -> PuzzleT:
	var puzzle: PuzzleT = PuzzleT.new()
	var group: Array = []
	for x in n:
		var cell := Vector2i(x, 0)
		group.append(cell)
		puzzle.cells[cell] = 0
	puzzle.regions.append({"cells": group, "rule": rule, "value": value})
	puzzle.tray.append_array(bones)
	return puzzle


# ── the set ─────────────────────────────────────────────────────────────────


func _test_set() -> void:
	_check_eq("a double-six set is 28 bones", BonesT.full_set().size(), 28)
	_check_eq("holding a bone canonically", BonesT.make(5, 2), Vector2i(2, 5))


# ── placement ───────────────────────────────────────────────────────────────


func _test_placement() -> void:
	var p: PuzzleT = _strip(4, PuzzleT.Rule.NONE, 0, [Vector2i(2, 5), Vector2i(0, 1)])
	_check("two adjacent empty cells accept a bone",
			p.can_place(Vector2i(0, 0), Vector2i(1, 0)))
	_check("cells that are not adjacent do not",
			not p.can_place(Vector2i(0, 0), Vector2i(2, 0)))
	_check("nor a cell that is off the board",
			not p.can_place(Vector2i(0, 0), Vector2i(0, 1)))
	_check("nor a cell to itself", not p.can_place(Vector2i(0, 0), Vector2i(0, 0)))

	_check("placing succeeds", p.place(Vector2i(2, 5), Vector2i(0, 0), Vector2i(1, 0)) != 0)
	_check_eq("and takes the bone out of the tray", p.tray.size(), 1)
	_check_eq("leaving its halves on the cells",
			[p.value_at(Vector2i(0, 0)), p.value_at(Vector2i(1, 0))], [2, 5])
	_check("an occupied cell refuses another bone",
			not p.can_place(Vector2i(1, 0), Vector2i(2, 0)))
	_check("a bone not in the tray cannot be placed",
			p.place(Vector2i(6, 6), Vector2i(2, 0), Vector2i(3, 0)) == 0)


## The rule that separates Pips from dominoes. A 2-5 laid beside a 0-1 puts a
## 5 next to a 0, and that is perfectly legal: only regions matter.
func _test_ends_need_not_match() -> void:
	var p: PuzzleT = _strip(4, PuzzleT.Rule.NONE, 0, [Vector2i(2, 5), Vector2i(0, 1)])
	p.place(Vector2i(2, 5), Vector2i(0, 0), Vector2i(1, 0))
	_check("a bone whose end does not match its neighbour is still legal",
			p.place(Vector2i(0, 1), Vector2i(2, 0), Vector2i(3, 0)) != 0)
	_check_eq("5 and 0 sit happily side by side",
			[p.value_at(Vector2i(1, 0)), p.value_at(Vector2i(2, 0))], [5, 0])


func _test_orientation() -> void:
	var p: PuzzleT = _strip(2, PuzzleT.Rule.NONE, 0, [Vector2i(2, 5)])
	p.place(Vector2i(2, 5), Vector2i(0, 0), Vector2i(1, 0), true)
	_check_eq("flipped puts the high half first",
			[p.value_at(Vector2i(0, 0)), p.value_at(Vector2i(1, 0))], [5, 2])


func _test_lift() -> void:
	var p: PuzzleT = _strip(2, PuzzleT.Rule.NONE, 0, [Vector2i(2, 5)])
	p.place(Vector2i(2, 5), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("lifting returns the bone", p.lift(Vector2i(1, 0)), Vector2i(2, 5))
	_check_eq("it goes back to the tray", p.tray, [Vector2i(2, 5)])
	_check("both cells are empty again",
			p.is_empty_cell(Vector2i(0, 0)) and p.is_empty_cell(Vector2i(1, 0)))
	_check_eq("lifting an empty cell is a no-op", p.lift(Vector2i(0, 0)), Vector2i(-1, -1))


# ── rules ───────────────────────────────────────────────────────────────────


## A rule reports VIOLATED as soon as it cannot come good — not merely when it
## is not yet right. Without that, a player is told nothing until the last cell.
func _test_rule_sum() -> void:
	var p: PuzzleT = _strip(2, PuzzleT.Rule.SUM, 7, [Vector2i(3, 4), Vector2i(6, 6)])
	_check_eq("an empty region is pending", p.region_status(0), PuzzleT.Status.PENDING)
	p.place(Vector2i(3, 4), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("3 + 4 = 7 satisfies it", p.region_status(0), PuzzleT.Status.SATISFIED)

	p.lift(Vector2i(0, 0))
	p.place(Vector2i(6, 6), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("6 + 6 overshoots", p.region_status(0), PuzzleT.Status.VIOLATED)

	# Overshooting HALF way is already fatal: pips cannot be negative.
	var q: PuzzleT = _strip(2, PuzzleT.Rule.SUM, 3, [Vector2i(5, 5)])
	q.place(Vector2i(5, 5), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("a single half over target is violated at once",
			q.region_status(0), PuzzleT.Status.VIOLATED)

	# And a target that can no longer be REACHED is equally dead.
	var r: PuzzleT = _strip(2, PuzzleT.Rule.SUM, 12, [Vector2i(0, 1), Vector2i(6, 6)])
	r.place(Vector2i(0, 1), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("a target now out of reach is violated",
			r.region_status(0), PuzzleT.Status.VIOLATED)


func _test_rule_bounds() -> void:
	var less: PuzzleT = _strip(2, PuzzleT.Rule.LESS, 6, [Vector2i(1, 2), Vector2i(4, 5)])
	less.place(Vector2i(1, 2), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("1 + 2 < 6 satisfies", less.region_status(0), PuzzleT.Status.SATISFIED)
	less.lift(Vector2i(0, 0))
	less.place(Vector2i(4, 5), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("4 + 5 is not < 6", less.region_status(0), PuzzleT.Status.VIOLATED)

	var more: PuzzleT = _strip(2, PuzzleT.Rule.GREATER, 6, [Vector2i(4, 5), Vector2i(0, 1)])
	more.place(Vector2i(4, 5), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("4 + 5 > 6 satisfies", more.region_status(0), PuzzleT.Status.SATISFIED)
	more.lift(Vector2i(0, 0))
	more.place(Vector2i(0, 1), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("0 + 1 is not > 6", more.region_status(0), PuzzleT.Status.VIOLATED)

	# The bound is on the region's SUM, not on each half — checked against two
	# sources because one guide claimed otherwise.
	var sum_rule: PuzzleT = _strip(2, PuzzleT.Rule.LESS, 8, [Vector2i(5, 2)])
	sum_rule.place(Vector2i(5, 2), Vector2i(0, 0), Vector2i(1, 0))
	_check("a half larger than the bound is fine while the SUM is under",
			sum_rule.region_status(0) == PuzzleT.Status.SATISFIED)


func _test_rule_equal() -> void:
	var p: PuzzleT = _strip(2, PuzzleT.Rule.EQUAL, 0, [Vector2i(3, 3), Vector2i(2, 5)])
	p.place(Vector2i(3, 3), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("two 3s are equal", p.region_status(0), PuzzleT.Status.SATISFIED)
	p.lift(Vector2i(0, 0))
	p.place(Vector2i(2, 5), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("a 2 and a 5 are not", p.region_status(0), PuzzleT.Status.VIOLATED)

	# Violated on the FIRST disagreement, with cells still empty.
	var wide: PuzzleT = _strip(4, PuzzleT.Rule.EQUAL, 0, [Vector2i(2, 5), Vector2i(1, 1)])
	wide.place(Vector2i(2, 5), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("a half-filled region already disagreeing is violated",
			wide.region_status(0), PuzzleT.Status.VIOLATED)


func _test_rule_not_equal() -> void:
	var p: PuzzleT = _strip(2, PuzzleT.Rule.NOT_EQUAL, 0, [Vector2i(2, 5), Vector2i(4, 4)])
	p.place(Vector2i(2, 5), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("2 and 5 differ", p.region_status(0), PuzzleT.Status.SATISFIED)
	p.lift(Vector2i(0, 0))
	p.place(Vector2i(4, 4), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("a double cannot be all-different", p.region_status(0), PuzzleT.Status.VIOLATED)

	# Eight cells cannot hold eight different pips: there are only seven values.
	var huge: PuzzleT = _strip(8, PuzzleT.Rule.NOT_EQUAL, 0, [])
	_check_eq("a region larger than the pip range is impossible from the start",
			huge.region_status(0), PuzzleT.Status.VIOLATED)


func _test_rule_none() -> void:
	var p: PuzzleT = _strip(2, PuzzleT.Rule.NONE, 0, [Vector2i(6, 6)])
	_check_eq("an unruled region is pending while empty",
			p.region_status(0), PuzzleT.Status.PENDING)
	p.place(Vector2i(6, 6), Vector2i(0, 0), Vector2i(1, 0))
	_check_eq("and satisfied once full", p.region_status(0), PuzzleT.Status.SATISFIED)


func _test_solved() -> void:
	var p: PuzzleT = _strip(2, PuzzleT.Rule.SUM, 7, [Vector2i(3, 4)])
	_check("an empty board is not solved", not p.is_solved())
	p.place(Vector2i(3, 4), Vector2i(0, 0), Vector2i(1, 0))
	_check("filling it correctly solves it", p.is_solved())
	_check("and nothing is violated", not p.has_violation())


# ── solver ──────────────────────────────────────────────────────────────────


func _test_solver_finds_placement() -> void:
	var p: PuzzleT = _strip(4, PuzzleT.Rule.SUM, 12,
			[Vector2i(3, 4), Vector2i(2, 3), Vector2i(0, 0)])
	var plan: Array = SolverT.new().find_placement(p)
	_check("the solver returns an arrangement, not just values", plan.size() == 2)

	# Replaying the plan on a fresh board must actually solve it — the point of
	# find_placement is that a hint can be applied, not merely displayed.
	var fresh: PuzzleT = _strip(4, PuzzleT.Rule.SUM, 12,
			[Vector2i(3, 4), Vector2i(2, 3), Vector2i(0, 0)])
	for step in plan:
		fresh.place(step["bone"], step["a"], step["b"], step["flipped"])
	_check("and replaying it solves the puzzle", fresh.is_solved())


## Two tilings can leave every cell showing the same number. To anyone
## reasoning about the rules those are one answer, and counting them twice sent
## the generator chasing a difference that did not exist.
func _test_solver_counts_grids_not_tilings() -> void:
	var p: PuzzleT = _strip(4, PuzzleT.Rule.EQUAL, 0,
			[Vector2i(0, 0), Vector2i(0, 0)])
	# Two 0-0 bones in a four-cell row: several tilings, one grid of values.
	p.tray = [Vector2i(0, 0), Vector2i(0, 0)]
	_check_eq("all-zero row has exactly one distinct answer",
			SolverT.new().count_solutions(p, 5), 1)


# ── generator and pack ──────────────────────────────────────────────────────


func _test_generator() -> void:
	for level in [GeneratorT.Level.EASY, GeneratorT.Level.MEDIUM]:
		var puzzle: PuzzleT = GeneratorT.new(level * 31 + 7).build(level)
		_check("the generator produces a puzzle (level %d)" % level, puzzle != null)
		if puzzle == null:
			continue
		_check_eq("with two cells per bone (level %d)" % level,
				puzzle.cell_count(), puzzle.tray.size() * 2)
		var covered: bool = true
		for region in puzzle.regions:
			for cell in region["cells"]:
				if not puzzle.cells.has(cell):
					covered = false
		_check("every region cell is on the board (level %d)" % level, covered)
		# Proved by the solver, not taken on the generator's word.
		_check("and it is solvable (level %d)" % level,
				not SolverT.new().solve(puzzle).is_empty())


func _test_library_roundtrip() -> void:
	var original: PuzzleT = GeneratorT.new(4242).build(GeneratorT.Level.EASY)
	if original == null:
		_check("generator produced a puzzle to encode", false)
		return
	var encoded := {"regions": [], "tray": []}
	for region in original.regions:
		var flat: Array = []
		for cell in region["cells"]:
			flat.append(cell.x)
			flat.append(cell.y)
		encoded["regions"].append({"c": flat, "r": region["rule"], "v": region["value"]})
	for bone in original.tray:
		encoded["tray"].append(bone.x)
		encoded["tray"].append(bone.y)

	var back: PuzzleT = LibraryT.decode(encoded)
	_check_eq("decode restores the cells", back.cell_count(), original.cell_count())
	_check_eq("decode restores the tray", back.tray, original.tray)
	_check_eq("decode restores the regions", back.regions.size(), original.regions.size())
	_check("a decoded puzzle is still solvable",
			not SolverT.new().solve(back).is_empty())


## The pack is what players actually meet, so it is checked rather than trusted.
## Solvability is verified for EVERY puzzle; uniqueness only for a sample,
## because proving it exhausts the search and costs seconds per hard board.
func _test_shipped_pack() -> void:
	var library: LibraryT = LibraryT.new()
	_check("the shipped puzzle pack loads (%s)" % library.load_error, library.loaded)
	if not library.loaded:
		return

	var total: int = 0
	var unsolvable: int = 0
	for level in 3:
		var count: int = library.count(level)
		total += count
		for i in count:
			var puzzle: PuzzleT = library.take(level, i)
			if puzzle == null or SolverT.new().solve(puzzle).is_empty():
				unsolvable += 1
	_check("the pack has puzzles at every level", total >= 3)
	_check_eq("every shipped puzzle is solvable (%d checked)" % total, unsolvable, 0)

	var not_unique: int = 0
	for level in 3:
		if library.count(level) == 0:
			continue
		var sample: PuzzleT = library.take(level, 0)
		if SolverT.new().count_solutions(sample, 2) != 1:
			not_unique += 1
	_check_eq("the sampled puzzles have exactly one answer", not_unique, 0)
