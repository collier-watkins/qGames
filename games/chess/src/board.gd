class_name ChessBoard
extends RefCounted

## The rules of chess, and nothing else. Pure RefCounted: no Node, no drawing,
## unit-testable headless (see tests/run.gd, which proves it by perft).
##
## Representation is 0x88 mailbox — a 16x8 array where a square is valid iff
## `sq & 0x88 == 0`. Off-board detection is therefore ONE bitwise AND, with no
## bounds arithmetic and no per-direction edge tables, which is what keeps the
## generator both short and fast enough for GDScript. The waste is 64 unused
## ints; that is nothing against the branch it removes from every ray step.
##
## Everything the game needs to know about legality lives here: castling and
## the three ways it is forbidden, en passant including the pin that makes it
## illegal, promotion, the fifty-move rule, threefold repetition, and dead
## positions. The view asks; it never decides.

# Colours. Multiplying by the colour is how a piece code becomes signed, so
# these must stay +1/-1 rather than 0/1.
const WHITE: int = 1
const BLACK: int = -1

# Piece codes. Positive is white, negative is black; abs() is the type.
const PAWN: int = 1
const KNIGHT: int = 2
const BISHOP: int = 3
const ROOK: int = 4
const QUEEN: int = 5
const KING: int = 6

# Castling rights, as bits.
const CR_WK: int = 1
const CR_WQ: int = 2
const CR_BK: int = 4
const CR_BQ: int = 8
const CR_ALL: int = 15

# Move flags, in bits 24..31 of a packed move.
const FLAG_NONE: int = 0
const FLAG_EP: int = 1        ## capture en passant
const FLAG_CASTLE: int = 2    ## king move of two files; rook is moved with it
const FLAG_DOUBLE: int = 3    ## pawn's initial two-square advance

# Terminal states, returned by status().
const ONGOING: int = 0
const CHECKMATE: int = 1
const STALEMATE: int = 2
const DRAW_FIFTY: int = 3
const DRAW_REPETITION: int = 4
const DRAW_MATERIAL: int = 5

const START_FEN: String = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

const KNIGHT_D: Array[int] = [33, 31, 18, 14, -33, -31, -18, -14]
const BISHOP_D: Array[int] = [17, 15, -17, -15]
const ROOK_D: Array[int] = [16, 1, -16, -1]
const KING_D: Array[int] = [17, 16, 15, 1, -17, -16, -15, -1]

const PIECE_LETTER: String = " PNBRQK"

## Squares whose vacancy or occupation costs a castling right. Losing rights
## when a ROOK IS CAPTURED ON ITS HOME SQUARE is the half everyone forgets:
## it is not the rook moving, it is the square changing hands either way, so
## the mask is applied to both `from` and `to`.
const CR_LOST: Dictionary = {
	4: CR_WK | CR_WQ, 116: CR_BK | CR_BQ,
	0: CR_WQ, 7: CR_WK, 112: CR_BQ, 119: CR_BK,
}

var board: PackedInt32Array = PackedInt32Array()
var side: int = WHITE
var ep: int = -1              ## en-passant TARGET square, or -1
var castling: int = CR_ALL
var halfmove: int = 0         ## plies since the last capture or pawn move
var fullmove: int = 1
var king_sq: Array[int] = [4, 116]   ## [white, black]

## Undo records, one per made move. Each is a plain Array of ints rather than a
## Dictionary: the search makes and unmakes millions of these, and a Dictionary
## allocation per ply is the difference between a usable engine and a slideshow.
var _undo: Array = []

## Repetition counter, keyed by position. Maintained only for moves made on the
## real game (make_move), never inside the search, because a search that had to
## hash into a Dictionary at every node would lose most of its speed for a rule
## that decides one game in a hundred.
var _reps: Dictionary = {}


func _init(fen: String = START_FEN) -> void:
	set_fen(fen)


# ---------------------------------------------------------------- setup / FEN

func set_fen(fen: String) -> void:
	board.resize(128)
	for i in 128:
		board[i] = 0
	var parts: PackedStringArray = fen.strip_edges().split(" ", false)
	if parts.size() < 4:
		push_error("ChessBoard: malformed FEN %s" % fen)
		parts = START_FEN.split(" ", false)

	var rank: int = 7
	var file: int = 0
	for ch in parts[0]:
		if ch == "/":
			rank -= 1
			file = 0
		elif ch >= "1" and ch <= "8":
			file += ch.to_int()
		else:
			var upper: String = ch.to_upper()
			var type: int = PIECE_LETTER.find(upper)
			if type > 0 and rank >= 0 and file < 8:
				board[rank * 16 + file] = type if ch == upper else -type
			file += 1

	side = WHITE if parts[1] == "w" else BLACK
	castling = 0
	if parts[2].contains("K"): castling |= CR_WK
	if parts[2].contains("Q"): castling |= CR_WQ
	if parts[2].contains("k"): castling |= CR_BK
	if parts[2].contains("q"): castling |= CR_BQ
	ep = square_from_name(parts[3]) if parts[3] != "-" else -1
	halfmove = parts[4].to_int() if parts.size() > 4 else 0
	fullmove = parts[5].to_int() if parts.size() > 5 else 1

	king_sq = [-1, -1]
	for sq in 128:
		if sq & 0x88:
			continue
		if board[sq] == KING:
			king_sq[0] = sq
		elif board[sq] == -KING:
			king_sq[1] = sq

	_undo.clear()
	_reps.clear()
	_reps[position_key()] = 1


func fen() -> String:
	var rows: PackedStringArray = PackedStringArray()
	for rank in range(7, -1, -1):
		var row: String = ""
		var gap: int = 0
		for file in 8:
			var p: int = board[rank * 16 + file]
			if p == 0:
				gap += 1
				continue
			if gap > 0:
				row += str(gap)
				gap = 0
			var letter: String = PIECE_LETTER[absi(p)]
			row += letter if p > 0 else letter.to_lower()
		if gap > 0:
			row += str(gap)
		rows.append(row)
	var rights: String = ""
	if castling & CR_WK: rights += "K"
	if castling & CR_WQ: rights += "Q"
	if castling & CR_BK: rights += "k"
	if castling & CR_BQ: rights += "q"
	if rights == "":
		rights = "-"
	return "%s %s %s %s %d %d" % [
		"/".join(rows), "w" if side == WHITE else "b", rights,
		square_name(ep) if ep >= 0 else "-", halfmove, fullmove,
	]


func duplicate_board() -> ChessBoard:
	## A detached copy, for the engine to search without touching the game.
	## History is deliberately NOT carried: the copy is a position, not a game.
	return ChessBoard.new(fen())


# ---------------------------------------------------------------- coordinates

static func square_name(sq: int) -> String:
	if sq < 0 or (sq & 0x88):
		return "-"
	return String.chr(97 + (sq & 7)) + str((sq >> 4) + 1)


static func square_from_name(s: String) -> int:
	if s.length() < 2:
		return -1
	var file: int = s.unicode_at(0) - 97
	var rank: int = s.unicode_at(1) - 49
	if file < 0 or file > 7 or rank < 0 or rank > 7:
		return -1
	return rank * 16 + file


static func square_of(file: int, rank: int) -> int:
	return rank * 16 + file


static func file_of(sq: int) -> int:
	return sq & 7


static func rank_of(sq: int) -> int:
	return sq >> 4


# ------------------------------------------------------------ move packing

static func pack(from: int, to: int, promo: int = 0, flag: int = FLAG_NONE) -> int:
	return from | (to << 8) | (promo << 16) | (flag << 24)


static func move_from(m: int) -> int:
	return m & 0xFF


static func move_to(m: int) -> int:
	return (m >> 8) & 0xFF


static func move_promo(m: int) -> int:
	return (m >> 16) & 0xFF


static func move_flag(m: int) -> int:
	return (m >> 24) & 0xFF


static func move_uci(m: int) -> String:
	var s: String = square_name(move_from(m)) + square_name(move_to(m))
	var promo: int = move_promo(m)
	if promo != 0:
		s += PIECE_LETTER[promo].to_lower()
	return s


func move_from_uci(uci: String) -> int:
	## Resolves a UCI string against the CURRENT position, so it comes back
	## with the right flags — the engine protocol carries "e1g1" with no hint
	## that it is a castle, and applying it as a plain king move would leave
	## the rook behind.
	if uci.length() < 4:
		return 0
	var from: int = square_from_name(uci.substr(0, 2))
	var to: int = square_from_name(uci.substr(2, 2))
	var promo: int = 0
	if uci.length() > 4:
		promo = PIECE_LETTER.find(uci[4].to_upper())
	for m in legal_moves():
		if move_from(m) == from and move_to(m) == to:
			if promo == 0 or move_promo(m) == promo:
				return m
	return 0


# ------------------------------------------------------------------- attacks

func is_attacked(sq: int, by: int) -> bool:
	## Is `sq` attacked by side `by`? Runs from the SQUARE outwards rather than
	## from every enemy piece inwards — one scan of eight rays and two jump
	## sets, instead of a full move generation, which is why legality checking
	## is affordable at every node.
	if by == WHITE:
		if not ((sq - 15) & 0x88) and board[sq - 15] == PAWN: return true
		if not ((sq - 17) & 0x88) and board[sq - 17] == PAWN: return true
	else:
		if not ((sq + 15) & 0x88) and board[sq + 15] == -PAWN: return true
		if not ((sq + 17) & 0x88) and board[sq + 17] == -PAWN: return true
	for d: int in KNIGHT_D:
		var t: int = sq + d
		if not (t & 0x88) and board[t] == KNIGHT * by:
			return true
	for d: int in KING_D:
		var t: int = sq + d
		if not (t & 0x88) and board[t] == KING * by:
			return true
	for d: int in BISHOP_D:
		var t: int = sq + d
		while not (t & 0x88):
			var p: int = board[t]
			if p != 0:
				if p == BISHOP * by or p == QUEEN * by:
					return true
				break
			t += d
	for d: int in ROOK_D:
		var t: int = sq + d
		while not (t & 0x88):
			var p: int = board[t]
			if p != 0:
				if p == ROOK * by or p == QUEEN * by:
					return true
				break
			t += d
	return false


func in_check(colour: int = 0) -> bool:
	var c: int = colour if colour != 0 else side
	var k: int = king_sq[0 if c == WHITE else 1]
	return k >= 0 and is_attacked(k, -c)


# ---------------------------------------------------------- move generation

func pseudo_moves(captures_only: bool = false) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var me: int = side
	for sq in 128:
		if sq & 0x88:
			continue
		var p: int = board[sq]
		if p == 0 or (p > 0) != (me > 0):
			continue
		var type: int = absi(p)
		if type == PAWN:
			_gen_pawn(out, sq, me, captures_only)
		elif type == KNIGHT or type == KING:
			var dirs: Array[int] = KNIGHT_D if type == KNIGHT else KING_D
			for d: int in dirs:
				var t: int = sq + d
				if t & 0x88:
					continue
				var q: int = board[t]
				if q == 0:
					if not captures_only:
						out.append(pack(sq, t))
				elif (q > 0) != (me > 0):
					out.append(pack(sq, t))
		else:
			var dirs2: Array[int] = BISHOP_D if type == BISHOP else (ROOK_D if type == ROOK else KING_D)
			for d: int in dirs2:
				var t: int = sq + d
				while not (t & 0x88):
					var q: int = board[t]
					if q == 0:
						if not captures_only:
							out.append(pack(sq, t))
					else:
						if (q > 0) != (me > 0):
							out.append(pack(sq, t))
						break
					t += d
	if not captures_only:
		_gen_castles(out, me)
	return out


func _gen_pawn(out: PackedInt32Array, sq: int, me: int, captures_only: bool) -> void:
	var fwd: int = 16 * me
	var last_rank: int = 7 if me == WHITE else 0
	var start_rank: int = 1 if me == WHITE else 6
	var one: int = sq + fwd
	if not (one & 0x88) and board[one] == 0:
		# A promotion is a capture as far as the quiescence search is concerned
		# — it changes material by more than most captures do.
		if not captures_only or rank_of(one) == last_rank:
			_add_pawn_move(out, sq, one, last_rank)
		if not captures_only and rank_of(sq) == start_rank:
			var two: int = one + fwd
			if board[two] == 0:
				out.append(pack(sq, two, 0, FLAG_DOUBLE))
	for dd: int in [fwd - 1, fwd + 1]:
		var t: int = sq + dd
		if t & 0x88:
			continue
		var q: int = board[t]
		if q != 0 and (q > 0) != (me > 0):
			_add_pawn_move(out, sq, t, last_rank)
		elif t == ep and ep >= 0:
			out.append(pack(sq, t, 0, FLAG_EP))


func _add_pawn_move(out: PackedInt32Array, from: int, to: int, last_rank: int) -> void:
	if rank_of(to) == last_rank:
		# Queen first so move ordering sees the one that matters without
		# sorting, and knight last but never omitted — underpromotion to a
		# knight is the only one that is ever the winning move.
		for promo: int in [QUEEN, ROOK, BISHOP, KNIGHT]:
			out.append(pack(from, to, promo))
	else:
		out.append(pack(from, to))


func _gen_castles(out: PackedInt32Array, me: int) -> void:
	## All three prohibitions are checked here: the king may not castle out of
	## check, through an attacked square, or into check. The third is checked
	## again by the legality filter, but the first two cannot be — the filter
	## only ever sees the final position.
	var opp: int = -me
	if me == WHITE:
		if (castling & CR_WK) and board[5] == 0 and board[6] == 0:
			if not is_attacked(4, opp) and not is_attacked(5, opp) and not is_attacked(6, opp):
				out.append(pack(4, 6, 0, FLAG_CASTLE))
		if (castling & CR_WQ) and board[3] == 0 and board[2] == 0 and board[1] == 0:
			if not is_attacked(4, opp) and not is_attacked(3, opp) and not is_attacked(2, opp):
				out.append(pack(4, 2, 0, FLAG_CASTLE))
	else:
		if (castling & CR_BK) and board[117] == 0 and board[118] == 0:
			if not is_attacked(116, opp) and not is_attacked(117, opp) and not is_attacked(118, opp):
				out.append(pack(116, 118, 0, FLAG_CASTLE))
		if (castling & CR_BQ) and board[115] == 0 and board[114] == 0 and board[113] == 0:
			if not is_attacked(116, opp) and not is_attacked(115, opp) and not is_attacked(114, opp):
				out.append(pack(116, 114, 0, FLAG_CASTLE))


func legal_moves() -> PackedInt32Array:
	## Legality by make-and-test. The alternative — pin detection during
	## generation — is faster and is where subtle bugs live, particularly for
	## en passant, where BOTH captured and capturing pawn leave the same rank
	## and can expose a king to a rook that neither piece was ever pinned by.
	## Making the move and asking is the version that cannot get that wrong.
	var out: PackedInt32Array = PackedInt32Array()
	for m in pseudo_moves():
		_make(m)
		if not is_attacked(king_sq[0 if -side == WHITE else 1], side):
			out.append(m)
		_unmake()
	return out


func legal_moves_from(sq: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for m in legal_moves():
		if move_from(m) == sq:
			out.append(m)
	return out


# --------------------------------------------------------- make / unmake

func _make(m: int) -> void:
	## The search path: no repetition bookkeeping, no SAN, no allocation beyond
	## one undo record. make_move() is the game path and wraps this.
	var from: int = m & 0xFF
	var to: int = (m >> 8) & 0xFF
	var promo: int = (m >> 16) & 0xFF
	var flag: int = (m >> 24) & 0xFF
	var piece: int = board[from]
	var captured: int = board[to]

	_undo.append([from, to, captured, ep, castling, halfmove, piece, flag])

	board[to] = piece if promo == 0 else promo * side
	board[from] = 0
	ep = -1
	halfmove += 1
	if captured != 0 or absi(piece) == PAWN:
		halfmove = 0

	if flag == FLAG_EP:
		var capsq: int = to - 16 * side
		_undo[-1][2] = board[capsq]
		board[capsq] = 0
	elif flag == FLAG_DOUBLE:
		ep = from + 16 * side
	elif flag == FLAG_CASTLE:
		match to:
			6: board[5] = board[7]; board[7] = 0
			2: board[3] = board[0]; board[0] = 0
			118: board[117] = board[119]; board[119] = 0
			114: board[115] = board[112]; board[112] = 0

	if absi(piece) == KING:
		king_sq[0 if side == WHITE else 1] = to

	castling &= ~int(CR_LOST.get(from, 0))
	castling &= ~int(CR_LOST.get(to, 0))

	if side == BLACK:
		fullmove += 1
	side = -side


func _unmake() -> void:
	var u: Array = _undo.pop_back()
	side = -side
	if side == BLACK:
		fullmove -= 1
	var from: int = u[0]
	var to: int = u[1]
	var captured: int = u[2]
	var flag: int = u[7]
	var piece: int = u[6]

	board[from] = piece
	if flag == FLAG_EP:
		board[to] = 0
		board[to - 16 * side] = captured
	else:
		board[to] = captured

	if flag == FLAG_CASTLE:
		match to:
			6: board[7] = board[5]; board[5] = 0
			2: board[0] = board[3]; board[3] = 0
			118: board[119] = board[117]; board[117] = 0
			114: board[112] = board[115]; board[115] = 0

	if absi(piece) == KING:
		king_sq[0 if side == WHITE else 1] = from

	ep = u[3]
	castling = u[4]
	halfmove = u[5]


func make_move(m: int) -> void:
	## The game path. Adds repetition bookkeeping, which the search skips.
	_make(m)
	var key: String = position_key()
	_reps[key] = int(_reps.get(key, 0)) + 1


func undo_move() -> void:
	if _undo.is_empty():
		return
	var key: String = position_key()
	var n: int = int(_reps.get(key, 0)) - 1
	if n <= 0:
		_reps.erase(key)
	else:
		_reps[key] = n
	_unmake()


func ply() -> int:
	return _undo.size()


# ------------------------------------------------------------ game outcome

func position_key() -> String:
	## Identity for the repetition rule: the same men on the same squares, the
	## same side to move, the same castling rights and the same en-passant
	## POSSIBILITY. The last word is the subtlety — a recorded ep square that
	## no pawn can actually capture on does not make the position different,
	## and including it blindly is how a genuine threefold goes unclaimed.
	var live_ep: int = -1
	if ep >= 0:
		for dd: int in [-16 * side - 1, -16 * side + 1]:
			var t: int = ep + dd
			if not (t & 0x88) and board[t] == PAWN * side:
				live_ep = ep
				break
	return "%s|%d|%d|%d" % [board, side, castling, live_ep]


func is_insufficient_material() -> bool:
	## Dead positions, in the practical form every server uses: lone kings,
	## king and one minor, and king-and-bishop against king-and-bishop when
	## both bishops stand on the same colour. Anything with a pawn, rook or
	## queen on the board can still be mated, so it is not dead.
	var minors: Array[int] = []
	for sq in 128:
		if sq & 0x88:
			continue
		var p: int = board[sq]
		if p == 0 or absi(p) == KING:
			continue
		var t: int = absi(p)
		if t == PAWN or t == ROOK or t == QUEEN:
			return false
		minors.append(sq if t == BISHOP else -1)
	if minors.size() <= 1:
		return true
	if minors.size() == 2 and minors[0] >= 0 and minors[1] >= 0:
		# Same-colour bishops: a square is dark iff file+rank is even.
		var a: int = (file_of(minors[0]) + rank_of(minors[0])) & 1
		var b: int = (file_of(minors[1]) + rank_of(minors[1])) & 1
		return a == b
	return false


func repetition_counts() -> Dictionary:
	## Read-only view of how often each position has occurred in THIS game.
	## The opponent is handed a copy so it can refuse to repeat a position it
	## is winning, which the search cannot see for itself — a detached copy
	## carries a position, not a history.
	return _reps


func is_threefold() -> bool:
	return int(_reps.get(position_key(), 0)) >= 3


func status() -> int:
	## Checked in the order the rules apply: mate and stalemate first, because
	## a position that is mate is mate even on the hundredth move without a
	## capture. The fifty-move and repetition draws come after.
	if legal_moves().is_empty():
		return CHECKMATE if in_check() else STALEMATE
	if is_insufficient_material():
		return DRAW_MATERIAL
	if halfmove >= 100:
		return DRAW_FIFTY
	if is_threefold():
		return DRAW_REPETITION
	return ONGOING


func is_over() -> bool:
	return status() != ONGOING


static func status_is_draw(s: int) -> bool:
	return s == STALEMATE or s == DRAW_FIFTY or s == DRAW_REPETITION or s == DRAW_MATERIAL


func result_string() -> String:
	## PGN's Result tag. The side to move is the side that has been mated, so
	## a white checkmate reads 0-1.
	var s: int = status()
	if s == CHECKMATE:
		return "0-1" if side == WHITE else "1-0"
	if status_is_draw(s):
		return "1/2-1/2"
	return "*"


# ------------------------------------------------------------------- SAN

func san(m: int) -> String:
	## Standard Algebraic Notation for a move IN THIS POSITION. Must be called
	## before the move is made — disambiguation depends on what else could
	## have gone to the same square.
	var from: int = move_from(m)
	var to: int = move_to(m)
	var flag: int = move_flag(m)
	if flag == FLAG_CASTLE:
		return _with_check_suffix(m, "O-O" if file_of(to) == 6 else "O-O-O")

	var piece: int = board[from]
	var type: int = absi(piece)
	var is_capture: bool = board[to] != 0 or flag == FLAG_EP
	var text: String = ""

	if type == PAWN:
		# A pawn capture always names its file, even when nothing is ambiguous.
		if is_capture:
			text = String.chr(97 + file_of(from)) + "x"
		text += square_name(to)
		var promo: int = move_promo(m)
		if promo != 0:
			text += "=" + PIECE_LETTER[promo]
	else:
		text = PIECE_LETTER[type] + _disambiguate(m, type, from, to)
		if is_capture:
			text += "x"
		text += square_name(to)
	return _with_check_suffix(m, text)


func _disambiguate(m: int, type: int, from: int, to: int) -> String:
	## File if that alone separates them, else rank, else both. Note this walks
	## LEGAL moves, not pseudo-legal ones: a second knight that is pinned and
	## cannot reach the square creates no ambiguity and must not add a letter.
	var rivals: Array[int] = []
	for other in legal_moves():
		if other == m:
			continue
		var of: int = move_from(other)
		if move_to(other) == to and absi(board[of]) == type and of != from:
			rivals.append(of)
	if rivals.is_empty():
		return ""
	var same_file: bool = false
	var same_rank: bool = false
	for r: int in rivals:
		if file_of(r) == file_of(from):
			same_file = true
		if rank_of(r) == rank_of(from):
			same_rank = true
	if not same_file:
		return String.chr(97 + file_of(from))
	if not same_rank:
		return str(rank_of(from) + 1)
	return square_name(from)


func _with_check_suffix(m: int, text: String) -> String:
	_make(m)
	var suffix: String = ""
	if is_attacked(king_sq[0 if side == WHITE else 1], -side):
		suffix = "#" if _no_legal_moves() else "+"
	_unmake()
	return text + suffix


func _no_legal_moves() -> bool:
	for m in pseudo_moves():
		_make(m)
		var ok: bool = not is_attacked(king_sq[0 if -side == WHITE else 1], side)
		_unmake()
		if ok:
			return false
	return true


func move_from_san(text: String) -> int:
	## Resolves SAN against the current position by generating every legal move
	## and comparing its own SAN. Slower than parsing, and immune to every
	## parsing bug — which is the right trade for something used by tests and
	## by opening data, not in the search.
	var want: String = text.strip_edges().replace("!", "").replace("?", "")
	for m in legal_moves():
		var s: String = san(m)
		if s == want or s.rstrip("+#") == want.rstrip("+#"):
			return m
	return 0


# ------------------------------------------------------------------- perft

func perft(depth: int) -> int:
	## Node count to `depth`, the standard correctness test for a move
	## generator: any error in castling, en passant, promotion or legality
	## shows up as a wrong total against published values.
	if depth == 0:
		return 1
	var n: int = 0
	for m in pseudo_moves():
		_make(m)
		if not is_attacked(king_sq[0 if -side == WHITE else 1], side):
			n += 1 if depth == 1 else perft(depth - 1)
		_unmake()
	return n
