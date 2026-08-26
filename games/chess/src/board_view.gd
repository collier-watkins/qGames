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

## How long a piece takes to travel between squares. Short enough that it never
## delays the player and long enough to be followed by eye — the point of the
## slide is that the computer's reply is SEEN rather than discovered, which a
## child playing their first games needs more than an adult does.
const MOVE_SEC: float = 0.20
## A taken piece fades rather than vanishing, so it is obvious what was lost.
## SHORTER than MOVE_SEC on purpose. The taken piece has to be gone by the time
## the capturing piece lands on it — run longer, and for the last fraction of a
## second there are two pieces on one square and the whole thing reads as a
## ghost rather than as a capture.
const CAPTURE_SEC: float = 0.16
## A promoted piece swells into place. It is the one move where a piece becomes
## a different piece, and without this it simply blinks.
const PROMOTE_SEC: float = 0.26
## Selection dots and the last-move wash come up rather than snapping on.
const HIGHLIGHT_SEC: float = 0.13
const SELECT_SEC: float = 0.10
## The check glow breathes at this rate. Slow: it is a warning, not an alarm.
const CHECK_PERIOD: float = 1.4
## Idle animations repaint at this rate, not at the frame rate. The same
## measurement that caught sequence idling at 52% CPU applies here — a board
## that repaints 60 times a second to pulse one square is a Pi running hot for
## nothing. Moves are exempt: they are brief and want every frame.
const IDLE_HZ: float = 24.0

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

## Where the piece artwork comes from. Owned here because the board is the only
## thing that draws pieces at board size; the promotion picker asks it too.
var art: ChessPieceArt = ChessPieceArt.new()

var _square: float = 64.0
var _origin: Vector2 = Vector2.ZERO

## Pieces currently sliding: {piece, from_sq, to_sq, t}. More than one at a
## time only for castling, where the rook travels with the king.
var _slides: Array = []
## Captured pieces fading out: {piece, sq, t}.
var _fades: Array = []
## Squares whose piece is swelling into place: sq -> t.
var _pops: Dictionary = {}
var _highlight_t: float = 1.0
var _select_t: float = 0.0
var _check_phase: float = 0.0
var _idle_accum: float = 0.0


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	art.load_set()


func show_position(b: ChessBoard, from_sq: int = -1, to_sq: int = -1) -> void:
	board = b
	last_from = from_sq
	last_to = to_sq
	_slides.clear()
	_fades.clear()
	_pops.clear()
	clear_selection()
	set_process(true)
	queue_redraw()


func clear_selection() -> void:
	selected = -1
	targets = PackedInt32Array()
	_dragging = false
	_drag_from = -1
	set_process(true)
	queue_redraw()


func select(sq: int) -> void:
	if board == null:
		return
	var moves: PackedInt32Array = board.legal_moves_from(sq)
	if moves.is_empty():
		clear_selection()
		return
	selected = sq
	_select_t = 0.0
	targets = PackedInt32Array()
	for m in moves:
		var to: int = B.move_to(m)
		if not targets.has(to):
			targets.append(to)
	set_process(true)
	queue_redraw()


func set_hint(from_sq: int, to_sq: int) -> void:
	hint_from = from_sq
	hint_to = to_sq
	queue_redraw()


func clear_hint() -> void:
	hint_from = -1
	hint_to = -1
	queue_redraw()


# ------------------------------------------------------------------ animation

func animate_move(m: int, moved_piece: int, captures: Array) -> void:
	## Called AFTER the board has been updated. The piece is therefore already
	## on its destination square as far as the model is concerned; the slide is
	## a lie told over the top of it, and `_draw` suppresses the destination so
	## the same piece is not drawn twice.
	var from: int = B.move_from(m)
	var to: int = B.move_to(m)
	var promo: int = B.move_promo(m)
	_slides.append({"piece": moved_piece, "from": from, "to": to, "t": 0.0})
	if B.move_flag(m) == B.FLAG_CASTLE:
		# The rook goes with the king, or castling looks like the rook
		# teleported — which is exactly the move a child is least sure of.
		var rook: Array = _castle_rook(to)
		if not rook.is_empty():
			_slides.append({"piece": ROOK_OF[to], "from": rook[0], "to": rook[1], "t": 0.0})
	for c: Array in captures:
		_fades.append({"piece": int(c[1]), "sq": int(c[0]), "t": 0.0})
	if promo != 0:
		_pops[to] = 0.0
	_highlight_t = 0.0
	set_process(true)
	queue_redraw()


## Rook origin and destination per king destination square, and the rook's
## signed piece code. Keyed by the king's `to`, which is the only thing the
## move carries.
const CASTLE_ROOKS: Dictionary = {
	6: [7, 5], 2: [0, 3], 118: [119, 117], 114: [112, 115],
}
const ROOK_OF: Dictionary = {6: B.ROOK, 2: B.ROOK, 118: -B.ROOK, 114: -B.ROOK}


func _castle_rook(king_to: int) -> Array:
	return CASTLE_ROOKS.get(king_to, [])


func is_animating() -> bool:
	return not _slides.is_empty() or not _fades.is_empty() or not _pops.is_empty()


func skip_animations() -> void:
	## Used when the position changes for a reason that is not a move — a
	## takeback, a review jump, a new game. Sliding a piece to a square it was
	## never on would be worse than not sliding it at all.
	_slides.clear()
	_fades.clear()
	_pops.clear()
	_highlight_t = 1.0
	queue_redraw()


func _process(delta: float) -> void:
	var busy: bool = false

	for i in range(_slides.size() - 1, -1, -1):
		_slides[i]["t"] = float(_slides[i]["t"]) + delta / MOVE_SEC
		if float(_slides[i]["t"]) >= 1.0:
			_slides.remove_at(i)
		else:
			busy = true
	for i in range(_fades.size() - 1, -1, -1):
		_fades[i]["t"] = float(_fades[i]["t"]) + delta / CAPTURE_SEC
		if float(_fades[i]["t"]) >= 1.0:
			_fades.remove_at(i)
		else:
			busy = true
	for sq: int in _pops.keys():
		_pops[sq] = float(_pops[sq]) + delta / PROMOTE_SEC
		if float(_pops[sq]) >= 1.0:
			_pops.erase(sq)
		else:
			busy = true

	if _highlight_t < 1.0:
		_highlight_t = minf(1.0, _highlight_t + delta / HIGHLIGHT_SEC)
		busy = true
	var want_select: float = 1.0 if selected >= 0 else 0.0
	if not is_equal_approx(_select_t, want_select):
		var step: float = delta / SELECT_SEC
		_select_t = minf(_select_t + step, 1.0) if want_select > 0.0 else maxf(_select_t - step, 0.0)
		busy = true

	var checking: bool = board != null and board.in_check()
	if checking:
		_check_phase = fmod(_check_phase + delta / CHECK_PERIOD, 1.0)

	if busy:
		queue_redraw()
		_idle_accum = 0.0
	elif checking:
		# Throttled: the glow is the only thing moving, and it does not need
		# sixty repaints a second to breathe.
		_idle_accum += delta
		if _idle_accum >= 1.0 / IDLE_HZ:
			_idle_accum = 0.0
			queue_redraw()
	else:
		set_process(false)


static func _ease_out(t: float) -> float:
	## Cubic ease-out. A linear slide reads as mechanical; starting fast and
	## settling is what makes it look like a hand putting a piece down.
	var u: float = 1.0 - clampf(t, 0.0, 1.0)
	return 1.0 - u * u * u


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

	art.set_square_size(_square)
	var font: Font = ThemeDB.fallback_font
	var coord_size: int = int(maxf(9.0, _square * 0.20))

	for rank in 8:
		for file in 8:
			var sq: int = B.square_of(file, rank)
			var r: Rect2 = square_rect(sq)
			var light: bool = (file + rank) % 2 == 1
			var base: Color = C_LIGHT if light else C_DARK
			if sq == last_from or sq == last_to:
				base = base.lerp(C_LIGHT_LAST if light else C_DARK_LAST, _highlight_t)
			draw_rect(r, base)
			if show_coords:
				_draw_coords(font, coord_size, file, rank, r, light)

	# The king in check, under the pieces so the piece is never obscured. The
	# glow breathes rather than sitting still: a static red square is read once
	# and then stops being noticed.
	if board.in_check():
		var k: int = board.king_sq[0 if board.side == B.WHITE else 1]
		if k >= 0:
			var pulse: float = 0.5 + 0.5 * sin(_check_phase * TAU)
			var kr: Rect2 = square_rect(k)
			draw_circle(kr.get_center(), _square * (0.50 + 0.04 * pulse),
					Color(C_CHECK, 0.22 + 0.16 * pulse))
			draw_circle(kr.get_center(), _square * 0.40, Color(C_CHECK, 0.38 + 0.14 * pulse))

	if selected >= 0 and _select_t > 0.0:
		var light_sel: bool = (B.file_of(selected) + B.rank_of(selected)) % 2 == 1
		var sel: Color = C_LIGHT_SELECT if light_sel else C_DARK_SELECT
		draw_rect(square_rect(selected), Color(sel, _select_t))

	for sq in targets:
		var r2: Rect2 = square_rect(sq)
		var dot: Color = Color(C_DOT, C_DOT.a * _select_t)
		if board.board[sq] != 0 or (sq == board.ep and absi(board.board[selected]) == B.PAWN):
			# A capture is a ring around the square, not a dot in the middle,
			# so the piece being taken stays visible.
			draw_arc(r2.get_center(), _square * 0.44, 0.0, TAU, 32, dot,
					_square * 0.09 * _select_t, true)
		else:
			draw_circle(r2.get_center(), _square * 0.16 * _select_t, dot)

	# Squares a sliding piece is heading for are left empty until it lands, or
	# the same piece is drawn twice — once travelling and once already there.
	var arriving: Dictionary = {}
	for slide: Dictionary in _slides:
		arriving[int(slide["to"])] = true

	for sq in 128:
		if sq & 0x88:
			continue
		var p: int = board.board[sq]
		if p == 0 or arriving.has(sq):
			continue
		if _dragging and sq == _drag_from:
			continue
		if _pops.has(sq):
			_draw_piece_at(p, _pop_rect(square_rect(sq), float(_pops[sq])))
		else:
			_draw_piece_at(p, square_rect(sq))

	for fade: Dictionary in _fades:
		var ft: float = float(fade["t"])
		_draw_piece_at(int(fade["piece"]), _capture_rect(square_rect(int(fade["sq"])), ft),
				_capture_alpha(ft))

	for slide: Dictionary in _slides:
		var a: Rect2 = square_rect(int(slide["from"]))
		var b: Rect2 = square_rect(int(slide["to"]))
		var k: float = _ease_out(float(slide["t"]))
		_draw_piece_at(int(slide["piece"]),
				Rect2(a.position.lerp(b.position, k), a.size))

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


func _capture_rect(r: Rect2, t: float) -> Rect2:
	## The taken piece COLLAPSES INTO its square. It used to call _pop_rect()
	## with a constant t of 1.0 — and at t=1.0 that function's factor works out
	## to exactly 1.0, so the piece sat at full size and only its alpha moved.
	## A full-size piece dissolving in place, under a full-size piece sliding
	## onto the same square, is what read as a ghost.
	##
	## Eased OUT, so it shrinks fast and then settles small: most of the
	## movement happens in the first third, which is what clears the square
	## before the capturing piece arrives.
	var factor: float = lerpf(1.0, 0.52, _ease_out(t))
	return Rect2(r.get_center() - r.size * factor * 0.5, r.size * factor)


static func _capture_alpha(t: float) -> float:
	## Slightly faster than linear. A straight fade leaves the piece at half
	## opacity exactly when the capturing piece is halfway across it, which is
	## the worst moment to still be visible.
	var u: float = 1.0 - clampf(t, 0.0, 1.0)
	return u * u


func _pop_rect(r: Rect2, t: float) -> Rect2:
	## Swells from a little under full size, overshooting slightly before it
	## settles. The overshoot is what makes it read as a piece being placed
	## rather than a sprite being scaled.
	var k: float = _ease_out(t)
	var factor: float = lerpf(0.55, 1.0, k) + 0.10 * sin(PI * clampf(t, 0.0, 1.0))
	return Rect2(r.get_center() - r.size * factor * 0.5, r.size * factor)


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


func _draw_piece_at(p: int, r: Rect2, alpha: float = 1.0) -> void:
	var white: bool = p > 0
	var fill: Color = C_PIECE_WHITE if white else C_PIECE_BLACK
	var edge: Color = C_PIECE_BLACK if white else C_PIECE_WHITE
	if alpha < 1.0:
		fill.a = alpha
		edge.a = alpha
	art.draw(self, p, r.grow(-r.size.x * 0.06), fill, edge)


func _draw_arrow(from: Vector2, to: Vector2) -> void:
	var dir: Vector2 = (to - from).normalized()
	var head: float = _square * 0.34
	var tip: Vector2 = to - dir * (_square * 0.06)
	var shaft_end: Vector2 = tip - dir * head
	draw_line(from + dir * (_square * 0.18), shaft_end, C_HINT, _square * 0.13, true)
	var perp: Vector2 = Vector2(-dir.y, dir.x) * head * 0.52
	draw_colored_polygon(PackedVector2Array([tip, shaft_end + perp, shaft_end - perp]), C_HINT)
