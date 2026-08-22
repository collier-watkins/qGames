class_name ChessBoardView
extends Control

## The board: draws it, and turns pointers and keys into a chosen move.
##
## It owns no rules. It is handed a position to draw and a set of legal moves
## to allow, and it emits the move the player asked for; whether that move is
## then made is the game's business, not its own.
##
## Both input paths are first class, per the house rule. Touch and mouse share
## one code path (Godot delivers a touch as a mouse event unless it is told
## otherwise, and both arrive here as press/motion/release). Keys and a d-pad
## drive a cursor square with ui_left/right/up/down and ui_accept.

signal move_attempted(from_sq: int, to_sq: int)
signal square_touched(sq: int)

const B := preload("res://src/board.gd")

const C_LIGHT: Color = Color(0.9255, 0.8863, 0.8118)
const C_DARK: Color = Color(0.4627, 0.5882, 0.3373)
const C_LIGHT_LAST: Color = Color(0.9569, 0.9059, 0.4392)
const C_DARK_LAST: Color = Color(0.7412, 0.7922, 0.2745)
const C_LIGHT_SELECT: Color = Color(0.9725, 0.9294, 0.4784)
const C_DARK_SELECT: Color = Color(0.8039, 0.8353, 0.3059)
const C_DOT: Color = Color(0.1216, 0.1216, 0.1216, 0.28)
const C_CHECK: Color = Color(0.8627, 0.2118, 0.1608)
const C_CURSOR: Color = Color(1.0, 0.8471, 0.3216)
const C_HINT: Color = Color(0.2000, 0.6000, 0.9412, 0.85)
const C_COORD_ON_LIGHT: Color = Color(0.4627, 0.5882, 0.3373)
const C_COORD_ON_DARK: Color = Color(0.9255, 0.8863, 0.8118)
const C_PIECE_WHITE: Color = Color(0.9843, 0.9765, 0.9569)
const C_PIECE_BLACK: Color = Color(0.1373, 0.1373, 0.1569)

## The piece is lifted slightly while dragged so a fingertip is not covering
## the thing it is carrying.
const DRAG_LIFT: float = 0.18

var board: ChessBoard = null
var flipped: bool = false
var interactive: bool = true
var show_coords: bool = true

var last_from: int = -1
var last_to: int = -1
var hint_from: int = -1
var hint_to: int = -1

var selected: int = -1
var targets: PackedInt32Array = PackedInt32Array()
var cursor: int = 4
var show_cursor: bool = false

var _dragging: bool = false
var _drag_from: int = -1
var _drag_pos: Vector2 = Vector2.ZERO
var _press_sq: int = -1
var _press_pos: Vector2 = Vector2.ZERO
## Distance a press must travel before it counts as a drag rather than a tap.
## Below it, releasing on the square you pressed leaves the piece selected,
## which is the tap-tap path; above it, the piece follows the finger.
const DRAG_SLOP: float = 8.0

var _square: float = 64.0
var _origin: Vector2 = Vector2.ZERO


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP


func show_position(b: ChessBoard, from_sq: int = -1, to_sq: int = -1) -> void:
	board = b
	last_from = from_sq
	last_to = to_sq
	clear_selection()
	queue_redraw()


func clear_selection() -> void:
	selected = -1
	targets = PackedInt32Array()
	_dragging = false
	_drag_from = -1
	queue_redraw()


func select(sq: int) -> void:
	if board == null:
		return
	var moves: PackedInt32Array = board.legal_moves_from(sq)
	if moves.is_empty():
		clear_selection()
		return
	selected = sq
	targets = PackedInt32Array()
	for m in moves:
		var to: int = B.move_to(m)
		if not targets.has(to):
			targets.append(to)
	queue_redraw()


func set_hint(from_sq: int, to_sq: int) -> void:
	hint_from = from_sq
	hint_to = to_sq
	queue_redraw()


func clear_hint() -> void:
	hint_from = -1
	hint_to = -1
	queue_redraw()


# ---------------------------------------------------------------- geometry

func board_rect() -> Rect2:
	## The largest centred square that fits, so the board never stretches. Its
	## size is quantised to a whole number of squares — an 8x8 grid drawn on a
	## non-multiple of 8 leaves one file a pixel wider than the rest, which is
	## visible as a seam.
	var side: float = floorf(minf(size.x, size.y) / 8.0) * 8.0
	side = maxf(side, 8.0)
	return Rect2(((size - Vector2(side, side)) * 0.5).floor(), Vector2(side, side))


func square_rect(sq: int) -> Rect2:
	var file: int = B.file_of(sq)
	var rank: int = B.rank_of(sq)
	var col: int = file if not flipped else 7 - file
	var row: int = 7 - rank if not flipped else rank
	return Rect2(_origin + Vector2(col, row) * _square, Vector2(_square, _square))


func square_at(pos: Vector2) -> int:
	var local: Vector2 = pos - _origin
	if local.x < 0.0 or local.y < 0.0:
		return -1
	var col: int = int(local.x / _square)
	var row: int = int(local.y / _square)
	if col < 0 or col > 7 or row < 0 or row > 7:
		return -1
	var file: int = col if not flipped else 7 - col
	var rank: int = 7 - row if not flipped else row
	return B.square_of(file, rank)


# ------------------------------------------------------------------- input

func _gui_input(event: InputEvent) -> void:
	if not interactive or board == null:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_press(event.position)
		else:
			_end_press(event.position)
		accept_event()
		return

	if event is InputEventScreenTouch:
		if event.pressed:
			_begin_press(event.position)
		else:
			_end_press(event.position)
		accept_event()
		return

	if event is InputEventMouseMotion or event is InputEventScreenDrag:
		if _press_sq >= 0:
			_drag_pos = event.position
			if not _dragging and _press_pos.distance_to(event.position) > DRAG_SLOP:
				_dragging = true
				_drag_from = _press_sq
			if _dragging:
				queue_redraw()
		return

	_key_input(event)


func _begin_press(pos: Vector2) -> void:
	var sq: int = square_at(pos)
	if sq < 0:
		clear_selection()
		return
	square_touched.emit(sq)
	_press_pos = pos
	_drag_pos = pos
	grab_focus()

	# Pressing a legal destination completes the move that is already begun.
	if selected >= 0 and targets.has(sq):
		_press_sq = -1
		var from: int = selected
		clear_selection()
		move_attempted.emit(from, sq)
		return

	var piece: int = board.board[sq]
	if piece != 0 and (piece > 0) == (board.side > 0):
		_press_sq = sq
		select(sq)
	else:
		_press_sq = -1
		clear_selection()


func _end_press(pos: Vector2) -> void:
	var was_dragging: bool = _dragging
	var from: int = _drag_from if was_dragging else _press_sq
	_dragging = false
	_drag_from = -1
	_press_sq = -1
	if not was_dragging or from < 0:
		queue_redraw()
		return
	var sq: int = square_at(pos)
	if sq >= 0 and sq != from and targets.has(sq):
		clear_selection()
		move_attempted.emit(from, sq)
	else:
		# A drag that ends nowhere useful leaves the piece selected rather than
		# deselecting it — the tap-tap path is still open, and a child who
		# fumbles a drag has not lost their place.
		queue_redraw()


func _key_input(event: InputEvent) -> void:
	if not event.is_pressed():
		return
	var delta: Vector2i = Vector2i.ZERO
	if event.is_action_pressed("ui_left", true):
		delta = Vector2i(-1, 0)
	elif event.is_action_pressed("ui_right", true):
		delta = Vector2i(1, 0)
	elif event.is_action_pressed("ui_up", true):
		delta = Vector2i(0, 1)
	elif event.is_action_pressed("ui_down", true):
		delta = Vector2i(0, -1)
	elif event.is_action_pressed("ui_accept"):
		show_cursor = true
		_activate(cursor)
		accept_event()
		return
	elif event.is_action_pressed("ui_cancel"):
		if selected >= 0:
			clear_selection()
			accept_event()
		return
	else:
		return

	if flipped:
		delta = -delta
	var file: int = clampi(B.file_of(cursor) + delta.x, 0, 7)
	var rank: int = clampi(B.rank_of(cursor) + delta.y, 0, 7)
	cursor = B.square_of(file, rank)
	show_cursor = true
	accept_event()
	queue_redraw()


func _activate(sq: int) -> void:
	if selected >= 0 and targets.has(sq):
		var from: int = selected
		clear_selection()
		move_attempted.emit(from, sq)
		return
	var piece: int = board.board[sq]
	if piece != 0 and (piece > 0) == (board.side > 0):
		select(sq)
	else:
		clear_selection()


# -------------------------------------------------------------------- draw

func _draw() -> void:
	var rect: Rect2 = board_rect()
	_origin = rect.position
	_square = rect.size.x / 8.0
	if board == null:
		return

	var font: Font = ThemeDB.fallback_font
	var coord_size: int = int(maxf(9.0, _square * 0.20))

	for rank in 8:
		for file in 8:
			var sq: int = B.square_of(file, rank)
			var r: Rect2 = square_rect(sq)
			var light: bool = (file + rank) % 2 == 1
			var is_last: bool = sq == last_from or sq == last_to
			var base: Color
			if is_last:
				base = C_LIGHT_LAST if light else C_DARK_LAST
			else:
				base = C_LIGHT if light else C_DARK
			draw_rect(r, base)
			if show_coords:
				_draw_coords(font, coord_size, file, rank, r, light)

	# The king in check, under the pieces so the piece is never obscured.
	if board.in_check():
		var k: int = board.king_sq[0 if board.side == B.WHITE else 1]
		if k >= 0:
			var kr: Rect2 = square_rect(k)
			draw_circle(kr.get_center(), _square * 0.52, Color(C_CHECK, 0.35))
			draw_circle(kr.get_center(), _square * 0.40, Color(C_CHECK, 0.45))

	if selected >= 0:
		var light_sel: bool = (B.file_of(selected) + B.rank_of(selected)) % 2 == 1
		draw_rect(square_rect(selected), C_LIGHT_SELECT if light_sel else C_DARK_SELECT)

	for sq in targets:
		var r2: Rect2 = square_rect(sq)
		if board.board[sq] != 0 or (sq == board.ep and absi(board.board[selected]) == B.PAWN):
			# A capture is a ring around the square, not a dot in the middle,
			# so the piece being taken stays visible.
			draw_arc(r2.get_center(), _square * 0.44, 0.0, TAU, 32, C_DOT, _square * 0.09, true)
		else:
			draw_circle(r2.get_center(), _square * 0.16, C_DOT)

	for sq in 128:
		if sq & 0x88:
			continue
		var p: int = board.board[sq]
		if p == 0:
			continue
		if _dragging and sq == _drag_from:
			continue
		_draw_piece_at(p, square_rect(sq))

	if hint_from >= 0 and hint_to >= 0:
		_draw_arrow(square_rect(hint_from).get_center(), square_rect(hint_to).get_center())

	if show_cursor:
		var cr: Rect2 = square_rect(cursor)
		draw_rect(cr.grow(-_square * 0.04), C_CURSOR, false, maxf(2.0, _square * 0.06))

	if _dragging and _drag_from >= 0:
		var p2: int = board.board[_drag_from]
		if p2 != 0:
			var s: float = _square * 1.06
			var centre: Vector2 = _drag_pos - Vector2(0.0, _square * DRAG_LIFT)
			_draw_piece_at(p2, Rect2(centre - Vector2(s, s) * 0.5, Vector2(s, s)))


func _draw_coords(font: Font, coord_size: int, file: int, rank: int,
		r: Rect2, light: bool) -> void:
	## Only the outer file and rank carry a label, which is where every board
	## puts them. Which edge is "outer" follows the flip.
	var colour: Color = C_COORD_ON_LIGHT if light else C_COORD_ON_DARK
	var bottom_rank: int = 0 if not flipped else 7
	var left_file: int = 0 if not flipped else 7
	if rank == bottom_rank:
		var letter: String = String.chr(97 + file)
		draw_string(font, r.position + Vector2(r.size.x - coord_size * 0.75, r.size.y - 3),
				letter, HORIZONTAL_ALIGNMENT_LEFT, -1, coord_size, colour)
	if file == left_file:
		draw_string(font, r.position + Vector2(3, coord_size + 1),
				str(rank + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, coord_size, colour)


func _draw_piece_at(p: int, r: Rect2) -> void:
	var white: bool = p > 0
	ChessPieces.draw_piece(self, absi(p), r.grow(-r.size.x * 0.06),
			C_PIECE_WHITE if white else C_PIECE_BLACK,
			C_PIECE_BLACK if white else C_PIECE_WHITE)


func _draw_arrow(from: Vector2, to: Vector2) -> void:
	var dir: Vector2 = (to - from).normalized()
	var head: float = _square * 0.34
	var tip: Vector2 = to - dir * (_square * 0.06)
	var shaft_end: Vector2 = tip - dir * head
	draw_line(from + dir * (_square * 0.18), shaft_end, C_HINT, _square * 0.13, true)
	var perp: Vector2 = Vector2(-dir.y, dir.x) * head * 0.52
	draw_colored_polygon(PackedVector2Array([tip, shaft_end + perp, shaft_end - perp]), C_HINT)
