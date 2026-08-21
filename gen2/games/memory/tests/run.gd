extends SceneTree

## Dependency-free headless test runner for MemoryBoard (src/board.gd).
## Invoke as:
##   godot --headless --path games/memory --script res://tests/run.gd

const MemoryBoard := preload("res://src/board.gd")
const QMqttClientT := preload("res://addons/qcore/mqtt_client.gd")
const QConfigT := preload("res://addons/qcore/config.gd")

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	_test_deck_composition()
	_test_seeded_shuffle_deterministic()
	_test_flip_same_card_twice_ignored()
	_test_match_sets_matched()
	_test_mismatch_and_resolve()
	_test_moves_increment()
	_test_is_won_only_after_all_pairs()

	_test_mem_slope_needs_evidence()
	_test_mem_slope_detects_a_leak()
	_test_mem_window_drops_old_samples()
	_test_leak_level_thresholds()
	_test_proc_readers()

	_test_game_id_resolution()
	_test_common_result_schema()
	_test_mqtt_queue()
	_test_mqtt_large_payload()
	_test_body_truncation_is_utf8_safe()
	_test_config_layering()
	_test_config_defaults()
	_test_config_writes_only_what_it_was_given()

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


## Same as _check, but prints what it actually got — the difference between a
## failure you can act on and one you have to go re-derive by hand.
func _check_eq(test_name: String, got, want) -> void:
	if str(got) == str(want):
		_pass += 1
		print("PASS  %s" % test_name)
	else:
		_fail += 1
		print("FAIL  %s\n        got:  %s\n        want: %s" % [test_name, got, want])


func _find_matching_pair(b: MemoryBoard) -> Array:
	for i in range(b.cards.size()):
		for j in range(i + 1, b.cards.size()):
			if b.cards[i].pair == b.cards[j].pair:
				return [i, j]
	return [-1, -1]


func _find_mismatched_pair(b: MemoryBoard) -> Array:
	for i in range(b.cards.size()):
		for j in range(i + 1, b.cards.size()):
			if b.cards[i].pair != b.cards[j].pair:
				return [i, j]
	return [-1, -1]


func _test_deck_composition() -> void:
	var b := MemoryBoard.new(1)
	_check("deck has 16 cards", b.cards.size() == 16)

	var counts: Dictionary = {}
	for c in b.cards:
		counts[c.pair] = counts.get(c.pair, 0) + 1

	var all_pairs_of_two := true
	for k in counts.keys():
		if counts[k] != 2:
			all_pairs_of_two = false
	_check("deck has 8 distinct pairs, 2 of each", counts.size() == 8 and all_pairs_of_two)


func _test_seeded_shuffle_deterministic() -> void:
	var b1 := MemoryBoard.new(42)
	var b2 := MemoryBoard.new(42)
	var same := true
	for i in range(b1.cards.size()):
		if b1.cards[i].pair != b2.cards[i].pair:
			same = false
			break
	_check("same seed produces identical deck order", same)


func _test_flip_same_card_twice_ignored() -> void:
	var b := MemoryBoard.new(2)
	var r1 := b.flip(0)
	var r2 := b.flip(0)
	_check("first flip returns 'flipped'", r1 == "flipped")
	_check("flipping the same card again is ignored", r2 == "ignored")


func _test_match_sets_matched() -> void:
	var b := MemoryBoard.new(3)
	var pair: Array = _find_matching_pair(b)
	b.flip(pair[0])
	var result := b.flip(pair[1])
	_check("matching pair returns 'match'", result == "match")
	_check("matched cards are marked matched", b.cards[pair[0]].matched and b.cards[pair[1]].matched)
	_check("matched_pairs increments on a match", b.matched_pairs == 1)


func _test_mismatch_and_resolve() -> void:
	var b := MemoryBoard.new(4)
	var pair: Array = _find_mismatched_pair(b)
	b.flip(pair[0])
	var result := b.flip(pair[1])
	_check("mismatched pair returns 'mismatch'", result == "mismatch")
	_check("mismatched cards stay face up until resolved",
			b.cards[pair[0]].face_up and b.cards[pair[1]].face_up)

	b.resolve_mismatch()
	_check("resolve_mismatch flips both back down",
			not b.cards[pair[0]].face_up and not b.cards[pair[1]].face_up)
	_check("resolve_mismatch does not mark them matched",
			not b.cards[pair[0]].matched and not b.cards[pair[1]].matched)


func _test_moves_increment() -> void:
	var b := MemoryBoard.new(5)
	_check("moves starts at 0", b.moves == 0)
	b.flip(0)
	_check("moves unchanged after the first flip of a pair", b.moves == 0)
	b.flip(1)
	_check("moves increments to 1 after the second flip", b.moves == 1)


func _test_is_won_only_after_all_pairs() -> void:
	var b := MemoryBoard.new(6)
	_check("not won at start", not b.is_won())

	var groups: Dictionary = {}
	for i in range(b.cards.size()):
		var p: int = b.cards[i].pair
		if not groups.has(p):
			groups[p] = []
		groups[p].append(i)

	for p in groups.keys():
		var idxs: Array = groups[p]
		b.flip(idxs[0])
		b.flip(idxs[1])

	_check("is_won true once all 8 pairs are matched", b.is_won())
	_check("matched_pairs equals TOTAL_PAIRS", b.matched_pairs == MemoryBoard.TOTAL_PAIRS)
	_check("moves equals TOTAL_PAIRS after a perfect playthrough", b.moves == MemoryBoard.TOTAL_PAIRS)


# ── qcore: QDebugStats (shared/qcore/debug_stats.gd) ─────────────────────────
# The leak detector is the part with real logic in it, and it is the part that
# would silently lie if it broke — a slope of 0 looks exactly like "healthy".


func _test_mem_slope_needs_evidence() -> void:
	var s := QDebugStats.new()
	_check("slope is NAN with no samples", is_nan(s.mem_slope_mb_per_min()))
	for i in range(3):
		s.push_mem_sample(float(i), 100.0)
	_check("slope is NAN below 4 samples", is_nan(s.mem_slope_mb_per_min()))

	var t := QDebugStats.new()
	for i in range(10):
		t.push_mem_sample(float(i) * 0.1, 100.0)  # 10 samples over 0.9 s
	_check("slope is NAN when the window is too short to fit a line",
			is_nan(t.mem_slope_mb_per_min()))


func _test_mem_slope_detects_a_leak() -> void:
	var flat := QDebugStats.new()
	for i in range(30):
		flat.push_mem_sample(float(i), 200.0)
	_check("flat memory reports ~0 MB/min", absf(flat.mem_slope_mb_per_min()) < 0.001)

	# 0.5 MB per second == 30 MB per minute.
	var leaky := QDebugStats.new()
	for i in range(30):
		leaky.push_mem_sample(float(i), 200.0 + 0.5 * i)
	_check("a 0.5 MB/s climb reports 30 MB/min",
			absf(leaky.mem_slope_mb_per_min() - 30.0) < 0.01)

	var freeing := QDebugStats.new()
	for i in range(30):
		freeing.push_mem_sample(float(i), 200.0 - 0.1 * i)
	_check("memory being released reports a negative slope",
			freeing.mem_slope_mb_per_min() < -5.0)


func _test_mem_window_drops_old_samples() -> void:
	var s := QDebugStats.new()
	# Two hours of samples, one a second, must not accumulate.
	for i in range(7200):
		s.push_mem_sample(float(i), 100.0)
	_check("memory history stays bounded by the window",
			s.mem_sample_count() <= int(QDebugStats.WINDOW_SEC) + 2)

	# A long-past leak must not colour the current reading.
	var s2 := QDebugStats.new()
	for i in range(60):
		s2.push_mem_sample(float(i), 100.0 + 10.0 * i)   # violent leak, then stops
	for i in range(60, 180):
		s2.push_mem_sample(float(i), 700.0)
	_check("an old leak ages out of the window",
			absf(s2.mem_slope_mb_per_min()) < 0.001)


func _test_leak_level_thresholds() -> void:
	var s := QDebugStats.new()
	for i in range(30):
		s.push_mem_sample(float(i), 100.0)
	_check("flat memory is level 0", s.leak_level() == 0)

	var warn := QDebugStats.new()
	for i in range(30):
		warn.push_mem_sample(float(i), 100.0 + (2.0 / 60.0) * i)   # 2 MB/min
	_check("2 MB/min is level 1 (watch)", warn.leak_level() == 1)

	var bad := QDebugStats.new()
	for i in range(30):
		bad.push_mem_sample(float(i), 100.0 + (10.0 / 60.0) * i)   # 10 MB/min
	_check("10 MB/min is level 2 (bad)", bad.leak_level() == 2)

	var orphaned := QDebugStats.new()
	for i in range(30):
		orphaned.push_mem_sample(float(i), 100.0)
	orphaned.orphans = 1
	_check("a single orphan node is level 2 regardless of slope",
			orphaned.leak_level() == 2)


func _test_proc_readers() -> void:
	# Linux and Android both have /proc; CI runs Linux, so these must work.
	# Anywhere else they return -1 and the HUD says "unavailable" — that is a
	# supported outcome, not a failure, so only the Linux case is asserted.
	if not OS.has_feature("linux"):
		print("SKIP  /proc readers (not Linux)")
		return
	var rss := QDebugStats.read_rss_mb()
	_check("read_rss_mb returns a plausible RSS", rss > 1.0 and rss < 100000.0)
	var cpu1 := QDebugStats.read_cpu_seconds()
	_check("read_cpu_seconds returns a non-negative time", cpu1 >= 0.0)
	# Burn a little CPU and confirm the counter moves forward, which is the
	# only thing that makes the percentage meaningful.
	var x := 0.0
	for i in range(2000000):
		x += sqrt(float(i))
	var cpu2 := QDebugStats.read_cpu_seconds()
	_check("read_cpu_seconds is monotonic under load", cpu2 >= cpu1)


# ── qcore: the common MQTT schema (shared/qcore/telemetry_schema.gd) ─────────
# QTelemetrySchema is pure and autoload-free, so the schema every game depends
# on is testable without a broker, a Node, or a clock. Telemetry itself cannot
# be preloaded here: it references the QConfig autoload, whose identifier is
# not in scope when a preload chain compiles under --script, which makes the
# whole script fail to compile and its statics quietly disappear.


func _test_game_id_resolution() -> void:
	_check("a declared id wins over the display name",
			QTelemetrySchema.resolve_game_id("memory", "Memory Match") == "memory")
	_check("an empty declaration falls back to the display name",
			QTelemetrySchema.resolve_game_id("", "Memory Match") == "memory_match")
	_check("whitespace-only declaration counts as empty",
			QTelemetrySchema.resolve_game_id("   ", "Memory Match") == "memory_match")
	_check("ids are lowercased and space-free",
			QTelemetrySchema.resolve_game_id("Battle Ship", "x") == "battle_ship")


func _test_common_result_schema() -> void:
	var pairs: Array = QTelemetrySchema.build_result_pairs("win", 14, "moves", 92,
			[["moves", 14]])

	var keys: Array = []
	for p in pairs:
		keys.append(p[0])

	_check("the core four come first, in order",
			keys.slice(0, 4) == ["result", "score", "score_unit", "duration_s"])
	_check("game-specific extras follow the core", keys[4] == "moves")
	_check("values are carried through",
			pairs[0][1] == "win" and pairs[1][1] == 14
			and pairs[2][1] == "moves" and pairs[3][1] == 92)

	# report() owns appending ts last. If build_result_pairs ever emitted one,
	# the topic would be published twice and the ordering invariant — the whole
	# reason ts exists — would be silently broken.
	_check("build_result_pairs never emits ts itself", not keys.has("ts"))

	var bare: Array = QTelemetrySchema.build_result_pairs("loss", 0, "shots", 5)
	_check("extras are optional", bare.size() == 4)


# ── qcore: the MQTT client's queue discipline ───────────────────────────────


func _test_mqtt_queue() -> void:
	# With no broker configured, poll() never drains — so anything queued would
	# sit there for the life of the process. Since MQTT is on by default, that
	# would be a slow memory leak on every machine that never configured one.
	var nowhere := QMqttClientT.new()
	nowhere.host = ""
	for i in 500:
		nowhere.enqueue("qGames/x/y", "value %d" % i)
	_check("with no broker, nothing is queued", not nowhere.has_pending())
	_check_eq("and the discards are counted", nowhere.dropped, 500)

	# With a broker, the queue is bounded. Going over drops EVERYTHING pending
	# rather than the oldest few: a partially-dropped report would publish some
	# of a round's values with a ts claiming they are current.
	var real := QMqttClientT.new()
	real.host = "192.0.2.1"  # TEST-NET-1, reserved and unroutable by definition
	for i in QMqttClientT.MAX_QUEUE + 1:
		real.enqueue("qGames/x/y", i)
	_check("the queue is cleared once it passes the ceiling",
			not real.has_pending())
	_check_eq("every dropped message is accounted for",
			real.dropped, QMqttClientT.MAX_QUEUE + 1)

	for i in 3:
		real.enqueue("qGames/x/y", i)
	_check_eq("and it keeps queuing afterwards", real.stats()["queued"], 3)


func _test_mqtt_large_payload() -> void:
	# A note published as a retained body is far longer than any scalar this
	# publisher shipped before it, which puts the remaining-length varint on
	# the critical path for the first time.
	_check_eq("a length under 128 is one byte",
			Array(QMqttClientT.encode_remaining_length(127)), [127])
	_check_eq("128 rolls into two bytes, low group first",
			Array(QMqttClientT.encode_remaining_length(128)), [0x80, 0x01])
	_check_eq("16383 is the last two-byte length",
			Array(QMqttClientT.encode_remaining_length(16383)), [0xFF, 0x7F])
	_check_eq("16384 needs three", 
			Array(QMqttClientT.encode_remaining_length(16384)), [0x80, 0x80, 0x01])

	var body: String = "# Note\n\n" + "word ".repeat(4000)
	var packet: PackedByteArray = QMqttClientT.encode_publish(
			"qGames/notes/content", body.to_utf8_buffer(), true)
	_check("a retained publish sets the retain bit", (packet[0] & 0x01) == 1)

	# Walk the varint back off the wire and confirm it describes the rest.
	var i: int = 1
	var mult: int = 1
	var remaining: int = 0
	while true:
		remaining += (packet[i] & 0x7F) * mult
		mult *= 128
		var more: bool = (packet[i] & 0x80) != 0
		i += 1
		if not more:
			break
	_check_eq("the decoded length matches the bytes that follow",
			remaining, packet.size() - i)
	_check_eq("and the payload survives the round trip",
			packet.slice(i + 2 + "qGames/notes/content".length()).get_string_from_utf8(),
			body)


## A body over the cap is truncated rather than handed to the broker whole, and
## the cut must not land inside a character. A byte limit knows nothing about
## characters, so cutting a 4-byte emoji after two bytes would publish an
## incomplete sequence — a replacement character on the wire, and a warning in
## the log on the way out.
func _test_body_truncation_is_utf8_safe() -> void:
	var emoji: String = "🙂"
	_check_eq("the test character really is four bytes",
			emoji.to_utf8_buffer().size(), 4)

	var buf: PackedByteArray = emoji.repeat(50).to_utf8_buffer()
	# 102 lands two bytes into the 26th character — the worst case.
	var cut: int = QTelemetrySchema.utf8_boundary(buf, 102)
	_check_eq("the cut is pulled back to a character boundary", cut, 100)
	_check_eq("so the truncated text holds whole characters only",
			buf.slice(0, cut).get_string_from_utf8(), emoji.repeat(25))
	_check("and no replacement character is produced",
			not buf.slice(0, cut).get_string_from_utf8().contains("�"))

	# A cut already on a boundary must not move, and ASCII is never affected.
	_check_eq("a cut already on a boundary stays put",
			QTelemetrySchema.utf8_boundary(buf, 100), 100)
	_check_eq("plain ASCII cuts anywhere",
			QTelemetrySchema.utf8_boundary("abcdefgh".to_utf8_buffer(), 3), 3)
	_check_eq("a limit past the end clamps to the end",
			QTelemetrySchema.utf8_boundary("abc".to_utf8_buffer(), 999), 3)


# ── qcore: layered config (shared/qcore/config.gd) ──────────────────────────


## config.gd is preloadable — unlike telemetry.gd it names no autoload — so the
## layering can be exercised directly rather than inferred from a running game.
func _test_config_layering() -> void:
	var cfg = QConfigT.new()

	# A missing file at any layer is normal, not an error: the baked config only
	# exists in an export, and the user file only after a setting is changed.
	cfg._values = {"mqtt/broker": "", "build/version": "0.0.0-dev"}
	cfg._merge_file("user://definitely_not_here.cfg")
	_check_eq("a missing config file leaves values untouched",
			cfg._values["mqtt/broker"], "")

	# A later layer overlays an earlier one, key by key, leaving the rest alone.
	var tmp := "user://_layertest.cfg"
	var f := ConfigFile.new()
	f.set_value("mqtt", "broker", "10.0.0.9")
	f.set_value("build", "version", "1.2.3")
	_check("the fixture wrote", f.save(tmp) == OK)
	cfg._merge_file(tmp)
	_check_eq("a merged file overrides the value it names",
			cfg._values["mqtt/broker"], "10.0.0.9")
	_check_eq("and every key it names", cfg._values["build/version"], "1.2.3")

	# Keys the file does not mention survive.
	cfg._values["mqtt/port"] = 1883
	cfg._merge_file(tmp)
	_check_eq("keys the file does not mention are left alone",
			cfg._values["mqtt/port"], 1883)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	cfg.free()


func _test_config_defaults() -> void:
	_check_eq("MQTT is on by default", QConfigT.DEFAULTS["mqtt/enabled"], true)
	_check_eq("but no broker is baked into the repo",
			QConfigT.DEFAULTS["mqtt/broker"], "")
	_check_eq("a source checkout reports itself as a dev build",
			QConfigT.DEFAULTS["build/version"], "0.0.0-dev")
	# The bare-name env fallback is what lets one exported environment serve
	# every game without a QGAMES_ prefix on each line.
	_check_eq("the bare env name for the broker",
			QConfigT.BARE_ENV["mqtt/broker"], "MQTT_BROKER")


## set_value/save must write ONLY what it was given. Writing the whole value set
## would copy the MQTT password out of the environment onto disk.
func _test_config_writes_only_what_it_was_given() -> void:
	var cfg = QConfigT.new()
	cfg._values = {"ui/theme": "light", "mqtt/password": "hunter2"}
	cfg._written = {}
	cfg.set_value("ui/theme", "dark")
	_check_eq("set_value records the key", cfg._written.has("ui/theme"), true)
	_check_eq("and nothing else", cfg._written.size(), 1)
	_check("a password read from the environment is not queued for writing",
			not cfg._written.has("mqtt/password"))
	cfg.free()

