extends SceneTree

## Generate the shipped puzzle pack. Run from the repo root:
##
##   godot --headless --path games/dominoes --script res://tools_gen_puzzles.gd -- 60
##
## WHY A PACK RATHER THAN GENERATING AT RUNTIME: making a puzzle that provably
## has one answer means proving it, and proving it means exhausting the search.
## That measured ~8 seconds for a hard board on this laptop, and a Raspberry Pi
## is several times slower again. Nobody taps "new puzzle" and waits half a
## minute. Generation is therefore done once, here, and the result is committed;
## the game only ever reads it.
##
## The pack is plain JSON so it can be inspected, diffed and regenerated. It is
## small — a few hundred puzzles is tens of kilobytes.

const OUT_PATH := "res://puzzles.json"
const LEVEL_NAMES := ["easy", "medium", "hard"]


func _initialize() -> void:
	var per_level: int = 60
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() > 0 and args[0].is_valid_int():
		per_level = int(args[0])

	var pack := {"version": 1, "levels": {}}
	var started: int = Time.get_ticks_msec()

	for level in [PipsGenerator.Level.EASY, PipsGenerator.Level.MEDIUM,
			PipsGenerator.Level.HARD]:
		var name: String = LEVEL_NAMES[level]
		var list: Array = []
		var level_started: int = Time.get_ticks_msec()
		var rejected: int = 0
		for i in per_level:
			# A distinct seed per puzzle, so the pack can be reproduced exactly.
			var seed_value: int = level * 1000003 + i * 7919 + 17
			var puzzle: PipsPuzzle = PipsGenerator.new(seed_value).build(level)
			if puzzle == null:
				rejected += 1
				continue
			# Never ship a puzzle without checking it: the pack is the thing
			# players actually meet, so it is verified here rather than trusted.
			var solver := PipsSolver.new()
			var found: int = solver.count_solutions(puzzle, 2)
			if found != 1 or solver.exhausted:
				rejected += 1
				continue
			list.append(_encode(puzzle, seed_value))
			if (i + 1) % 10 == 0:
				print("  %s %d/%d (%.1fs)" % [name, i + 1, per_level,
						(Time.get_ticks_msec() - level_started) / 1000.0])
		pack["levels"][name] = list
		print("%s: %d puzzles, %d rejected, %.1fs" % [name, list.size(), rejected,
				(Time.get_ticks_msec() - level_started) / 1000.0])

	var file := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("cannot write " + OUT_PATH)
		quit(1)
		return
	file.store_string(JSON.stringify(pack))
	file.close()
	print("wrote %s in %.1fs" % [OUT_PATH, (Time.get_ticks_msec() - started) / 1000.0])
	quit(0)


## Compact JSON. Cells live only inside their region, since the board is the
## union of its regions — storing them twice would just be a way for the two
## copies to disagree.
func _encode(puzzle: PipsPuzzle, seed_value: int) -> Dictionary:
	var regions: Array = []
	for region in puzzle.regions:
		var flat: Array = []
		for cell in region["cells"]:
			flat.append(int(cell.x))
			flat.append(int(cell.y))
		regions.append({"c": flat, "r": int(region["rule"]), "v": int(region["value"])})
	var tray: Array = []
	for bone in puzzle.tray:
		tray.append(int(bone.x))
		tray.append(int(bone.y))
	return {"seed": seed_value, "regions": regions, "tray": tray}
