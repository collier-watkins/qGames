extends Node

## Game telemetry over MQTT. Autoload as "Telemetry".
##
## Topics are flat scalars, one value per topic:
##
##     qGames/<game_id>/<subtopic>
##
## Flat rather than a JSON blob because Home Assistant binds one MQTT topic to
## one sensor state; a JSON payload forces a value_template on every sensor and
## buys nothing.
##
## The ordering invariant from the old suite is enforced in code rather than
## repeated as a comment in every game: report() always appends the timestamp
## topic LAST, so an automation triggered by "<game>/ts" sees every other value
## already updated.
##
## The wire schema itself — the common core every game publishes, and the
## game-id rules — lives in QTelemetrySchema (telemetry_schema.gd), which is
## pure and unit-tested. This file is the Node that puts it on a socket.

# Re-exported so games can write Telemetry.RESULT_WIN without knowing the
# schema class exists.
const RESULT_WIN := QTelemetrySchema.RESULT_WIN
const RESULT_LOSS := QTelemetrySchema.RESULT_LOSS
const RESULT_QUIT := QTelemetrySchema.RESULT_QUIT
const RESULT_DONE := QTelemetrySchema.RESULT_DONE

var game_name: String = ""

var _client: QMqttClient = null
var _perf_accum: float = 0.0
var _round_start_msec: int = 0
var _selftest_active: bool = false
var _selftest_elapsed: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Identity layering, most specific first: an env/user override (testing and
	# CI), then the id declared in project.godot (the real source — it is a
	# build-time fact, not a per-machine setting), then the display name.
	var declared: String = str(QConfig.get_value("telemetry/game_id", ""))
	if declared.strip_edges() == "":
		declared = str(ProjectSettings.get_setting("telemetry/game_id", ""))
	game_name = QTelemetrySchema.resolve_game_id(
			declared,
			str(ProjectSettings.get_setting("application/config/name", "unknown")))
	_round_start_msec = Time.get_ticks_msec()

	_client = QMqttClient.new()
	_client.host = QConfig.get_value("mqtt/broker", "")
	_client.port = int(QConfig.get_value("mqtt/port", 1883))
	_client.username = QConfig.get_value("mqtt/username", "")
	_client.password = QConfig.get_value("mqtt/password", "")
	_client.client_id = "qgames_%s_%d" % [game_name, randi() % 100000]
	_client.failed.connect(func(reason): push_warning("[telemetry] %s" % reason))

	if _selftest_requested():
		_selftest_begin()


func _process(delta: float) -> void:
	if _client == null:
		return
	_client.poll(delta)

	if _selftest_active:
		_selftest_poll(delta)
		return

	var interval: float = float(QConfig.get_value("telemetry/perf_interval_sec", 0.0))
	if interval > 0.0:
		_perf_accum += delta
		if _perf_accum >= interval:
			_perf_accum = 0.0
			_report_perf()


## Report a finished round in the common schema. This is what games should
## call; report() is the escape hatch for anything that does not fit.
##
##     Telemetry.report_result(Telemetry.RESULT_WIN, board.moves, "moves",
##             [["moves", board.moves]])
## `retained` holds [subtopic, value] pairs published RETAINED and BEFORE the
## scalars — for a body of content rather than a measurement, such as the text
## of the note that was just saved. Retained because the point of putting a
## document on the broker is that a dashboard which restarts an hour later
## still has it; a normal reading is a fact about a moment and would be stale,
## but the note is the current note until it changes.
func report_result(result: String, score: int, score_unit: String,
		extra: Array = [], retained: Array = []) -> void:
	var duration_s: int = int(round(float(Time.get_ticks_msec() - _round_start_msec) / 1000.0))
	_round_start_msec = Time.get_ticks_msec()
	if not retained.is_empty():
		_publish_retained(retained)
	report(QTelemetrySchema.build_result_pairs(
			result, score, score_unit, duration_s, extra))


## Largest body published in one go. A note is a few kilobytes; this is a
## backstop so a pathological document cannot hand the broker a packet it will
## drop the connection over, taking the round's scalars down with it.
const MAX_BODY_BYTES: int = 131072


func _publish_retained(pairs: Array) -> void:
	if not publishing_enabled():
		return
	var prefix: String = QConfig.get_value("mqtt/topic_prefix", "qGames")
	for pair in pairs:
		var value = pair[1]
		if value is String:
			var utf8: PackedByteArray = (value as String).to_utf8_buffer()
			if utf8.size() > MAX_BODY_BYTES:
				push_warning("[telemetry] %s truncated: %d bytes over the %d limit"
						% [pair[0], utf8.size() - MAX_BODY_BYTES, MAX_BODY_BYTES])
				value = utf8.slice(0, QTelemetrySchema.utf8_boundary(
						utf8, MAX_BODY_BYTES)) \
						.get_string_from_utf8()
		_client.enqueue("%s/%s/%s" % [prefix, game_name, pair[0]], value, true)


## Report a completed game. pairs is an Array of [subtopic, value].
## The "<game>/ts" topic is appended automatically, last.
func report(pairs: Array) -> void:
	if not publishing_enabled():
		return
	var prefix: String = QConfig.get_value("mqtt/topic_prefix", "qGames")
	for pair in pairs:
		_client.enqueue("%s/%s/%s" % [prefix, game_name, pair[0]], pair[1], false)
	_client.enqueue("%s/%s/ts" % [prefix, game_name],
			int(Time.get_unix_time_from_system()), false)


## Publish an image (retained) followed by scalar pairs, then ts — image first
## so anything reacting to a later topic sees the new picture.
func report_image(subtopic: String, png: PackedByteArray, pairs: Array = []) -> void:
	if not publishing_enabled():
		return
	var prefix: String = QConfig.get_value("mqtt/topic_prefix", "qGames")
	_client.enqueue("%s/%s/%s" % [prefix, game_name, subtopic], png, true)
	report(pairs)


## Two switches, because they mean different things. `telemetry/enabled` is
## "this game should not report"; `mqtt/enabled` is "this machine should not
## talk to a broker". Both default to on — with no broker configured the client
## publishes nowhere regardless, so on is a safe default rather than a
## surprising one.
func publishing_enabled() -> bool:
	return bool(QConfig.get_value("telemetry/enabled", true)) \
			and bool(QConfig.get_value("mqtt/enabled", true))


# ── the wire self-test ───────────────────────────────────────────────────────
#
## A wrong broker address and no broker address look identical from outside the
## process: both publish nothing, silently, by design. That cost a fortnight
## once — every installed build carried a pre-renumber address baked into its
## .pck and nobody could tell, because the failure mode of "publish nowhere" is
## to say nothing at all.
##
## So: ask the machine that is failing.
##
##     ~/.local/share/qgames/memory/memory --headless -- --telemetry-selftest
##     make selftest GAME=memory
##
## Publishes one message to <prefix>/_selftest/<game_id> — deliberately NOT a
## game topic, so Home Assistant never sees a round that did not happen — then
## prints where it tried to reach and what the client's own counters say, and
## exits nonzero if nothing left the machine. No GUI, no round to finish, and
## no shell environment required: it reads the same layered config the game
## does, so it tests what the game would actually do.
const SELFTEST_ARG := "--telemetry-selftest"
const SELFTEST_TIMEOUT_SEC := 15.0


func _selftest_requested() -> bool:
	# After `--` (the documented form) and before it (the convenient one), so
	# neither invocation silently does nothing.
	return OS.get_cmdline_user_args().has(SELFTEST_ARG) \
			or OS.get_cmdline_args().has(SELFTEST_ARG)


func _selftest_begin() -> void:
	var prefix: String = str(QConfig.get_value("mqtt/topic_prefix", "qGames"))
	print("[selftest] game=%s endpoint=%s topic=%s/_selftest/%s"
			% [game_name, _client.endpoint_label(), prefix, game_name])

	if not publishing_enabled():
		print("[selftest] FAIL — telemetry/enabled=%s mqtt/enabled=%s: this game is switched off"
				% [QConfig.get_value("telemetry/enabled", true),
				QConfig.get_value("mqtt/enabled", true)])
		_selftest_quit(1)
		return

	if str(QConfig.get_value("mqtt/broker", "")).strip_edges() == "":
		print("[selftest] FAIL — no broker configured. Set mqtt/broker in "
				+ "user://config.cfg, bake it with tools/bake_config.sh, or "
				+ "export MQTT_BROKER.")
		_selftest_quit(1)
		return

	_selftest_active = true
	_client.enqueue("%s/_selftest/%s" % [prefix, game_name],
			int(Time.get_unix_time_from_system()), false)


func _selftest_poll(delta: float) -> void:
	_selftest_elapsed += delta
	var stats: Dictionary = _client.stats()
	var done: bool = int(stats["messages_sent"]) > 0 or int(stats["failures"]) > 0
	if not done and _selftest_elapsed < SELFTEST_TIMEOUT_SEC:
		return

	_selftest_active = false
	var sent: int = int(stats["messages_sent"])
	print("[selftest] %s — sent=%d dropped=%d failures=%d bytes_out=%d bytes_in=%d%s"
			% ["OK" if sent > 0 else "FAIL", sent, int(stats["dropped"]),
			int(stats["failures"]), int(stats["bytes_out"]), int(stats["bytes_in"]),
			"" if str(stats["last_error"]) == "" else " last_error=%s" % stats["last_error"]])
	if sent == 0 and _selftest_elapsed >= SELFTEST_TIMEOUT_SEC:
		print("[selftest] timed out after %ds — nothing answered at %s"
				% [int(SELFTEST_TIMEOUT_SEC), _client.endpoint_label()])
	_selftest_quit(0 if sent > 0 else 1)


func _selftest_quit(code: int) -> void:
	var tree: SceneTree = get_tree()
	if tree != null:
		tree.quit(code)


## MQTT I/O snapshot for the debug HUD (QDebug). Includes the things that
## explain a silent telemetry failure: whether a broker is even configured,
## whether telemetry is switched off, and the client's own counters.
func io_stats() -> Dictionary:
	var out: Dictionary = {
		"game": game_name,
		"enabled": publishing_enabled(),
		"mqtt_enabled": bool(QConfig.get_value("mqtt/enabled", true)),
		"prefix": str(QConfig.get_value("mqtt/topic_prefix", "qGames")),
		"perf_interval_sec": float(QConfig.get_value("telemetry/perf_interval_sec", 0.0)),
	}
	if _client == null:
		out["state"] = "no client"
		return out
	out.merge(_client.stats())
	return out


func _report_perf() -> void:
	report([
		["perf/fps", int(Performance.get_monitor(Performance.TIME_FPS))],
		["perf/mem_mb", int(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0)],
		["perf/objects", int(Performance.get_monitor(Performance.OBJECT_COUNT))],
	])
