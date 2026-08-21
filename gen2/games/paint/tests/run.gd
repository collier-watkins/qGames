extends SceneTree

## Headless tests for the Paint canvas:
##   godot --headless --path games/paint --script res://tests/run.gd
##
## Only autoload-free classes are exercised. An autoload identifier (QConfig,
## Telemetry, QInput) anywhere in a preload chain is not in scope while that
## chain compiles under --script: the whole script fails to compile and its
## statics silently cease to exist. That is why canvas.gd never mentions one,
## and why src/main.gd is not touched below.

const CanvasT := preload("res://src/canvas.gd")
const SCRATCH := "user://paint_selftest"

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	_test_blank()
	_test_dab()
	_test_square_dab()
	_test_stroke_is_continuous()
	_test_fill()
	_test_fill_respects_edges()
	_test_fill_matches_a_drawn_pixel()
	_test_undo_redo()
	_test_stray_tap_costs_no_history()
	_test_history_is_bounded_by_bytes()
	_test_history_survives_a_long_session()
	_test_compression_is_why_this_fits()
	_test_resize_keeps_the_drawing()
	_test_save_png()
	_test_publish_png()

	print("")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(name: String, condition: bool) -> void:
	if condition:
		_pass += 1
		print("PASS  %s" % name)
	else:
		_fail += 1
		print("FAIL  %s" % name)


func _check_eq(name: String, got, want) -> void:
	if str(got) == str(want):
		_pass += 1
		print("PASS  %s" % name)
	else:
		_fail += 1
		print("FAIL  %s\n        got:  %s\n        want: %s" % [name, got, want])


func _same(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01


# ── drawing ─────────────────────────────────────────────────────────────────


func _test_blank() -> void:
	var c: CanvasT = CanvasT.new(64, 48, Color.WHITE)
	_check_eq("a new canvas has the size asked for", [c.width, c.height], [64, 48])
	_check("and starts blank", _same(c.image.get_pixel(10, 10), Color.WHITE))
	_check("with nothing to undo", not c.can_undo())


func _test_dab() -> void:
	var c: CanvasT = CanvasT.new(64, 64, Color.WHITE)
	c.dab(Vector2i(32, 32), 4, Color.RED)
	_check("a dab marks its centre", _same(c.image.get_pixel(32, 32), Color.RED))
	_check("and its edge", _same(c.image.get_pixel(35, 32), Color.RED))
	_check("but is round, not square",
			_same(c.image.get_pixel(35, 35), Color.WHITE))
	_check("and leaves the rest alone", _same(c.image.get_pixel(5, 5), Color.WHITE))

	# A dab off the edge must clip, not crash or wrap.
	c.dab(Vector2i(-5, -5), 3, Color.BLUE)
	c.dab(Vector2i(1000, 1000), 3, Color.BLUE)
	_check("a dab off the canvas is clipped away", true)


## A fast drag delivers far-apart points. Dabbing only at those points would
## leave a dotted trail, which is the classic paint-program bug.
func _test_stroke_is_continuous() -> void:
	var c: CanvasT = CanvasT.new(128, 32, Color.WHITE)
	c.stroke(Vector2i(4, 16), Vector2i(120, 16), 2, Color.BLACK)
	var gaps: int = 0
	for x in range(6, 118):
		if not _same(c.image.get_pixel(x, 16), Color.BLACK):
			gaps += 1
	_check_eq("a long stroke leaves no gaps", gaps, 0)


func _test_fill() -> void:
	var c: CanvasT = CanvasT.new(32, 32, Color.WHITE)
	_check("filling a blank canvas reports a change", c.fill(Vector2i(1, 1), Color.RED))
	_check("a far corner is filled too", _same(c.image.get_pixel(31, 31), Color.RED))
	_check("filling with the colour already there does nothing",
			not c.fill(Vector2i(1, 1), Color.RED))


## The fill must stop at a drawn line, or it floods the whole picture — which
## is what "fill" means to a child holding the paint pot.
func _test_fill_respects_edges() -> void:
	var c: CanvasT = CanvasT.new(64, 64, Color.WHITE)
	c.stroke(Vector2i(32, 0), Vector2i(32, 63), 1, Color.BLACK)
	c.fill(Vector2i(5, 5), Color.GREEN)
	_check("the fill covers its own side", _same(c.image.get_pixel(20, 40), Color.GREEN))
	_check("and stops at the line", _same(c.image.get_pixel(50, 40), Color.WHITE))
	_check("leaving the line intact", _same(c.image.get_pixel(32, 40), Color.BLACK))


# ── history ─────────────────────────────────────────────────────────────────


func _test_undo_redo() -> void:
	var c: CanvasT = CanvasT.new(48, 48, Color.WHITE)
	c.begin_stroke()
	c.dab(Vector2i(24, 24), 5, Color.RED)
	c.end_stroke()
	_check("a finished stroke can be undone", c.can_undo())

	_check("undo succeeds", c.undo())
	_check("and the mark is gone", _same(c.image.get_pixel(24, 24), Color.WHITE))
	_check("with a redo now available", c.can_redo())

	_check("redo succeeds", c.redo())
	_check("and the mark is back", _same(c.image.get_pixel(24, 24), Color.RED))

	# A new stroke abandons the redo branch, and holding it would be dead weight.
	c.undo()
	c.begin_stroke()
	c.dab(Vector2i(10, 10), 3, Color.BLUE)
	c.end_stroke()
	_check("drawing after an undo drops the redo branch", not c.can_redo())


## Beginning and ending a stroke that marked nothing must not consume a slot,
## or a child tapping the canvas idly empties their history.
func _test_stray_tap_costs_no_history() -> void:
	var c: CanvasT = CanvasT.new(32, 32, Color.WHITE)
	c.begin_stroke()
	c.end_stroke()
	_check("an empty stroke records nothing", not c.can_undo())
	_check_eq("and costs no bytes", c.history_bytes(), 0)


## THE test this game exists to pass.
##
## The previous generation kept twenty full-resolution surface copies for undo
## and twenty more for redo — bounded by COUNT, roughly 240 MB at 1080p, and
## that is what killed the Pi. History here is capped in bytes as well, so no
## amount of drawing can grow it past the ceiling.
func _test_history_is_bounded_by_bytes() -> void:
	var c: CanvasT = CanvasT.new(640, 480, Color.WHITE)
	# Deliberately awful for compression: noisy strokes everywhere, which is
	# the worst case for a PNG history.
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for i in 60:
		c.begin_stroke()
		for _j in 12:
			c.stroke(Vector2i(rng.randi_range(0, 639), rng.randi_range(0, 479)),
					Vector2i(rng.randi_range(0, 639), rng.randi_range(0, 479)),
					3, Color(rng.randf(), rng.randf(), rng.randf()))
		c.end_stroke()

	_check("history never exceeds its step ceiling (%d)" % c.history_steps(),
			c.history_steps() <= CanvasT.MAX_STEPS)
	_check("history never exceeds its byte ceiling (%.1f MB of %.1f)" % [
			c.history_bytes() / 1048576.0, CanvasT.MAX_BYTES / 1048576.0],
			c.history_bytes() <= CanvasT.MAX_BYTES)
	_check("and undo still works after the cap bit", c.undo())


## A long session is the case that actually crashed the Pi, so it is played
## out rather than reasoned about: hundreds of strokes with undo and redo mixed
## in, checking the ceiling holds the whole way.
func _test_history_survives_a_long_session() -> void:
	var c: CanvasT = CanvasT.new(800, 600, Color.WHITE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var peak: int = 0
	var breached: int = 0
	for i in 400:
		c.begin_stroke()
		c.stroke(Vector2i(rng.randi_range(0, 799), rng.randi_range(0, 599)),
				Vector2i(rng.randi_range(0, 799), rng.randi_range(0, 599)),
				rng.randi_range(2, 10), Color(rng.randf(), rng.randf(), rng.randf()))
		c.end_stroke()
		if i % 7 == 0:
			c.undo()
		if i % 11 == 0:
			c.redo()
		peak = maxi(peak, c.history_bytes())
		if c.history_bytes() > CanvasT.MAX_BYTES:
			breached += 1
	_check_eq("400 strokes never breach the ceiling", breached, 0)
	_check("peak history was %.1f MB, ceiling %.1f MB" % [
			peak / 1048576.0, CanvasT.MAX_BYTES / 1048576.0], peak <= CanvasT.MAX_BYTES)
	_check("the picture is still usable afterwards", c.image.get_width() == 800)


## Why a deep history is affordable at all: a painting is mostly flat colour.
## This measures it rather than asserting it, so the day it stops being true
## the number changes in front of somebody.
func _test_compression_is_why_this_fits() -> void:
	var c: CanvasT = CanvasT.new(1280, 720, Color.WHITE)
	c.begin_stroke()
	for i in 40:
		c.stroke(Vector2i(i * 30, 40), Vector2i(i * 30, 680), 8,
				Color(float(i) / 40.0, 0.4, 0.7))
	c.end_stroke()
	var raw: int = 1280 * 720 * 4
	var png: int = c.image.save_png_to_buffer().size()
	_check("a typical picture is far smaller as PNG (%.2f MB raw -> %.2f MB)" % [
			raw / 1048576.0, png / 1048576.0], png * 4 < raw)


# ── the rest ────────────────────────────────────────────────────────────────


func _test_resize_keeps_the_drawing() -> void:
	var c: CanvasT = CanvasT.new(64, 64, Color.WHITE)
	c.dab(Vector2i(10, 10), 3, Color.RED)
	c.resize(128, 96, Color.WHITE)
	_check_eq("the canvas took the new size", [c.width, c.height], [128, 96])
	_check("and the drawing survived", _same(c.image.get_pixel(10, 10), Color.RED))
	_check("with the new area blank", _same(c.image.get_pixel(120, 90), Color.WHITE))


func _test_save_png() -> void:
	DirAccess.make_dir_recursive_absolute(SCRATCH)
	var path: String = SCRATCH + "/picture.png"
	var c: CanvasT = CanvasT.new(40, 30, Color.WHITE)
	c.dab(Vector2i(20, 15), 6, Color.RED)
	_check("saving succeeds (%s)" % c.last_error, c.save_png(path))
	_check("the file exists", FileAccess.file_exists(path))

	var back := Image.new()
	_check_eq("and reads back as a PNG", back.load(path), OK)
	_check_eq("at the right size", [back.get_width(), back.get_height()], [40, 30])
	_check("with the drawing in it", _same(back.get_pixel(20, 15), Color.RED))

	# Saving into a directory that does not exist yet must work: the pictures
	# folder will not be there on a fresh install.
	var nested: String = SCRATCH + "/deeper/still/picture.png"
	_check("saving creates missing folders", c.save_png(nested))

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(nested))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH + "/deeper/still"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH + "/deeper"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH))


func _test_publish_png() -> void:
	var c: CanvasT = CanvasT.new(1280, 720, Color.WHITE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 300:
		c.stroke(Vector2i(rng.randi_range(0, 1279), rng.randi_range(0, 719)),
				Vector2i(rng.randi_range(0, 1279), rng.randi_range(0, 719)),
				rng.randi_range(3, 30), Color(rng.randf(), rng.randf(), rng.randf()))

	var full: PackedByteArray = c.publish_png()
	var back := Image.new()
	_check_eq("the published bytes decode as a PNG", back.load_png_from_buffer(full), OK)
	_check_eq("and it is the picture at full size, not a thumbnail",
			[back.get_width(), back.get_height()], [1280, 720])

	# The finding that changed this: a bilinear downscale blurs flat colour
	# into gradients and the "smaller" image comes out BIGGER. Asserted so
	# nobody reintroduces the scaling as an optimisation.
	var blurred := Image.create_empty(1280, 720, false, Image.FORMAT_RGBA8)
	blurred.copy_from(c.image)
	blurred.resize(800, 450, Image.INTERPOLATE_BILINEAR)
	_check("scaling down with bilinear makes the PNG bigger, not smaller (%d KB vs %d KB)"
			% [blurred.save_png_to_buffer().size() / 1024, full.size() / 1024],
			blurred.save_png_to_buffer().size() > full.size())

	# Over the cap it must shrink, and it must still be a valid picture.
	var capped: PackedByteArray = c.publish_png(20 * 1024)
	_check("a picture over the cap is stepped down", capped.size() < full.size())
	var small := Image.new()
	_check_eq("and still decodes", small.load_png_from_buffer(capped), OK)
	_check("keeping its shape",
			absf(float(small.get_width()) / float(small.get_height()) - 1280.0 / 720.0) < 0.05)
	_check("and the picture itself is untouched", c.width == 1280)


## The fill writes pixels as packed int32s, which depends on the byte order of
## an RGBA8 buffer. Rather than assume it, compare a filled pixel against one
## written the ordinary way: if the packing were ever wrong, this fails instead
## of the game quietly painting the wrong colour.
func _test_fill_matches_a_drawn_pixel() -> void:
	var wanted := Color("#3498db")
	var drawn: CanvasT = CanvasT.new(8, 8, Color.WHITE)
	drawn.dab(Vector2i(4, 4), 1, wanted)
	var by_hand: Color = drawn.image.get_pixel(4, 4)

	var filled: CanvasT = CanvasT.new(8, 8, Color.WHITE)
	filled.fill(Vector2i(4, 4), wanted)
	var by_fill: Color = filled.image.get_pixel(4, 4)

	_check("a filled pixel is the same colour as a drawn one", _same(by_hand, by_fill))
	_check("and it really is the colour asked for", _same(by_fill, wanted))
	_check_eq("alpha is preserved", snappedf(by_fill.a, 0.01), 1.0)


## The eraser rubs out a BLOCK, because that is the shape drawn under the
## pointer. Showing a square while erasing a circle is a small lie a child
## would find the first time they tried to clear a corner.
func _test_square_dab() -> void:
	var c: CanvasT = CanvasT.new(64, 64, Color.WHITE)
	c.dab(Vector2i(32, 32), 6, Color.RED, true)
	_check("a square dab marks its centre", _same(c.image.get_pixel(32, 32), Color.RED))
	_check("and its straight edge", _same(c.image.get_pixel(38, 32), Color.RED))
	_check("AND its corner, where a round one would not reach",
			_same(c.image.get_pixel(38, 38), Color.RED))
	_check("but stops just outside", _same(c.image.get_pixel(39, 39), Color.WHITE))

	# The round dab is unchanged: only the eraser asks for a square.
	var round_one: CanvasT = CanvasT.new(64, 64, Color.WHITE)
	round_one.dab(Vector2i(32, 32), 6, Color.RED)
	_check("a round dab still misses the corner",
			_same(round_one.image.get_pixel(38, 38), Color.WHITE))

	# A square stroke must be continuous too, corners included.
	var line: CanvasT = CanvasT.new(96, 32, Color.WHITE)
	line.stroke(Vector2i(8, 16), Vector2i(88, 16), 5, Color.BLACK, true)
	var gaps: int = 0
	for x in range(10, 86):
		for y in [12, 16, 20]:
			if not _same(line.image.get_pixel(x, y), Color.BLACK):
				gaps += 1
	_check_eq("a square stroke leaves no gaps across its width", gaps, 0)
