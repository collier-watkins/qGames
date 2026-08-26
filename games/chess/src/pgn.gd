class_name ChessPgn
extends RefCounted

## Writes a finished game as PGN in chess.com's export shape: the seven-tag
## roster, chess.com's own supplementary tags, and a per-move `{[%clk H:MM:SS.t]}`
## comment carrying the mover's remaining time.
##
## Pure and static. The game records moves as it plays them; this only formats.

## Standard PGN wraps the movetext so no line exceeds 80 columns. Nothing
## breaks if it does not, but every tool that round-trips PGN produces it, and
## a diff against a chess.com export should not be full of rewrapping.
const WRAP_COLUMNS: int = 80


static func escape_tag(value: String) -> String:
	## PGN tag values are quoted strings in which `"` and `\` must be escaped.
	## A player called `Sam "Fish" B` would otherwise close the string early
	## and make the whole file unparseable.
	return value.replace("\\", "\\\\").replace("\"", "\\\"")


static func tag(name: String, value: String) -> String:
	return "[%s \"%s\"]" % [name, escape_tag(value)]


static func date_tag(unix_time: int) -> String:
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(unix_time)
	return "%04d.%02d.%02d" % [d.year, d.month, d.day]


static func time_tag(unix_time: int) -> String:
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(unix_time)
	return "%02d:%02d:%02d" % [d.hour, d.minute, d.second]


static func time_control(base_seconds: int, increment_seconds: int) -> String:
	## PGN time control field. "-" is the standard token for no control at all;
	## a bare number is sudden death in seconds; "600+5" adds an increment.
	if base_seconds <= 0:
		return "-"
	if increment_seconds > 0:
		return "%d+%d" % [base_seconds, increment_seconds]
	return str(base_seconds)


static func build(headers: Dictionary, moves: Array) -> String:
	## `moves` is an Array of Dictionaries: {san: String, clock_ms: int}.
	## clock_ms < 0 omits the annotation, which is what an untimed game wants —
	## chess.com never writes a [%clk] it does not have.
	##
	## Tag order follows chess.com's export: the seven required tags of the STR
	## in their mandated order first, then the supplementary ones. Order is not
	## optional in the standard, and readers do rely on it.
	var order: Array[String] = [
		"Event", "Site", "Date", "Round", "White", "Black", "Result",
		"WhiteElo", "BlackElo", "TimeControl", "EndTime", "Termination",
		"UTCDate", "UTCTime", "Variant", "SetUp", "FEN",
	]
	var lines: Array[String] = []
	for key: String in order:
		if headers.has(key):
			lines.append(tag(key, str(headers[key])))
	for key: String in headers.keys():
		if not order.has(key):
			lines.append(tag(key, str(headers[key])))
	lines.append("")

	var tokens: Array[String] = []
	for i in range(moves.size()):
		var m: Dictionary = moves[i]
		if i % 2 == 0:
			tokens.append("%d." % [i / 2 + 1])
		tokens.append(str(m.get("san", "")))
		var clock_ms: int = int(m.get("clock_ms", -1))
		if clock_ms >= 0:
			tokens.append("{[%%clk %s]}" % ChessClock.format_clk(clock_ms))
	tokens.append(str(headers.get("Result", "*")))

	var line: String = ""
	for t: String in tokens:
		if line.is_empty():
			line = t
		elif line.length() + 1 + t.length() <= WRAP_COLUMNS:
			line += " " + t
		else:
			lines.append(line)
			line = t
	if not line.is_empty():
		lines.append(line)
	return "\n".join(lines) + "\n"
