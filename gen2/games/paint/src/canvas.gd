class_name PaintCanvas
extends RefCounted

## The picture, and the only thing that owns pixels.
##
## MEMORY IS THE WHOLE DESIGN HERE. The previous generation of this game
## crashed a Raspberry Pi after a long session, and the cause was not an
## unbounded leak — its undo and redo stacks were both `deque(maxlen=20)`. What
## it stored in them was the problem: twenty full-resolution surface copies
## each, so forty at ~6 MB apiece on a 1080p screen. Around 240 MB of
## perfectly "bounded" history.
##
## So history here is bounded in BYTES, not in entries, and each entry is a
## PNG rather than raw pixels. A child's painting is mostly flat colour and
## compresses enormously — a blank 1280x720 canvas is 3.5 MB raw and about 6 KB
## as ZSTD-compressed raw pixels — which is what makes a deep history
## affordable at all. It used to be PNG, and PNG is the wrong codec here: it
## filters every row before deflating, and MEASURED on the Pi 4 that cost
## 116 ms for one 1280x720 snapshot against 7 ms for ZSTD. A snapshot is taken
## when a stroke ENDS, so that was a sixth of a second of frozen application
## every time a child lifted the pen — which is what made this game unusable on
## the Pi. ZSTD is 16x faster to write, 4x faster to read back (4.2 ms against
## 17.3 ms) and 23% larger on a real drawing (76 KB against 62 KB), and the
## step ceiling binds long before the byte one, so that size costs nothing
## real. The cap is
## enforced on the total, so a busy, detailed picture simply keeps fewer steps
## instead of quietly growing.
##
## There is exactly one Image for the life of the canvas. Nothing here creates
## a second one per stroke or per frame.

## Ceilings on history. Whichever is reached first wins, and MAX_BYTES is the
## one that actually protects the Pi.
const MAX_STEPS: int = 24
const MAX_BYTES: int = 8 * 1024 * 1024

signal changed(region: Rect2i)

var image: Image
var width: int = 0
var height: int = 0

var _undo: Array = []
var _redo: Array = []
var _undo_bytes: int = 0
var _redo_bytes: int = 0
## The picture as of the last committed state, already encoded. Undo pushes
## THIS and then re-encodes — so the one PNG encode per stroke happens when the
## stroke ENDS rather than when it begins.
##
## Encoding measured ~29 ms for a 1280x720 canvas on this laptop, so it is a
## real hitch and its timing matters: at touch-down it lands in the middle of a
## child starting to draw, which is the worst possible moment. At lift-off they
## have already finished the line.
## A snapshot is {data, w, h}: ZSTD-compressed pixels plus the size they
## decompress to. The dimensions travel WITH the snapshot because decompression
## needs the exact byte count, and resize() can change it between one snapshot
## and the next — a history entry from before a resize would otherwise fail to
## restore, silently, and only for someone who had resized the window.
var _baseline: Dictionary = {}
var _dirty_since_snapshot: bool = false


func _init(w: int = 960, h: int = 600, background: Color = Color.WHITE) -> void:
	resize(w, h, background)


## Make (or remake) the picture. Any existing content is kept, drawn into the
## top-left of the new size, because a window resize must not throw away a
## child's drawing.
func resize(w: int, h: int, background: Color = Color.WHITE) -> void:
	w = maxi(1, w)
	h = maxi(1, h)
	if image != null and w == width and h == height:
		return
	var fresh := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	fresh.fill(background)
	if image != null:
		var copy_w: int = mini(width, w)
		var copy_h: int = mini(height, h)
		fresh.blit_rect(image, Rect2i(0, 0, copy_w, copy_h), Vector2i.ZERO)
	image = fresh
	width = w
	height = h
	_baseline = _snapshot()
	changed.emit(Rect2i(0, 0, w, h))


# ── drawing ─────────────────────────────────────────────────────────────────


## Begin a stroke. Free — the previous state was encoded when the last stroke
## finished, so there is nothing to do here.
func begin_stroke() -> void:
	_dirty_since_snapshot = false


## Finish a stroke: the old baseline becomes an undo step and the new state
## becomes the baseline. A stroke that marked nothing costs neither, so a
## stray tap does not consume history.
func end_stroke() -> void:
	if not _dirty_since_snapshot:
		return
	if not _baseline.is_empty():
		_push_undo(_baseline)
	_baseline = _snapshot()
	_dirty_since_snapshot = false


## A round dab, drawn as horizontal SPANS rather than pixels.
##
## A circle of radius r is 2r+1 rows, each one contiguous — so it is 2r+1 calls
## to fill_rect instead of pi*r^2 calls to set_pixel. At the largest brush that
## is 69 calls rather than 3600, and it is the difference between a stroke that
## keeps up with a finger and one that does not: measured, the biggest brush
## went from 30 ms per 100 px of drag to under 2 ms.
func dab(at: Vector2i, radius: int, colour: Color, square: bool = false) -> Rect2i:
	radius = maxi(1, radius)
	if square:
		return _dab_square(at, radius, colour)
	var r2: int = radius * radius
	var y0: int = maxi(0, at.y - radius)
	var y1: int = mini(height - 1, at.y + radius)
	var x_lo: int = width
	var x_hi: int = -1
	for y in range(y0, y1 + 1):
		var dy: int = y - at.y
		var half: int = int(sqrt(float(r2 - dy * dy)))
		var x0: int = maxi(0, at.x - half)
		var x1: int = mini(width - 1, at.x + half)
		if x0 > x1:
			continue
		image.fill_rect(Rect2i(x0, y, x1 - x0 + 1, 1), colour)
		x_lo = mini(x_lo, x0)
		x_hi = maxi(x_hi, x1)
	if x_hi < 0:
		return Rect2i()
	_dirty_since_snapshot = true
	var region := Rect2i(x_lo, y0, x_hi - x_lo + 1, y1 - y0 + 1)
	changed.emit(region)
	return region


## A square dab — one fill_rect, and the shape the eraser actually erases.
##
## A real eraser is a block, and drawing a square outline while rubbing out a
## circle is a small lie a child would notice the first time they tried to
## clear a corner.
func _dab_square(at: Vector2i, half: int, colour: Color) -> Rect2i:
	var x0: int = maxi(0, at.x - half)
	var y0: int = maxi(0, at.y - half)
	var x1: int = mini(width - 1, at.x + half)
	var y1: int = mini(height - 1, at.y + half)
	if x0 > x1 or y0 > y1:
		return Rect2i()
	var region := Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
	image.fill_rect(region, colour)
	_dirty_since_snapshot = true
	changed.emit(region)
	return region


## A stroke segment, as overlapping dabs along the line.
##
## The step is half the brush radius, not one pixel. A round dab of radius r
## covers everything within r, so consecutive dabs r/2 apart overlap heavily
## and the line is solid — while dabbing every pixel would redraw the same
## disc dozens of times for nothing. The step is clamped to at least 1 so a
## tiny brush still moves.
func stroke(from: Vector2i, to: Vector2i, radius: int, colour: Color,
		square: bool = false) -> Rect2i:
	radius = maxi(1, radius)
	var delta: Vector2 = Vector2(to - from)
	var distance: float = delta.length()
	# A square of half-width r covers at least r in every direction, same as a
	# circle of radius r, so the same step keeps both continuous.
	var step: float = maxf(1.0, float(radius) * 0.5)
	var count: int = maxi(1, int(ceil(distance / step)))
	var covered := Rect2i()
	var first: bool = true
	for i in range(count + 1):
		var t: float = float(i) / float(count)
		var point := Vector2i(int(round(lerpf(from.x, to.x, t))),
				int(round(lerpf(from.y, to.y, t))))
		var region: Rect2i = dab(point, radius, colour, square)
		if region.size.x <= 0:
			continue
		covered = region if first else covered.merge(region)
		first = false
	return covered


## Flood fill from a point.
##
## Scanline and iterative — a per-pixel recursive fill overflows the stack on a
## large area, which kills the session just as dead as running out of memory.
##
## ONE PIXEL IS ONE INT here, not four bytes and not a Color. Both of the
## obvious ways are far too slow in GDScript: get_pixel/set_pixel allocate a
## Color per call, and indexing a PackedByteArray costs about the same four
## times over. A full-canvas fill measured 737 ms through Colors and 784 ms
## through bytes — a visible freeze here, several seconds on a Pi. Viewing the
## buffer as int32s makes a pixel test a single integer compare.
func fill(at: Vector2i, colour: Color) -> bool:
	if at.x < 0 or at.y < 0 or at.x >= width or at.y >= height:
		return false

	var pixels: PackedInt32Array = image.get_data().to_int32_array()
	var seed_index: int = at.y * width + at.x
	var target: int = pixels[seed_index]
	var want: int = _packed(colour)
	if target == want:
		return false

	var stack: Array[int] = [seed_index]
	while not stack.is_empty():
		var index: int = stack.pop_back()
		if pixels[index] != target:
			continue
		var y: int = index / width
		var row: int = y * width

		var left: int = index - row
		while left > 0 and pixels[row + left - 1] == target:
			left -= 1
		var right: int = index - row
		while right < width - 1 and pixels[row + right + 1] == target:
			right += 1

		for x in range(left, right + 1):
			pixels[row + x] = want

		# Seed the rows above and below once per contiguous run rather than
		# once per pixel — that is what keeps the stack small.
		for dy in [-1, 1]:
			var ny: int = y + dy
			if ny < 0 or ny >= height:
				continue
			var other: int = ny * width
			var run: bool = false
			for x in range(left, right + 1):
				var hit: bool = pixels[other + x] == target
				if hit and not run:
					stack.append(other + x)
					run = true
				elif not hit:
					run = false

	image.set_data(width, height, false, Image.FORMAT_RGBA8, pixels.to_byte_array())
	_dirty_since_snapshot = true
	changed.emit(Rect2i(0, 0, width, height))
	return true


## A Colour as it sits in an RGBA8 buffer viewed as int32s. Derived rather than
## assumed: `_test_fill_matches_a_drawn_pixel` compares a filled pixel against
## one written the ordinary way, so a byte order that ever disagreed would fail
## a test rather than paint the wrong colour.
static func _packed(colour: Color) -> int:
	var r: int = int(round(clampf(colour.r, 0.0, 1.0) * 255.0))
	var g: int = int(round(clampf(colour.g, 0.0, 1.0) * 255.0))
	var b: int = int(round(clampf(colour.b, 0.0, 1.0) * 255.0))
	var a: int = int(round(clampf(colour.a, 0.0, 1.0) * 255.0))
	var value: int = r | (g << 8) | (b << 16) | (a << 24)
	# int32 is signed; a full-alpha colour sets the top bit.
	if value >= 0x80000000:
		value -= 0x100000000
	return value


func clear(background: Color) -> void:
	begin_stroke()
	image.fill(background)
	_dirty_since_snapshot = true
	end_stroke()
	changed.emit(Rect2i(0, 0, width, height))


## Colours are compared with a tolerance because an 8-bit channel does not
## always survive a round trip exactly, and a fill that stops one shade short
## leaves a halo.
static func _same(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.004 and absf(a.g - b.g) < 0.004 \
			and absf(a.b - b.b) < 0.004 and absf(a.a - b.a) < 0.004


# ── history ─────────────────────────────────────────────────────────────────


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo() -> bool:
	if _undo.is_empty():
		return false
	# The current state is already encoded as the baseline, so stepping back
	# costs no encode at all.
	_push(_redo, _baseline, true)
	_baseline = _undo.pop_back()
	_restore(_baseline)
	_undo_bytes = _total(_undo)
	return true


func redo() -> bool:
	if _redo.is_empty():
		return false
	_push(_undo, _baseline, false)
	_baseline = _redo.pop_back()
	_restore(_baseline)
	_redo_bytes = _total(_redo)
	return true


## Bytes currently held by undo and redo together. The debug HUD and the tests
## read this: a number that can be asserted is the difference between "we
## believe it is bounded" and "it is".
func history_bytes() -> int:
	return _undo_bytes + _redo_bytes


func history_steps() -> int:
	return _undo.size() + _redo.size()


func _push_undo(snap: Dictionary) -> void:
	_push(_undo, snap, false)
	# A new stroke invalidates the redo branch, and holding it would be so much
	# dead weight.
	_redo.clear()
	_redo_bytes = 0


func _push(stack: Array, snap: Dictionary, to_redo: bool) -> void:
	stack.append(snap)
	var bytes: int = _total(stack)
	# Drop the OLDEST steps until both ceilings are met. Losing the deepest
	# undo is the least surprising thing that can be lost.
	while stack.size() > MAX_STEPS or (bytes > MAX_BYTES and stack.size() > 1):
		var dropped: Dictionary = stack.pop_front()
		bytes -= (dropped["data"] as PackedByteArray).size()
	if to_redo:
		_redo_bytes = bytes
	else:
		_undo_bytes = bytes


static func _total(stack: Array) -> int:
	var sum: int = 0
	for entry in stack:
		sum += ((entry as Dictionary)["data"] as PackedByteArray).size()
	return sum


## The picture as a history entry. get_data() is a reference to the image's own
## buffer and costs nothing measurable; the compress() is the whole price.
func _snapshot() -> Dictionary:
	var raw: PackedByteArray = image.get_data()
	return {
		"data": raw.compress(FileAccess.COMPRESSION_ZSTD),
		"w": width,
		"h": height,
		"raw": raw.size(),
	}


## Load a snapshot back into the ONE image. set_data() replaces the contents in
## place; it does not hand back a new Image to leak.
func _restore(snap: Dictionary) -> void:
	var raw: PackedByteArray = (snap["data"] as PackedByteArray).decompress(
			int(snap["raw"]), FileAccess.COMPRESSION_ZSTD)
	width = int(snap["w"])
	height = int(snap["h"])
	image.set_data(width, height, false, Image.FORMAT_RGBA8, raw)
	changed.emit(Rect2i(0, 0, width, height))


# ── saving ──────────────────────────────────────────────────────────────────


## Write the picture. Returns "" on failure, with the reason in `last_error`.
var last_error: String = ""


func save_png(path: String) -> bool:
	last_error = ""
	var folder: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(folder):
		var err: int = DirAccess.make_dir_recursive_absolute(folder)
		if err != OK:
			last_error = "cannot create %s (%d)" % [folder, err]
			return false
	var err2: int = image.save_png(path)
	if err2 != OK:
		last_error = "cannot write %s (%d)" % [path, err2]
		return false
	return true


## The picture as PNG bytes, ready to publish.
##
## THE FULL-SIZE IMAGE, unless it is genuinely too big — which measurement says
## it almost never is. The previous generation scaled to 800px wide before
## publishing, and copying that turned out to make things WORSE: a bilinear
## downscale blurs flat colour into gradients, which is exactly what PNG
## compresses well, so the "thumbnail" came out roughly twice the size of the
## original. Measured on a 1280x720 canvas:
##
##     painting      full PNG   800 bilinear   800 nearest
##     simple            12 KB          20 KB         6 KB
##     busy              63 KB         128 KB        39 KB
##     dense             87 KB         167 KB        53 KB
##
## So the full picture goes out as-is: smaller than the scaled version AND at
## full quality. Only if it exceeds `max_bytes` is it stepped down, and then
## with NEAREST — which keeps flat areas flat and therefore keeps compressing.
##
## The cap exists because a broker that refuses an oversized packet drops the
## publish silently, and "the picture sometimes does not arrive" is a horrible
## thing to debug later.
func publish_png(max_bytes: int = 256 * 1024) -> PackedByteArray:
	var png: PackedByteArray = image.save_png_to_buffer()
	if png.size() <= max_bytes:
		return png

	var w: int = width
	var scaled := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	while png.size() > max_bytes and w > 240:
		w = int(float(w) * 0.75)
		var h: int = maxi(1, int(round(float(height) * float(w) / float(width))))
		scaled.copy_from(image)
		scaled.resize(w, h, Image.INTERPOLATE_NEAREST)
		png = scaled.save_png_to_buffer()
	return png
