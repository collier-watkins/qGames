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
##
## The foot flares out to a lip rather than meeting the ground straight, which
## is what makes a Staunton base read as turned wood rather than as a cylinder.
const BASE: String = "M 30,70 L 70,70 C 70,74 72,77 76,79 C 79,81 80,84 80,88 L 20,88 C 20,84 21,81 24,79 C 28,77 30,74 30,70 Z"
const BASE_WIDE: String = "M 26,70 L 74,70 C 74,74 77,77 82,79 C 85,81 86,84 86,88 L 14,88 C 14,84 15,81 18,79 C 23,77 26,74 26,70 Z"

## One entry per piece. `fills` are closed outlines painted and then outlined;
## `circles` are exact circles (a Bezier circle would ripple at large sizes);
## `strokes` are open paths that are only outlined — a slit or a mane line
## disappears at board size if it is cut out of the silhouette instead.
##
## The governing rule throughout is CONTRAST AT THE JOINT. A Staunton piece is
## read by its steps: ball to neck, mitre to collar, coronet to band. Where two
## parts are within a few units of the same width they fuse into one mass at
## board size and the piece loses its name — the first version of this set drew
## a pawn whose neck was as wide as its ball and it read as a lampshade. Every
## neck here is deliberately much narrower than the thing sitting on it.
const PIECES: Dictionary = {
	PAWN: {
		# Ball 24 wide on a neck 14 wide. That ratio is the whole pawn: at 32px
		# the ball is four pixels clear of the shoulders on each side, which is
		# what stops it merging into the body and reading as a bell.
		"circles": [[Vector2(50, 22), 12.0]],
		"fills": [
			# A collar between the ball and the skirt. The pawn is the piece
			# repeated eight times in a row, so it is the one that has to hold
			# up under repetition — a plain cone eight times reads as a picket
			# fence, and the collar is what breaks that up.
			"M 42,32 L 58,32 L 61,39 L 39,39 Z",
			"M 39,39 C 37,46 33,53 31,61 C 30,65 30,68 30,70 L 70,70 C 70,68 70,65 69,61 C 67,53 63,46 61,39 Z",
			BASE,
		],
		"strokes": [],
		"dots": [],
	},
	ROOK: {
		"circles": [],
		"fills": [
			# Three merlons and two embrasures. Two merlons reads as a tuning
			# fork and four closes up to a comb at board size; three is the
			# fewest that still says "battlement".
			"M 24,13 L 35,13 L 35,20 L 44,20 L 44,13 L 56,13 L 56,20 L 65,20 L 65,13 L 76,13 L 76,29 L 24,29 Z",
			# A cornice WIDER than the battlement it carries, so the top of the
			# rook overhangs instead of stacking flush.
			"M 21,29 L 79,29 L 75,37 L 25,37 Z",
			# The shaft is waisted — it pulls in to 69 at the knee and flares
			# back out to meet the base. A straight-sided shaft is a chimney.
			"M 28,37 L 72,37 C 70,47 69,58 71,70 L 29,70 C 31,58 30,47 28,37 Z",
			BASE_WIDE,
		],
		"strokes": [],
		"dots": [],
	},
	BISHOP: {
		"circles": [[Vector2(50, 7), 5.0]],
		"fills": [
			"M 50,12 C 62,19 68,29 68,40 C 68,48 60,54 50,54 C 40,54 32,48 32,40 C 32,29 38,19 50,12 Z",
			# A collar between mitre and skirt. Without it the mitre sits
			# straight on the body and the bishop becomes a pawn with a slit.
			"M 35,54 L 65,54 L 67,61 L 33,61 Z",
			"M 33,61 L 67,61 C 68,64 69,67 70,70 L 30,70 C 31,67 32,64 33,61 Z",
			BASE,
		],
		# The mitre's slit, cut across the shoulder the way a real one is. It
		# runs corner to corner rather than sitting near the crown: high up it
		# is a short mark on a curve and reads as a nick in the outline.
		"strokes": ["M 41,27 C 46,34 53,40 61,44"],
		"dots": [],
	},
	KNIGHT: {
		"circles": [],
		"fills": [
			# Traced against the reference set rather than drawn from memory,
			# which is what the first four attempts were and why they all came
			# out as dogs. The corrections that mattered, in order of effect:
			#
			#  1. The head is BIG. It is not a head on a neck — head and neck
			#     are one mass filling the whole upper square, and drawing the
			#     head small is what made every earlier version canine.
			#  2. ONE ear, at the top LEFT, with a notch behind it. Two peaks
			#     read as a wolf no matter how the notch between them is cut.
			#  3. The face is a steep, DISHED diagonal — control points to the
			#     left of the chord — from the ear down to a blunt nose at the
			#     far left. A straight or convex face is a muzzle, not a head.
			#  4. The throat notch. A wedge opening to the left between the jaw
			#     above and the chest below, apex at (52,46). Without it the
			#     jaw merges into the neck and the profile disappears. It has
			#     to stay a WEDGE — cut narrower it reads as a slash through
			#     the piece rather than as the shape of a throat.
			#
			# The ear is short and wide-based on purpose. Drawn tall off a
			# narrow notch it becomes a horn and the knight becomes a unicorn,
			# which is a real thing this went through.
			#
			# Landmarks in path order: chest, notch apex, jaw, chin, nose,
			# face, ear, crown, back of the neck, down to the base.
			"M 34,70 C 38,64 45,55 52,46"
			+ " C 44,51 34,57 27,59 C 20,60 14,59 12,54"
			+ " C 14,42 19,29 26,17"
			+ " L 22,8 L 32,16"
			+ " C 37,10 42,7 47,7"
			+ " C 59,10 70,20 77,33"
			+ " C 82,43 84,57 80,66 C 79,68 76,70 74,70 Z",
			BASE_WIDE,
		],
		"strokes": [
			# The mane, as five roughly horizontal hatches off the back edge —
			# which is what the reference does. An earlier version drew it as a
			# filled band, and a band is more robust at 44px but it reads as a
			# saddle blanket rather than hair. Five is what fits before the
			# gaps close up.
			"M 62,25 L 73,28",
			"M 61,35 L 79,37",
			"M 59,45 L 82,46",
			"M 57,55 L 81,55",
			"M 55,64 L 78,64",
			# The mouth line, which is what separates muzzle from jaw. Without
			# it the head ends in a blunt wedge and reads as a dog.
			"M 13,52 C 17,55 22,57 27,57",
		],
		"dots": [[Vector2(27, 30), 3.0], [Vector2(16, 50), 1.6]],
	},
	QUEEN: {
		"circles": [
			[Vector2(18, 20), 4.5], [Vector2(34, 13), 4.5], [Vector2(50, 9), 5.0],
			[Vector2(66, 13), 4.5], [Vector2(82, 20), 4.5],
		],
		"fills": [
			# Five spikes rising INTO the pearls rather than stopping short of
			# them. Left short, the pearls float free of the coronet and the
			# crown reads as a row of unrelated dots.
			"M 24,44 L 18,24 L 27,35 L 34,17 L 41,37 L 50,14"
			+ " L 59,37 L 66,17 L 73,35 L 82,24 L 76,44 Z",
			"M 26,44 L 74,44 L 75,51 L 25,51 Z",
			"M 25,51 L 75,51 C 77,58 79,64 80,70 L 20,70 C 21,64 23,58 25,51 Z",
			BASE_WIDE,
		],
		"strokes": [],
		"dots": [],
	},
	KING: {
		"circles": [],
		"fills": [
			"M 46,2 L 54,2 L 54,8 L 61,8 L 61,14 L 54,14 L 54,21 L 46,21 L 46,14 L 39,14 L 39,8 L 46,8 Z",
			# A wide, low crown with a dip in the middle for the cross to stand
			# in. The dip is what tells it apart from the bishop's dome.
			"M 15,40 C 14,26 26,16 38,16 C 45,16 47,21 50,21"
			+ " C 53,21 55,16 62,16 C 74,16 86,26 85,40 Z",
			"M 30,40 L 70,40 C 73,50 77,61 79,70 L 21,70 C 23,61 27,50 30,40 Z",
			BASE_WIDE,
		],
		"strokes": [
			# The reference set's figure-eight, as a STROKE. It was drawn first
			# as two overlapping filled ellipses, which is the obvious way and
			# the wrong one: fills have no holes, so the pair came out as two
			# eggs rather than as a ribbon. A stroke can cross itself, which is
			# the whole shape — the two diagonals between the lobes make the X
			# in the middle, and that X is what names a Staunton king.
			"M 36,20 C 24,20 24,36 36,36 C 46,36 54,20 64,20"
			+ " C 76,20 76,36 64,36 C 54,36 46,20 36,20",
			# Two bands across the body, as the reference has. They stop the
			# body reading as a plain skirt under all that crown.
			"M 28,51 C 39,48 61,48 72,51",
			"M 25,60 C 38,57 62,57 75,60",
		],
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

## Marks a file as still being the generated artwork rather than somebody's
## own. A committed set SHADOWS the drawn artwork in src/pieces.gd — that is
## the point of it — which means an improvement to the drawn set would
## otherwise never be seen again. A test regenerates every file that still
## carries this line and fails if it has drifted, so the trap is loud instead
## of silent. Editing a piece means deleting the line.
const GENERATED_MARK: String = "<!-- generated from src/pieces.gd by 'make chess-pieces-repo' — delete this line once you have edited this file -->"

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
	# Circles FIRST, and this is not cosmetic. They were omitted entirely until
	# 2026-08-25, which cost the pawn its head, the bishop its finial and the
	# queen all five pearls — in the shipped set only, because a committed set
	# shadows the drawn artwork, so the game looked wrong while every test and
	# every in-editor run looked right. Ahead of the fills because each ball
	# sits at the top of the piece with the neck below it, so a fill painted
	# afterwards covers at most a two-unit sliver of the ball's outline where
	# they overlap; the alternative — a fill pass and then a stroke pass over
	# the whole set — doubles every path and makes the file miserable to open
	# in a vector editor, which is the one thing these files are for.
	for c: Array in spec["circles"]:
		body.append('  <circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s" stroke="%s" stroke-width="%.1f"/>'
				% [Vector2(c[0]).x - ART_MIN.x, Vector2(c[0]).y - ART_MIN.y,
				float(c[1]), fill, edge, SVG_STROKE_WIDTH])
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
			% [int(art.x) * 4, int(art.y) * 4, art.x, art.y]) \
			+ "  " + GENERATED_MARK + "\n" + "\n".join(body) + "\n</svg>\n"


# ------------------------------------------------------------------ icon

## The game's icon is the knight, on this game's own background, and it is
## GENERATED from the same artwork as the pieces rather than drawn beside them.
## Hand-drawn is what it was, and it drifted exactly as you would expect: the
## icon in the repository was a tracing of an early knight and stayed that way
## through every later revision of the piece, so the launcher and the board
## showed two different horses.
const ICON_BG: String = "#19233c"
const ICON_FG: String = "#f6f9fa"
const ICON_MARGIN: float = 10.0

## Heavier than SVG_STROKE_WIDTH because an icon is read at 32px in a taskbar,
## where the piece's own line weight sands away to nothing.
const ICON_STROKE_WIDTH: float = 2.6


static func to_icon_svg() -> String:
	var spec: Dictionary = PIECES[KNIGHT]
	var art: Vector2 = ART_MAX - ART_MIN
	var room: float = 100.0 - 2.0 * ICON_MARGIN
	var scale: float = minf(room / art.x, room / art.y)
	var off: Vector2 = (Vector2(100.0, 100.0) - art * scale) * 0.5
	var body: PackedStringArray = PackedStringArray()
	body.append('  <rect x="0" y="0" width="100" height="100" rx="16" ry="16" fill="%s"/>' % ICON_BG)
	for d: String in spec["fills"]:
		body.append('  <path d="%s" fill="%s" stroke="%s" stroke-width="%.1f" stroke-linejoin="round"/>'
				% [_fit(d, scale, off), ICON_FG, ICON_BG, ICON_STROKE_WIDTH])
	for d: String in spec["strokes"]:
		body.append('  <path d="%s" fill="none" stroke="%s" stroke-width="%.1f" stroke-linecap="round" stroke-linejoin="round"/>'
				% [_fit(d, scale, off), ICON_BG, ICON_STROKE_WIDTH])
	for dot: Array in spec["dots"]:
		var c: Vector2 = (Vector2(dot[0]) - ART_MIN) * scale + off
		body.append('  <circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s"/>'
				% [c.x, c.y, float(dot[1]) * scale, ICON_BG])
	return '<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 100 100">\n' \
			+ "  " + GENERATED_MARK + "\n" + "\n".join(body) + "\n</svg>\n"


static func _fit(d: String, scale: float, off: Vector2) -> String:
	## Rewrites path data through a scale about ART_MIN and then a translation,
	## leaving the commands intact.
	var out: PackedStringArray = PackedStringArray()
	var tokens: PackedStringArray = d.replace(",", " ").split(" ", false)
	var i: int = 0
	while i < tokens.size():
		var t: String = tokens[i]
		if t == "M" or t == "L" or t == "C" or t == "Q" or t == "Z":
			out.append(t)
			i += 1
			continue
		var pt: Vector2 = (Vector2(t.to_float(), tokens[i + 1].to_float()) - ART_MIN) * scale + off
		out.append("%.2f %.2f" % [pt.x, pt.y])
		i += 2
	return " ".join(out)


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
