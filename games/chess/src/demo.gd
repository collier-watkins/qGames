class_name ChessDemo
extends Node

## `--demo`: the game plays itself, so the training aids can be watched on a
## screen nobody is sitting at (the games Pi). A fixed line, not the engine:
## it has to reach the moments worth showing — a check the player must answer,
## then a checkmate the player gives — every time, in a minute.
##
## It drives the real view (selection, pointing, _apply_move), so what is seen
## is the game, not a recording of it. main.gd keeps a demo out of the
## player's prefs and out of telemetry; see ChessView._demo.

const B := preload("res://src/board.gd")

## 1.e4 e5 2.d4 Bb4+ 3.c3 Ba5 4.Bc4 Nc6 5.Qh5 Nf6 6.Qxf7#
const LINE: PackedStringArray = ["e2e4", "e7e5", "d2d4", "f8b4", "c2c3", "b4a5",
		"f1c4", "b8c6", "d1h5", "g8f6", "h5f7"]

## Seconds. Slow enough to read the panel aloud to a child.
const BETWEEN_MOVES: float = 1.6
const SELECTED: float = 0.9
const CHECK_LOOK: float = 3.5   # the arrow and the glowing answers
const CHECK_POINT: float = 3.0  # one answer's ways out, as if pointed at
const AFTER_CARD: float = 6.0

## Untyped on purpose: naming ChessView here makes this script depend on
## main.gd, which needs the autoloads, and tools that load this outside the
## game (tests/demo_shots.gd) have none.
var _main: Node


func _init(main: Node) -> void:
	_main = main


func _ready() -> void:
	_run()


func _run() -> void:
	while is_inside_tree():
		_main.call("_start_demo")
		await _pause(2.0)
		for mv: String in LINE:
			if _main.get("_game").over:
				break
			await _play(mv)
		# The mate show runs, then the end card; let it be read, then again.
		while _main.get("_endcard") == null:
			await _pause(0.5)
		await _pause(AFTER_CARD)


func _play(mv: String) -> void:
	var board: ChessBoard = _main.get("_game").board
	var view: ChessBoardView = _main.get("_board_view")
	var from: int = B.square_from_name(mv.substr(0, 2))
	var to: int = B.square_from_name(mv.substr(2, 2))
	var move: int = 0
	for m: int in board.legal_moves():
		if B.move_from(m) == from and B.move_to(m) == to:
			move = m
	if move == 0:
		push_error("chess demo: %s is not legal here" % mv)
		return
	if board.in_check():
		await _pause(CHECK_LOOK)
		view.set_inspect(from)
		await _pause(CHECK_POINT)
	view.select(from)
	await _pause(SELECTED)
	view.set_inspect(-1)
	_main.call("_apply_move", move)
	await _pause(BETWEEN_MOVES)


func _pause(seconds: float) -> Signal:
	return get_tree().create_timer(seconds).timeout
