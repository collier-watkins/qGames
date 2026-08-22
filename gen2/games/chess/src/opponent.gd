class_name ChessOpponent
extends RefCounted

## The computer player: difficulty levels, and the thread that keeps thinking
## off the frame.
##
## The search runs on a worker Thread and is polled once a frame. A time-sliced
## search on the main thread was the alternative and is worse in the one way
## that matters here — the deepest level wants two or three seconds, and slicing
## that across frames means the board stops responding to a child's touch while
## the machine thinks. A thread gets a live board and a spinner instead.
##
## The worker is handed a FEN, never the game's own ChessBoard. Two threads on
## one mutable board is the obvious way to corrupt a position, and copying via
## FEN costs microseconds against a search measured in hundreds of milliseconds.

const B := preload("res://src/board.gd")
const S := preload("res://src/search.gd")
const U := preload("res://src/uci.gd")

## Eight levels. `noise` is the width, in centipawns, of a uniform random bonus
## added to each ROOT move's score before the best is chosen — the search is
## never crippled, it is only overruled. That matters: a weak level made by
## searching one ply produces moves that are stupid in a boring, uniform way,
## while a full search plus noise produces a player that develops sensibly and
## then hangs a piece, which is what a human beginner does and what a child can
## learn to punish.
##
## `min_think_ms` is a floor on how long a move takes to arrive. An opponent
## that answers instantly does not read as an opponent.
const LEVELS: Array[Dictionary] = [
	{"name": "Beginner", "depth": 1, "budget_ms": 60, "noise": 320, "skill": 0, "min_think_ms": 450},
	{"name": "Very easy", "depth": 2, "budget_ms": 120, "noise": 210, "skill": 2, "min_think_ms": 450},
	{"name": "Easy", "depth": 3, "budget_ms": 220, "noise": 130, "skill": 4, "min_think_ms": 450},
	{"name": "Gentle", "depth": 4, "budget_ms": 400, "noise": 75, "skill": 7, "min_think_ms": 400},
	{"name": "Fair", "depth": 5, "budget_ms": 700, "noise": 42, "skill": 10, "min_think_ms": 350},
	{"name": "Tough", "depth": 6, "budget_ms": 1200, "noise": 20, "skill": 13, "min_think_ms": 300},
	{"name": "Hard", "depth": 8, "budget_ms": 2000, "noise": 8, "skill": 17, "min_think_ms": 250},
	{"name": "Ruthless", "depth": 20, "budget_ms": 3000, "noise": 0, "skill": 20, "min_think_ms": 200},
]

## A mate found or a mate avoided is never overruled by noise. Without this a
## low level would walk into mate in one at random, which reads as broken
## rather than as weak, and — worse for a beginner — would sometimes MISS a
## mate it had already found, so the game refuses to end.
const NOISE_IMMUNE_CP: int = 900

var level: int = 4                    ## 1..8
var external_enabled: bool = false
var external_name: String = ""

var last_depth: int = 0
var last_score: int = 0
var last_nodes: int = 0
var last_ms: int = 0

var _thread: Thread = null
var _mutex: Mutex = Mutex.new()
var _result: int = 0
var _done: bool = false
var _thinking: bool = false
var _ready_at_ms: int = 0
## Owned RNG, never the global one. A seeded opponent is reproducible, which is
## what lets a test assert that level 1 and level 8 differ without the assertion
## depending on whatever else in the process last called randi().
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _uci: ChessUci = null


func _init(seed_value: int = 0) -> void:
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()


func level_config() -> Dictionary:
	return LEVELS[clampi(level - 1, 0, LEVELS.size() - 1)]


func level_name() -> String:
	return str(level_config()["name"])


func try_external(configured_path: String = "") -> bool:
	## Opt-in, and silent when it fails: no engine present is the normal case,
	## not an error.
	var path: String = U.discover(configured_path)
	if path == "":
		return false
	_uci = U.new()
	if not _uci.open(path):
		_uci = null
		return false
	external_enabled = true
	external_name = _uci.name if _uci.name != "" else path.get_file()
	return true


func think(board: ChessBoard, avoid_keys: Dictionary = {}) -> void:
	if _thinking:
		return
	_thinking = true
	_done = false
	_result = 0
	var cfg: Dictionary = level_config()
	_ready_at_ms = Time.get_ticks_msec() + int(cfg["min_think_ms"])
	_thread = Thread.new()
	_thread.start(_worker.bind(board.fen(), avoid_keys.duplicate(), cfg))


func is_thinking() -> bool:
	return _thinking


func poll() -> int:
	## Returns the chosen move once the search has finished AND the minimum
	## thinking time has elapsed; 0 until then. Called once a frame.
	if not _thinking:
		return 0
	_mutex.lock()
	var done: bool = _done
	var move: int = _result
	_mutex.unlock()
	if not done or Time.get_ticks_msec() < _ready_at_ms:
		return 0
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_thinking = false
	return move


func shutdown() -> void:
	## Must be called before the owner goes away. A running Thread that is
	## never waited on prints an error on exit and can outlive the scene.
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_thinking = false
	if _uci != null:
		_uci.close()
		_uci = null


# ------------------------------------------------------------- worker thread

func _worker(fen: String, avoid_keys: Dictionary, cfg: Dictionary) -> void:
	var t0: int = Time.get_ticks_msec()
	var board: ChessBoard = B.new(fen)
	var move: int = 0
	if _uci != null and _uci.is_open():
		_uci.set_skill(int(cfg["skill"]))
		var uci_move: String = _uci.best_move(fen, int(cfg["depth"]), int(cfg["budget_ms"]))
		move = board.move_from_uci(uci_move)
	if move == 0:
		var s: ChessSearch = S.new()
		var r: Dictionary = s.search(board, int(cfg["depth"]), int(cfg["budget_ms"]), avoid_keys)
		last_depth = int(r["depth"])
		last_score = int(r["score"])
		last_nodes = int(r["nodes"])
		move = choose(r["scored"], int(cfg["noise"]))
	last_ms = Time.get_ticks_msec() - t0
	_mutex.lock()
	_result = move
	_done = true
	_mutex.unlock()


func choose(scored: Array, noise: int) -> int:
	## Pick a root move given every move's searched score. Public and pure so a
	## test can drive it with a fixed list instead of a real search.
	if scored.is_empty():
		return 0
	var best_real: int = -(1 << 30)
	for entry: Array in scored:
		best_real = maxi(best_real, int(entry[1]))
	# Anything decisive is exempt from noise, in both directions.
	var decisive: bool = absi(best_real) >= NOISE_IMMUNE_CP
	var best_move: int = int(scored[0][0])
	var best_value: int = -(1 << 30)
	for entry: Array in scored:
		var v: int = int(entry[1])
		if noise > 0 and not decisive:
			v += _rng.randi_range(0, noise)
		if v > best_value:
			best_value = v
			best_move = int(entry[0])
	return best_move
