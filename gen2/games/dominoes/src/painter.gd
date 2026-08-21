class_name DominoPainter
extends RefCounted

## Drawing a domino. Shared by the table and the hand so a bone looks the same
## wherever it appears — the same reason the pip arrangement lives in one table
## rather than being re-derived per view.

## Pip positions in a unit square, as a 3x3 grid. This IS the arrangement
## everyone recognises from dice and dominoes; getting it from a formula instead
## produces something subtly wrong that reads as "not a domino".
const PIP_LAYOUT: Array = [
	[],                                                        # 0
	[Vector2(0.5, 0.5)],                                       # 1
	[Vector2(0.28, 0.28), Vector2(0.72, 0.72)],                # 2
	[Vector2(0.28, 0.28), Vector2(0.5, 0.5), Vector2(0.72, 0.72)],
	[Vector2(0.28, 0.28), Vector2(0.72, 0.28),
	 Vector2(0.28, 0.72), Vector2(0.72, 0.72)],
	[Vector2(0.28, 0.28), Vector2(0.72, 0.28), Vector2(0.5, 0.5),
	 Vector2(0.28, 0.72), Vector2(0.72, 0.72)],
	[Vector2(0.28, 0.25), Vector2(0.72, 0.25),
	 Vector2(0.28, 0.5), Vector2(0.72, 0.5),
	 Vector2(0.28, 0.75), Vector2(0.72, 0.75)],
]

## A bone is twice as long as it is wide — the real proportion, and what makes
## a rotated double sit squarely across the line.
const ASPECT: float = 2.0

const PIP_RADIUS: float = 0.088          ## of the half's short side
const CORNER: float = 0.11               ## of the short side

static var _box: StyleBoxFlat = null


## Draw one bone. `low`/`high` are the pip values in the order they should
## appear — the CHAIN's order, not the bone's canonical order, which is why the
## caller passes values rather than a Vector2i.
##
## `vertical` lays the bone along the y axis; the divider and both halves follow.
static func draw_bone(ci: CanvasItem, rect: Rect2, low: int, high: int,
		vertical: bool, face: Color, pip: Color, edge: Color,
		edge_width: float = 2.0) -> void:
	var short_side: float = rect.size.y if not vertical else rect.size.x
	fill_round(ci, rect, short_side * CORNER, face)

	# Halves, split across the long axis.
	var half_a: Rect2
	var half_b: Rect2
	if vertical:
		half_a = Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.5))
		half_b = Rect2(rect.position + Vector2(0.0, rect.size.y * 0.5),
				Vector2(rect.size.x, rect.size.y * 0.5))
	else:
		half_a = Rect2(rect.position, Vector2(rect.size.x * 0.5, rect.size.y))
		half_b = Rect2(rect.position + Vector2(rect.size.x * 0.5, 0.0),
				Vector2(rect.size.x * 0.5, rect.size.y))

	_draw_pips(ci, half_a, low, pip)
	_draw_pips(ci, half_b, high, pip)

	# The divider stops short of the edges, the way a moulded domino's does.
	var inset: float = short_side * 0.13
	if vertical:
		var y: float = rect.position.y + rect.size.y * 0.5
		ci.draw_line(Vector2(rect.position.x + inset, y),
				Vector2(rect.end.x - inset, y), edge, edge_width, true)
	else:
		var x: float = rect.position.x + rect.size.x * 0.5
		ci.draw_line(Vector2(x, rect.position.y + inset),
				Vector2(x, rect.end.y - inset), edge, edge_width, true)


## A face-down bone: the opponent's hand and the boneyard.
static func draw_back(ci: CanvasItem, rect: Rect2, vertical: bool,
		face: Color, mark: Color) -> void:
	var short_side: float = rect.size.y if not vertical else rect.size.x
	fill_round(ci, rect, short_side * CORNER, face)
	var pad: float = short_side * 0.18
	var inner := Rect2(rect.position + Vector2(pad, pad),
			rect.size - Vector2(pad, pad) * 2.0)
	if inner.size.x > 1.0 and inner.size.y > 1.0:
		ci.draw_rect(inner, mark, false, maxf(1.0, short_side * 0.05), true)


static func _draw_pips(ci: CanvasItem, half: Rect2, value: int, colour: Color) -> void:
	if value <= 0 or value >= PIP_LAYOUT.size():
		return
	# Pips sit in the SQUARE inscribed in the half, so they stay round and
	# evenly spaced whichever way the bone is turned.
	var side: float = minf(half.size.x, half.size.y)
	var origin: Vector2 = half.position + (half.size - Vector2(side, side)) * 0.5
	var r: float = side * PIP_RADIUS
	for p in PIP_LAYOUT[value]:
		ci.draw_circle(origin + Vector2(p.x * side, p.y * side), r, colour, true)


## One shared StyleBoxFlat, mutated per call. Allocating a StyleBox per rounded
## rectangle cost this platform a doubling of idle CPU once already.
static func fill_round(ci: CanvasItem, rect: Rect2, radius: float, colour: Color) -> void:
	if _box == null:
		_box = StyleBoxFlat.new()
	_box.bg_color = colour
	_box.set_corner_radius_all(int(maxf(1.0, radius)))
	ci.draw_style_box(_box, rect)
