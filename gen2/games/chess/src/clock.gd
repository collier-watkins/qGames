class_name ChessClock
extends RefCounted

## A chess clock. Pure RefCounted — it is advanced by whoever owns the frame,
## which keeps it testable with a synthetic delta instead of real time.
##
## Times are held in MILLISECONDS as integers. Accumulating a float of seconds
## sixty times a second over a ten minute game drifts, and a clock that is
## visibly wrong is worse than no clock at all.

const NO_LIMIT: int = 0

var base_ms: int = 600000
var increment_ms: int = 0
var remaining: Array[int] = [600000, 600000]
var running_side: int = 0     ## +1 white, -1 black, 0 stopped
var flagged_side: int = 0     ## the side whose time ran out, or 0


func _init(base_seconds: int = 600, increment_seconds: int = 0) -> void:
	configure(base_seconds, increment_seconds)


func configure(base_seconds: int, increment_seconds: int) -> void:
	base_ms = base_seconds * 1000
	increment_ms = increment_seconds * 1000
	remaining = [base_ms, base_ms]
	running_side = 0
	flagged_side = 0


func is_unlimited() -> bool:
	return base_ms <= NO_LIMIT


func start(side: int) -> void:
	if is_unlimited():
		return
	running_side = side


func stop() -> void:
	running_side = 0


func tick(delta_sec: float) -> bool:
	## Returns true on the transition to flagged, once, so the caller can end
	## the game without having to remember whether it already did.
	if running_side == 0 or is_unlimited() or flagged_side != 0:
		return false
	var i: int = _index(running_side)
	remaining[i] = maxi(0, remaining[i] - int(delta_sec * 1000.0))
	if remaining[i] == 0:
		flagged_side = running_side
		running_side = 0
		return true
	return false


func on_move_made(by_side: int) -> void:
	## The increment is added AFTER the move, to the side that moved — the
	## Fischer rule. Adding it before would let a player bank time by simply
	## being on move.
	if is_unlimited() or flagged_side != 0:
		return
	remaining[_index(by_side)] += increment_ms
	running_side = -by_side


func ms_left(side: int) -> int:
	return remaining[_index(side)]


static func _index(side: int) -> int:
	return 0 if side > 0 else 1


static func format(ms: int) -> String:
	## m:ss above a minute, and tenths below ten seconds — the convention every
	## clock uses, because tenths are noise until they are the whole story.
	var total: int = maxi(0, ms)
	var minutes: int = total / 60000
	var seconds: float = (total % 60000) / 1000.0
	if total < 10000:
		return "%d:%04.1f" % [minutes, seconds]
	return "%d:%02d" % [minutes, int(seconds)]


static func format_clk(ms: int) -> String:
	## PGN's [%clk] annotation: H:MM:SS.t, always full width.
	var total: int = maxi(0, ms)
	var hours: int = total / 3600000
	var minutes: int = (total % 3600000) / 60000
	var seconds: float = (total % 60000) / 1000.0
	return "%d:%02d:%04.1f" % [hours, minutes, seconds]
