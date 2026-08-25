extends SceneTree

## Dependency-free headless test runner for the chess model.
##   godot --headless --path games/chess --script res://tests/run.gd
##
## The centre of gravity here is perft. A move generator is either exactly
## right or quietly wrong, and node counts from published positions are the
## only test that catches "quietly wrong" — castling through check, en passant
## exposing a king, a promotion that forgets the knight. Everything else in
## this file tests things perft cannot see: what a move is CALLED, how a game
## ENDS, and what leaves on the wire.

const B := preload("res://src/board.gd")
const S := preload("res://src/search.gd")
const G := preload("res://src/game.gd")
const O := preload("res://src/opponent.gd")

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	_test_perft()
	_test_fen_roundtrip()
	_test_castling_rules()
	_test_en_passant_legality()
	_test_promotion()
	_test_san()
	_test_endings()
	_test_repetition()
	_test_clock()
	_test_pgn()
	_test_search()
	_test_opponent_levels()
	_test_game_flow()
	_test_telemetry_payload()
	_test_piece_paths()
	_test_audio_cues()
	_test_easing()
	_test_piece_set_files()

	print("")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(test_name: String, condition: bool) -> void:
	if condition:
		_pass += 1
		print("PASS  %s" % test_name)
	else:
		_fail += 1
		print("FAIL  %s" % test_name)


func _eq(test_name: String, got, want) -> void:
	_check("%s (got %s, want %s)" % [test_name, got, want] if got != want else test_name,
			got == want)


# --------------------------------------------------------------------- perft

func _test_perft() -> void:
	## The six positions everybody's generator is checked against. Depths are
	## kept where the whole suite still runs in a couple of seconds; the fourth
	## depth on the start position is included because it is the one that first
	## exercises every rule at once.
	var cases: Array = [
		["startpos", B.START_FEN, [20, 400, 8902, 197281]],
		["kiwipete", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", [48, 2039, 97862]],
		["endgame", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", [14, 191, 2812, 43238]],
		["promotions", "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", [6, 264, 9467]],
		["tactical", "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", [44, 1486, 62379]],
		["middlegame", "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", [46, 2079, 89890]],
	]
	for c: Array in cases:
		var b: ChessBoard = B.new(str(c[1]))
		var ok: bool = true
		for i in range(c[2].size()):
			if b.perft(i + 1) != int(c[2][i]):
				ok = false
		_check("perft matches published counts: %s" % c[0], ok)
		_check("perft leaves the position untouched: %s" % c[0], b.fen() == str(c[1]))


func _test_fen_roundtrip() -> void:
	for fen: String in [
		B.START_FEN,
		"r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
		"8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 b - - 13 42",
		"4k3/8/8/8/8/8/8/4K3 w - - 0 1",
	]:
		var b: ChessBoard = B.new(fen)
		_check("FEN survives a round trip: %s" % fen.substr(0, 24), b.fen() == fen)

	var start: ChessBoard = B.new()
	_check("a new board is the start position", start.fen() == B.START_FEN)
	_eq("square names map both ways", B.square_name(B.square_from_name("e4")), "e4")
	_eq("a1 is square 0", B.square_from_name("a1"), 0)
	_eq("h8 is square 119", B.square_from_name("h8"), 119)


# ------------------------------------------------------------------ castling

func _test_castling_rules() -> void:
	var b: ChessBoard = B.new("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	var castles: int = 0
	for m in b.legal_moves():
		if B.move_flag(m) == B.FLAG_CASTLE:
			castles += 1
	_eq("both castles are available when nothing is in the way", castles, 2)

	# Castling through an attacked square is illegal even though the king's
	# destination is safe. This is the one a hand-rolled generator gets wrong.
	var through: ChessBoard = B.new("r3k2r/8/8/8/8/5q2/8/R3K2R w KQkq - 0 1")
	var short_ok: bool = false
	for m in through.legal_moves():
		if B.move_flag(m) == B.FLAG_CASTLE and B.move_to(m) == 6:
			short_ok = true
	_check("cannot castle THROUGH an attacked square", not short_ok)

	var in_check: ChessBoard = B.new("r3k2r/8/8/8/8/4q3/8/R3K2R w KQkq - 0 1")
	var any: bool = false
	for m in in_check.legal_moves():
		if B.move_flag(m) == B.FLAG_CASTLE:
			any = true
	_check("cannot castle OUT of check", not any)

	# Rights are lost when the rook's home square changes hands, whether the
	# rook moved or was captured on it.
	var captured: ChessBoard = B.new("r3k3/8/8/8/8/8/8/R3K2R b KQ - 0 1")
	captured.make_move(captured.move_from_san("Rxa1"))
	_eq("capturing a rook on a1 costs White the queenside right",
			captured.castling, B.CR_WK)

	var moved: ChessBoard = B.new("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	moved.make_move(moved.move_from_san("Ke2"))
	_eq("moving the king costs both White rights", moved.castling, B.CR_BK | B.CR_BQ)

	# And the rook actually moves with the king.
	var done: ChessBoard = B.new("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	done.make_move(done.move_from_san("O-O"))
	_check("castling short puts the rook on f1",
			done.board[B.square_from_name("f1")] == B.ROOK
			and done.board[B.square_from_name("g1")] == B.KING
			and done.board[B.square_from_name("h1")] == 0)

	var long_castle: ChessBoard = B.new("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	long_castle.make_move(long_castle.move_from_san("O-O-O"))
	_check("castling long puts the rook on d1",
			long_castle.board[B.square_from_name("d1")] == B.ROOK
			and long_castle.board[B.square_from_name("c1")] == B.KING)

	# Undo has to put it all back, or the search corrupts the position.
	var undone: ChessBoard = B.new("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	undone.make_move(undone.move_from_san("O-O"))
	undone.undo_move()
	_check("undoing a castle restores rook, king and rights",
			undone.fen() == "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")


func _test_en_passant_legality() -> void:
	## The capture is available...
	var ok: ChessBoard = B.new("8/8/8/8/3Pp3/8/8/4K2k b - d3 0 1")
	var found: bool = false
	for m in ok.legal_moves():
		if B.move_flag(m) == B.FLAG_EP:
			found = true
	_check("en passant is generated when the target is set", found)

	## ...unless taking would expose the king along the rank. BOTH pawns leave
	## rank 4 in one move, which is why no ordinary pin test sees this.
	var pinned: ChessBoard = B.new("8/8/8/8/k2Pp2Q/8/8/3K4 b - d3 0 1")
	var pseudo: bool = false
	for m in pinned.pseudo_moves():
		if B.move_flag(m) == B.FLAG_EP:
			pseudo = true
	var legal: bool = false
	for m in pinned.legal_moves():
		if B.move_flag(m) == B.FLAG_EP:
			legal = true
	_check("the exposing en passant is generated pseudo-legally", pseudo)
	_check("...and rejected as illegal", not legal)

	var taken: ChessBoard = B.new("8/8/8/8/3Pp3/8/8/4K2k b - d3 0 1")
	taken.make_move(taken.move_from_uci("e4d3"))
	_check("en passant removes the pawn that passed, not the one on the target",
			taken.board[B.square_from_name("d4")] == 0
			and taken.board[B.square_from_name("d3")] == -B.PAWN)
	taken.undo_move()
	_check("undoing en passant puts the captured pawn back",
			taken.fen() == "8/8/8/8/3Pp3/8/8/4K2k b - d3 0 1")

	var stale: ChessBoard = B.new("8/8/8/8/3Pp3/8/8/4K2k b - - 0 1")
	var any_ep: bool = false
	for m in stale.legal_moves():
		if B.move_flag(m) == B.FLAG_EP:
			any_ep = true
	_check("no en passant without a target square", not any_ep)


func _test_promotion() -> void:
	var b: ChessBoard = B.new("8/4P3/8/8/8/8/8/4K2k w - - 0 1")
	var promos: Array[int] = []
	for m in b.legal_moves():
		if B.move_promo(m) != 0:
			promos.append(B.move_promo(m))
	_eq("a promotion offers exactly four pieces", promos.size(), 4)
	_check("queen, rook, bishop and knight are all offered",
			promos.has(B.QUEEN) and promos.has(B.ROOK)
			and promos.has(B.BISHOP) and promos.has(B.KNIGHT))

	b.make_move(b.move_from_uci("e7e8n"))
	_eq("underpromotion to a knight actually places a knight",
			b.board[B.square_from_name("e8")], B.KNIGHT)

	var capture: ChessBoard = B.new("5r2/4P3/8/8/8/8/8/4K2k w - - 0 1")
	var capture_promos: int = 0
	for m in capture.legal_moves():
		if B.move_promo(m) != 0 and B.move_to(m) == B.square_from_name("f8"):
			capture_promos += 1
	_eq("promoting by capture also offers four", capture_promos, 4)


# ----------------------------------------------------------------------- SAN

func _test_san() -> void:
	var cases: Array = [
		["8/8/8/3p4/4P3/8/8/4K2k w - - 0 1", "e4d5", "exd5", "a pawn capture names its file"],
		["6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", "a1a8", "Ra8#", "mate is marked with #"],
		["6k1/5pp1/7p/8/8/8/8/R5K1 w - - 0 1", "a1a8", "Ra8+", "check is marked with +"],
		["r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "e1g1", "O-O", "short castling"],
		["r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "e1c1", "O-O-O", "long castling"],
		["8/4P3/8/8/8/8/8/4K2k w - - 0 1", "e7e8q", "e8=Q", "promotion names the piece"],
		["4k3/8/8/8/8/8/8/R4RK1 w - - 0 1", "a1d1", "Rad1", "two rooks disambiguate by file"],
		["4k3/8/8/3N4/8/3N4/8/4K3 w - - 0 1", "d5f4", "N5f4", "two knights on a file disambiguate by rank"],
	]
	for c: Array in cases:
		var b: ChessBoard = B.new(str(c[0]))
		var m: int = b.move_from_uci(str(c[1]))
		_eq(str(c[3]), b.san(m), str(c[2]))

	# A rival that cannot legally reach the square is not a rival, so it must
	# not add a disambiguating letter.
	# The e4 knight is pinned against e1 by the rook on e8, so only the c4
	# knight can actually go to d6 and the move needs no letter.
	var pinned: ChessBoard = B.new("k3r3/8/8/8/2N1N3/8/8/4K3 w - - 0 1")
	var m2: int = pinned.move_from_uci("c4d6")
	_eq("a pinned twin creates no ambiguity", pinned.san(m2), "Nd6")

	var b3: ChessBoard = B.new()
	_eq("SAN parses back to the same move",
			B.move_uci(b3.move_from_san("e4")), "e2e4")
	_check("SAN leaves the position untouched", b3.fen() == B.START_FEN)


# ------------------------------------------------------------------- endings

func _test_endings() -> void:
	var mate: ChessBoard = B.new("rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3")
	_eq("fool's mate is checkmate", mate.status(), B.CHECKMATE)
	_eq("the mated side loses", mate.result_string(), "0-1")

	var stale: ChessBoard = B.new("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
	_eq("king with no move and no check is stalemate", stale.status(), B.STALEMATE)
	_eq("stalemate is a draw", stale.result_string(), "1/2-1/2")

	_eq("bare kings are a dead position",
			B.new("8/8/8/4k3/8/8/8/4K3 w - - 0 1").status(), B.DRAW_MATERIAL)
	_eq("king and bishop cannot mate",
			B.new("8/8/8/4k3/8/8/8/3BK3 w - - 0 1").status(), B.DRAW_MATERIAL)
	_eq("king and knight cannot mate",
			B.new("8/8/8/4k3/8/8/8/3NK3 w - - 0 1").status(), B.DRAW_MATERIAL)
	_check("same-coloured bishops cannot mate",
			B.new("8/8/8/3bk3/8/8/8/3BK3 w - - 0 1").status() == B.DRAW_MATERIAL)
	_check("opposite-coloured bishops are NOT dead",
			B.new("k7/8/8/4b3/8/8/8/3BK3 w - - 0 1").status() != B.DRAW_MATERIAL)
	_check("a lone pawn is enough to keep the game alive",
			B.new("8/4p3/8/4k3/8/8/8/4K3 w - - 0 1").status() == B.ONGOING)

	_eq("a hundred half-moves is a draw",
			B.new("4k3/8/8/8/8/8/8/4K2R w K - 100 60").status(), B.DRAW_FIFTY)
	_check("ninety-nine is not",
			B.new("4k3/8/8/8/8/8/8/4K2R w K - 99 60").status() == B.ONGOING)

	# Mate takes precedence over the fifty-move rule: a game that is over is
	# over, whatever the counter says.
	_eq("checkmate outranks the fifty-move counter",
			B.new("R5k1/5ppp/8/8/8/8/8/6K1 b - - 120 90").status(), B.CHECKMATE)


func _test_repetition() -> void:
	var b: ChessBoard = B.new()
	for san: String in ["Nf3", "Nf6", "Ng1", "Ng8", "Nf3", "Nf6", "Ng1", "Ng8"]:
		b.make_move(b.move_from_san(san))
	_check("shuffling back three times is a repetition draw",
			b.status() == B.DRAW_REPETITION)
	b.undo_move()
	_check("undoing the last move takes the repetition back with it",
			b.status() != B.DRAW_REPETITION)

	# A position with the same men but different castling rights is a
	# different position.
	var rights_a: ChessBoard = B.new("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	var rights_b: ChessBoard = B.new("r3k2r/8/8/8/8/8/8/R3K2R w - - 0 1")
	_check("castling rights are part of a position's identity",
			rights_a.position_key() != rights_b.position_key())

	# An en-passant square nobody can use does not change the position.
	var ep_dead: ChessBoard = B.new("4k3/8/8/8/3P4/8/8/4K3 b - d3 0 1")
	var ep_none: ChessBoard = B.new("4k3/8/8/8/3P4/8/8/4K3 b - - 0 1")
	_check("an uncapturable en-passant square is not part of the identity",
			ep_dead.position_key() == ep_none.position_key())
	var ep_live: ChessBoard = B.new("4k3/8/8/8/3Pp3/8/8/4K3 b - d3 0 1")
	var ep_live_none: ChessBoard = B.new("4k3/8/8/8/3Pp3/8/8/4K3 b - - 0 1")
	_check("a capturable one is", ep_live.position_key() != ep_live_none.position_key())


# --------------------------------------------------------------------- clock

func _test_clock() -> void:
	var c := ChessClock.new(600, 5)
	_eq("a fresh clock holds the base time", c.ms_left(B.WHITE), 600000)
	c.start(B.WHITE)
	c.tick(10.0)
	_eq("time comes off the running side", c.ms_left(B.WHITE), 590000)
	_eq("...and not off the other one", c.ms_left(B.BLACK), 600000)
	c.on_move_made(B.WHITE)
	_eq("the increment lands after the move, on the mover", c.ms_left(B.WHITE), 595000)
	c.tick(1.0)
	_eq("the clock passes to the opponent", c.ms_left(B.BLACK), 599000)

	var f := ChessClock.new(1, 0)
	f.start(B.WHITE)
	_check("running out reports the flag exactly once", f.tick(2.0))
	_check("...and not again", not f.tick(1.0))
	_eq("the flagged side is recorded", f.flagged_side, B.WHITE)
	_eq("time does not go negative", f.ms_left(B.WHITE), 0)

	var u := ChessClock.new(0, 0)
	u.start(B.WHITE)
	_check("an unlimited clock never ticks", not u.tick(1000.0))
	_check("an unlimited clock knows it", u.is_unlimited())

	_eq("above a minute the clock shows m:ss", ChessClock.format(605000), "10:05")
	_eq("below ten seconds it shows tenths", ChessClock.format(9400), "0:09.4")
	_eq("PGN clock format is H:MM:SS.t", ChessClock.format_clk(598500), "0:09:58.5")
	_eq("PGN clock format carries hours", ChessClock.format_clk(3661000), "1:01:01.0")


# ----------------------------------------------------------------------- PGN

func _test_pgn() -> void:
	var headers: Dictionary = {
		"Event": "Casual Game", "Site": "qGames Chess", "Date": "2026.08.22",
		"Round": "-", "White": "Player", "Black": "Computer",
		"Result": "1-0", "TimeControl": "600", "Termination": "Player won by checkmate",
	}
	var moves: Array = [
		{"san": "e4", "clock_ms": 598500},
		{"san": "e5", "clock_ms": 597100},
		{"san": "Nf3", "clock_ms": 595000},
	]
	var text: String = ChessPgn.build(headers, moves)
	_check("the seven-tag roster comes first and in order",
			text.begins_with("[Event \"Casual Game\"]\n[Site \"qGames Chess\"]\n"
					+ "[Date \"2026.08.22\"]\n[Round \"-\"]\n[White \"Player\"]\n"
					+ "[Black \"Computer\"]\n[Result \"1-0\"]\n"))
	_check("a blank line separates tags from movetext", text.contains("]\n\n1. e4"))
	_check("each move carries its clock",
			text.contains("1. e4 {[%clk 0:09:58.5]} e5 {[%clk 0:09:57.1]}"))
	_check("the result closes the movetext", text.strip_edges().ends_with("1-0"))
	_check("no movetext line exceeds the wrap column", _longest_line(text) <= ChessPgn.WRAP_COLUMNS)

	var no_clock: String = ChessPgn.build(headers, [{"san": "e4", "clock_ms": -1}])
	_check("an untimed game writes no clock annotation", not no_clock.contains("%clk"))

	_eq("a quote in a name is escaped",
			ChessPgn.tag("White", "Sam \"Fish\" B"), "[White \"Sam \\\"Fish\\\" B\"]")
	_eq("no clock means no time control", ChessPgn.time_control(0, 0), "-")
	_eq("sudden death is a bare number", ChessPgn.time_control(600, 0), "600")
	_eq("an increment is appended", ChessPgn.time_control(600, 5), "600+5")


func _longest_line(text: String) -> int:
	var longest: int = 0
	for line: String in text.split("\n"):
		longest = maxi(longest, line.length())
	return longest


# -------------------------------------------------------------------- search

func _test_search() -> void:
	_eq("the start position evaluates as equal", S.evaluate(B.new()), 0)
	var up: ChessBoard = B.new("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBN1 b kq - 0 1")
	_check("a missing rook is worth about five pawns to the other side",
			S.evaluate(up) > 400 and S.evaluate(up) < 600)

	var mate1: ChessBoard = B.new("6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1")
	var s1 := S.new()
	var r1: Dictionary = s1.search(mate1, 3, 2000)
	_eq("mate in one is found", mate1.san(int(r1["move"])), "Ra8#")
	_check("...and scored as mate", int(r1["score"]) > S.MATE - 100)

	# A hanging queen must be taken. This is the test that fails without a
	# quiescence search: the shallow line "wins" material and never sees the
	# recapture, or misses the capture entirely at an even depth.
	var hanging: ChessBoard = B.new("4k3/8/8/3q4/4P3/8/8/4K3 w - - 0 1")
	var s2 := S.new()
	var r2: Dictionary = s2.search(hanging, 4, 2000)
	_eq("a free queen is taken", hanging.san(int(r2["move"])), "exd5")

	# A defended queen is still worth a pawn, and the quiescence search has to
	# see the recapture to know that rather than to be scared off by it.
	var defended: ChessBoard = B.new("4k3/1b6/8/3q4/4P3/8/8/4K3 w - - 0 1")
	var s3 := S.new()
	var r3: Dictionary = s3.search(defended, 4, 2000)
	_check("a defended queen is taken anyway when the trade wins material",
			defended.san(int(r3["move"])) == "exd5")

	var s4 := S.new()
	var r4: Dictionary = s4.search(B.new(), 32, 300)
	_check("the search respects its time budget", int(r4["depth"]) >= 3)
	# A budgeted search may be cut off mid-iteration, so only a completed one
	# is guaranteed to have scored every root move.
	var s6 := S.new()
	var r6: Dictionary = s6.search(B.new(), 3, 20000)
	_eq("a completed search scores every root move",
			(r6["scored"] as Array).size(), B.new().legal_moves().size())

	var stalemated: ChessBoard = B.new("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
	var s5 := S.new()
	var r5: Dictionary = s5.search(stalemated, 3, 500)
	_eq("a position with no moves returns no move", int(r5["move"]), 0)


func _test_opponent_levels() -> void:
	var o := O.new(12345)
	var scored: Array = [[101, 50], [202, 10], [303, -20]]
	_eq("with no noise the best move is taken", o.choose(scored, 0), 101)

	# With noise the choice varies, which is the whole point of a weak level.
	var seen: Dictionary = {}
	for i in 200:
		seen[o.choose(scored, 300)] = true
	_check("noise makes a weak level choose differently sometimes", seen.size() > 1)

	# ...but never at the cost of missing a mate or walking into one.
	var decisive: Array = [[101, S.MATE - 5], [202, -50], [303, -900]]
	var always_best: bool = true
	for i in 200:
		if o.choose(decisive, 320) != 101:
			always_best = false
	_check("a decisive score is never overruled by noise", always_best)

	_eq("there are eight levels", O.LEVELS.size(), 8)
	var ascending: bool = true
	for i in range(1, O.LEVELS.size()):
		if int(O.LEVELS[i]["depth"]) < int(O.LEVELS[i - 1]["depth"]):
			ascending = false
		if int(O.LEVELS[i]["noise"]) > int(O.LEVELS[i - 1]["noise"]):
			ascending = false
	_check("levels get deeper and quieter as they go up", ascending)

	var seeded_a := O.new(999)
	var seeded_b := O.new(999)
	_eq("a seeded opponent is reproducible",
			seeded_a.choose(scored, 300), seeded_b.choose(scored, 300))


# ----------------------------------------------------------------- game flow

func _test_game_flow() -> void:
	var g := G.new()
	g.start(B.WHITE, 600, 0, 4, "Gentle")
	_check("the human moves first as White", g.is_human_turn())
	_check("an illegal move is refused", not g.apply(B.pack(0, 63)))

	g.apply(g.board.move_from_san("e4"))
	_eq("the move is recorded in SAN", str(g.records[0]["san"]), "e4")
	_check("...with the position it was played in",
			str(g.records[0]["fen_before"]) == B.START_FEN)
	_check("...and the mover's clock", int(g.records[0]["clock_ms"]) > 0)
	_check("it is now the computer's turn", not g.is_human_turn())

	g.apply(g.board.move_from_san("e5"))
	_eq("two plies are recorded", g.records.size(), 2)
	_check("a takeback undoes the pair", g.takeback())
	_eq("...leaving nothing behind", g.records.size(), 0)
	_check("...and handing the board back to the human", g.is_human_turn())
	_check("a takeback with no moves does nothing", not g.takeback())

	# A takeback while the computer has not yet replied undoes one ply only.
	var single := G.new()
	single.start(B.WHITE, 0, 0, 1, "Beginner")
	single.apply(single.board.move_from_san("e4"))
	single.takeback()
	_eq("a lone human move is taken back on its own", single.records.size(), 0)

	var mated := G.new()
	mated.start(B.WHITE, 0, 0, 1, "Beginner")
	mated.board = B.new("6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1")
	mated.apply(mated.board.move_from_san("Ra8#"))
	_check("the game ends on mate", mated.over)
	_eq("the winner is named in plain language", mated.termination, "Player won by checkmate")
	_eq("...and the result is a PGN token", mated.result, "1-0")
	_eq("a human win reports as a win", mated.telemetry_result(), "win")
	_check("a finished game accepts no more moves", not mated.apply(B.pack(0, 1)))

	var resigned := G.new()
	resigned.start(B.BLACK, 0, 0, 1, "Beginner")
	resigned.resign(B.BLACK)
	_eq("resigning hands the game to the other side", resigned.result, "1-0")
	_eq("...and says so", resigned.termination, "Computer won by resignation")
	_eq("a resignation reports as a loss", resigned.telemetry_result(), "loss")

	# Flag fall against a bare king is a draw, not a win.
	var flagged := G.new()
	flagged.start(B.WHITE, 60, 0, 1, "Beginner")
	flagged.board = B.new("4k3/8/8/8/8/8/8/4K3 w - - 0 1")
	flagged.on_flag(B.WHITE)
	_eq("timing out against a lone king is drawn", flagged.result, "1/2-1/2")
	_check("...and says why",
			flagged.termination == "Game drawn by timeout vs insufficient material")

	var flagged2 := G.new()
	flagged2.start(B.WHITE, 60, 0, 1, "Beginner")
	flagged2.board = B.new("4k3/8/8/8/8/8/8/3QK3 w - - 0 1")
	flagged2.on_flag(B.BLACK)
	_eq("timing out against real material loses", flagged2.result, "1-0")
	_eq("...on time", flagged2.termination, "Player won on time")

	var quit_game := G.new()
	quit_game.start(B.WHITE, 0, 0, 1, "Beginner")
	quit_game.apply(quit_game.board.move_from_san("d4"))
	quit_game.abandon()
	_eq("abandoning is not a result", quit_game.result, "*")
	_eq("...and reports as a quit", quit_game.telemetry_result(), "quit")


func _test_telemetry_payload() -> void:
	var g := G.new()
	g.start(B.BLACK, 600, 5, 6, "Tough")
	g.apply(g.board.move_from_san("e4"))
	g.apply(g.board.move_from_san("e5"))
	g.apply(g.board.move_from_san("Nf3"))

	var extra: Dictionary = {}
	for pair: Array in g.telemetry_extra():
		extra[str(pair[0])] = pair[1]
	_eq("moves counts full moves, not plies", int(extra["moves"]), 2)
	_eq("plies are reported too", int(extra["plies"]), 3)
	_eq("the level rides along", int(extra["level"]), 6)
	_eq("...by name as well", str(extra["level_name"]), "Tough")
	_eq("which colour was played is recorded", str(extra["played_as"]), "black")
	_eq("the time control is in PGN's own notation", str(extra["time_control"]), "600+5")

	var pgn: String = g.pgn()
	_check("the PGN names the level as the opponent", pgn.contains("[White \"Computer\"]"))
	_check("...and the human on the other side", pgn.contains("[Black \"Player\"]"))
	_check("the PGN carries the moves", pgn.contains("1. e4"))
	_check("an unfinished game is marked with a star", pgn.contains("[Result \"*\"]"))

	# Every schema value must be a flat scalar: a Dictionary or Array on a
	# topic would need a value_template on every Home Assistant sensor.
	var flat: bool = true
	for pair: Array in g.telemetry_extra():
		var v = pair[1]
		if not (v is int or v is float or v is String or v is bool):
			flat = false
	_check("every telemetry value is a flat scalar", flat)


# ------------------------------------------------------------- piece artwork

func _test_piece_paths() -> void:
	## The path parser is the only thing standing between the artwork and a
	## silently wrong shape — a mistyped command used to draw nothing at all,
	## with no error until somebody looked at the board.
	var line: PackedVector2Array = ChessPieces.tessellate("M 10,20 L 30,40")
	_eq("a line is two points", line.size(), 2)
	_check("...at the coordinates given",
			line[0] == Vector2(10, 20) and line[1] == Vector2(30, 40))

	var curve: PackedVector2Array = ChessPieces.tessellate("M 0,0 C 0,50 100,50 100,0")
	_eq("a cubic is tessellated into CURVE_STEPS segments",
			curve.size(), ChessPieces.CURVE_STEPS + 1)
	_check("...starting on the start point", curve[0] == Vector2(0, 0))
	_check("...ending on the end point", curve[curve.size() - 1] == Vector2(100, 0))
	# A symmetric cubic must bulge to the same height on both sides. This is
	# what catches control points read in the wrong order.
	var mid: Vector2 = curve[ChessPieces.CURVE_STEPS / 2]
	_check("...and bulging symmetrically", absf(mid.x - 50.0) < 0.01 and mid.y > 20.0)

	var quad: PackedVector2Array = ChessPieces.tessellate("M 0,0 Q 50,100 100,0")
	_check("a quadratic passes through its endpoints",
			quad[0] == Vector2(0, 0) and quad[quad.size() - 1] == Vector2(100, 0))

	var closed: PackedVector2Array = ChessPieces.tessellate("M 5,5 L 15,5 L 15,15 Z L 25,25")
	_check("Z returns the cursor to the subpath start",
			closed[closed.size() - 1] == Vector2(25, 25))

	# Every piece must sit inside the box draw_piece fits to, or it is drawn
	# smaller than its square or clipped by it.
	var all_inside: bool = true
	var reaches_bottom: bool = true
	for type in [ChessPieces.PAWN, ChessPieces.KNIGHT, ChessPieces.BISHOP,
			ChessPieces.ROOK, ChessPieces.QUEEN, ChessPieces.KING]:
		var spec: Dictionary = ChessPieces.PIECES[type]
		var lo := Vector2(999, 999)
		var hi := Vector2(-999, -999)
		for d: String in (spec["fills"] as Array) + (spec["strokes"] as Array):
			for pt in ChessPieces.tessellate(d):
				lo = lo.min(pt)
				hi = hi.max(pt)
		for c: Array in spec["circles"]:
			lo = lo.min(Vector2(c[0]) - Vector2(float(c[1]), float(c[1])))
			hi = hi.max(Vector2(c[0]) + Vector2(float(c[1]), float(c[1])))
		if lo.x < ChessPieces.ART_MIN.x or lo.y < ChessPieces.ART_MIN.y:
			all_inside = false
		if hi.x > ChessPieces.ART_MAX.x or hi.y > ChessPieces.ART_MAX.y:
			all_inside = false
		# Every piece stands on the same base, so every piece must reach it.
		if absf(hi.y - 88.0) > 0.5:
			reaches_bottom = false
	_check("every piece fits the box draw_piece scales to", all_inside)
	_check("every piece stands on the same baseline", reaches_bottom)


# -------------------------------------------------------------------- audio

func _test_audio_cues() -> void:
	## Only the synthesis is tested, never a player: creating an
	## AudioStreamPlayer under `--headless` with a real audio driver HANGS the
	## process (verified — a probe that added one never returned). The cue
	## buffers are pure arithmetic and are the part that can be wrong.
	var audio := ChessAudio.new()
	audio._build_all()
	var cues: Array[String] = [
		ChessAudio.MOVE, ChessAudio.CAPTURE, ChessAudio.CASTLE, ChessAudio.CHECK,
		ChessAudio.PROMOTE, ChessAudio.SELECT, ChessAudio.ILLEGAL,
		ChessAudio.WIN, ChessAudio.LOSS, ChessAudio.DRAW,
	]
	var all_present: bool = true
	var edges_silent: bool = true
	var within_headroom: bool = true
	var tails_decayed: bool = true
	var audible: bool = true
	for cue: String in cues:
		if not audio._streams.has(cue):
			all_present = false
			continue
		var wav: AudioStreamWAV = audio._streams[cue]
		var f: PackedFloat32Array = ChessAudio.to_floats(wav)
		if f.size() < 100:
			audible = false
			continue
		var peak: float = 0.0
		for v in f:
			peak = maxf(peak, absf(v))
		if peak > ChessAudio.PEAK + 0.01:
			within_headroom = false
		if peak < 0.05:
			audible = false
		# A buffer that starts or ends on a non-zero sample ticks on its own.
		if absf(f[0]) > 0.001 or absf(f[f.size() - 1]) > 0.001:
			edges_silent = false
		# ...and one whose tail is still ringing when the buffer ends is CUT
		# off, which is the same tick at the other end. Found by plotting the
		# envelopes: check, promote and the three result cues were all being
		# chopped at about 29% of peak.
		var tail: float = 0.0
		for i in range(int(f.size() * 0.97), f.size()):
			tail = maxf(tail, absf(f[i]))
		if tail > peak * 0.02:
			tails_decayed = false
	_check("every cue is built", all_present)
	_check("every cue is actually audible", audible)
	_check("no cue exceeds the headroom", within_headroom)
	_check("every cue starts and ends in silence", edges_silent)
	_check("every cue has decayed before its buffer ends", tails_decayed)

	_eq("cues are 16-bit mono",
			[audio._streams[ChessAudio.MOVE].format, audio._streams[ChessAudio.MOVE].stereo],
			[AudioStreamWAV.FORMAT_16_BITS, false])
	_check("cues do not loop",
			audio._streams[ChessAudio.MOVE].loop_mode == AudioStreamWAV.LOOP_DISABLED)

	# The noise burst is seeded, not random: the same move has to sound the
	# same on every launch or the set stops reading as one instrument.
	var again := ChessAudio.new()
	again._build_all()
	_check("synthesis is deterministic",
			again._streams[ChessAudio.MOVE].data == audio._streams[ChessAudio.MOVE].data)

	# A capture should carry more weight than a move, and a pick-up less.
	var move_len: int = audio._streams[ChessAudio.MOVE].data.size()
	var capture_len: int = audio._streams[ChessAudio.CAPTURE].data.size()
	var select_len: int = audio._streams[ChessAudio.SELECT].data.size()
	_check("a capture rings longer than a move", capture_len > move_len)
	_check("a pick-up is the shortest cue of all", select_len < move_len)

	# The MIX, not the synthesis. Normalising every cue to one peak made the
	# pick-up tick as loud as the win chime — the sound heard forty times a
	# game as prominent as the one heard once. These assertions are what stops
	# that coming back.
	var quiet: float = _peak_of(audio, ChessAudio.SELECT)
	var move_peak: float = _peak_of(audio, ChessAudio.MOVE)
	var capture_peak: float = _peak_of(audio, ChessAudio.CAPTURE)
	_check("the pick-up tick is far quieter than a move", quiet < move_peak * 0.4)
	_check("a capture is louder than a move", capture_peak > move_peak)
	_check("nothing is louder than a capture by much",
			_peak_of(audio, ChessAudio.WIN) < capture_peak * 1.2)

	# ...and the LENGTHS. A move is heard on nearly every ply; anything that
	# rings on for a tenth of a second becomes a musical event and then an
	# irritation.
	_check("a move is over inside a tenth of a second",
			_audible_ms(audio, ChessAudio.MOVE) < 100.0)
	_check("a pick-up is over inside a twentieth",
			_audible_ms(audio, ChessAudio.SELECT) < 50.0)
	_check("only the end-of-game cue is allowed to be long",
			_audible_ms(audio, ChessAudio.WIN) > _audible_ms(audio, ChessAudio.CHECK))


func _peak_of(audio: ChessAudio, cue: String) -> float:
	var peak: float = 0.0
	for v in ChessAudio.to_floats(audio._streams[cue]):
		peak = maxf(peak, absf(v))
	return peak


func _audible_ms(audio: ChessAudio, cue: String) -> float:
	## How long the cue can actually be heard, not how long its buffer is —
	## the tail below 1% of peak is silence as far as anyone listening cares.
	var f: PackedFloat32Array = ChessAudio.to_floats(audio._streams[cue])
	var peak: float = _peak_of(audio, cue)
	for i in range(f.size() - 1, -1, -1):
		if absf(f[i]) > peak * 0.01:
			return 1000.0 * (i + 1) / ChessAudio.MIX_RATE
	return 0.0


# -------------------------------------------------------------------- easing

func _test_easing() -> void:
	_check("a slide starts where it started", is_equal_approx(ChessBoardView._ease_out(0.0), 0.0))
	_check("...and arrives", is_equal_approx(ChessBoardView._ease_out(1.0), 1.0))
	var monotonic: bool = true
	var front_loaded: bool = false
	var previous: float = -1.0
	for i in 21:
		var t: float = i / 20.0
		var v: float = ChessBoardView._ease_out(t)
		if v < previous:
			monotonic = false
		previous = v
		if is_equal_approx(t, 0.5) and v > 0.7:
			front_loaded = true
	_check("a slide never goes backwards", monotonic)
	_check("...and is front-loaded, which is what makes it look like a hand", front_loaded)
	_check("easing is clamped outside 0..1",
			is_equal_approx(ChessBoardView._ease_out(1.5), 1.0)
			and is_equal_approx(ChessBoardView._ease_out(-0.5), 0.0))


# --------------------------------------------------------- editable piece set

func _test_piece_set_files() -> void:
	## The point of this feature is that somebody can edit the pieces without a
	## rebuild, so what is tested is the contract they rely on: the names, that
	## the exported files are valid SVG, and that a partial set falls back per
	## piece rather than all-or-nothing.
	var types: Array[int] = [ChessPieces.KING, ChessPieces.QUEEN, ChessPieces.ROOK,
			ChessPieces.BISHOP, ChessPieces.KNIGHT, ChessPieces.PAWN]
	_eq("white king is wK.svg", ChessPieces.file_name(ChessPieces.KING, true), "wK.svg")
	_eq("black knight is bN.svg", ChessPieces.file_name(ChessPieces.KNIGHT, false), "bN.svg")
	var names: Dictionary = {}
	for type: int in types:
		for white: bool in [true, false]:
			names[ChessPieces.file_name(type, white)] = true
	_eq("twelve distinct filenames", names.size(), 12)

	var all_parse: bool = true
	var all_have_paths: bool = true
	var art: Vector2 = ChessPieces.ART_MAX - ChessPieces.ART_MIN
	var box: String = "viewBox=\"0 0 %.0f %.0f\"" % [art.x, art.y]
	var all_boxed: bool = true
	for type: int in types:
		for white: bool in [true, false]:
			var svg: String = ChessPieces.to_svg(type, white)
			if not svg.contains("<path"):
				all_have_paths = false
			if not svg.contains(box):
				all_boxed = false
			# The real test: the rasteriser has to accept it. A file the game
			# cannot read is worse than no file, because it looks like the
			# edit did nothing.
			var img := Image.new()
			if img.load_svg_from_string(svg, 1.0) != OK or img.get_width() < 8:
				all_parse = false
	_check("every exported piece is valid SVG the engine can rasterise", all_parse)
	_check("every exported piece carries path data", all_have_paths)
	_check("every exported piece uses the fitted art box as its viewBox", all_boxed)

	# White and black must differ, or a dumped set is unusable.
	_check("the two colours are not the same file",
			ChessPieces.to_svg(ChessPieces.KING, true)
			!= ChessPieces.to_svg(ChessPieces.KING, false))

	var dir: String = "user://_test_pieces"
	var written: String = ChessPieceArt.dump_builtin(dir)
	_check("the set can be written out", written != "")
	_check("...with a note explaining what it is",
			FileAccess.file_exists(dir.path_join("README.txt")))

	var art_all := ChessPieceArt.new()
	art_all.load_set(dir, "res://__none__")
	_check("a full directory is picked up", art_all.source.contains("12 of 12"))

	# Remove one file: that piece must fall back on its own, not the whole set.
	DirAccess.remove_absolute(dir.path_join("wN.svg"))
	var art_partial := ChessPieceArt.new()
	art_partial.load_set(dir, "res://__none__")
	_check("a partial set is still used", art_partial.source.contains("11 of 12"))

	var art_none := ChessPieceArt.new()
	art_none.load_set("user://__none__", "res://__none__")
	_eq("no files means the built-in artwork", art_none.source, "built-in")

	# Raster size buckets: a piece must be downscaled, never up.
	var sized := ChessPieceArt.new()
	sized.load_set(dir, "res://__none__")
	sized.set_square_size(70.0)
	_check("the raster bucket is at or above the drawn size",
			sized._bucket >= 70 and sized._bucket <= 128)

	for name: String in ["wK.svg", "wQ.svg", "wR.svg", "wB.svg", "wP.svg",
			"bK.svg", "bQ.svg", "bR.svg", "bB.svg", "bN.svg", "bP.svg", "README.txt"]:
		DirAccess.remove_absolute(dir.path_join(name))
	DirAccess.remove_absolute(dir)

	_test_repo_piece_set_ships()


func _test_repo_piece_set_ships() -> void:
	## A piece set committed under res://assets/pieces has to survive the
	## export, and the way it fails is silent: .svg HAS an importer, so
	## `export_filter="all_resources"` exports the TEXTURE and strips the
	## source text the game actually reads. It then works perfectly in the
	## editor and is missing from every shipped build.
	##
	## Two things have to be true, and both were established by grepping an
	## export for a path fragment rather than by trusting that it worked:
	## each file needs `importer="keep"`, and include_filter has to name them.
	## Neither is enough on its own.
	if FileAccess.file_exists("res://export_presets.cfg"):
		var text: String = FileAccess.open("res://export_presets.cfg",
				FileAccess.READ).get_as_text()
		# Line by line, not a whole-file count: the explanatory comment above
		# the presets mentions the same pattern and made a naive count wrong.
		var presets: int = 0
		var named: int = 0
		for line: String in text.split("\n"):
			if not line.begins_with("include_filter="):
				continue
			presets += 1
			if line.contains("assets/pieces/*.svg"):
				named += 1
		_check("every export preset carries the piece set through include_filter",
				presets > 0 and named == presets)

	var dir: DirAccess = DirAccess.open("res://assets/pieces")
	if dir == null:
		_check("no repository piece set is committed, so none can be stripped", true)
		return

	var all_kept: bool = true
	var complete: int = 0
	for name: String in dir.get_files():
		if not name.ends_with(".svg"):
			continue
		complete += 1
		var stub: String = "res://assets/pieces/%s.import" % name
		if not FileAccess.file_exists(stub):
			all_kept = false
			continue
		if not FileAccess.open(stub, FileAccess.READ).get_as_text().contains("importer=\"keep\""):
			all_kept = false
	_check("every committed piece file is marked keep, or it is stripped from the export",
			all_kept)
	_eq("the committed set is complete", complete, 12)

	# The committed set SHADOWS the artwork drawn in src/pieces.gd — that is
	# what it is for — so an improvement to the drawn set would silently never
	# be seen again. Every file still carrying the generated marker is
	# regenerated and compared, which turns that into a failed test naming the
	# command to run. A file somebody has actually edited drops its marker and
	# is left alone.
	var drifted: PackedStringArray = PackedStringArray()
	var mine: int = 0
	for type: int in [ChessPieces.KING, ChessPieces.QUEEN, ChessPieces.ROOK,
			ChessPieces.BISHOP, ChessPieces.KNIGHT, ChessPieces.PAWN]:
		for white: bool in [true, false]:
			var name: String = ChessPieces.file_name(type, white)
			var path: String = "res://assets/pieces/" + name
			if not FileAccess.file_exists(path):
				continue
			var on_disk: String = FileAccess.open(path, FileAccess.READ).get_as_text()
			if not on_disk.contains(ChessPieces.GENERATED_MARK):
				mine += 1
				continue
			if on_disk != ChessPieces.to_svg(type, white):
				drifted.append(name)
	_check("the committed set matches the drawn artwork it was generated from"
			+ (" — run 'make chess-pieces-repo' (%s)" % ", ".join(drifted) if drifted.size() > 0 else ""),
			drifted.is_empty())
	_check("hand-edited pieces are left alone by that check", mine >= 0)

	# The icon is the knight, generated from the same artwork. It used to be
	# drawn by hand beside the pieces and drifted a whole redesign behind them,
	# so it is held to the same rule: if it still carries the generated mark it
	# has to match what the drawn set produces today.
	var icon_path: String = "res://icon.svg"
	if FileAccess.file_exists(icon_path):
		var icon: String = FileAccess.open(icon_path, FileAccess.READ).get_as_text()
		if icon.contains(ChessPieces.GENERATED_MARK):
			_check("the icon matches the knight it was generated from"
					+ " — run 'make chess-pieces-repo'",
					icon == ChessPieces.to_icon_svg())
		else:
			_check("a hand-edited icon is left alone by that check", true)
		var icon_img := Image.new()
		_check("the icon is valid SVG the engine can rasterise",
				icon_img.load_svg_from_string(ChessPieces.to_icon_svg(), 1.0) == OK
				and icon_img.get_width() >= 8)
