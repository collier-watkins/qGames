class_name MemoryBoard
extends RefCounted

## Pure model for the 4x4 memory-match game. No Node, no rendering, no engine
## singletons beyond RandomNumberGenerator. Fully unit-testable headless.
##
## Flip protocol:
##   flip(i) on a fresh pair  -> "flipped"   (card i now face up, wait for a 2nd flip)
##   flip(j) that matches     -> "match"     (both cards marked matched, unblocked immediately)
##   flip(j) that mismatches  -> "mismatch"  (both cards stay face up; further flips are
##                                            "ignored" until resolve_mismatch() is called)
##   flip on an already face-up/matched card, an out-of-range index, while a
##   mismatch is pending, or after the board is won -> "ignored"

const COLS: int = 4
const ROWS: int = 4
const TOTAL_PAIRS: int = COLS * ROWS / 2

class Card:
	extends RefCounted

	var pair: int = -1
	var face_up: bool = false
	var matched: bool = false

	func _init(p: int) -> void:
		pair = p


var cards: Array[Card] = []
var moves: int = 0
var matched_pairs: int = 0

var _flipped: Array[int] = []
var _rng: RandomNumberGenerator


## rng_seed == 0 means "pick a random seed" (real gameplay). Any other value
## deterministically reproduces the same deck order — tests rely on this.
func _init(rng_seed: int = 0) -> void:
	_rng = RandomNumberGenerator.new()
	if rng_seed == 0:
		_rng.randomize()
	else:
		_rng.seed = rng_seed
	_build_deck()


func _build_deck() -> void:
	var pairs: Array[int] = []
	for p in range(TOTAL_PAIRS):
		pairs.append(p)
		pairs.append(p)

	# Fisher-Yates, driven by the seeded RNG.
	for i in range(pairs.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var tmp: int = pairs[i]
		pairs[i] = pairs[j]
		pairs[j] = tmp

	cards.clear()
	for p in pairs:
		cards.append(Card.new(p))


## Flip the card at index. Returns "ignored" | "flipped" | "match" | "mismatch".
func flip(index: int) -> String:
	if is_won():
		return "ignored"
	if index < 0 or index >= cards.size():
		return "ignored"
	if _flipped.size() == 2:
		return "ignored"  # mismatched pair awaiting resolve_mismatch()

	var card: Card = cards[index]
	if card.face_up or card.matched:
		return "ignored"

	card.face_up = true
	_flipped.append(index)
	if _flipped.size() == 1:
		return "flipped"

	moves += 1
	var a: Card = cards[_flipped[0]]
	var b: Card = cards[_flipped[1]]
	if a.pair == b.pair:
		a.matched = true
		b.matched = true
		matched_pairs += 1
		_flipped.clear()  # a match never blocks further flips
		return "match"

	return "mismatch"


## The two indices left face up after a "mismatch" result, until
## resolve_mismatch() is called. Empty otherwise.
func pending_pair() -> Array:
	if _flipped.size() == 2:
		return _flipped.duplicate()
	return []


## Flips a pending mismatched pair back face down. No-op if there is none.
func resolve_mismatch() -> void:
	if _flipped.size() != 2:
		return
	for i in _flipped:
		cards[i].face_up = false
	_flipped.clear()


func is_won() -> bool:
	return matched_pairs == TOTAL_PAIRS
