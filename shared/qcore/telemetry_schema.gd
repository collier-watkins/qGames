class_name QTelemetrySchema
extends RefCounted

## The MQTT schema every qGames title publishes. Pure — imports no Node and
## touches no autoload — so it is unit-testable headless and, importantly, can
## be preloaded from a `--script` test runner. Telemetry (the autoload) is not:
## it references QConfig, and autoload identifiers are not in scope at the
## moment a preload chain compiles, so the whole script fails to compile and
## its static functions silently cease to exist. Keeping the schema here is
## what makes it testable at all.
##
## ── the common core ─────────────────────────────────────────────────────────
## Every game publishes these, in this order, under qGames/<game_id>/:
##
##     result       "win" | "loss" | "quit" | "done"
##     score        int — whatever this game counts
##     score_unit   "moves" | "shots" | "rounds" | "correct" — labels `score`
##     duration_s   int — length of the round just finished
##     ts           unix seconds, appended by Telemetry.report(), ALWAYS last
##
## One Home Assistant card then works for every game with no per-game
## templates. Anything else a game wants goes in `extra` under the same
## namespace, which is how a game keeps publishing its historical topic names
## (memory still emits `moves`) without breaking existing sensors.
##
## Topics are flat scalars, one value per topic, rather than a JSON blob:
## Home Assistant binds one MQTT topic to one sensor state, so JSON would force
## a value_template on every sensor and buy nothing.

const RESULT_WIN := "win"
const RESULT_LOSS := "loss"
const RESULT_QUIT := "quit"
const RESULT_DONE := "done"

const RESULTS: Array[String] = [RESULT_WIN, RESULT_LOSS, RESULT_QUIT, RESULT_DONE]

## The core subtopics, in publish order. "ts" is deliberately absent — report()
## owns appending it last, and emitting it here would publish it twice and
## break the ordering invariant it exists to provide.
const CORE_KEYS: Array[String] = ["result", "score", "score_unit", "duration_s"]


## The MQTT namespace for a game. Declared id wins; the display name is only a
## fallback so a game that has not set one still publishes somewhere sensible.
##
## Deriving this from application/config/name — the old behaviour — meant
## renaming a game silently repointed every Home Assistant sensor at a topic
## nobody publishes. "Memory Match" became qGames/memory_match/ and orphaned
## every qGames/memory/ sensor with no error anywhere.
static func resolve_game_id(declared: String, display_name: String) -> String:
	var id: String = declared.strip_edges()
	if id == "":
		id = display_name
	return id.to_lower().strip_edges().replace(" ", "_")


## Build the ordered [subtopic, value] pairs for a finished round.
static func build_result_pairs(result: String, score: int, score_unit: String,
		duration_s: int, extra: Array = []) -> Array:
	var pairs: Array = [
		[CORE_KEYS[0], result],
		[CORE_KEYS[1], score],
		[CORE_KEYS[2], score_unit],
		[CORE_KEYS[3], duration_s],
	]
	pairs.append_array(extra)
	return pairs


## The largest cut at or below `limit` that does not land inside a character.
##
## Lives here rather than in telemetry.gd for the same reason the rest of this
## file does: telemetry.gd names the QConfig autoload, and an autoload
## identifier is not in scope while a preload chain compiles under `--script`,
## so the whole file fails to compile and its statics silently vanish. A pure
## function that needs testing has to live somewhere testable.
##
## A byte limit knows nothing about characters: cutting a 4-byte emoji after two
## bytes yields an incomplete sequence, which decodes to a replacement character
## and complains on the way. UTF-8 continuation bytes are 10xxxxxx, so walking
## back to the first byte that is not one lands on a character start.
static func utf8_boundary(buf: PackedByteArray, limit: int) -> int:
	var cut: int = mini(limit, buf.size())
	# Nothing is being cut off, so nothing can be cut in half — and buf[cut]
	# would be one past the end.
	if cut >= buf.size():
		return buf.size()
	while cut > 0 and (buf[cut] & 0xC0) == 0x80:
		cut -= 1
	return cut

