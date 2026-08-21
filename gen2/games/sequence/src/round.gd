class_name SequenceRound
extends RefCounted

## Sequence — "what comes next in the pattern?", for 3–4 year olds.
##
## Pure model: no Node, no drawing, unit-testable headless (house rule 3).
## Ported from the pygame original (~/Projects/qGames/games/sequence/main.py),
## keeping its generation rules exactly so the difficulty curve the kids are
## used to does not shift.

const ROUND_SIZE: int = 10

## One repeating period per entry, as [shape, colour] pairs. Deliberately
## narrow for the age group: four shapes, primary colours, and only AB / AAB /
## ABB pattern types, where exactly one attribute changes at a time.
const PATTERNS: Array = [
	# AB colour, same shape — the simplest case, one thing changes
	[["circle", "blue"], ["circle", "red"]],
	[["circle", "red"], ["circle", "yellow"]],
	[["circle", "green"], ["circle", "blue"]],
	[["circle", "yellow"], ["circle", "green"]],
	[["square", "blue"], ["square", "red"]],
	[["square", "red"], ["square", "green"]],
	[["square", "yellow"], ["square", "orange"]],
	[["square", "orange"], ["square", "blue"]],
	[["triangle", "red"], ["triangle", "blue"]],
	[["triangle", "green"], ["triangle", "yellow"]],
	[["triangle", "blue"], ["triangle", "orange"]],
	[["star", "orange"], ["star", "blue"]],
	[["star", "red"], ["star", "green"]],
	[["star", "yellow"], ["star", "red"]],
	# AB shape, same colour
	[["circle", "red"], ["square", "red"]],
	[["circle", "blue"], ["triangle", "blue"]],
	[["square", "green"], ["triangle", "green"]],
	[["triangle", "yellow"], ["circle", "yellow"]],
	[["star", "orange"], ["circle", "orange"]],
	[["square", "red"], ["star", "red"]],
	[["circle", "blue"], ["star", "blue"]],
	[["triangle", "green"], ["square", "green"]],
	# AAB colour — two the same, then one different
	[["circle", "blue"], ["circle", "blue"], ["circle", "red"]],
	[["circle", "red"], ["circle", "red"], ["circle", "blue"]],
	[["square", "green"], ["square", "green"], ["square", "yellow"]],
	[["square", "yellow"], ["square", "yellow"], ["square", "orange"]],
	[["triangle", "yellow"], ["triangle", "yellow"], ["triangle", "green"]],
	[["triangle", "blue"], ["triangle", "blue"], ["triangle", "red"]],
	[["star", "orange"], ["star", "orange"], ["star", "blue"]],
	# ABB colour — one, then two the same
	[["circle", "blue"], ["circle", "red"], ["circle", "red"]],
	[["circle", "yellow"], ["circle", "green"], ["circle", "green"]],
	[["square", "green"], ["square", "yellow"], ["square", "yellow"]],
	[["square", "orange"], ["square", "blue"], ["square", "blue"]],
	[["triangle", "red"], ["triangle", "blue"], ["triangle", "blue"]],
	[["star", "blue"], ["star", "orange"], ["star", "orange"]],
]

const MAX_VISIBLE: int = 7
const OPTION_COUNT: int = 4

# ── current question ─────────────────────────────────────────────────────────
var visible: Array = []      ## the run of elements shown to the player
var answer: Array = []       ## the element that comes next
var options: Array = []      ## OPTION_COUNT choices, one of which is `answer`
var pattern: Array = []      ## the period the question was generated from

# ── round progress ───────────────────────────────────────────────────────────
var asked: int = 0
var correct_total: int = 0
var results: Array[bool] = []

var _rng := RandomNumberGenerator.new()


## seed 0 means "random" — any other value gives a reproducible round, which is
## what the tests use.
func _init(seed_value: int = 0) -> void:
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()
	next_question()


## Every distinct element appearing anywhere in PATTERNS. Built rather than
## listed so adding a pattern cannot silently desync the distractor pool.
static func all_elements() -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	for pat in PATTERNS:
		for elem in pat:
			var key: String = "%s/%s" % [elem[0], elem[1]]
			if not seen.has(key):
				seen[key] = true
				out.append(elem)
	return out


func next_question() -> void:
	pattern = PATTERNS[_rng.randi_range(0, PATTERNS.size() - 1)]
	var period: int = pattern.size()

	# Show at least two full periods, so the pattern is actually inferable, and
	# never more than MAX_VISIBLE cells or the row stops fitting on a phone.
	var min_show: int = 2 * period
	var max_show: int = mini(MAX_VISIBLE, 4 * period - 1)
	var n_shown: int = _rng.randi_range(min_show, maxi(min_show, max_show))

	# Start at a random phase, so the answer is not always the same element of
	# the period — otherwise a child can win by memorising the library.
	var offset: int = _rng.randi_range(0, period - 1)
	var sequence: Array = []
	for i in range(n_shown + 1):
		sequence.append(pattern[(i + offset) % period])

	visible = sequence.slice(0, n_shown)
	answer = sequence[n_shown]

	# Distractors come from the question's own pattern first: a wrong answer
	# that appears in the sequence is a real discrimination, where a random
	# unrelated shape is a giveaway.
	var from_pattern: Array = []
	for elem in pattern:
		if not _same(elem, answer):
			from_pattern.append(elem)
	var from_pool: Array = []
	for elem in all_elements():
		if _same(elem, answer):
			continue
		if _contains(from_pattern, elem):
			continue
		from_pool.append(elem)

	_shuffle(from_pattern)
	_shuffle(from_pool)

	var distractors: Array = []
	for elem in from_pattern + from_pool:
		if distractors.size() >= OPTION_COUNT - 1:
			break
		if not _contains(distractors, elem):
			distractors.append(elem)

	options = [answer] + distractors
	_shuffle(options)


## Record an answer. Returns true if it was correct. Ignored once the round is
## over, so a stray tap during the end screen cannot corrupt the score.
func answer_with(option_index: int) -> bool:
	if is_over() or option_index < 0 or option_index >= options.size():
		return false
	var right: bool = _same(options[option_index], answer)
	results.append(right)
	asked += 1
	if right:
		correct_total += 1
	return right


func is_over() -> bool:
	return asked >= ROUND_SIZE


## 0–3 stars. Thresholds carried over from the original unchanged.
func stars() -> int:
	if correct_total == ROUND_SIZE:
		return 3
	if correct_total > 6:
		return 2
	if correct_total >= 5:
		return 1
	return 0


func message() -> String:
	if correct_total == ROUND_SIZE:
		return "Perfect score!"
	if correct_total >= 8:
		return "Amazing!"
	if correct_total >= 5:
		return "Good job!"
	if correct_total >= 2:
		return "Keep trying!"
	return "Don't give up!"


static func _same(a: Array, b: Array) -> bool:
	return a.size() == b.size() and a[0] == b[0] and a[1] == b[1]


static func _contains(list: Array, elem: Array) -> bool:
	for e in list:
		if _same(e, elem):
			return true
	return false


## Fisher-Yates against our own RNG. Array.shuffle() uses the global RNG, which
## would make a seeded round non-reproducible and the tests useless.
func _shuffle(list: Array) -> void:
	for i in range(list.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var tmp = list[i]
		list[i] = list[j]
		list[j] = tmp
