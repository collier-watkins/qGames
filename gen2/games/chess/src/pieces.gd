class_name ChessPieces
extends RefCounted

## The piece set, drawn in code from Bezier outlines.
##
## There is no shipped alternative. Godot's default font carries none of the
## chess glyphs (VERIFIED: Open Sans SemiBold has_char() is false for the whole
## U+2654..U+265F block), and the system fonts that do have them — DejaVu,
## FreeSerif, Noto Sans Symbols 2 — are present on this desktop and absent on
## Android, so depending on one would make the pieces vanish on a target we
## intend to ship to. Bundling a symbol font means a licence and half a
## megabyte for twelve glyphs.
##
## The shapes are Staunton: ball-headed pawn, crenellated rook, slit mitre,
## coronet, cross-topped king, and a knight with a mane. Each is authored as
## SVG-style path data in a 100x100 box with y downwards, tessellated ONCE into
## polygons and cached, then transformed per draw. Curves rather than polygons
## because a chess set is nothing but curves — the first version of this file
## was straight-edged and read as a set of road signs.

const KING: int = 6
const QUEEN: int = 5
const ROOK: int = 4
const BISHOP: int = 3
const KNIGHT: int = 2
const PAWN: int = 1

## Line segments per Bezier. Twelve is smooth at any size a board square
## reaches on the screens this ships to, and the cost is paid once.
const CURVE_STEPS: int = 12

## The box the artwork actually occupies, as the UNION across all six pieces —
## measured, not guessed (tests/run.gd asserts every piece stays inside it).
## Fitting THIS rather than the nominal 100x100 box is what makes a piece fill
## its square: the tallest piece reaches y=1 and every base ends at y=88, so a
## naive fit left a tenth of every square empty underneath. It has to be the
## union and not each piece's own bounds, or a pawn would be scaled up to the
## size of a king.
const ART_MIN: Vector2 = Vector2(11.0, 0.0)
const ART_MAX: Vector2 = Vector2(89.0, 89.0)

## Every piece stands on the same flared base, so a rank of mixed pieces sits
## on one line and shares one silhouette at the foot. ONE shape, not a stack of
## rings: the first draft had a base band and a foot band, and with the collar
## above them every piece read as a wedding cake — three horizontal bars that
## merged into a smudge at 32px, which is the size a phone actually draws.
const BASE: String = "M 29,70 L 71,70 C 71,74 73,77 77,79 C 80,81 81,84 81,88 L 19,88 C 19,84 20,81 23,79 C 27,77 29,74 29,70 Z"
const BASE_WIDE: String = "M 26,70 L 74,70 C 74,74 76,77 81,79 C 84,81 85,84 85,88 L 15,88 C 15,84 16,81 19,79 C 24,77 26,74 26,70 Z"

## One entry per piece. `fills` are closed outlines painted and then outlined;
## `circles` are exact circles (a Bezier circle would ripple at large sizes);
## `strokes` are open paths that are only outlined — a slit or a mane line
## disappears at board size if it is cut out of the silhouette instead.
const PIECES: Dictionary = {
	PAWN: {
		"circles": [[Vector2(50, 24), 11.0]],
		"fills": [
			"M 41,34 C 41,39 38,42 35,47 C 31,54 29,62 28,70 L 72,70 C 71,62 69,54 65,47 C 62,42 59,39 59,34 Z",
			BASE,
		],
		"strokes": [],
		"dots": [],
	},
	ROOK: {
		"circles": [],
		"fills": [
			"M 22,14 L 34,14 L 34,22 L 43,22 L 43,14 L 57,14 L 57,22 L 66,22 L 66,14 L 78,14 L 78,32 L 22,32 Z",
			"M 25,32 L 75,32 L 71,39 L 29,39 Z",
			"M 31,39 L 69,39 C 68,50 68,61 70,70 L 30,70 C 32,61 32,50 31,39 Z",
			BASE,
		],
		"strokes": [],
		"dots": [],
	},
	BISHOP: {
		"circles": [[Vector2(50, 9), 4.5]],
		"fills": [
			"M 50,13 C 60,18 66,28 66,38 C 66,46 59,51 50,51 C 41,51 34,46 34,38 C 34,28 40,18 50,13 Z",
			"M 37,51 L 63,51 C 64,54 65,56 66,57 L 34,57 C 35,56 36,54 37,51 Z",
			"M 37,57 L 63,57 C 65,62 67,66 69,70 L 31,70 C 33,66 35,62 37,57 Z",
			BASE,
		],
		# The mitre's slit, cut across the shoulder the way a real one is.
		"strokes": ["M 43,22 C 46,27 51,32 57,36"],
		"dots": [],
	},
	KNIGHT: {
		"circles": [],
		"fills": [
			# Landmarks, in order: chest, jaw, muzzle, nose, face, brow, ear,
			# crest, back of the neck. The ear is an explicit notch rather than
			# a bump — a rounded head reads as a dog, and a pair of bumps reads
			# as a rabbit. Both were drawn and looked at before this one.
			"M 30,70 C 30,62 28,55 26,50"
			+ " C 24,47 21,45 17,44 C 13,43 11,41 12,38"
			+ " C 14,34 18,31 23,28 C 27,26 30,23 32,18"
			+ " L 39,6 L 46,17"
			+ " C 53,18 58,21 63,26 C 69,34 73,45 74,57"
			+ " C 74,64 73,68 72,70 Z",
			BASE,
		],
		"strokes": [
			"M 45,18 C 50,23 55,30 58,39 C 60,46 61,54 61,64",
			"M 13,42 C 16,44 20,45 24,44",
		],
		"dots": [[Vector2(28, 29), 2.2], [Vector2(15, 38), 1.3]],
	},
	QUEEN: {
		"circles": [
			[Vector2(18, 20), 4.0], [Vector2(34, 13), 4.0], [Vector2(50, 9), 4.0],
			[Vector2(66, 13), 4.0], [Vector2(82, 20), 4.0],
		],
		"fills": [
			"M 28,42 L 18,24 C 22,31 27,33 31,30 L 34,17"
			+ " C 37,30 43,37 50,39 C 57,37 63,30 66,17 L 69,30"
			+ " C 73,33 78,31 82,24 L 72,42 Z",
			"M 34,42 L 66,42 L 67,48 L 33,48 Z",
			"M 33,48 L 67,48 C 70,55 73,63 75,70 L 25,70 C 27,63 30,55 33,48 Z",
			BASE_WIDE,
		],
		"strokes": [],
		"dots": [],
	},
	KING: {
		"circles": [],
		"fills": [
			"M 46,1 L 54,1 L 54,9 L 62,9 L 62,17 L 54,17 L 54,26 L 46,26 L 46,17 L 38,17 L 38,9 L 46,9 Z",
			# The crown is NARROWER than the body it stands on. Drawn the same
			# width, it merged with the collar into one mass and the piece read
			# as a bell with a cross stuck on top.
			"M 30,42 C 30,32 36,25 44,26 C 47,26 48,29 50,29 C 52,29 53,26 56,26 C 64,25 70,32 70,42 Z",
			"M 36,42 L 64,42 L 65,48 L 35,48 Z",
			"M 35,48 L 65,48 C 68,55 72,63 74,70 L 26,70 C 28,63 32,55 35,48 Z",
			BASE_WIDE,
		],
		"strokes": [],
		"dots": [],
	},
}


## Tessellated outlines in the 100x100 authoring box, keyed by piece type. Built
## on first use and never rebuilt: the curves do not depend on the draw size,
## only the transform does.
static var _fills: Dictionary = {}
static var _strokes: Dictionary = {}


## Draws one piece filling `rect`. `fill` is the body colour and `edge` the
## outline; a white piece is a light fill with a dark edge and a black piece is
## the reverse, which is how both stay legible on both colours of square.
static func draw_piece(ci: CanvasItem, type: int, rect: Rect2,
		fill: Color, edge: Color) -> void:
	if not PIECES.has(type):
		return
	_build(type)
	var spec: Dictionary = PIECES[type]
	var art: Vector2 = ART_MAX - ART_MIN
	var scale: float = minf(rect.size.x / art.x, rect.size.y / art.y)
	var origin: Vector2 = rect.position + (rect.size - art * scale) * 0.5 - ART_MIN * scale
	var width: float = maxf(1.0, scale * 2.0)

	# Fill everything first, then outline everything. Interleaving would let a
	# later fill paint over an earlier outline where shapes abut, which is
	# exactly where the outline is doing its work.
	for c: Array in spec["circles"]:
		ci.draw_circle(origin + Vector2(c[0]) * scale, float(c[1]) * scale, fill)
	for poly: PackedVector2Array in _fills[type]:
		ci.draw_colored_polygon(_xf(poly, origin, scale), fill)
	for c: Array in spec["circles"]:
		ci.draw_arc(origin + Vector2(c[0]) * scale, float(c[1]) * scale,
				0.0, TAU, 32, edge, width, true)
	for poly: PackedVector2Array in _fills[type]:
		ci.draw_polyline(_closed(_xf(poly, origin, scale)), edge, width, true)
	for poly: PackedVector2Array in _strokes[type]:
		ci.draw_polyline(_xf(poly, origin, scale), edge, width, true)
	for d: Array in spec["dots"]:
		ci.draw_circle(origin + Vector2(d[0]) * scale, float(d[1]) * scale, edge)


static func _build(type: int) -> void:
	if _fills.has(type):
		return
	var spec: Dictionary = PIECES[type]
	var fills: Array[PackedVector2Array] = []
	for d: String in spec["fills"]:
		fills.append(tessellate(d))
	var strokes: Array[PackedVector2Array] = []
	for d: String in spec["strokes"]:
		strokes.append(tessellate(d))
	_fills[type] = fills
	_strokes[type] = strokes


## Turns SVG-style path data into a polyline. Absolute commands only — M, L, C,
## Q and Z — because that is all the artwork uses and a general parser would be
## a second thing to get wrong. Static and pure, so tests/run.gd can check the
## curves land where the control points say they should.
static func tessellate(d: String) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	var tokens: PackedStringArray = d.replace(",", " ").split(" ", false)
	var i: int = 0
	var cursor: Vector2 = Vector2.ZERO
	var start: Vector2 = Vector2.ZERO
	while i < tokens.size():
		var cmd: String = tokens[i]
		i += 1
		match cmd:
			"M":
				cursor = Vector2(tokens[i].to_float(), tokens[i + 1].to_float())
				i += 2
				start = cursor
				out.append(cursor)
			"L":
				cursor = Vector2(tokens[i].to_float(), tokens[i + 1].to_float())
				i += 2
				out.append(cursor)
			"C":
				var c1 := Vector2(tokens[i].to_float(), tokens[i + 1].to_float())
				var c2 := Vector2(tokens[i + 2].to_float(), tokens[i + 3].to_float())
				var to := Vector2(tokens[i + 4].to_float(), tokens[i + 5].to_float())
				i += 6
				for s in range(1, CURVE_STEPS + 1):
					out.append(_cubic(cursor, c1, c2, to, float(s) / CURVE_STEPS))
				cursor = to
			"Q":
				var qc := Vector2(tokens[i].to_float(), tokens[i + 1].to_float())
				var qto := Vector2(tokens[i + 2].to_float(), tokens[i + 3].to_float())
				i += 4
				for s in range(1, CURVE_STEPS + 1):
					out.append(_quad(cursor, qc, qto, float(s) / CURVE_STEPS))
				cursor = qto
			"Z":
				cursor = start
			_:
				push_error("ChessPieces: unsupported path command '%s'" % cmd)
				return out
	return out


static func _cubic(a: Vector2, c1: Vector2, c2: Vector2, b: Vector2, t: float) -> Vector2:
	var u: float = 1.0 - t
	return a * (u * u * u) + c1 * (3.0 * u * u * t) + c2 * (3.0 * u * t * t) + b * (t * t * t)


static func _quad(a: Vector2, c: Vector2, b: Vector2, t: float) -> Vector2:
	var u: float = 1.0 - t
	return a * (u * u) + c * (2.0 * u * t) + b * (t * t)


static func _xf(p: PackedVector2Array, origin: Vector2, scale: float) -> PackedVector2Array:
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


# ------------------------------------------------------------ SVG export

## Filenames follow the convention every chess program uses — wK, bN and so on
## — so a set dumped from here can be edited and dropped back, and so ANY
## standard set (Cburnett's, for one) can be dropped in instead with no
## renaming.
const LETTER: Dictionary = {
	KING: "K", QUEEN: "Q", ROOK: "R", BISHOP: "B", KNIGHT: "N", PAWN: "P",
}

const SVG_LIGHT: String = "#f4f4f2"
const SVG_DARK: String = "#1f2126"
const SVG_STROKE_WIDTH: float = 2.2


static func file_name(type: int, white: bool) -> String:
	return "%s%s.svg" % ["w" if white else "b", LETTER.get(type, "?")]


static func to_svg(type: int, white: bool) -> String:
	## The built-in artwork as an editable SVG file, in a viewBox that is the
	## fitted art box — so a replacement drawn against the same box lands on
	## the same squares without anyone having to work out the transform.
	if not PIECES.has(type):
		return ""
	var spec: Dictionary = PIECES[type]
	var art: Vector2 = ART_MAX - ART_MIN
	var fill: String = SVG_LIGHT if white else SVG_DARK
	var edge: String = SVG_DARK if white else SVG_LIGHT
	var body: PackedStringArray = PackedStringArray()
	for d: String in spec["fills"]:
		body.append('  <path d="%s" fill="%s" stroke="%s" stroke-width="%.1f" stroke-linejoin="round"/>'
				% [_shift(d, -ART_MIN), fill, edge, SVG_STROKE_WIDTH])
	for d: String in spec["strokes"]:
		body.append('  <path d="%s" fill="none" stroke="%s" stroke-width="%.1f" stroke-linecap="round" stroke-linejoin="round"/>'
				% [_shift(d, -ART_MIN), edge, SVG_STROKE_WIDTH])
	for dot: Array in spec["dots"]:
		var c: Vector2 = Vector2(dot[0]) - ART_MIN
		body.append('  <circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s"/>'
				% [c.x, c.y, float(dot[1]), edge])
	return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %.0f %.0f">\n'
			% [int(art.x) * 4, int(art.y) * 4, art.x, art.y]) + "\n".join(body) + "\n</svg>\n"


static func _shift(d: String, by: Vector2) -> String:
	## Rewrites path data through a translation, leaving the commands intact.
	var out: PackedStringArray = PackedStringArray()
	var tokens: PackedStringArray = d.replace(",", " ").split(" ", false)
	var i: int = 0
	while i < tokens.size():
		var t: String = tokens[i]
		if t == "M" or t == "L" or t == "C" or t == "Q" or t == "Z":
			out.append(t)
			i += 1
			continue
		var pt: Vector2 = Vector2(t.to_float(), tokens[i + 1].to_float()) + by
		out.append("%.2f %.2f" % [pt.x, pt.y])
		i += 2
	return " ".join(out)
