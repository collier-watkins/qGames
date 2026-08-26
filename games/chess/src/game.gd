class_name ChessGame
extends RefCounted

## One game: the position, the clock, the move record and how it ended. Pure
## RefCounted — the view reads it and the view draws; it decides nothing.
##
## The move record is kept as it is played, in SAN, with the mover's remaining
## clock at the moment the move was made. Reconstructing SAN afterwards from a
## list of coordinates would need the position each move was played in, which
## is exactly the thing that has been thrown away by then.

const B := preload("res://src/board.gd")

const RESULT_WHITE: String = "1-0"
const RESULT_BLACK: String = "0-1"
const RESULT_DRAW: String = "1/2-1/2"
const RESULT_UNFINISHED: String = "*"

var board: ChessBoard = null
var clock: ChessClock = null
var human_side: int = 1
var level: int = 4
var level_name: String = ""
var human_name: String = "Player"

## One entry per ply: {san, uci, clock_ms, think_ms, fen_before}.
var records: Array = []
var started_unix: int = 0
var ended_unix: int = 0
var result: String = RESULT_UNFINISHED
var termination: String = ""
var over: bool = false

var _move_started_ms: int = 0


func _init() -> void:
	board = B.new()
	clock = ChessClock.new()


func start(side_for_human: int, base_seconds: int, increment_seconds: int,
		difficulty: int, difficulty_name: String) -> void:
	board = B.new()
	clock = ChessClock.new(base_seconds, increment_seconds)
	human_side = side_for_human
	level = difficulty
	level_name = difficulty_name
	records = []
	result = RESULT_UNFINISHED
	termination = ""
	over = false
	started_unix = int(Time.get_unix_time_from_system())
	ended_unix = 0
	_move_started_ms = Time.get_ticks_msec()
	clock.start(B.WHITE)


func side_to_move() -> int:
	return board.side


func is_human_turn() -> bool:
	return not over and board.side == human_side


func computer_side() -> int:
	return -human_side


func apply(m: int) -> bool:
	## Records SAN BEFORE making the move — SAN is a statement about the
	## position the move was played in, and after the move that position is
	## gone. Then makes it, stops the clock for the mover and starts it for the
	## opponent, and asks the board whether the game is now over.
	if over or m == 0:
		return false
	var legal: bool = false
	for candidate in board.legal_moves():
		if candidate == m:
			legal = true
			break
	if not legal:
		return false

	var mover: int = board.side
	var text: String = board.san(m)
	var uci: String = B.move_uci(m)
	var fen_before: String = board.fen()
	board.make_move(m)
	clock.on_move_made(mover)
	var now: int = Time.get_ticks_msec()
	records.append({
		"san": text,
		"uci": uci,
		"clock_ms": clock.ms_left(mover) if not clock.is_unlimited() else -1,
		"think_ms": now - _move_started_ms,
		"fen_before": fen_before,
	})
	_move_started_ms = now
	_check_terminal()
	return true


func _check_terminal() -> void:
	var s: int = board.status()
	if s == B.ONGOING:
		return
	match s:
		B.CHECKMATE:
			# The side to move has been mated, so the winner is the other one.
			_finish(RESULT_BLACK if board.side == B.WHITE else RESULT_WHITE,
					"%s won by checkmate" % name_of(-board.side))
		B.STALEMATE:
			_finish(RESULT_DRAW, "Game drawn by stalemate")
		B.DRAW_MATERIAL:
			_finish(RESULT_DRAW, "Game drawn by insufficient material")
		B.DRAW_FIFTY:
			_finish(RESULT_DRAW, "Game drawn by the 50-move rule")
		B.DRAW_REPETITION:
			_finish(RESULT_DRAW, "Game drawn by repetition")


func on_flag(flagged: int) -> void:
	## Time out. If the winner cannot possibly mate with what they have left,
	## it is a draw and not a win — the rule everyone forgets, and the one that
	## a child with a lone king on the wrong end of a flag fall notices.
	if over:
		return
	var winner: int = -flagged
	if _only_king_or_worse(winner):
		_finish(RESULT_DRAW, "Game drawn by timeout vs insufficient material")
	else:
		_finish(RESULT_WHITE if winner == B.WHITE else RESULT_BLACK,
				"%s won on time" % name_of(winner))


func resign(side: int) -> void:
	if over:
		return
	var winner: int = -side
	_finish(RESULT_WHITE if winner == B.WHITE else RESULT_BLACK,
			"%s won by resignation" % name_of(winner))


func agree_draw() -> void:
	if over:
		return
	_finish(RESULT_DRAW, "Game drawn by agreement")


func abandon() -> void:
	## Quit mid-game. The record is still worth publishing — how far a game got
	## before it was abandoned is the interesting part — but it is not a result.
	if over:
		return
	ended_unix = int(Time.get_unix_time_from_system())
	termination = "Game abandoned"
	over = true
	clock.stop()


func _finish(r: String, reason: String) -> void:
	result = r
	termination = reason
	over = true
	ended_unix = int(Time.get_unix_time_from_system())
	clock.stop()


func _only_king_or_worse(side: int) -> bool:
	## True when `side` has no piece that could ever deliver mate.
	var minors: int = 0
	for sq in 128:
		if sq & 0x88:
			continue
		var p: int = board.board[sq]
		if p == 0 or (p > 0) != (side > 0):
			continue
		var t: int = absi(p)
		if t == B.KING:
			continue
		if t == B.PAWN or t == B.ROOK or t == B.QUEEN:
			return false
		minors += 1
	return minors <= 1


func takeback() -> bool:
	## Undoes back to the human's turn — normally two plies, one if the
	## computer has not answered yet. A takeback of one ply would hand the
	## board back with the computer still to move, which from a child's side of
	## the table looks like the takeback did nothing.
	if over or records.is_empty():
		return false
	board.undo_move()
	records.pop_back()
	if board.side != human_side and not records.is_empty():
		board.undo_move()
		records.pop_back()
	clock.start(board.side)
	_move_started_ms = Time.get_ticks_msec()
	return true


func name_of(side: int) -> String:
	if side == human_side:
		return human_name
	return "Computer"


func white_name() -> String:
	return name_of(B.WHITE)


func black_name() -> String:
	return name_of(B.BLACK)


func duration_s() -> int:
	var end: int = ended_unix if ended_unix > 0 else int(Time.get_unix_time_from_system())
	return maxi(0, end - started_unix)


func move_number_text(index: int) -> String:
	return "%d." % [index / 2 + 1] if index % 2 == 0 else ""


func headers() -> Dictionary:
	## chess.com's tag roster, with our names in it. Site is ours rather than
	## theirs — claiming a game was played on chess.com when it was not is the
	## sort of small lie that makes an archive untrustworthy.
	var h: Dictionary = {
		"Event": "Casual Game",
		"Site": "qGames Chess",
		"Date": ChessPgn.date_tag(started_unix),
		"Round": "-",
		"White": white_name(),
		"Black": black_name(),
		"Result": result,
		"TimeControl": ChessPgn.time_control(clock.base_ms / 1000, clock.increment_ms / 1000),
		"Termination": termination if termination != "" else "Unterminated",
		"UTCDate": ChessPgn.date_tag(started_unix),
		"UTCTime": ChessPgn.time_tag(started_unix),
	}
	if ended_unix > 0:
		h["EndTime"] = ChessPgn.time_tag(ended_unix)
	return h


func pgn() -> String:
	return ChessPgn.build(headers(), records)


func telemetry_extra() -> Array:
	## Game-specific topics alongside the common schema. Flat scalars, one
	## value per topic, per the house rule.
	var human_ms: int = clock.ms_left(human_side)
	return [
		["moves", int(ceil(records.size() / 2.0))],
		["plies", records.size()],
		["level", level],
		["level_name", level_name],
		["played_as", "white" if human_side == B.WHITE else "black"],
		["termination", termination],
		["pgn_result", result],
		["time_control", ChessPgn.time_control(clock.base_ms / 1000, clock.increment_ms / 1000)],
		["clock_left_s", int(human_ms / 1000) if not clock.is_unlimited() else -1],
	]


func telemetry_result() -> String:
	if result == RESULT_DRAW:
		return "draw"
	if result == RESULT_UNFINISHED:
		return "quit"
	var human_won: bool = (result == RESULT_WHITE) == (human_side == B.WHITE)
	return "win" if human_won else "loss"
