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
## Training mode's words for what the board is showing — why a king is in
## check and the ways out, then the take chain of the piece being pointed at —
## or "" when there is nothing. The panel shows it; the board only has room
## for arrows.
signal explained(text: String)
## The checkmate has been dwelt on long enough (or the player tapped past it):
## time for the end card.
signal mate_done

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
## Training mode's danger squares. Washed over the square so its own colour
## still shows through: "a little bit red", not a second check glow. Stronger
## on the dark squares because red over green mixes to brown — at the light
## squares' 0.34 a dark square read as olive, not red (swatch-checked).
const C_DANGER: Color = Color(0.8627, 0.1490, 0.1490)
const DANGER_ALPHA_LIGHT: float = 0.34
const DANGER_ALPHA_DARK: float = 0.50
## Training mode's attack squares: where the watched side could take. Same
## reasoning for the split alphas — blue over green reads teal below ~0.56.
## A square that is both is split on the diagonal, half red and half blue: the
## two washes stacked mix to a muddy purple that reads as neither.
const C_ATTACK: Color = Color(0.13, 0.40, 0.92)
const ATTACK_ALPHA_LIGHT: float = 0.38
const ATTACK_ALPHA_DARK: float = 0.56
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

## Training mode, danger squares: the side whose pieces are watched, or 0 for
## off. `_danger` holds the squares where the opponent could take one of that
## side's pieces — empty or not (ChessBoard.danger_squares).
var danger_for: int = 0
var _danger: PackedInt32Array = PackedInt32Array()
## Training mode, attack squares: the side whose take squares are shown, or 0.
## `_attack` holds the squares where that side could take an enemy piece —
## the same question as `_danger`, asked the other way round.
var attack_for: int = 0
var _attack: PackedInt32Array = PackedInt32Array()
## The piece being looked at: under the mouse, under the keyboard cursor, or
## last tapped (touch has no hover). While it is set, the maps narrow to that
## ONE piece — the computer's piece shows its red take squares, the player's
## its blue ones — which is what teaches "this piece guards these squares".
## `hover_only` false shows the whole board's maps when nothing is pointed at.
var hover_only: bool = true
var _inspect: int = -1
## The selected piece's destinations where it could be taken straight back.
## All of these are recomputed when the position, the pointed-at piece or the
## selection changes, never per frame.
var _hanging: PackedInt32Array = PackedInt32Array()
## Training mode, take chains: the player's side, or 0 for off. `_in_danger` is
## the player's pieces that can be taken without the taker losing on it,
## square -> worth (ChessBoard.pieces_in_danger): badged "!" all the time.
## `_chain` is the pointed-at piece's capture sequence (ChessBoard.take_chain),
## drawn as numbered arrows.
var chains_for: int = 0
var _in_danger: Dictionary = {}
var _chain: Dictionary = {}
var _chain_text: String = ""
## Training mode, why check: while a king is in check, the checker is ringed,
## an arrow runs from it to the king over its line of attack, and the panel
## gets the reason and the ways out (ChessBoard.check_info). Either side's
## check: the one the player gives teaches as much as the one they get.
var checks_on: bool = false
var _check: Dictionary = {}
var _check_text: String = ""
var _explained: String = ""
## On checkmate, the squares round the mated king and what holds each one
## (ChessBoard.king_trap): drawn as the net the king is caught in.
var _trap: Array = []
## The checkmate show: seconds since the mating move landed, or -1. The trap
## is shown first, then the mated king topples and, when the player won,
## confetti flies; mate_done is sent at MATE_DWELL or on a tap.
var _mate_t: float = -1.0
var _mate_win: bool = false
var _mate_sent: bool = false
var _confetti: Array = []
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
	_mate_t = -1.0
	_mate_sent = false
	_confetti.clear()
	last_from = from_sq
	last_to = to_sq
	_slides.clear()
	_fades.clear()
	_pops.clear()
	clear_selection()
	_refresh_maps()
	set_process(true)
	queue_redraw()


func set_training(danger_side: int, attack_side: int, only_pointed: bool,
		chains_side: int = 0, explain_checks: bool = false) -> void:
	danger_for = danger_side
	attack_for = attack_side
	hover_only = only_pointed
	chains_for = chains_side
	checks_on = explain_checks
	_refresh_maps()
	_refresh_hanging()
	queue_redraw()


func set_inspect(sq: int) -> void:
	## Only a square with a piece on it is worth looking at; anything else
	## clears it. Unchanged → nothing is recomputed, so a mouse wandering
	## around inside one square costs nothing.
	if sq >= 0 and (board == null or board.board[sq] == 0):
		sq = -1
	if sq == _inspect:
		return
	_inspect = sq
	_refresh_maps(false)
	queue_redraw()


func _refresh_maps(position_changed: bool = true) -> void:
	_danger = PackedInt32Array()
	_attack = PackedInt32Array()
	if position_changed:
		_in_danger = {}
		if board != null and chains_for != 0:
			_in_danger = board.pieces_in_danger(chains_for)
		_check = {}
		_check_text = ""
		_trap = []
		# A checkmate is always shown as the trap it is, aid or not: it is the
		# one position every player should be able to read.
		if board != null and (checks_on or _mate_t >= 0.0):
			_check = board.check_info()
			_check_text = explain_check(board, _check, _human_side())
			if _is_stuck():
				_trap = board.king_trap()
	_refresh_chain()
	if board == null:
		return
	var p: int = board.board[_inspect] if _inspect >= 0 else 0
	if p != 0:
		var colour: int = 1 if p > 0 else -1
		if danger_for != 0 and colour == -danger_for:
			_danger = board.danger_squares(danger_for, _inspect)
		if attack_for != 0 and colour == attack_for:
			_attack = board.danger_squares(-attack_for, _inspect)
		return
	if hover_only:
		return
	if danger_for != 0:
		_danger = board.danger_squares(danger_for)
	if attack_for != 0:
		_attack = board.danger_squares(-attack_for)


func _refresh_chain() -> void:
	_chain = {}
	if board != null and chains_for != 0 and _inspect >= 0 and board.board[_inspect] != 0:
		_chain = board.take_chain(_inspect)
	_chain_text = explain_chain(board, _inspect, _chain, chains_for)
	var parts: PackedStringArray = PackedStringArray()
	for t: String in [_check_text, _chain_text]:
		if t != "":
			parts.append(t)
	var text: String = "\n\n".join(parts)
	if text != _explained:
		_explained = text
		explained.emit(text)


func _is_stuck() -> bool:
	return not _check.is_empty() \
			and (_check["king_moves"] as PackedInt32Array).is_empty() \
			and (_check["blocks"] as PackedInt32Array).is_empty() \
			and (_check["takers"] as PackedInt32Array).is_empty()


func celebrate_mate(player_won: bool) -> void:
	## Called once the game has ended in checkmate, after the mating move was
	## shown. The end card waits for mate_done.
	_mate_win = player_won
	_mate_t = 0.0
	_mate_sent = false
	_confetti.clear()
	_refresh_maps()
	set_process(true)
	queue_redraw()


func is_celebrating() -> bool:
	return _mate_t >= 0.0 and not _mate_sent


func _finish_mate() -> void:
	if _mate_sent:
		return
	_mate_sent = true
	# Skipped early: the king is shown already down.
	_mate_t = maxf(_mate_t, MATE_TOPPLE_AT + MATE_TOPPLE_SEC)
	queue_redraw()
	mate_done.emit()


func _human_side() -> int:
	## Whose point of view the words take. The training aids are all set for
	## the player's side; with chains off, the side at the bottom of the board.
	for s: int in [chains_for, danger_for, attack_for]:
		if s != 0:
			return s
	return B.BLACK if flipped else B.WHITE


const PIECE_NAMES: Array[String] = ["", "pawn", "knight", "bishop", "rook", "queen", "king"]


static func explain_chain(b: ChessBoard, sq: int, chain: Dictionary, me: int) -> String:
	## The chain in a sentence a child can be read: whose piece, who takes with
	## what in order, and how it ends. Only the steps worth playing are told —
	## the faded ones on the board are the "and then nobody would" part.
	if b == null or chain.is_empty() or sq < 0:
		return ""
	var target: int = b.board[sq]
	var mine: bool = (target > 0) == (me > 0)
	var owner: String = "Your " if mine else "Their "
	var what: String = PIECE_NAMES[absi(target)]
	var worth: int = int(chain["worth"])
	var played: int = int(chain["played"])
	var steps: Array = chain["steps"]
	if played == 0:
		# Taking it at all loses the first taker material.
		var who: String = "them" if mine else "you"
		return "%s%s is protected: taking it would cost %s %s." % [
				owner, what, who, _points(-worth)]
	var parts: PackedStringArray = PackedStringArray()
	for i in played:
		var piece: int = int(steps[i]["piece"])
		var by_me: bool = (piece > 0) == (me > 0)
		var verb: String = "take" if i == 0 else "take back"
		parts.append("%s %s with %s %s" % ["you" if by_me else "they", verb,
				"your" if by_me else "their", PIECE_NAMES[absi(piece)]])
	var first_mine: bool = (int(steps[0]["piece"]) > 0) == (me > 0)
	var ending: String
	if worth == 0:
		ending = "An even trade."
	elif first_mine:
		ending = "You win %s." % _points(worth)
	else:
		ending = "You lose %s." % _points(worth)
	return "%s%s: %s. %s" % [owner, what, ", then ".join(parts), ending]


const LINE_WORDS: Dictionary = {
	B.PAWN: "diagonally, one step away",
	B.KNIGHT: "with a knight's jump",
}


static func explain_check(b: ChessBoard, info: Dictionary, me: int) -> String:
	## Why the king is in check, and what can be done about it, in words a
	## child can be read: who attacks the king and how, then the ways out by
	## kind. Squares are named, because the board shows their letters and
	## numbers along its edges.
	if b == null or info.is_empty():
		return ""
	var mine: bool = b.side == me
	var whose_king: String = "your king" if mine else "their king"
	var their: String = "their" if mine else "your"
	var found: Array = info["checkers"]
	var names: PackedStringArray = PackedStringArray()
	for c: Dictionary in found:
		names.append("%s %s on %s" % [their, PIECE_NAMES[absi(int(c["piece"]))],
				B.square_name(int(c["from"]))])
	var text: String
	if found.size() > 1:
		text = "Double check! %s and %s both attack %s." % [
				_cap(names[0]), names[1], whose_king]
	else:
		var c0: Dictionary = found[0]
		# No "Check!" in front: the status line right above already says it.
		text = "%s attacks %s %s." % [_cap(names[0]), whose_king,
				_how_it_attacks(b, int(c0["piece"]), int(c0["from"]), int(info["king"]))]
		if absi(int(c0["piece"])) == B.KNIGHT:
			text += " A knight jumps, so it cannot be blocked."
	var ways: String = _ways_out(b, info, mine)
	if ways != "":
		return text + " " + ways
	# No way out. Say what the trap is made of, square by square.
	text = "Checkmate! " + text.trim_prefix("Double check! ")
	return text + " " + _trap_words(b, found, mine)


static func _trap_words(b: ChessBoard, found: Array, mine: bool) -> String:
	var their: String = "their" if mine else "your"
	var by_guard: Dictionary = {}
	var own_sqs: PackedStringArray = PackedStringArray()
	var own_types: Dictionary = {}
	for e: Dictionary in b.king_trap():
		var name: String = B.square_name(int(e["sq"]))
		if bool(e["own"]):
			own_sqs.append(name)
			own_types[absi(b.board[int(e["sq"])])] = true
			continue
		var guards: PackedInt32Array = e["guards"]
		if guards.is_empty():
			continue
		# Array, not PackedStringArray: a packed array is copied on the way out
		# of the Dictionary, and appending to the copy is lost.
		if not by_guard.has(guards[0]):
			by_guard[guards[0]] = []
		(by_guard[guards[0]] as Array).append(name)
	var clauses: PackedStringArray = PackedStringArray()
	for g: int in by_guard:
		var sqs := PackedStringArray(by_guard[g])
		sqs.sort()
		clauses.append("%s %s on %s covers %s" % [their, PIECE_NAMES[absi(b.board[g])],
				B.square_name(g), _and_list(sqs)])
	if not own_sqs.is_empty():
		own_sqs.sort()
		var what: String = "pieces"
		if own_types.size() == 1:
			what = PIECE_NAMES[int(own_types.keys()[0])] + ("s" if own_sqs.size() > 1 else "")
		elif own_sqs.size() == 1:
			what = "piece"
		clauses.append("%s own %s %s %s" % ["your" if mine else "their", what,
				"fills" if own_sqs.size() == 1 else "fill", _and_list(own_sqs)])
	if found.size() > 1:
		clauses.append("no one move answers two checks")
	else:
		var checker: String = PIECE_NAMES[absi(int(found[0]["piece"]))]
		if (found[0]["line"] as PackedInt32Array).is_empty():
			clauses.append("nothing can take the %s" % checker)
		else:
			clauses.append("nothing can block the %s or take it" % checker)
	var last: String = clauses[clauses.size() - 1]
	var head: PackedStringArray = clauses.slice(0, clauses.size() - 1)
	return "It is a trap: %s, and %s." % [", ".join(head), last] if not head.is_empty() \
			else "It is a trap: %s." % last


static func _and_list(items: PackedStringArray) -> String:
	if items.size() <= 1:
		return "".join(items)
	return ", ".join(items.slice(0, items.size() - 1)) + " and " + items[items.size() - 1]


static func _how_it_attacks(b: ChessBoard, piece: int, from: int, king: int) -> String:
	var type: int = absi(piece)
	if LINE_WORDS.has(type):
		return LINE_WORDS[type]
	if B.file_of(from) == B.file_of(king):
		return "straight along the column"
	if B.rank_of(from) == B.rank_of(king):
		return "straight along the row"
	return "along the diagonal"


static func _ways_out(b: ChessBoard, info: Dictionary, mine: bool) -> String:
	var found: Array = info["checkers"]
	var your: String = "your" if mine else "their"
	var checker_at: Dictionary = {}
	for c: Dictionary in found:
		checker_at[int(c["from"])] = absi(int(c["piece"]))
	var options: PackedStringArray = PackedStringArray()
	# The king taking a checker is a take, not a step: said that way it is the
	# same idea as any other piece taking it.
	var steps: PackedStringArray = PackedStringArray()
	var king_takes: Array[int] = []
	for t: int in info["king_moves"]:
		if checker_at.has(t):
			king_takes.append(int(checker_at[t]))
		else:
			steps.append(B.square_name(t))
	if not steps.is_empty():
		options.append("move %s king to %s" % [your, _or_list(steps)] if steps.size() <= 3
				else "move %s king (%d squares)" % [your, steps.size()])
	var blocks: PackedStringArray = PackedStringArray()
	for t: int in info["blocks"]:
		blocks.append(B.square_name(t))
	if not blocks.is_empty():
		options.append("block on %s" % _or_list(blocks))
	if found.size() == 1:
		var taker_names: PackedStringArray = PackedStringArray()
		for f: int in info["takers"]:
			var n: String = PIECE_NAMES[absi(b.board[f])]
			if not taker_names.has(n):
				taker_names.append(n)
		if not king_takes.is_empty():
			taker_names.append("king")
		if not taker_names.is_empty():
			options.append("take the %s with %s %s" % [
					PIECE_NAMES[absi(int(found[0]["piece"]))], your, _or_list(taker_names)])
	else:
		for type: int in king_takes:
			options.append("take the %s with %s king" % [PIECE_NAMES[type], your])
	if options.is_empty():
		return ""
	if found.size() > 1:
		return "Only the king can get out of a double check: %s." % _options(options)
	return ("Ways out: " if mine else "They have to answer it: ") + _options(options) + "."


static func _options(items: PackedStringArray) -> String:
	## The ways out, comma before the last "or": an option can hold an "or" of
	## its own ("block on c3 or d2"), and without it the sentence runs together.
	if items.size() <= 1:
		return "".join(items)
	return ", ".join(items.slice(0, items.size() - 1)) + ", or " + items[items.size() - 1]


static func _cap(text: String) -> String:
	return text.substr(0, 1).to_upper() + text.substr(1)


static func _or_list(items: PackedStringArray) -> String:
	if items.size() <= 1:
		return "".join(items)
	return ", ".join(items.slice(0, items.size() - 1)) + " or " + items[items.size() - 1]


static func _points(n: int) -> String:
	return "%d point" % n if n == 1 else "%d points" % n


func _refresh_hanging() -> void:
	_hanging = PackedInt32Array()
	if board == null or danger_for == 0:
		return
	if selected >= 0 and board.side == danger_for:
		for m in board.legal_moves_from(selected):
			var to: int = B.move_to(m)
			# Promotions repeat the destination four times; one answer will do.
			if not _hanging.has(to) and board.move_hangs(m):
				_hanging.append(to)


func clear_selection() -> void:
	selected = -1
	targets = PackedInt32Array()
	_hanging = PackedInt32Array()
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
	_refresh_hanging()
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

	if is_celebrating():
		busy = true
		# The clock starts once the mating move has landed.
		if _slides.is_empty():
			var before: float = _mate_t
			_mate_t += delta
			if _mate_win and before < MATE_TOPPLE_AT and _mate_t >= MATE_TOPPLE_AT:
				_spawn_confetti()
			if _mate_t >= MATE_DWELL:
				_finish_mate()
	elif _mate_t >= 0.0 and _mate_t < MATE_TOPPLE_AT + MATE_TOPPLE_SEC:
		busy = true
	if not _confetti.is_empty():
		_step_confetti(delta)
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

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _press_sq < 0:
		set_inspect(-1)


func _gui_input(event: InputEvent) -> void:
	if board == null:
		return
	# Pointing at a piece works even when the board is read-only — looking at a
	# finished game is exactly when "what did that piece guard?" gets asked.
	# Not during a press: the piece being dragged stays the one looked at.
	if event is InputEventMouseMotion and _press_sq < 0:
		set_inspect(square_at(event.position))
	if is_celebrating() and _mate_t >= MATE_SKIP_AFTER and (
			(event is InputEventMouseButton and event.pressed)
			or (event is InputEventScreenTouch and event.pressed)
			or event.is_action_pressed("ui_accept")):
		_finish_mate()
		accept_event()
		return
	if not interactive:
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
	# Touch has no hover, so a tap is how a piece gets looked at — either
	# colour, including the computer's, which cannot be selected.
	set_inspect(sq)

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
	set_inspect(cursor)
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

	# Training mode: squares where a piece would be taken. A flat wash over the square,
	# under the pieces, drawn before the check glow and the selection so both
	# still read on top of it.
	# Attack squares the same way, in blue; a square that is both is split.
	for sq in _danger:
		var light_d: bool = (B.file_of(sq) + B.rank_of(sq)) % 2 == 1
		var red := Color(C_DANGER, DANGER_ALPHA_LIGHT if light_d else DANGER_ALPHA_DARK)
		var rd: Rect2 = square_rect(sq)
		if _attack.has(sq):
			var blue := Color(C_ATTACK, ATTACK_ALPHA_LIGHT if light_d else ATTACK_ALPHA_DARK)
			var tl: Vector2 = rd.position
			var br: Vector2 = rd.end
			var tr := Vector2(br.x, tl.y)
			var bl := Vector2(tl.x, br.y)
			draw_colored_polygon(PackedVector2Array([tl, tr, bl]), red)
			draw_colored_polygon(PackedVector2Array([tr, br, bl]), blue)
		else:
			draw_rect(rd, red)
	for sq in _attack:
		if _danger.has(sq):
			continue
		var light_a: bool = (B.file_of(sq) + B.rank_of(sq)) % 2 == 1
		draw_rect(square_rect(sq), Color(C_ATTACK,
				ATTACK_ALPHA_LIGHT if light_a else ATTACK_ALPHA_DARK))

	# The king in check, under the pieces so the piece is never obscured. The
	# glow breathes rather than sitting still: a static red square is read once
	# and then stops being noticed.
	if board.in_check():
		var k: int = board.king_sq[0 if board.side == B.WHITE else 1]
		if k >= 0:
			var pulse: float = 0.5 + 0.5 * sin(_check_phase * TAU)
			var kr: Rect2 = square_rect(k)
			# A mated king's glow goes out as it topples: no king left standing there.
			var lit: float = 1.0
			if _mate_t >= 0.0:
				lit = 1.0 - clampf((_mate_t - MATE_TOPPLE_AT) / MATE_TOPPLE_SEC, 0.0, 1.0)
			draw_circle(kr.get_center(), _square * (0.50 + 0.04 * pulse),
					Color(C_CHECK, (0.22 + 0.16 * pulse) * lit))
			draw_circle(kr.get_center(), _square * 0.40, Color(C_CHECK, (0.38 + 0.14 * pulse) * lit))

	if selected >= 0 and _select_t > 0.0:
		var light_sel: bool = (B.file_of(selected) + B.rank_of(selected)) % 2 == 1
		var sel: Color = C_LIGHT_SELECT if light_sel else C_DARK_SELECT
		draw_rect(square_rect(selected), Color(sel, _select_t))

	for sq in targets:
		var r2: Rect2 = square_rect(sq)
		var dot: Color = Color(C_DOT, C_DOT.a * _select_t)
		if _hanging.has(sq):
			# A move that leaves the piece where it can be taken: the same red
			# as the danger squares, so it reads as "this would be one".
			dot = Color(C_DANGER, 0.62 * _select_t)
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
		if sq == _mated_king():
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
		_draw_arrow(_arrow_points(hint_from, hint_to))

	_draw_mated_king()
	_draw_danger_badges()
	_draw_check_why()
	_draw_chain()
	_draw_mate_show()

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


## Take-chain colours: the player's captures blue, the computer's red, both
## strong enough to read over a tinted square. Steps past where a sensible
## player stops are drawn at CHAIN_FADED.
const C_CHAIN_MINE: Color = Color(0.11, 0.36, 0.86, 0.90)
const C_CHAIN_THEIRS: Color = Color(0.80, 0.12, 0.12, 0.90)
const CHAIN_FADED: float = 0.28
const C_BADGE_LOSE: Color = Color(0.84, 0.13, 0.13)
const C_BADGE_EVEN: Color = Color(0.93, 0.62, 0.10)
const C_VERDICT_GOOD: Color = Color(0.13, 0.55, 0.25)


func _draw_danger_badges() -> void:
	## A "!" in the top-right corner of each of the player's pieces that can be
	## taken: red when the taker comes out ahead, amber for an even trade. In
	## the corner so the piece itself stays readable.
	var font: Font = ThemeDB.fallback_font
	var radius: float = _square * 0.15
	var fs: int = int(maxf(9.0, _square * 0.24))
	# Not while the check aid is up: the only thing to do then is get out of
	# check, and the badges were a second set of red marks competing with it.
	if not _check.is_empty():
		return
	for sq: int in _in_danger:
		if _slides.size() > 0:
			break
		var r: Rect2 = square_rect(sq)
		var c: Vector2 = r.position + Vector2(r.size.x - radius * 1.15, radius * 1.15)
		var colour: Color = C_BADGE_LOSE if int(_in_danger[sq]) > 0 else C_BADGE_EVEN
		draw_circle(c, radius, colour)
		draw_arc(c, radius, 0.0, TAU, 24, Color(1, 1, 1, 0.9), maxf(1.0, _square * 0.02), true)
		draw_string(font, c + Vector2(-radius, fs * 0.36), "!", HORIZONTAL_ALIGNMENT_CENTER,
				radius * 2.0, fs, Color.WHITE)


## Why check: the arrow from the checker to the king.
const C_CHECK_ARROW: Color = Color(0.80, 0.12, 0.12, 0.92)
## The ways out of check.
const C_ESCAPE: Color = Color(0.10, 0.62, 0.28, 0.95)
## Checkmate's net: the thin ring on a piece that helps the checker.
const C_GUARD_LINE: Color = Color(0.80, 0.12, 0.12, 0.55)
## The checkmate show's timing, in seconds after the mating move lands.
const MATE_TOPPLE_AT: float = 1.4
const MATE_TOPPLE_SEC: float = 0.7
const MATE_SKIP_AFTER: float = 0.8
const MATE_DWELL: float = 6.0
const CONFETTI: Array[Color] = [Color(0.96, 0.26, 0.21), Color(1.0, 0.76, 0.03),
		Color(0.30, 0.69, 0.31), Color(0.13, 0.59, 0.95), Color(0.61, 0.15, 0.69),
		Color(1.0, 0.60, 0.0), Color(0.0, 0.74, 0.83)]


func _draw_check_why() -> void:
	## Over the pieces: an arrow from each checker to the king (an L for a
	## knight), then the ways out or, on mate, the trap. Nothing else: the
	## king's own glow already says "check", the panel names it, and a wash
	## along the line, a box on the checker or a label over the king each
	## repeated one of those and covered pieces doing it (gallery-checked,
	## tests/gallery_checks.gd).
	if _check.is_empty() or not _slides.is_empty():
		return
	var king: int = int(_check["king"])
	var found: Array = _check["checkers"]
	for c: Dictionary in found:
		_draw_arrow_coloured(_arrow_points(int(c["from"]), king), C_CHECK_ARROW, 0.10)
	if _is_stuck():
		_draw_trap(found)
	else:
		_draw_escapes(found)


func _draw_escapes(found: Array) -> void:
	## The ways out, in green: a dot where the king can step (a ring where it
	## steps by taking), a box on each square a block can go to, and an arrow
	## from each piece that can take the checker.
	var line_w: float = maxf(2.0, _square * 0.06)
	for t: int in _check["king_moves"]:
		var c: Vector2 = square_rect(t).get_center()
		if board.board[t] != 0:
			draw_arc(c, _square * 0.40, 0.0, TAU, 32, C_ESCAPE, _square * 0.07, true)
		else:
			draw_circle(c, _square * 0.15, C_ESCAPE)
	for t: int in _check["blocks"]:
		draw_rect(square_rect(t).grow(-_square * 0.12), C_ESCAPE, false, line_w)
	if found.size() == 1:
		var target: int = int(found[0]["from"])
		for f: int in _check["takers"]:
			_draw_arrow_coloured(_arrow_points(f, target), C_ESCAPE, 0.06)


func _draw_trap(found: Array) -> void:
	## Checkmate as the net it is. Every square round the king is closed: a
	## red cross where an enemy piece covers it, an amber box where the
	## king's own piece is in the way, and a thin ring on each enemy piece
	## that helps the checker. No lines
	## from guard to square: on a ladder or a queen mate they crossed the
	## king and each other, and the panel already says who covers what.
	var checker_sqs: Array[int] = []
	for c: Dictionary in found:
		checker_sqs.append(int(c["from"]))
	var helpers: Dictionary = {}
	var w: float = maxf(2.0, _square * 0.07)
	for e: Dictionary in _trap:
		var sq: int = int(e["sq"])
		var r: Rect2 = square_rect(sq)
		if bool(e["own"]):
			draw_rect(r.grow(-_square * 0.08), C_BADGE_EVEN, false, maxf(2.0, _square * 0.05))
			continue
		var guards: PackedInt32Array = e["guards"]
		if guards.is_empty():
			continue
		for g: int in guards:
			if not checker_sqs.has(g):
				helpers[g] = true
		# An attacker standing next to the king, protected: no mark on it. A
		# cross on the player's own piece read as "this piece is wrong"
		# (owner, 2026-11-19); the ring on its protector says why the king
		# cannot take it.
		if board.board[sq] != 0:
			continue
		var c: Vector2 = r.get_center()
		var a: float = _square * 0.20
		draw_line(c + Vector2(-a, -a), c + Vector2(a, a), C_CHECK_ARROW, w, true)
		draw_line(c + Vector2(-a, a), c + Vector2(a, -a), C_CHECK_ARROW, w, true)
	for g: int in helpers:
		draw_rect(square_rect(g).grow(-_square * 0.07), C_GUARD_LINE, false,
				maxf(2.0, _square * 0.045))


func _mated_king() -> int:
	if _mate_t < 0.0 or board == null:
		return -1
	return board.king_sq[0 if board.side == B.WHITE else 1]


func _draw_mated_king() -> void:
	## The mated king tips over, away from the piece that mated it, pivoting
	## on the edge of its base like a real piece pushed over.
	var k: int = _mated_king()
	if k < 0 or board.board[k] == 0:
		return
	var r: Rect2 = square_rect(k)
	var u: float = clampf((_mate_t - MATE_TOPPLE_AT) / MATE_TOPPLE_SEC, 0.0, 1.0)
	if u <= 0.0:
		_draw_piece_at(board.board[k], r)
		return
	var dir: float = 1.0
	if not _check.is_empty():
		var from: Vector2 = square_rect(int(_check["checkers"][0]["from"])).get_center()
		dir = -1.0 if from.x > r.get_center().x else 1.0
	# A small bounce at the end, as it lands.
	var k_ease: float = _ease_out(u)
	var angle: float = dir * deg_to_rad(78.0) * k_ease
	var pivot := Vector2(r.position.x + r.size.x * (0.5 + 0.28 * dir), r.end.y - r.size.y * 0.10)
	draw_set_transform(pivot, angle, Vector2.ONE)
	_draw_piece_at(board.board[k], Rect2(r.position - pivot, r.size))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_mate_show() -> void:
	## The banner and the confetti, over everything else on the board.
	for c: Dictionary in _confetti:
		var life: float = float(c["life"])
		var alpha: float = clampf(life / 0.5, 0.0, 1.0)
		draw_set_transform(c["pos"], float(c["rot"]), Vector2.ONE)
		var sz: Vector2 = c["size"]
		# Flutter: the piece of paper turns edge-on and back.
		sz.y *= absf(cos(float(c["flip"])))
		draw_rect(Rect2(-sz * 0.5, sz), Color(c["colour"], alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if not is_celebrating() or _mate_t < MATE_TOPPLE_AT:
		return
	var u: float = clampf((_mate_t - MATE_TOPPLE_AT) / 0.35, 0.0, 1.0)
	var pop: float = _ease_out(u) + 0.12 * sin(PI * u)
	var font: Font = ThemeDB.fallback_font
	var fs: int = int(maxf(14.0, _square * 0.62 * pop))
	var text: String = "Checkmate!"
	var tw: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var sub: String = "You won!" if _mate_win else "The computer won"
	var sfs: int = int(maxf(10.0, _square * 0.26 * pop))
	var bw: float = maxf(tw, font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs).x) + fs
	var bh: float = fs * 1.25 + sfs * 1.6
	# On the half of the board away from the mated king, so the trap stays in view.
	var k: int = _mated_king()
	var board_mid: float = _origin.y + _square * 4.0
	var upper: bool = k >= 0 and square_rect(k).get_center().y > board_mid
	var cy: float = _origin.y + _square * (2.0 if upper else 6.0)
	var box := Rect2(Vector2(_origin.x + _square * 4.0 - bw * 0.5, cy - bh * 0.5), Vector2(bw, bh))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_VERDICT_GOOD if _mate_win else C_BADGE_LOSE, 0.94)
	sb.set_corner_radius_all(int(minf(bh * 0.3, 24.0)))
	sb.border_color = Color(1, 1, 1, 0.9)
	sb.set_border_width_all(int(maxf(2.0, _square * 0.04)))
	draw_style_box(sb, box)
	draw_string(font, Vector2(box.position.x, box.position.y + fs * 1.05), text,
			HORIZONTAL_ALIGNMENT_CENTER, bw, fs, Color.WHITE)
	draw_string(font, Vector2(box.position.x, box.position.y + fs * 1.25 + sfs * 1.05), sub,
			HORIZONTAL_ALIGNMENT_CENTER, bw, sfs, Color(1, 1, 1, 0.92))


func _spawn_confetti() -> void:
	## Two bursts: one from the piece that gave mate, one from each top corner
	## of the board, so it fills the board rather than one spot.
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var unit: float = _square / 64.0
	var sources: Array = []
	if not _check.is_empty():
		sources.append([square_rect(int(_check["checkers"][0]["from"])).get_center(), 70, -PI * 0.5, PI * 0.9])
	sources.append([_origin + Vector2(0, _square * 0.5), 45, -PI * 0.3, PI * 0.35])
	sources.append([_origin + Vector2(_square * 8.0, _square * 0.5), 45, -PI * 0.7, PI * 0.35])
	for src: Array in sources:
		for i in int(src[1]):
			var ang: float = float(src[2]) + rng.randf_range(-1.0, 1.0) * float(src[3])
			var speed: float = rng.randf_range(260.0, 620.0) * unit
			_confetti.append({
				"pos": src[0], "vel": Vector2(cos(ang), sin(ang)) * speed,
				"rot": rng.randf() * TAU, "spin": rng.randf_range(-9.0, 9.0),
				"flip": rng.randf() * TAU, "flip_rate": rng.randf_range(6.0, 14.0),
				"size": Vector2(rng.randf_range(7.0, 12.0), rng.randf_range(4.0, 7.0)) * unit,
				"colour": CONFETTI[rng.randi() % CONFETTI.size()],
				"life": rng.randf_range(2.2, 3.2)})


func _step_confetti(delta: float) -> void:
	var gravity: float = 820.0 * _square / 64.0
	for i in range(_confetti.size() - 1, -1, -1):
		var c: Dictionary = _confetti[i]
		c["life"] = float(c["life"]) - delta
		if float(c["life"]) <= 0.0:
			_confetti.remove_at(i)
			continue
		var v: Vector2 = c["vel"]
		v.y += gravity * delta
		v *= pow(0.35, delta)  # air drag, so it drifts down rather than drops
		c["vel"] = v
		c["pos"] = (c["pos"] as Vector2) + v * delta
		c["rot"] = float(c["rot"]) + float(c["spin"]) * delta
		c["flip"] = float(c["flip"]) + float(c["flip_rate"]) * delta


func _draw_chain() -> void:
	## The pointed-at piece's take chain: an arrow from each taker to the
	## square, a numbered disc on the taker giving the order, and the verdict
	## in a pill beside the square.
	if _chain.is_empty() or _inspect < 0 or not _slides.is_empty():
		return
	var steps: Array = _chain["steps"]
	var played: int = int(_chain["played"])
	var font: Font = ThemeDB.fallback_font
	# Faded first so the steps that happen are drawn over them.
	for pass_faded: bool in [true, false]:
		for i in steps.size():
			if (i >= played) != pass_faded:
				continue
			var from_sq: int = int(steps[i]["from"])
			var mine: bool = (int(steps[i]["piece"]) > 0) == (chains_for > 0)
			var colour: Color = C_CHAIN_MINE if mine else C_CHAIN_THEIRS
			if pass_faded:
				colour.a = CHAIN_FADED
			_draw_arrow_coloured(_arrow_points(from_sq, _inspect), colour, 0.08)
			var dr: Rect2 = square_rect(from_sq)
			var disc: Vector2 = dr.position + Vector2(_square * 0.19, _square * 0.19)
			var rad: float = _square * 0.16
			draw_circle(disc, rad, colour)
			var fs: int = int(maxf(9.0, _square * 0.22))
			draw_string(font, disc + Vector2(-rad, fs * 0.36), str(i + 1),
					HORIZONTAL_ALIGNMENT_CENTER, rad * 2.0, fs, Color(1, 1, 1, colour.a))
	_draw_verdict()


func _draw_verdict() -> void:
	var target_piece: int = board.board[_inspect]
	var mine: bool = (target_piece > 0) == (chains_for > 0)
	var worth: int = int(_chain["worth"])
	var played: int = int(_chain["played"])
	var first_mine: bool = (int(_chain["steps"][0]["piece"]) > 0) == (chains_for > 0)
	var text: String
	var colour: Color
	if played == 0:
		text = "safe" if mine else "protected"
		colour = C_VERDICT_GOOD if mine else C_BADGE_EVEN
	elif worth == 0:
		text = "even trade"
		colour = C_BADGE_EVEN
	elif first_mine:
		text = "win %d" % worth
		colour = C_VERDICT_GOOD
	else:
		text = "lose %d" % worth
		colour = C_BADGE_LOSE
	_draw_pill(_inspect, text, colour)


func _draw_pill(sq: int, text: String, colour: Color) -> void:
	var font: Font = ThemeDB.fallback_font
	var fs: int = int(maxf(10.0, _square * 0.22))
	var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + fs * 0.9
	var h: float = fs * 1.5
	var r: Rect2 = square_rect(sq)
	# Above the square, or below it on the top row; kept inside the board.
	var y: float = r.position.y - h - _square * 0.04
	if y < _origin.y:
		y = r.end.y + _square * 0.04
	var x: float = clampf(r.get_center().x - w * 0.5, _origin.x, _origin.x + _square * 8.0 - w)
	var pill := Rect2(Vector2(x, y), Vector2(w, h))
	var sb := StyleBoxFlat.new()
	sb.bg_color = colour
	sb.set_corner_radius_all(int(h * 0.5))
	draw_style_box(sb, pill)
	draw_string(font, Vector2(x, y + h * 0.5 + fs * 0.36), text, HORIZONTAL_ALIGNMENT_CENTER,
			w, fs, Color.WHITE)


func _arrow_points(from_sq: int, to_sq: int) -> PackedVector2Array:
	## Square centres for an arrow from one square to another. A knight's jump
	## (only a knight moves 1x2) bends at a right angle like the classic L:
	## the long leg first, then the short one into the target.
	var a: Vector2 = square_rect(from_sq).get_center()
	var b: Vector2 = square_rect(to_sq).get_center()
	var df: int = absi((to_sq & 7) - (from_sq & 7))
	var dr: int = absi((to_sq >> 4) - (from_sq >> 4))
	if df * dr != 2:
		return PackedVector2Array([a, b])
	var corner: Vector2 = Vector2(b.x, a.y) if absf(b.x - a.x) > absf(b.y - a.y) else Vector2(a.x, b.y)
	return PackedVector2Array([a, corner, b])


func _draw_arrow_path(pts: PackedVector2Array, colour: Color, width: float, head: float,
		head_half: float, start_trim: float, tip_trim: float) -> void:
	## A straight arrow (2 points) or one with a single right-angle bend
	## (3 points). The bent shaft is ONE polygon with a mitred corner, not two
	## lines, so a translucent arrow has no darker overlap at the bend.
	var last: int = pts.size() - 1
	var d0: Vector2 = (pts[1] - pts[0]).normalized()
	var d1: Vector2 = (pts[last] - pts[last - 1]).normalized()
	var start: Vector2 = pts[0] + d0 * start_trim
	var tip: Vector2 = pts[last] - d1 * tip_trim
	var shaft_end: Vector2 = tip - d1 * head
	if last == 1:
		draw_line(start, shaft_end, colour, width, true)
	else:
		var c: Vector2 = pts[1]
		var n0: Vector2 = Vector2(-d0.y, d0.x) * width * 0.5
		var n1: Vector2 = Vector2(-d1.y, d1.x) * width * 0.5
		draw_colored_polygon(PackedVector2Array([start + n0, c + n0 + n1, shaft_end + n1,
				shaft_end - n1, c - n0 - n1, start - n0]), colour)
	var perp: Vector2 = Vector2(-d1.y, d1.x) * head * head_half
	draw_colored_polygon(PackedVector2Array([tip, shaft_end + perp, shaft_end - perp]), colour)


func _draw_arrow_coloured(pts: PackedVector2Array, colour: Color, width: float) -> void:
	## A slimmer arrow than the hint's, stopping short of the target's centre
	## so several converging on one square do not bury the piece.
	_draw_arrow_path(pts, colour, _square * width, _square * 0.24, 0.55,
			_square * 0.20, _square * 0.30)


func _draw_arrow(pts: PackedVector2Array) -> void:
	_draw_arrow_path(pts, C_HINT, _square * 0.13, _square * 0.34, 0.52,
			_square * 0.18, _square * 0.06)
