class_name ChessSearch
extends RefCounted

## Evaluation and search. Pure RefCounted — no Node, no threads, no timers, so
## the whole thing is testable headless and can be driven from a worker thread
## by whoever owns it (see src/opponent.gd).
##
## Negamax with alpha-beta, a quiescence search over captures and promotions,
## MVV-LVA plus killers and history for ordering, and iterative deepening under
## a wall-clock budget. That combination is what makes GDScript viable here:
## measured on the dev box the raw generator runs ~190k nodes/sec, and ordering
## is worth more than an order of magnitude of that.

const B := preload("res://src/board.gd")

const MATE: int = 30000
const INF: int = 1 << 20
## Nodes between clock checks. Reading the clock is not free and the search
## calls it nowhere else; 2048 is about a millisecond of work at our node rate.
const CLOCK_MASK: int = 2047
## Hard ceiling on search depth. Bounds the check extension and sizes the
## killer table.
const MAX_PLY: int = 48

const PIECE_VALUE: Array[int] = [0, 100, 320, 330, 500, 900, 0]

## Piece-square tables, in centipawns, from WHITE's point of view with a1 = 0.
## Black reads them mirrored by rank. These are the classic "simplified
## evaluation" tables — not tuned, and not worth tuning for an opponent whose
## job is to lose gracefully to a child.
const PST_PAWN: Array[int] = [
	0, 0, 0, 0, 0, 0, 0, 0,
	5, 10, 10, -20, -20, 10, 10, 5,
	5, -5, -10, 0, 0, -10, -5, 5,
	0, 0, 0, 20, 20, 0, 0, 0,
	5, 5, 10, 25, 25, 10, 5, 5,
	10, 10, 20, 30, 30, 20, 10, 10,
	50, 50, 50, 50, 50, 50, 50, 50,
	0, 0, 0, 0, 0, 0, 0, 0,
]
const PST_KNIGHT: Array[int] = [
	-50, -40, -30, -30, -30, -30, -40, -50,
	-40, -20, 0, 5, 5, 0, -20, -40,
	-30, 5, 10, 15, 15, 10, 5, -30,
	-30, 0, 15, 20, 20, 15, 0, -30,
	-30, 5, 15, 20, 20, 15, 5, -30,
	-30, 0, 10, 15, 15, 10, 0, -30,
	-40, -20, 0, 0, 0, 0, -20, -40,
	-50, -40, -30, -30, -30, -30, -40, -50,
]
const PST_BISHOP: Array[int] = [
	-20, -10, -10, -10, -10, -10, -10, -20,
	-10, 5, 0, 0, 0, 0, 5, -10,
	-10, 10, 10, 10, 10, 10, 10, -10,
	-10, 0, 10, 10, 10, 10, 0, -10,
	-10, 5, 5, 10, 10, 5, 5, -10,
	-10, 0, 5, 10, 10, 5, 0, -10,
	-10, 0, 0, 0, 0, 0, 0, -10,
	-20, -10, -10, -10, -10, -10, -10, -20,
]
const PST_ROOK: Array[int] = [
	0, 0, 0, 5, 5, 0, 0, 0,
	-5, 0, 0, 0, 0, 0, 0, -5,
	-5, 0, 0, 0, 0, 0, 0, -5,
	-5, 0, 0, 0, 0, 0, 0, -5,
	-5, 0, 0, 0, 0, 0, 0, -5,
	-5, 0, 0, 0, 0, 0, 0, -5,
	5, 10, 10, 10, 10, 10, 10, 5,
	0, 0, 0, 0, 0, 0, 0, 0,
]
const PST_QUEEN: Array[int] = [
	-20, -10, -10, -5, -5, -10, -10, -20,
	-10, 0, 5, 0, 0, 0, 0, -10,
	-10, 5, 5, 5, 5, 5, 0, -10,
	0, 0, 5, 5, 5, 5, 0, -5,
	-5, 0, 5, 5, 5, 5, 0, -5,
	-10, 0, 5, 5, 5, 5, 0, -10,
	-10, 0, 0, 0, 0, 0, 0, -10,
	-20, -10, -10, -5, -5, -10, -10, -20,
]
## Two king tables. In the middlegame the king wants a corner behind pawns; in
## the endgame it wants the middle, and a king that stays cowering in the
## corner cannot escort a pawn or help mate. Switching between them on material
## is the cheapest thing that stops the engine drawing won king-and-pawn
## endings, which is the ending a child actually reaches.
const PST_KING_MID: Array[int] = [
	20, 30, 10, 0, 0, 10, 30, 20,
	20, 20, 0, 0, 0, 0, 20, 20,
	-10, -20, -20, -20, -20, -20, -20, -10,
	-20, -30, -30, -40, -40, -30, -30, -20,
	-30, -40, -40, -50, -50, -40, -40, -30,
	-30, -40, -40, -50, -50, -40, -40, -30,
	-30, -40, -40, -50, -50, -40, -40, -30,
	-30, -40, -40, -50, -50, -40, -40, -30,
]
const PST_KING_END: Array[int] = [
	-50, -30, -30, -30, -30, -30, -30, -50,
	-30, -30, 0, 0, 0, 0, -30, -30,
	-30, -10, 20, 30, 30, 20, -10, -30,
	-30, -10, 30, 40, 40, 30, -10, -30,
	-30, -10, 30, 40, 40, 30, -10, -30,
	-30, -10, 20, 30, 30, 20, -10, -30,
	-30, -20, -10, 0, 0, -10, -20, -30,
	-50, -40, -30, -20, -20, -30, -40, -50,
]

## Below this much non-pawn material for BOTH sides together, the king tables
## swap to the endgame set. A queen plus a rook a side is roughly the point at
## which kings stop being targets and start being pieces.
const ENDGAME_MATERIAL: int = 2 * (PIECE_VALUE[5] + PIECE_VALUE[4])

var nodes: int = 0
var depth_reached: int = 0
var score_cp: int = 0
var pv_move: int = 0

var _board: ChessBoard = null
var _deadline_ms: int = 0
var _aborted: bool = false
## Killers are two quiet moves per ply that caused a cutoff at the same depth
## elsewhere in the tree. History is a from/to table of how often a quiet move
## cut off anywhere. Both are cheap, and together they do most of the ordering
## work that a transposition table would otherwise be needed for.
var _killers: Array = []
var _history: PackedInt32Array = PackedInt32Array()


# ------------------------------------------------------------------ evaluate

## Material and piece-square values FUSED into one lookup per piece, built
## once. The naive form — a value table, a table-per-type, and a `match` to
## choose between them — cost a function call and two array reads for every
## piece on every leaf, and the quiescence search evaluates almost every node
## it visits. Folding them collapses that to one indexed read.
static var _val_mid: PackedInt32Array = PackedInt32Array()
static var _val_end: PackedInt32Array = PackedInt32Array()


static func _build_tables() -> void:
	if not _val_mid.is_empty():
		return
	var mid: Array = [[], PST_PAWN, PST_KNIGHT, PST_BISHOP, PST_ROOK, PST_QUEEN, PST_KING_MID]
	var end: Array = [[], PST_PAWN, PST_KNIGHT, PST_BISHOP, PST_ROOK, PST_QUEEN, PST_KING_END]
	_val_mid.resize(7 * 64)
	_val_end.resize(7 * 64)
	for type in range(1, 7):
		for i in 64:
			_val_mid[type * 64 + i] = PIECE_VALUE[type] + int(mid[type][i])
			_val_end[type * 64 + i] = PIECE_VALUE[type] + int(end[type][i])


static func evaluate(b: ChessBoard) -> int:
	## Score in centipawns from the SIDE TO MOVE's point of view, which is what
	## negamax requires. Material plus piece-square tables plus a bishop pair
	## bonus; deliberately no pawn structure or mobility term, because every
	## term costs node rate and node rate is the scarce resource in GDScript.
	##
	## One pass over the 64 real squares, not 128 with an off-board test and
	## not two passes. The endgame decision needs a total the pass has not
	## finished computing, so the two kings are held back and added afterwards
	## — the only pieces whose table depends on it.
	_build_tables()
	var score: int = 0
	var non_pawn: int = 0
	var bishops_w: int = 0
	var bishops_b: int = 0
	var kw: int = -1
	var kb: int = -1
	var board: PackedInt32Array = b.board
	for rank in 8:
		var base: int = rank * 16
		for file in 8:
			var p: int = board[base + file]
			if p == 0:
				continue
			if p > 0:
				if p == 6:
					kw = rank * 8 + file
					continue
				if p != 1:
					non_pawn += PIECE_VALUE[p]
				if p == 3:
					bishops_w += 1
				score += _val_mid[p * 64 + rank * 8 + file]
			else:
				var t: int = -p
				if t == 6:
					kb = (7 - rank) * 8 + file
					continue
				if t != 1:
					non_pawn += PIECE_VALUE[t]
				if t == 3:
					bishops_b += 1
				score -= _val_mid[t * 64 + (7 - rank) * 8 + file]

	var table: PackedInt32Array = _val_end if non_pawn <= ENDGAME_MATERIAL else _val_mid
	if kw >= 0:
		score += table[6 * 64 + kw]
	if kb >= 0:
		score -= table[6 * 64 + kb]
	if bishops_w >= 2:
		score += 30
	if bishops_b >= 2:
		score -= 30
	return score if b.side == 1 else -score


# -------------------------------------------------------------------- search

func search(b: ChessBoard, max_depth: int, budget_ms: int,
		avoid_keys: Dictionary = {}) -> Dictionary:
	## Iterative deepening. Returns {move, score, depth, nodes, scored}, where
	## `scored` is every root move with its value — the level system picks from
	## that rather than always taking the best, which is how a weak setting
	## stays weak without the search itself being crippled.
	_board = b
	nodes = 0
	_aborted = false
	_deadline_ms = Time.get_ticks_msec() + maxi(budget_ms, 1)
	_killers = []
	for i in MAX_PLY + 16:
		_killers.append([0, 0])
	_history = PackedInt32Array()
	_history.resize(128 * 128)

	var roots: PackedInt32Array = b.legal_moves()
	if roots.is_empty():
		return {"move": 0, "score": 0, "depth": 0, "nodes": 0, "scored": []}

	var best: int = roots[0]
	var best_score: int = 0
	var scored: Array = []
	depth_reached = 0

	for depth in range(1, maxi(max_depth, 1) + 1):
		var this_scored: Array = []
		var alpha: int = -INF
		var local_best: int = roots[0]
		var ordered: PackedInt32Array = _order_root(roots, best)
		for m in ordered:
			b._make(m)
			var v: int = -_negamax(depth - 1, -INF, -alpha, 1)
			b._unmake()
			if _aborted:
				break
			# A move that hands the opponent a third occurrence is worth
			# exactly a draw, whatever the search thinks of the position.
			if int(avoid_keys.get(_key_after(m), 0)) >= 2:
				v = 0
			this_scored.append([m, v])
			if v > alpha:
				alpha = v
				local_best = m
		if _aborted and this_scored.size() < 2:
			break
		best = local_best
		best_score = alpha
		scored = this_scored
		depth_reached = depth
		if _aborted:
			break
		# A forced mate is found; deeper search cannot improve on it.
		if absi(alpha) > MATE - 100:
			break

	score_cp = best_score
	pv_move = best
	return {
		"move": best, "score": best_score, "depth": depth_reached,
		"nodes": nodes, "scored": scored,
	}


func _key_after(m: int) -> String:
	_board._make(m)
	var k: String = _board.position_key()
	_board._unmake()
	return k


func _order_root(roots: PackedInt32Array, first: int) -> PackedInt32Array:
	## Search the previous iteration's best move first. That is most of what
	## iterative deepening is FOR — the shallow search is not thrown away, it
	## becomes the move ordering that makes the deep one cheap.
	if first == 0:
		return roots
	var out: PackedInt32Array = PackedInt32Array([first])
	for m in roots:
		if m != first:
			out.append(m)
	return out


func _negamax(depth: int, alpha: int, beta: int, ply: int) -> int:
	nodes += 1
	if (nodes & CLOCK_MASK) == 0 and Time.get_ticks_msec() >= _deadline_ms:
		_aborted = true
	if _aborted:
		return 0

	var b: ChessBoard = _board
	if b.halfmove >= 100:
		return 0

	var check: bool = b.in_check()
	if check and ply < MAX_PLY:
		# Never stop the search in check: the position is too volatile to
		# evaluate and a check extension costs almost nothing. The ply bound is
		# not decoration — without it a perpetual check extends the search
		# forever and only the deadline ever ends it.
		depth += 1
	if depth <= 0:
		return _quiesce(alpha, beta, ply)

	var moves: PackedInt32Array = b.pseudo_moves()
	var scores: PackedInt32Array = _score_moves(moves, ply)
	var legal: int = 0
	var a: int = alpha

	for i in range(moves.size()):
		var m: int = _pick(moves, scores, i)
		b._make(m)
		if b.is_attacked(b.king_sq[0 if -b.side == 1 else 1], b.side):
			b._unmake()
			continue
		legal += 1
		var v: int = -_negamax(depth - 1, -beta, -a, ply + 1)
		b._unmake()
		if _aborted:
			return 0
		if v >= beta:
			_remember_cutoff(m, ply, depth)
			return beta
		if v > a:
			a = v

	if legal == 0:
		# Mate scores are offset by ply so a mate in three is preferred to a
		# mate in five, and so the engine actually delivers it rather than
		# shuffling between two equally "winning" lines forever.
		return -MATE + ply if check else 0
	return a


func _quiesce(alpha: int, beta: int, ply: int) -> int:
	## Captures and promotions only, until the position is quiet. Without this
	## the search happily "wins" a queen on the last ply and never sees it
	## recaptured — the single biggest source of nonsense in a shallow engine.
	nodes += 1
	if (nodes & CLOCK_MASK) == 0 and Time.get_ticks_msec() >= _deadline_ms:
		_aborted = true
	if _aborted:
		return 0

	var b: ChessBoard = _board
	var stand: int = evaluate(b)
	if stand >= beta:
		return beta
	var a: int = maxi(alpha, stand)

	var moves: PackedInt32Array = b.pseudo_moves(true)
	var scores: PackedInt32Array = _score_moves(moves, ply)
	for i in range(moves.size()):
		var m: int = _pick(moves, scores, i)
		b._make(m)
		if b.is_attacked(b.king_sq[0 if -b.side == 1 else 1], b.side):
			b._unmake()
			continue
		var v: int = -_quiesce(-beta, -a, ply + 1)
		b._unmake()
		if _aborted:
			return 0
		if v >= beta:
			return beta
		if v > a:
			a = v
	return a


func _score_moves(moves: PackedInt32Array, ply: int) -> PackedInt32Array:
	var b: ChessBoard = _board
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(moves.size())
	var k: Array = _killers[ply] if ply < _killers.size() else [0, 0]
	for i in range(moves.size()):
		var m: int = moves[i]
		var to: int = (m >> 8) & 0xFF
		var from: int = m & 0xFF
		var victim: int = absi(b.board[to])
		var s: int = 0
		if victim != 0:
			# MVV-LVA: take the most valuable victim with the least valuable
			# attacker. Ordering captures this way is worth more than any
			# other single ordering rule.
			s = 1000000 + PIECE_VALUE[victim] * 16 - PIECE_VALUE[absi(b.board[from])]
		elif ((m >> 24) & 0xFF) == 1:
			s = 1000000 + PIECE_VALUE[1] * 16
		if ((m >> 16) & 0xFF) != 0:
			s += 900000
		if s == 0:
			if m == k[0]:
				s = 800000
			elif m == k[1]:
				s = 790000
			else:
				s = _history[from * 128 + to]
		out[i] = s
	return out


func _pick(moves: PackedInt32Array, scores: PackedInt32Array, from_index: int) -> int:
	## Selection sort, one move at a time. A full sort would order moves that a
	## beta cutoff means we never look at; this pays only for what it uses, and
	## allocates nothing.
	var best: int = from_index
	for j in range(from_index + 1, moves.size()):
		if scores[j] > scores[best]:
			best = j
	if best != from_index:
		var tm: int = moves[from_index]
		moves[from_index] = moves[best]
		moves[best] = tm
		var ts: int = scores[from_index]
		scores[from_index] = scores[best]
		scores[best] = ts
	return moves[from_index]


func _remember_cutoff(m: int, ply: int, depth: int) -> void:
	var b: ChessBoard = _board
	var to: int = (m >> 8) & 0xFF
	if b.board[to] != 0:
		return    # captures are already ordered first; do not dilute the tables
	if ply < _killers.size():
		var k: Array = _killers[ply]
		if k[0] != m:
			k[1] = k[0]
			k[0] = m
	var idx: int = (m & 0xFF) * 128 + to
	_history[idx] = mini(_history[idx] + depth * depth, 700000)
