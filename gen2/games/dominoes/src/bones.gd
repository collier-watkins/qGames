class_name DominoBones
extends RefCounted

## The double-six set, and the arithmetic that goes with it.
##
## A bone is a Vector2i held CANONICALLY, x <= y, so (2,5) and (5,2) are the
## same physical piece and compare equal. Orientation is a property of how a
## bone is laid on the table, not of the bone, and lives in DominoChain.
##
## Pure by rule: no Node, no autoload identifier anywhere in this file or
## anything it preloads. An autoload name is not in scope while a preload chain
## compiles under `--script`, which makes the test runner fail to compile and
## its statics silently disappear.

## Highest pip value. Six here is the whole set: "double-six" IS this number.
const MAX_PIP: int = 6

## 28 for a double-six set: (MAX_PIP + 1)(MAX_PIP + 2) / 2.
const BONE_COUNT: int = 28


## Every bone in the set, once each, in a fixed order.
static func full_set() -> Array:
	var out: Array = []
	for a in MAX_PIP + 1:
		for b in range(a, MAX_PIP + 1):
			out.append(Vector2i(a, b))
	return out


## Canonical form, so a bone built either way round compares equal.
static func make(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))


static func is_double(bone: Vector2i) -> bool:
	return bone.x == bone.y


static func pips(bone: Vector2i) -> int:
	return bone.x + bone.y


static func total_pips(bones: Array) -> int:
	var sum: int = 0
	for b in bones:
		sum += pips(b)
	return sum


static func has_value(bone: Vector2i, value: int) -> bool:
	return bone.x == value or bone.y == value


## The other half of a bone. Asking for a value the bone does not carry is a
## caller bug, so it returns -1 rather than guessing.
static func other_half(bone: Vector2i, value: int) -> int:
	if bone.x == value:
		return bone.y
	if bone.y == value:
		return bone.x
	return -1


static func to_text(bone: Vector2i) -> String:
	return "%d-%d" % [bone.x, bone.y]


## The heaviest double in a hand, or the heaviest bone when there is none.
## This is the classic opening rule, and it is deterministic — which is what
## makes an opening testable rather than a matter of whose turn it "feels" like.
static func opening_bone(hand: Array) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_double := Vector2i(-1, -1)
	for b in hand:
		if is_double(b) and (best_double.x < 0 or b.x > best_double.x):
			best_double = b
		if best.x < 0 or pips(b) > pips(best):
			best = b
	return best_double if best_double.x >= 0 else best
