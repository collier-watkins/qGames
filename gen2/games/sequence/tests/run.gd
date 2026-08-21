extends SceneTree

## Dependency-free headless test runner for SequenceRound (src/round.gd).
##   godot --headless --path games/sequence --script res://tests/run.gd

const Round := preload("res://src/round.gd")

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	_test_pattern_library_is_well_formed()
	_test_visible_run_follows_the_pattern()
	_test_answer_continues_the_pattern()
	_test_options_contain_the_answer_exactly_once()
	_test_options_are_distinct()
	_test_seeded_rounds_are_reproducible()
	_test_scoring_and_round_length()
	_test_answer_after_round_over_is_ignored()
	_test_stars_and_messages()
	_test_generation_holds_over_many_rounds()

	print("")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(test_name: String, condition: bool) -> void:
	if condition:
		_pass += 1
		print("PASS  %s" % test_name)
	else:
		_fail += 1
		print("FAIL  %s" % test_name)


func _index_of_answer(r) -> int:
	for i in range(r.options.size()):
		if Round._same(r.options[i], r.answer):
			return i
	return -1


func _test_pattern_library_is_well_formed() -> void:
	var ok_len := true
	var ok_shape := true
	var known := ["circle", "square", "triangle", "star"]
	for pat in Round.PATTERNS:
		if pat.size() < 2 or pat.size() > 3:
			ok_len = false
		for elem in pat:
			if elem.size() != 2 or not known.has(elem[0]):
				ok_shape = false
	_check("every pattern is an AB or AAB/ABB period", ok_len)
	_check("every element is a known shape plus a colour", ok_shape)
	_check("the distractor pool is built from the library",
			Round.all_elements().size() > 4)


func _test_visible_run_follows_the_pattern() -> void:
	# The whole game is "spot the repeat", so a visible run that does not
	# actually repeat the period would be unanswerable.
	var all_ok := true
	var enough := true
	for seed_value in range(1, 40):
		var r = Round.new(seed_value)
		var period: int = r.pattern.size()
		if r.visible.size() < 2 * period:
			enough = false
		var off: int = _offset(r)
		if off < 0:
			all_ok = false
			continue
		for i in range(r.visible.size()):
			if not Round._same(r.visible[i], r.pattern[(i + off) % period]):
				all_ok = false
	_check("the visible run is the period repeated", all_ok)
	_check("at least two full periods are always shown", enough)


## Recover the phase the question was generated at. Matching on the first
## element alone is ambiguous — in an AAB period, visible[0] == "A" fits both
## offset 0 and offset 1 — so the only sound recovery is the offset that
## explains the WHOLE visible run. Returns -1 if none does, which is itself a
## failure worth reporting.
func _offset(r) -> int:
	for off in range(r.pattern.size()):
		var fits := true
		for i in range(r.visible.size()):
			if not Round._same(r.visible[i], r.pattern[(i + off) % r.pattern.size()]):
				fits = false
				break
		if fits:
			return off
	return -1


func _test_answer_continues_the_pattern() -> void:
	var ok := true
	for seed_value in range(1, 40):
		var r = Round.new(seed_value)
		var period: int = r.pattern.size()
		var off: int = _offset(r)
		if off < 0:
			ok = false
			continue
		var expected = r.pattern[(r.visible.size() + off) % period]
		if not Round._same(r.answer, expected):
			ok = false
	_check("the answer is the next element of the period", ok)


func _test_options_contain_the_answer_exactly_once() -> void:
	var ok := true
	var count_ok := true
	for seed_value in range(1, 40):
		var r = Round.new(seed_value)
		if r.options.size() != Round.OPTION_COUNT:
			count_ok = false
		var hits := 0
		for o in r.options:
			if Round._same(o, r.answer):
				hits += 1
		if hits != 1:
			ok = false
	_check("there are always four options", count_ok)
	_check("the answer appears exactly once among them", ok)


func _test_options_are_distinct() -> void:
	# A duplicated option would mean two correct-looking taps, one of which
	# scores wrong. Silent and infuriating for a four year old.
	var ok := true
	for seed_value in range(1, 60):
		var r = Round.new(seed_value)
		for i in range(r.options.size()):
			for j in range(i + 1, r.options.size()):
				if Round._same(r.options[i], r.options[j]):
					ok = false
	_check("no option is repeated", ok)


func _test_seeded_rounds_are_reproducible() -> void:
	var a = Round.new(1234)
	var b = Round.new(1234)
	var same: bool = Round._same(a.answer, b.answer) and a.visible.size() == b.visible.size()
	for i in range(a.options.size()):
		if not Round._same(a.options[i], b.options[i]):
			same = false
	_check("the same seed produces the same question, options included", same)

	var c = Round.new(999)
	_check("a different seed produces a different question",
			not Round._same(a.answer, c.answer)
			or a.visible.size() != c.visible.size()
			or not Round._same(a.pattern[0], c.pattern[0]))


func _test_scoring_and_round_length() -> void:
	var r = Round.new(7)
	_check("a round starts empty", r.asked == 0 and r.correct_total == 0)

	# Always answer correctly.
	for i in range(Round.ROUND_SIZE):
		var idx: int = _index_of_answer(r)
		var was_right: bool = r.answer_with(idx)
		if not was_right:
			_check("answering with the answer index scores correct", false)
			return
		if not r.is_over():
			r.next_question()
	_check("a round is exactly ROUND_SIZE questions", r.asked == Round.ROUND_SIZE)
	_check("a perfect round scores every question", r.correct_total == Round.ROUND_SIZE)
	_check("is_over is true at the end", r.is_over())
	_check("one result is recorded per question", r.results.size() == Round.ROUND_SIZE)

	# Always answer wrongly.
	var w = Round.new(8)
	for i in range(Round.ROUND_SIZE):
		var idx: int = _index_of_answer(w)
		w.answer_with((idx + 1) % w.options.size())
		if not w.is_over():
			w.next_question()
	_check("a round of wrong answers scores zero", w.correct_total == 0)
	_check("wrong answers still advance the round", w.asked == Round.ROUND_SIZE)


func _test_answer_after_round_over_is_ignored() -> void:
	var r = Round.new(11)
	for i in range(Round.ROUND_SIZE):
		r.answer_with(_index_of_answer(r))
		if not r.is_over():
			r.next_question()
	var score_before: int = r.correct_total
	var asked_before: int = r.asked
	r.answer_with(_index_of_answer(r))
	_check("a tap after the round ends does not change the score",
			r.correct_total == score_before and r.asked == asked_before)

	var bad = Round.new(12)
	_check("an out-of-range option index is rejected", not bad.answer_with(99))
	_check("a negative option index is rejected", not bad.answer_with(-1))
	_check("rejected answers do not advance the round", bad.asked == 0)


func _test_stars_and_messages() -> void:
	# Thresholds carried over from the pygame original; if these drift, the
	# reward the kids already know changes.
	var cases := {0: 0, 4: 0, 5: 1, 6: 1, 7: 2, 9: 2, 10: 3}
	var ok := true
	for score in cases.keys():
		var r = Round.new(3)
		r.correct_total = score
		if r.stars() != cases[score]:
			ok = false
	_check("star thresholds match the original (5+ = 1, 7+ = 2, 10 = 3)", ok)

	var r10 = Round.new(3)
	r10.correct_total = 10
	var r0 = Round.new(3)
	r0.correct_total = 0
	_check("a perfect round gets its own message", r10.message() == "Perfect score!")
	_check("a zero round still gets an encouraging message",
			r0.message() == "Don't give up!")


func _test_generation_holds_over_many_rounds() -> void:
	# The per-seed tests above each check one question. This walks 300 real
	# questions through the same invariants, which is where an off-by-one in
	# the phase or the distractor pool actually shows up.
	var r = Round.new(4242)
	var ok := true
	var lengths := {}
	for i in range(300):
		if r.visible.size() > Round.MAX_VISIBLE:
			ok = false
		if r.options.size() != Round.OPTION_COUNT:
			ok = false
		if _index_of_answer(r) < 0:
			ok = false
		lengths[r.visible.size()] = true
		r.next_question()
	_check("300 generated questions all hold the invariants", ok)
	_check("visible run length actually varies", lengths.size() > 1)
