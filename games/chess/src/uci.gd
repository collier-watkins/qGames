class_name ChessUci
extends RefCounted

## An optional external UCI engine — Stockfish, in practice — spoken to over a
## pipe. The native search in src/search.gd is the default and the only one
## that ships; this exists so a stronger engine can be dropped in without a
## rewrite, and so nothing has to be bundled to get one.
##
## Every call here BLOCKS on the pipe. It is meant to be driven from the same
## worker thread that drives the native search (see src/opponent.gd), never
## from the frame.
##
## Deliberately not bundled: Debian's Stockfish 16 is ~40 MB installed per
## architecture because the NNUE net is embedded, against a dist/ that is
## already ~810 MB for four games and four architectures — and on Android a
## binary in app-writable storage cannot be executed at all since API 29, so it
## would have to ship as a jniLib in a custom Gradle build. Neither cost buys
## anything for an opponent that already beats every player in the house.

## Where to look, in order. A caller-supplied path wins so a machine can name
## an engine the search path does not know about.
##
## The configured path is a PARAMETER and not a QConfig lookup on purpose: a
## script that names an autoload cannot be preloaded under `--script`, and the
## whole headless test suite preloads its way here. That failure is silent —
## the class compiles, its functions simply cease to exist.
const CANDIDATES: Array[String] = ["stockfish", "/usr/games/stockfish", "/usr/bin/stockfish"]

var _pid: int = -1
var _stdio: FileAccess = null
var path: String = ""
var name: String = ""


static func discover(configured: String = "") -> String:
	## Returns a usable engine path, or "" if there is none. Never throws and
	## never blocks for long: on Android every candidate simply fails.
	if configured != "" and FileAccess.file_exists(configured):
		return configured

	# Beside the game binary first — that is where someone who dropped an
	# engine in next to it would expect it to be found.
	var beside: String = OS.get_executable_path().get_base_dir().path_join("stockfish")
	if FileAccess.file_exists(beside):
		return beside

	for c: String in CANDIDATES:
		if c.begins_with("/") and FileAccess.file_exists(c):
			return c
	var out: Array = []
	if OS.execute("/usr/bin/env", ["which", "stockfish"], out, false) == 0 and not out.is_empty():
		var found: String = str(out[0]).strip_edges()
		if found != "" and FileAccess.file_exists(found):
			return found
	return ""


func open(engine_path: String) -> bool:
	close()
	if engine_path == "":
		return false
	var r: Dictionary = OS.execute_with_pipe(engine_path, [])
	if r.is_empty() or not r.has("stdio"):
		return false
	_pid = int(r.get("pid", -1))
	_stdio = r["stdio"]
	path = engine_path
	_send("uci")
	name = ""
	for i in 200:
		var line: String = _read_line()
		if line == "":
			break
		if line.begins_with("id name "):
			name = line.substr(8).strip_edges()
		if line.begins_with("uciok"):
			_send("isready")
			while _read_line().begins_with("readyok") == false:
				pass
			return true
	close()
	return false


func is_open() -> bool:
	return _stdio != null and _stdio.is_open()


func set_skill(skill: int) -> void:
	## Stockfish's own weakening knob, 0-20. Used only when an external engine
	## is driving; the native search weakens itself differently (see
	## src/opponent.gd), because Skill Level below about 5 produces moves that
	## look random rather than merely weak.
	_send("setoption name Skill Level value %d" % clampi(skill, 0, 20))


func best_move(fen: String, depth: int, movetime_ms: int) -> String:
	## Blocking. Returns a UCI move string, or "" if the engine died.
	if not is_open():
		return ""
	_send("position fen " + fen)
	if movetime_ms > 0:
		_send("go depth %d movetime %d" % [maxi(depth, 1), movetime_ms])
	else:
		_send("go depth %d" % maxi(depth, 1))
	# A bounded read: a broken engine must not hang the worker thread forever.
	for i in 100000:
		var line: String = _read_line()
		if line == "":
			break
		if line.begins_with("bestmove"):
			var parts: PackedStringArray = line.split(" ", false)
			return parts[1] if parts.size() > 1 else ""
	return ""


func close() -> void:
	if _stdio != null and _stdio.is_open():
		_send("quit")
		_stdio.close()
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_stdio = null
	_pid = -1


func _send(cmd: String) -> void:
	if _stdio != null and _stdio.is_open():
		_stdio.store_line(cmd)
		_stdio.flush()


func _read_line() -> String:
	if _stdio == null or not _stdio.is_open():
		return ""
	if _stdio.eof_reached():
		return ""
	return _stdio.get_line()
