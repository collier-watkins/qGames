class_name ChessPieces
extends RefCounted

## The piece set, drawn in code.
##
## There is no shipped alternative. Godot's default font carries none of the
## chess glyphs (VERIFIED: Open Sans SemiBold has_char() is false for the whole
## U+2654..U+265F block), and the system fonts that do have them — DejaVu,
## FreeSerif, Noto Sans Symbols 2 — are present on this desktop and absent on
## Android, so depending on one would make the pieces vanish on a target we
## intend to ship to. Bundling a symbol font means a licence and half a
## megabyte for twelve glyphs. Polygons cost nothing, scale to any square size
## without an atlas, and recolour by argument.
##
## Geometry is authored in a 100x100 box with y downwards, and scaled to the
## square at draw time. Shapes are listed back to front.

const KING: int = 6
const QUEEN: int = 5
const ROOK: int = 4
const BISHOP: int = 3
const KNIGHT: int = 2
const PAWN: int = 1

## Every piece stands on the same pedestal, so a rank of mixed pieces sits on
## one line. The board is not drawn with a ground shadow; this is what supplies
## the sense of standing.
const BASE: Array[Vector2] = [
	Vector2(18, 88), Vector2(82, 88), Vector2(76, 78), Vector2(24, 78),
]
const BASE_WIDE: Array[Vector2] = [
	Vector2(14, 88), Vector2(86, 88), Vector2(78, 76), Vector2(22, 76),
]

const PAWN_HEAD_C: Vector2 = Vector2(50, 27)
const PAWN_HEAD_R: float = 13.0
const PAWN_BODY: Array[Vector2] = [
	Vector2(39, 40), Vector2(61, 40), Vector2(57, 50), Vector2(64, 78),
	Vector2(36, 78), Vector2(43, 50),
]

const ROOK_TOP: Array[Vector2] = [
	Vector2(24, 18), Vector2(36, 18), Vector2(36, 27), Vector2(44, 27),
	Vector2(44, 18), Vector2(56, 18), Vector2(56, 27), Vector2(64, 27),
	Vector2(64, 18), Vector2(76, 18), Vector2(76, 37), Vector2(24, 37),
]
const ROOK_NECK: Array[Vector2] = [
	Vector2(30, 37), Vector2(70, 37), Vector2(66, 45), Vector2(34, 45),
]
const ROOK_BODY: Array[Vector2] = [
	Vector2(34, 45), Vector2(66, 45), Vector2(71, 78), Vector2(29, 78),
]

const BISHOP_BALL_C: Vector2 = Vector2(50, 11)
const BISHOP_BALL_R: float = 5.0
const BISHOP_MITRE: Array[Vector2] = [
	Vector2(50, 15), Vector2(58, 20), Vector2(64, 30), Vector2(65, 41),
	Vector2(60, 51), Vector2(40, 51), Vector2(35, 41), Vector2(36, 30),
	Vector2(42, 20),
]
const BISHOP_COLLAR: Array[Vector2] = [
	Vector2(36, 51), Vector2(64, 51), Vector2(66, 59), Vector2(34, 59),
]
const BISHOP_BODY: Array[Vector2] = [
	Vector2(35, 59), Vector2(65, 59), Vector2(71, 78), Vector2(29, 78),
]
## The mitre's slit, drawn as a stroke rather than cut out of the polygon —
## a notch in the silhouette disappears at small sizes, a line does not.
const BISHOP_SLIT: Array[Vector2] = [
	Vector2(46, 24), Vector2(54, 34),
]

const KNIGHT_BODY: Array[Vector2] = [
	Vector2(26, 88), Vector2(28, 74), Vector2(27, 62), Vector2(22, 55),
	Vector2(17, 48), Vector2(21, 42), Vector2(30, 40), Vector2(34, 33),
	Vector2(31, 25), Vector2(36, 16), Vector2(43, 25), Vector2(49, 19),
	Vector2(56, 26), Vector2(64, 34), Vector2(71, 47), Vector2(74, 62),
	Vector2(74, 88),
]
const KNIGHT_EYE_C: Vector2 = Vector2(37, 35)
const KNIGHT_EYE_R: float = 2.6
## The mane, as a stroke down the back of the head — without it the silhouette
## reads as a bird at board size.
const KNIGHT_MANE: Array[Vector2] = [
	Vector2(44, 26), Vector2(52, 34), Vector2(58, 44), Vector2(61, 56),
]

const QUEEN_BALLS: Array[Vector2] = [
	Vector2(17, 24), Vector2(33, 16), Vector2(50, 12),
	Vector2(67, 16), Vector2(83, 24),
]
const QUEEN_BALL_R: float = 5.0
const QUEEN_CROWN: Array[Vector2] = [
	Vector2(17, 28), Vector2(27, 46), Vector2(73, 46), Vector2(83, 28),
	Vector2(67, 21), Vector2(59, 40), Vector2(50, 17), Vector2(41, 40),
	Vector2(33, 21),
]
const QUEEN_COLLAR: Array[Vector2] = [
	Vector2(27, 46), Vector2(73, 46), Vector2(75, 56), Vector2(25, 56),
]
const QUEEN_BODY: Array[Vector2] = [
	Vector2(26, 56), Vector2(74, 56), Vector2(79, 76), Vector2(21, 76),
]

const KING_CROSS_V: Array[Vector2] = [
	Vector2(45, 4), Vector2(55, 4), Vector2(55, 27), Vector2(45, 27),
]
const KING_CROSS_H: Array[Vector2] = [
	Vector2(37, 11), Vector2(63, 11), Vector2(63, 20), Vector2(37, 20),
]
const KING_CROWN: Array[Vector2] = [
	Vector2(25, 46), Vector2(29, 28), Vector2(40, 35), Vector2(50, 25),
	Vector2(60, 35), Vector2(71, 28), Vector2(75, 46),
]
const KING_COLLAR: Array[Vector2] = [
	Vector2(27, 46), Vector2(73, 46), Vector2(75, 56), Vector2(25, 56),
]
const KING_BODY: Array[Vector2] = [
	Vector2(26, 56), Vector2(74, 56), Vector2(79, 76), Vector2(21, 76),
]


## Draws one piece filling `rect`. `fill` is the body colour and `edge` the
## outline; a white piece is a light fill with a dark edge and a black piece is
## the reverse, which is how both stay legible on both colours of square.
static func draw_piece(ci: CanvasItem, type: int, rect: Rect2,
		fill: Color, edge: Color) -> void:
	var scale: float = minf(rect.size.x, rect.size.y) / 100.0
	var origin: Vector2 = rect.position + (rect.size - Vector2(100, 100) * scale) * 0.5
	var width: float = maxf(1.0, scale * 2.2)

	var polys: Array = []
	var circles: Array = []
	var strokes: Array = []
	var dots: Array = []

	match type:
		PAWN:
			circles.append([PAWN_HEAD_C, PAWN_HEAD_R])
			polys.append(PAWN_BODY)
			polys.append(BASE)
		ROOK:
			polys.append(ROOK_TOP)
			polys.append(ROOK_NECK)
			polys.append(ROOK_BODY)
			polys.append(BASE)
		BISHOP:
			circles.append([BISHOP_BALL_C, BISHOP_BALL_R])
			polys.append(BISHOP_MITRE)
			polys.append(BISHOP_COLLAR)
			polys.append(BISHOP_BODY)
			polys.append(BASE)
			strokes.append(BISHOP_SLIT)
		KNIGHT:
			polys.append(KNIGHT_BODY)
			polys.append(BASE)
			strokes.append(KNIGHT_MANE)
			dots.append([KNIGHT_EYE_C, KNIGHT_EYE_R])
		QUEEN:
			for c: Vector2 in QUEEN_BALLS:
				circles.append([c, QUEEN_BALL_R])
			polys.append(QUEEN_CROWN)
			polys.append(QUEEN_COLLAR)
			polys.append(QUEEN_BODY)
			polys.append(BASE_WIDE)
		KING:
			polys.append(KING_CROSS_V)
			polys.append(KING_CROSS_H)
			polys.append(KING_CROWN)
			polys.append(KING_COLLAR)
			polys.append(KING_BODY)
			polys.append(BASE_WIDE)

	# Fill everything first, then outline everything. Interleaving would let a
	# later fill paint over an earlier outline where shapes abut, which is
	# exactly where the outline is doing its work.
	for c: Array in circles:
		ci.draw_circle(origin + Vector2(c[0]) * scale, float(c[1]) * scale, fill)
	for p: Array in polys:
		ci.draw_colored_polygon(_xf(p, origin, scale), fill)
	for c: Array in circles:
		ci.draw_arc(origin + Vector2(c[0]) * scale, float(c[1]) * scale,
				0.0, TAU, 24, edge, width, true)
	for p: Array in polys:
		ci.draw_polyline(_closed(_xf(p, origin, scale)), edge, width, true)
	for s: Array in strokes:
		ci.draw_polyline(_xf(s, origin, scale), edge, width, true)
	for d: Array in dots:
		ci.draw_circle(origin + Vector2(d[0]) * scale, float(d[1]) * scale, edge)


static func _xf(p: Array, origin: Vector2, scale: float) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	out.resize(p.size())
	for i in range(p.size()):
		out[i] = origin + p[i] * scale
	return out


static func _closed(p: PackedVector2Array) -> PackedVector2Array:
	var out: PackedVector2Array = p.duplicate()
	if out.size() > 0:
		out.append(out[0])
	return out
