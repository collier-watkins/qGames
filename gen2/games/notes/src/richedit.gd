class_name QRichEdit
extends Control

## A Markdown editor whose editing surface is the RENDERED text.
##
## Godot ships no rich-text editing control. RichTextLabel displays BBCode and
## nothing else — no caret, no text input, no editing API — so a WYSIWYG
## surface has to be built from the layout primitives underneath it. That is
## what this is: TextParagraph shapes and wraps, TextServer draws the glyphs,
## and everything above it — caret, selection, hit testing, input, undo,
## scrolling — is here.
##
## THE IDEA THAT MAKES IT WORK: the document is Markdown source, always. The
## caret is an index into that source, never into the rendered text. Every
## visible character records which source character produced it
## (QMarkdown.parse_blocks builds that map during the scan), so a click becomes
## a source index and an edit is a plain string splice followed by a reparse.
## Nothing ever converts rendered text back to Markdown — that reverse step is
## what makes most WYSIWYG editors lossy, and there is none of it here.
##
## The caret can therefore never sit inside a marker. `**` produces no visible
## character, so it has no entry in the map, so no caret position maps into it.
## Stepping right through **bold** goes b, o, l, d and then out past the
## closing asterisks.
##
## Reparsing the whole document per keystroke sounds wasteful and is not: a
## note is a few kilobytes and the scan is one pass. Shaping is the expensive
## half, and _para_cache keeps the paragraph of every line whose source text
## did not change — so a keystroke reshapes one line.

## Emitted after any edit. The document owner listens to mark itself dirty.
signal source_changed()

## Emitted when the caret or selection moves without the text changing.
signal caret_moved()

## Emitted when a [text](url) run is clicked.
signal link_clicked(url: String)

const PAD_X: float = 18.0
const PAD_Y: float = 14.0

## Extra breathing room above a block, by kind. Headings get the most; a run of
## list items gets none so the list reads as one object.
const SPACE_BEFORE: Dictionary = {
	QMarkdown.Block.HEADING: 14.0,
	QMarkdown.Block.RULE: 10.0,
	QMarkdown.Block.QUOTE: 4.0,
}

## Indent per nesting level for lists and quotes.
const INDENT_STEP: float = 26.0

## Width reserved for a list marker in the gutter.
const MARKER_W: float = 24.0

## Fake-bold weight and fake-italic shear, used when the base font has no real
## bold or italic face — which is the normal case for Godot's default font.
##
## The shear goes in the x axis's Y component, NOT the y axis's X component.
## The latter is the intuitive reading of "shear x by y" and it renders as a
## sagging, jittery mess rather than a lean; the sign matters too, since the
## negative leans the text backwards. Both were established by rendering all
## four combinations and looking at them.
const BOLD_EMBOLDEN: float = 0.55
const ITALIC_SKEW: float = 0.22

## Caret blink period. The redraw happens only when the state flips, never per
## frame: an idle caret that repainted every frame is exactly the mistake that
## doubled this platform's CPU once already.
const BLINK_SEC: float = 0.55

## Keystrokes closer together than this coalesce into one undo entry, so undo
## steps back by a word or so rather than by a character.
const UNDO_COALESCE_MSEC: int = 700
const UNDO_DEPTH: int = 120

## Scroll distance per wheel notch.
const WHEEL_STEP: float = 64.0

const CARET_W: float = 2.0

const SCROLLBAR_W: float = 5.0

## Width of the highlight stub that shows a selected newline.
const EOL_SEL_W: float = 8.0

var base_font_size: int = 17

var col_bg: Color = Color(0.0706, 0.1020, 0.1804)
var col_text: Color = Color(0.8784, 0.9098, 0.9686)
var col_dim: Color = Color(0.6275, 0.7255, 0.9020)
var col_accent: Color = Color(0.9412, 0.7843, 0.1961)
var col_code: Color = Color(0.5608, 0.8275, 0.7529)
var col_code_bg: Color = Color(1, 1, 1, 0.0471)
var col_link: Color = Color(0.4941, 0.7451, 0.9882)
var col_sel: Color = Color(0.2588, 0.4392, 0.7059, 0.5490)
var col_caret: Color = Color(0.9412, 0.7843, 0.1961)
var col_rule: Color = Color(0.2353, 0.3059, 0.4706)
var col_scroll_track: Color = Color(1, 1, 1, 0.0392)
var col_scroll_grip: Color = Color(1, 1, 1, 0.1961)

var _source: String = ""
var _blocks: Array = []
var _rows: Array = []
var _vlines: Array = []
var _content_h: float = 0.0

var _caret: int = 0
var _anchor: int = -1
## Remembered x for up/down, so walking through a short line and back out does
## not drag the caret left. -1 means "take it from the caret's current x".
var _goal_x: float = -1.0

var _scroll: float = 0.0
var _dragging: bool = false
var _blink_t: float = 0.0
var _blink_on: bool = true

var _undo: Array = []
var _redo: Array = []
var _last_edit_msec: int = 0
var _undo_open: bool = false

var _para_cache: Dictionary = {}
## Parsed lines, keyed by text. Survives between keystrokes so typing reparses
## the one line that changed instead of the whole note.
var _block_cache: Dictionary = {}
var _cache_width: float = -1.0
var _cache_size: int = -1

var _f_base: Font
var _f_bold: Font
var _f_italic: Font
var _f_bold_italic: Font
var _f_mono: Font


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_IBEAM
	_build_fonts()
	resized.connect(_on_resized)
	focus_entered.connect(_on_focus_entered)
	focus_exited.connect(_on_focus_exited)
	set_process(false)
	_relayout()


func _build_fonts() -> void:
	_f_base = get_theme_default_font()
	if _f_base == null:
		_f_base = ThemeDB.fallback_font

	# Godot's default font has no bold or italic face. FontVariation fakes both
	# from the base outline, which is what RichTextLabel does for [b] and [i] —
	# so the editor and the BBCode preview weigh their text the same way.
	_f_bold = make_variation(_f_base, BOLD_EMBOLDEN, 0.0)
	_f_italic = make_variation(_f_base, 0.0, ITALIC_SKEW)
	_f_bold_italic = make_variation(_f_base, BOLD_EMBOLDEN, ITALIC_SKEW)

	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["monospace", "Monospace",
			"DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono",
			"Courier New"])
	_f_mono = mono


## Synthesise a bold or italic face from a base font. Public because the
## toolbar draws its B and I buttons with the same faces the editor uses.
static func make_variation(base: Font, embolden: float, skew: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = base
	fv.variation_embolden = embolden
	if skew != 0.0:
		fv.variation_transform = Transform2D(Vector2(1.0, skew),
				Vector2(0.0, 1.0), Vector2.ZERO)
	return fv


# ── Document ────────────────────────────────────────────────────────────────


func get_source() -> String:
	return _source


## Replace the whole document. `keep_caret` is for a reload of the same text;
## a genuinely new document should start at the top with an empty undo stack.
func set_source(value: String, keep_caret: bool = false) -> void:
	_source = value
	if not keep_caret:
		_caret = 0
		_anchor = -1
		_scroll = 0.0
		_undo.clear()
		_redo.clear()
	_caret = clampi(_caret, 0, _source.length())
	# Close any open coalescing group: the next keystroke starts a new undo
	# entry rather than joining one recorded against different text.
	_undo_open = false
	_para_cache.clear()
	_relayout()
	_clamp_scroll()
	queue_redraw()


func caret_index() -> int:
	return _caret


func has_selection() -> bool:
	return _anchor >= 0 and _anchor != _caret


## The selection as a sorted [from, to). Collapses to [caret, caret) when there
## is no selection, so callers never need to branch.
func selection() -> Vector2i:
	if not has_selection():
		return Vector2i(_caret, _caret)
	return Vector2i(mini(_anchor, _caret), maxi(_anchor, _caret))


func selected_text() -> String:
	var s: Vector2i = selection()
	return _source.substr(s.x, s.y - s.x)


func select_all() -> void:
	_anchor = 0
	_caret = _source.length()
	_goal_x = -1.0
	_after_move()


# ── Editing ─────────────────────────────────────────────────────────────────


## Every edit funnels through here, which is what keeps undo honest: there is
## exactly one place that mutates _source.
func replace_range(from: int, to: int, with_text: String, coalesce: bool = false) -> void:
	from = clampi(from, 0, _source.length())
	to = clampi(to, from, _source.length())
	if from == to and with_text == "":
		return
	_push_undo(coalesce)
	_source = _source.substr(0, from) + with_text + _source.substr(to)
	_caret = from + with_text.length()
	_anchor = -1
	_goal_x = -1.0
	_relayout()
	_ensure_caret_visible()
	queue_redraw()
	source_changed.emit()


func insert_text(s: String, coalesce: bool = false) -> void:
	var sel: Vector2i = selection()
	replace_range(sel.x, sel.y, s, coalesce and not has_selection())


func delete_selection() -> bool:
	if not has_selection():
		return false
	var sel: Vector2i = selection()
	replace_range(sel.x, sel.y, "")
	return true


func _backspace() -> void:
	if delete_selection():
		return
	if _caret <= 0:
		return
	# Delete ONE SOURCE CHARACTER, at the previous caret stop — not the whole
	# span between the stops. The two differ exactly where markers sit between
	# them: with the caret after the b in `a **b** c`, the previous stop is the
	# b itself, and deleting the span would take `b**` and leave a dangling
	# opener. Deleting one character takes the b and leaves the emphasis empty,
	# which is what "backspace removes a character" has to mean.
	# At the START of a block's own text, backspace strips the block's marker
	# rather than joining lines. Without this a `- ` or a `# ` could never be
	# deleted at all: markers have no visible character, so no caret position
	# maps into them, and the caret would step straight past to the line above —
	# leaving a marker on screen with no way to remove it.
	var bi: int = _block_at(_caret)
	if bi >= 0:
		var b: Dictionary = _blocks[bi]
		var body: int = int(b["body_from"])
		if body > int(b["src_from"]) and _vis_index(b, _caret) == 0:
			replace_range(int(b["src_from"]), body, "")
			return

	var prev: int = _prev_caret_stop(_caret)
	if prev >= _caret and prev >= _source.length():
		return
	replace_range(prev, prev + 1, "", true)


func _delete_forward() -> void:
	if delete_selection():
		return
	if _caret >= _source.length():
		return
	# The caret already sits on a source position that is either a visible
	# character or the newline ending the block, so forward-delete is one
	# character from here. Same reasoning as _backspace.
	replace_range(_caret, _caret + 1, "", true)


## Undo snapshots the whole document. A note is small enough that this is
## cheaper than tracking deltas and impossible to get subtly wrong.
func _push_undo(coalesce: bool) -> void:
	var now: int = Time.get_ticks_msec()
	# _undo must be non-empty to coalesce INTO something. Without that test a
	# group left open before the history was cleared swallows the first
	# snapshot of the next document, and undo silently does nothing.
	if coalesce and _undo_open and not _undo.is_empty() \
			and now - _last_edit_msec < UNDO_COALESCE_MSEC:
		_last_edit_msec = now
		return
	_undo.append({"text": _source, "caret": _caret})
	if _undo.size() > UNDO_DEPTH:
		_undo.pop_front()
	_redo.clear()
	_last_edit_msec = now
	_undo_open = true


func undo() -> void:
	if _undo.is_empty():
		return
	_redo.append({"text": _source, "caret": _caret})
	var s: Dictionary = _undo.pop_back()
	_apply_snapshot(s)


func redo() -> void:
	if _redo.is_empty():
		return
	_undo.append({"text": _source, "caret": _caret})
	var s: Dictionary = _redo.pop_back()
	_apply_snapshot(s)


func _apply_snapshot(s: Dictionary) -> void:
	_source = str(s["text"])
	_caret = clampi(int(s["caret"]), 0, _source.length())
	_anchor = -1
	_undo_open = false
	_relayout()
	_ensure_caret_visible()
	queue_redraw()
	source_changed.emit()


## Wrap or unwrap the selection in `marker` (** or *). With no selection this
## acts on the word under the caret, which is what a reader expects Ctrl+B to
## do mid-word.
func toggle_wrap(marker: String) -> void:
	var sel: Vector2i = selection()
	if sel.x == sel.y:
		sel = _word_at(_caret)
	if sel.x == sel.y:
		return
	var before: String = _source.substr(sel.x, sel.y - sel.x)
	var after: String = QMarkdown.toggle_wrap(before, marker)
	_push_undo(false)
	_source = _source.substr(0, sel.x) + after + _source.substr(sel.y)
	# Keep the same words selected, not the same offsets — the markers moved.
	var delta: int = after.length() - before.length()
	_anchor = sel.x
	_caret = sel.y + delta
	_relayout()
	_ensure_caret_visible()
	queue_redraw()
	source_changed.emit()


## Add or remove a line prefix ("# ", "- ", "> ") on every line the selection
## touches.
func toggle_line_prefix(prefix: String) -> void:
	var sel: Vector2i = selection()
	var first: int = _line_start(sel.x)
	var last: int = _line_end(sel.y)
	var body: String = _source.substr(first, last - first)
	var out: PackedStringArray = PackedStringArray()
	for line in body.split("\n"):
		out.append(QMarkdown.toggle_line_prefix(line, prefix))
	var joined: String = "\n".join(out)
	_push_undo(false)
	_source = _source.substr(0, first) + joined + _source.substr(last)
	_anchor = -1
	_caret = clampi(_caret + (joined.length() - body.length()), first,
			first + joined.length())
	_relayout()
	_ensure_caret_visible()
	queue_redraw()
	source_changed.emit()


func _line_start(i: int) -> int:
	var nl: int = _source.rfind("\n", maxi(0, i - 1))
	if i == 0 or nl == -1:
		return 0
	return nl + 1 if nl < i else 0


func _line_end(i: int) -> int:
	var nl: int = _source.find("\n", i)
	return _source.length() if nl == -1 else nl


func _word_at(i: int) -> Vector2i:
	var n: int = _source.length()
	if n == 0:
		return Vector2i(0, 0)
	var from: int = clampi(i, 0, n)
	var to: int = from
	while from > 0 and _is_word(_source[from - 1]):
		from -= 1
	while to < n and _is_word(_source[to]):
		to += 1
	return Vector2i(from, to)


static func _is_word(c: String) -> bool:
	return not " \t\n".contains(c)


# ── Layout ──────────────────────────────────────────────────────────────────


func _on_resized() -> void:
	_para_cache.clear()
	_relayout()
	_clamp_scroll()
	queue_redraw()


func _relayout() -> void:
	# Fonts are built lazily rather than only in _ready(), so the editor lays
	# out correctly before it is in a tree — which is what lets the test suite
	# drive it headless instead of only through a running game.
	if _f_base == null:
		_build_fonts()
	_blocks = QMarkdown.parse_blocks(_source, _block_cache)
	var avail: float = maxf(64.0, size.x - PAD_X * 2.0)
	if not is_equal_approx(avail, _cache_width) or _cache_size != base_font_size:
		_para_cache.clear()
		_cache_width = avail
		_cache_size = base_font_size

	var fresh: Dictionary = {}
	_rows.clear()
	var y: float = PAD_Y

	for i in _blocks.size():
		var b: Dictionary = _blocks[i]
		var kind: int = int(b["kind"])
		var indent: float = _indent_for(b)
		var key: String = "%d|%d|%s" % [kind, int(b["level"]),
				_source.substr(int(b["src_from"]), int(b["src_to"]) - int(b["src_from"]))]

		var para: TextParagraph
		if fresh.has(key):
			# Identical lines SHARE one paragraph. A TextParagraph holds shaped
			# text and nothing positional — where it is drawn lives in _rows — so
			# two lines reading the same wrap the same and can reuse the shaping.
			# Reshaping each repeat instead was costing a document with sixty
			# identical list items sixty shapings on every keystroke.
			para = fresh[key]
		elif _para_cache.has(key):
			para = _para_cache[key]
		else:
			para = _make_paragraph(b, avail - indent)
		fresh[key] = para

		if i > 0:
			y += float(SPACE_BEFORE.get(kind, 0.0))
		var h: float = para.get_size().y
		_rows.append({"para": para, "y": y, "h": h,
				"x": PAD_X + indent, "empty": (b["runs"] as Array).is_empty()})
		y += h

	_para_cache = fresh
	_content_h = y + PAD_Y
	_build_vlines()


func _make_paragraph(b: Dictionary, width: float) -> TextParagraph:
	var para := TextParagraph.new()
	para.set_width(maxf(32.0, width))
	var kind: int = int(b["kind"])
	var fs: int = _size_for(b)
	var runs: Array = b["runs"]
	if runs.is_empty():
		# An empty line still needs height, or the caret would sit in a
		# zero-tall row and the document would jump as you typed into it.
		para.add_string(" ", _f_base, fs)
	else:
		for r in runs:
			para.add_string(str(r["text"]), _font_for(r, kind), fs)
	return para


func _size_for(b: Dictionary) -> int:
	if int(b["kind"]) == QMarkdown.Block.HEADING:
		var lvl: int = clampi(int(b["level"]), 1, 6)
		# HEADING_SIZES is written against a ~16px body; rescale so changing
		# base_font_size moves headings with it.
		var ratio: float = float(QMarkdown.HEADING_SIZES[lvl - 1]) / 16.0
		return int(round(float(base_font_size) * ratio))
	return base_font_size


func _indent_for(b: Dictionary) -> float:
	match int(b["kind"]):
		QMarkdown.Block.BULLET, QMarkdown.Block.ORDERED:
			return MARKER_W + INDENT_STEP * float(b["level"])
		QMarkdown.Block.QUOTE:
			return INDENT_STEP * float(b["level"])
		QMarkdown.Block.CODE:
			return INDENT_STEP * 0.5
	return 0.0


func _font_for(run: Dictionary, kind: int) -> Font:
	if bool(run["code"]):
		return _f_mono
	var bold: bool = bool(run["bold"]) or kind == QMarkdown.Block.HEADING
	var italic: bool = bool(run["italic"]) or kind == QMarkdown.Block.QUOTE
	if bold and italic:
		return _f_bold_italic
	if bold:
		return _f_bold
	if italic:
		return _f_italic
	return _f_base


func _color_for(run: Dictionary, kind: int) -> Color:
	if str(run["link"]) != "":
		return col_link
	if bool(run["code"]):
		return col_code
	if kind == QMarkdown.Block.QUOTE:
		return col_dim
	if kind == QMarkdown.Block.HEADING:
		return col_text
	return col_text


# ── Source <-> visible mapping ──────────────────────────────────────────────


## The block containing a source index: the last one that starts at or before
## it. Blocks tile the document with no gaps, so this is total.
func _block_at(src: int) -> int:
	if _blocks.is_empty():
		return -1
	var lo: int = 0
	var hi: int = _blocks.size() - 1
	while lo < hi:
		var mid: int = (lo + hi + 1) / 2
		if int(_blocks[mid]["src_from"]) <= src:
			lo = mid
		else:
			hi = mid - 1
	return lo


## Visible index within a block for a source index: the first visible character
## whose source position is at or past `src`. Because markers have no entry in
## the map, a source index inside one resolves to the next visible character —
## the caret slides out of the marker rather than into it.
## `map` holds offsets relative to the block's own line, so both directions go
## through src_from. That relativity is what lets an unchanged line stay a
## parse-cache hit after something above it grew.
static func _vis_index(b: Dictionary, src: int) -> int:
	var map: PackedInt32Array = b["map"]
	var target: int = src - int(b["src_from"])
	var lo: int = 0
	var hi: int = map.size() - 1
	while lo < hi:
		var mid: int = (lo + hi) / 2
		if map[mid] < target:
			lo = mid + 1
		else:
			hi = mid
	return lo


## Snap an arbitrary source index to the nearest legal caret position.
##
## Not every source index is one: the `#` of a heading and the `**` of an
## emphasis have no visible character, so the caret cannot be there. Anything
## arriving from outside — Ctrl+Home, a set_caret() call, a restored
## selection — has to be pulled onto a real stop, or the caret would be drawn
## against one character while typing inserted text at another.
func _canonical(src: int) -> int:
	var bi: int = _block_at(src)
	if bi < 0:
		return clampi(src, 0, _source.length())
	var b: Dictionary = _blocks[bi]
	return _src_index(b, _vis_index(b, src))


static func _src_index(b: Dictionary, vis: int) -> int:
	var map: PackedInt32Array = b["map"]
	return int(b["src_from"]) + map[clampi(vis, 0, map.size() - 1)]


## The next place the caret may legally stop, walking forward. Source indices
## inside a marker are not caret stops, so this is not simply caret + 1.
func _next_caret_stop(src: int) -> int:
	var bi: int = _block_at(src)
	if bi < 0:
		return src
	var b: Dictionary = _blocks[bi]
	var map: PackedInt32Array = b["map"]
	var vis: int = _vis_index(b, src)
	if vis < map.size() - 1:
		return _src_index(b, vis + 1)
	# Past the last visible character: step over the newline into the next block.
	if bi + 1 < _blocks.size():
		return int(_blocks[bi + 1]["src_from"])
	return _source.length()


func _prev_caret_stop(src: int) -> int:
	var bi: int = _block_at(src)
	if bi < 0:
		return src
	var b: Dictionary = _blocks[bi]
	var map: PackedInt32Array = b["map"]
	var vis: int = _vis_index(b, src)
	if vis > 0:
		return _src_index(b, vis - 1)
	if bi > 0:
		var prev: Dictionary = _blocks[bi - 1]
		return _src_index(prev, (prev["map"] as PackedInt32Array).size() - 1)
	return 0


# ── Visual lines ────────────────────────────────────────────────────────────
#
# A block wraps into one or more visual lines. Up/Down, Home/End and Page
# Up/Down all move by VISUAL line, not by block — anything else feels broken
# the moment a paragraph wraps. _vlines is that flattened list, rebuilt with
# the layout.


func _build_vlines() -> void:
	_vlines.clear()
	for i in _rows.size():
		var row: Dictionary = _rows[i]
		var para: TextParagraph = row["para"]
		row["vl0"] = _vlines.size()
		var y: float = float(row["y"])
		for line in para.get_line_count():
			var r: Vector2i = para.get_line_range(line)
			var lh: float = para.get_line_size(line).y
			_vlines.append({"bi": i, "line": line, "y": y, "h": lh,
					"from": r.x, "to": r.y})
			y += lh
		row["vln"] = _vlines.size() - int(row["vl0"])


## Which visual line holds a source index. At a soft wrap the position belongs
## to the start of the following line, which is where a reader expects to see
## the caret after typing the character that caused the wrap.
func _vline_index(src: int) -> int:
	var bi: int = _block_at(src)
	if bi < 0 or bi >= _rows.size():
		return 0
	var b: Dictionary = _blocks[bi]
	var row: Dictionary = _rows[bi]
	var vis: int = _vis_index(b, src)
	var first: int = int(row["vl0"])
	var count: int = int(row["vln"])
	for k in count:
		var vl: Dictionary = _vlines[first + k]
		if vis < int(vl["to"]) or k == count - 1:
			return first + k
	return first


## Where in the source a click at visual-line `vi`, x pixels across, lands.
func _src_in_vline(vi: int, x: float) -> int:
	vi = clampi(vi, 0, _vlines.size() - 1)
	var vl: Dictionary = _vlines[vi]
	var bi: int = int(vl["bi"])
	var b: Dictionary = _blocks[bi]
	var row: Dictionary = _rows[bi]
	if bool(row["empty"]):
		return int(b["src_from"])
	var para: TextParagraph = row["para"]
	# hit_test takes paragraph-local coordinates; aim at the middle of the row
	# so the answer cannot drift onto a neighbouring line.
	var local := Vector2(x - float(row["x"]),
			float(vl["y"]) - float(row["y"]) + float(vl["h"]) * 0.5)
	var vis: int = clampi(para.hit_test(local), 0, str(b["text"]).length())
	return _src_index(b, vis)


## Caret geometry in content coordinates.
func _caret_rect(src: int) -> Rect2:
	if _rows.is_empty():
		return Rect2(PAD_X, PAD_Y, CARET_W, float(base_font_size))
	var vi: int = _vline_index(src)
	var vl: Dictionary = _vlines[vi]
	var bi: int = int(vl["bi"])
	var b: Dictionary = _blocks[bi]
	var row: Dictionary = _rows[bi]
	if bool(row["empty"]):
		return Rect2(float(row["x"]), float(vl["y"]), CARET_W, float(vl["h"]))
	var vis: int = _vis_index(b, src)
	var x: float = _x_at(row, vl, vis)
	return Rect2(float(row["x"]) + x, float(vl["y"]), CARET_W, float(vl["h"]))


## X offset of a visible index within one visual line.
##
## shaped_text_get_grapheme_bounds(rid, v) returns the bounds of the grapheme
## ENDING at v, so its `y` component is the width of the first v characters —
## which is exactly the caret x. At the first index of a line there is no
## preceding grapheme on that line, so the answer is 0. Both were measured
## against this Godot build rather than assumed; an off-by-one here would put
## the caret one character away from the click for the life of the editor.
func _x_at(row: Dictionary, vl: Dictionary, vis: int) -> float:
	var from: int = int(vl["from"])
	var to: int = int(vl["to"])
	if vis <= from:
		return 0.0
	var para: TextParagraph = row["para"]
	var ts: TextServer = TextServerManager.get_primary_interface()
	return ts.shaped_text_get_grapheme_bounds(
			para.get_line_rid(int(vl["line"])), mini(vis, to)).y


# ── Scrolling ───────────────────────────────────────────────────────────────


func _clamp_scroll() -> void:
	_scroll = clampf(_scroll, 0.0, maxf(0.0, _content_h - size.y))


func _scroll_by(amount: float) -> void:
	var before: float = _scroll
	_scroll += amount
	_clamp_scroll()
	if not is_equal_approx(before, _scroll):
		queue_redraw()


func _ensure_caret_visible() -> void:
	var r: Rect2 = _caret_rect(_caret)
	var top: float = r.position.y - PAD_Y
	var bottom: float = r.position.y + r.size.y + PAD_Y
	if top < _scroll:
		_scroll = top
	elif bottom > _scroll + size.y:
		_scroll = bottom - size.y
	_clamp_scroll()


# ── Drawing ─────────────────────────────────────────────────────────────────


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), col_bg)
	if _rows.is_empty():
		return
	var sel: Vector2i = selection()
	var showing_sel: bool = has_selection()

	for i in _rows.size():
		var row: Dictionary = _rows[i]
		var b: Dictionary = _blocks[i]
		var y: float = float(row["y"]) - _scroll
		if y + float(row["h"]) < -32.0 or y > size.y + 32.0:
			continue
		_draw_decorations(b, row, y)
		if showing_sel:
			_draw_selection(i, b, row, sel, y)
		_draw_glyphs(b, row, Vector2(float(row["x"]), y))

	_draw_scrollbar()

	if has_focus() and _blink_on and not showing_sel:
		var c: Rect2 = _caret_rect(_caret)
		c.position.y -= _scroll
		draw_rect(c, col_caret)


## Everything that is not text: quote bars, code backgrounds, list markers and
## horizontal rules.
func _draw_decorations(b: Dictionary, row: Dictionary, y: float) -> void:
	var kind: int = int(b["kind"])
	var h: float = float(row["h"])

	match kind:
		QMarkdown.Block.RULE:
			var mid: float = y + h * 0.5
			draw_line(Vector2(PAD_X, mid), Vector2(size.x - PAD_X, mid),
					col_rule, 2.0)
		QMarkdown.Block.QUOTE:
			var bx: float = PAD_X + INDENT_STEP * float(b["level"]) - 12.0
			draw_rect(Rect2(bx, y, 3.0, h), col_rule)
		QMarkdown.Block.CODE:
			draw_rect(Rect2(PAD_X * 0.5, y, size.x - PAD_X, h), col_code_bg)
		QMarkdown.Block.BULLET, QMarkdown.Block.ORDERED:
			var marker: String = str(b["marker"])
			if marker != "":
				var mx: float = float(row["x"]) - MARKER_W
				var asc: float = (row["para"] as TextParagraph).get_line_ascent(0)
				draw_string(_f_base, Vector2(mx, y + asc), marker,
						HORIZONTAL_ALIGNMENT_LEFT, MARKER_W - 4.0,
						base_font_size, col_dim)


## Per-run colour is why this draws glyph by glyph instead of calling
## TextParagraph.draw(): that method paints the whole paragraph in one colour,
## and a code span or link has to differ from the prose around it. Each glyph
## reports the span index it came from, so the colour lookup is direct.
func _draw_glyphs(b: Dictionary, row: Dictionary, at: Vector2) -> void:
	var runs: Array = b["runs"]
	if runs.is_empty():
		return
	var ts: TextServer = TextServerManager.get_primary_interface()
	var para: TextParagraph = row["para"]
	var kind: int = int(b["kind"])
	var ci: RID = get_canvas_item()
	var y: float = at.y

	for line in para.get_line_count():
		var rid: RID = para.get_line_rid(line)
		var pen := Vector2(at.x, y + para.get_line_ascent(line))
		for g in ts.shaped_text_get_glyphs(rid):
			var span: int = int(g["span_index"])
			var colour: Color = col_text
			if span >= 0 and span < runs.size():
				colour = _color_for(runs[span], kind)
			var frid: RID = g["font_rid"]
			var advance: float = float(g["advance"])
			for _rep in maxi(1, int(g["repeat"])):
				if frid.is_valid():
					ts.font_draw_glyph(frid, ci, int(g["font_size"]),
							pen + g["offset"], int(g["index"]), colour, 0.0)
				pen.x += advance
		y += para.get_line_size(line).y


func _draw_selection(bi: int, b: Dictionary, row: Dictionary,
		sel: Vector2i, y: float) -> void:
	var src_from: int = int(b["src_from"])
	var src_to: int = int(b["src_to"])
	if sel.y < src_from or sel.x > src_to:
		return
	# The selection running past this line means the newline is inside it, so
	# the highlight gets a stub past the last character to show that.
	var eol: bool = sel.y > src_to
	var vf: int = _vis_index(b, sel.x)
	var vt: int = _vis_index(b, sel.y)
	if vf == vt and not eol:
		return

	if bool(row["empty"]):
		draw_rect(Rect2(float(row["x"]), y, EOL_SEL_W, float(row["h"])), col_sel)
		return

	var first: int = int(row["vl0"])
	for k in int(row["vln"]):
		var vl: Dictionary = _vlines[first + k]
		var lo: int = maxi(vf, int(vl["from"]))
		var hi: int = mini(vt, int(vl["to"]))
		var last_line: bool = k == int(row["vln"]) - 1
		if lo >= hi and not (eol and last_line):
			continue
		var x0: float = _x_at(row, vl, lo)
		var x1: float = _x_at(row, vl, maxi(hi, lo))
		if eol and last_line:
			x1 += EOL_SEL_W
		draw_rect(Rect2(float(row["x"]) + x0, float(vl["y"]) - _scroll,
				maxf(x1 - x0, 1.0), float(vl["h"])), col_sel)


## A slim track on the right edge, drawn only when there is something below
## the fold. Without it a note that runs past the pane looks like it simply
## ends — the wheel works either way, but nothing says so.
func _draw_scrollbar() -> void:
	var overflow: float = _content_h - size.y
	if overflow <= 1.0:
		return
	var track := Rect2(size.x - SCROLLBAR_W - 3.0, 2.0, SCROLLBAR_W, size.y - 4.0)
	draw_rect(track, col_scroll_track)
	var frac: float = clampf(size.y / _content_h, 0.06, 1.0)
	var grip_h: float = track.size.y * frac
	var travel: float = track.size.y - grip_h
	var at: float = travel * clampf(_scroll / overflow, 0.0, 1.0)
	draw_rect(Rect2(track.position.x, track.position.y + at,
			track.size.x, grip_h), col_scroll_grip)


func _process(delta: float) -> void:
	_blink_t += delta
	if _blink_t >= BLINK_SEC:
		_blink_t = 0.0
		_blink_on = not _blink_on
		# Redraw only on the flip. A caret that queued a redraw every frame
		# would repaint the whole document sixty times a second for nothing.
		queue_redraw()


func _on_focus_entered() -> void:
	_blink_t = 0.0
	_blink_on = true
	set_process(true)
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_show(_source, Rect2(), 
				DisplayServer.KEYBOARD_TYPE_MULTILINE)
	queue_redraw()


func _on_focus_exited() -> void:
	set_process(false)
	_blink_on = false
	_dragging = false
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_hide()
	queue_redraw()


# ── Input ───────────────────────────────────────────────────────────────────


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion and _dragging:
		_caret = _source_at_point((event as InputEventMouseMotion).position)
		_goal_x = -1.0
		_after_move()
		accept_event()
	elif event is InputEventKey and (event as InputEventKey).pressed:
		_key(event as InputEventKey)


func _source_at_point(p: Vector2) -> int:
	if _vlines.is_empty():
		return 0
	var y: float = p.y + _scroll
	var vi: int = _vlines.size() - 1
	for i in _vlines.size():
		var vl: Dictionary = _vlines[i]
		if y < float(vl["y"]) + float(vl["h"]):
			vi = i
			break
	return _src_in_vline(vi, p.x)


func _mouse_button(e: InputEventMouseButton) -> void:
	match e.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if e.pressed:
				_scroll_by(-WHEEL_STEP * e.factor if e.factor > 0.0 else -WHEEL_STEP)
				accept_event()
		MOUSE_BUTTON_WHEEL_DOWN:
			if e.pressed:
				_scroll_by(WHEEL_STEP * e.factor if e.factor > 0.0 else WHEEL_STEP)
				accept_event()
		MOUSE_BUTTON_LEFT:
			if e.pressed:
				grab_focus()
				var at: int = _source_at_point(e.position)
				if e.ctrl_pressed:
					var url: String = _link_at(at)
					if url != "":
						link_clicked.emit(url)
						accept_event()
						return
				if e.double_click:
					var w: Vector2i = _word_at(at)
					_anchor = w.x
					_caret = w.y
				elif e.shift_pressed:
					if _anchor < 0:
						_anchor = _caret
					_caret = at
				else:
					_anchor = -1
					_caret = at
					_dragging = true
				_goal_x = -1.0
				_after_move()
			else:
				_dragging = false
			accept_event()


func _link_at(src: int) -> String:
	var bi: int = _block_at(src)
	if bi < 0:
		return ""
	var b: Dictionary = _blocks[bi]
	var vis: int = _vis_index(b, src)
	var seen: int = 0
	for r in b["runs"]:
		seen += str(r["text"]).length()
		if vis < seen:
			return str(r["link"])
	return ""


func _key(e: InputEventKey) -> void:
	var extend: bool = e.shift_pressed
	var ctrl: bool = e.ctrl_pressed or e.meta_pressed

	if ctrl:
		match e.keycode:
			KEY_A: select_all(); accept_event(); return
			KEY_C: _copy(); accept_event(); return
			KEY_X: _copy(); delete_selection(); accept_event(); return
			KEY_V: _paste(); accept_event(); return
			KEY_Z:
				if extend: redo()
				else: undo()
				accept_event(); return
			KEY_Y: redo(); accept_event(); return
			KEY_B: toggle_wrap("**"); accept_event(); return
			KEY_I: toggle_wrap("*"); accept_event(); return
			KEY_HOME: _move_to(0, extend); accept_event(); return
			KEY_END: _move_to(_source.length(), extend); accept_event(); return

	match e.keycode:
		KEY_LEFT:
			_move_to(_prev_caret_stop(_caret), extend); accept_event(); return
		KEY_RIGHT:
			_move_to(_next_caret_stop(_caret), extend); accept_event(); return
		KEY_UP:
			_move_vertical(-1, extend); accept_event(); return
		KEY_DOWN:
			_move_vertical(1, extend); accept_event(); return
		KEY_PAGEUP:
			_move_page(-1, extend); accept_event(); return
		KEY_PAGEDOWN:
			_move_page(1, extend); accept_event(); return
		KEY_HOME:
			_move_to(_line_edge(false), extend); accept_event(); return
		KEY_END:
			_move_to(_line_edge(true), extend); accept_event(); return
		KEY_BACKSPACE:
			_backspace(); accept_event(); return
		KEY_DELETE:
			_delete_forward(); accept_event(); return
		KEY_ENTER, KEY_KP_ENTER:
			_newline(); accept_event(); return
		KEY_TAB:
			# Tab indents inside a list or a code block, where an indent is
			# what it means. Everywhere else it moves focus, so the toolbar
			# stays reachable from the keyboard without a secret handshake.
			if _tab_indents():
				_indent(not e.shift_pressed)
				accept_event()
			return
		# Escape is deliberately NOT handled here. It has three jobs in this
		# game — close a modal, leave the editor, quit — and only the game root
		# can tell which one applies. Swallowing it here would strand the writer
		# with no keyboard way out of the editor.

	if e.unicode >= 32 and not ctrl:
		insert_text(String.chr(e.unicode), true)
		accept_event()


func _copy() -> void:
	if has_selection():
		DisplayServer.clipboard_set(selected_text())


func _paste() -> void:
	var s: String = DisplayServer.clipboard_get()
	if s != "":
		insert_text(s)


func _move_to(src: int, extend: bool) -> void:
	if extend:
		if _anchor < 0:
			_anchor = _caret
	else:
		_anchor = -1
	_caret = _canonical(clampi(src, 0, _source.length()))
	_goal_x = -1.0
	_after_move()


func _move_vertical(dir: int, extend: bool) -> void:
	var vi: int = _vline_index(_caret)
	if _goal_x < 0.0:
		var vl: Dictionary = _vlines[vi]
		var row: Dictionary = _rows[int(vl["bi"])]
		_goal_x = float(row["x"]) + _x_at(row, vl, _vis_index(
				_blocks[int(vl["bi"])], _caret))
	var target: int = vi + dir
	if target < 0 or target >= _vlines.size():
		_move_to(0 if dir < 0 else _source.length(), extend)
		return
	var goal: float = _goal_x
	if extend and _anchor < 0:
		_anchor = _caret
	elif not extend:
		_anchor = -1
	_caret = _src_in_vline(target, goal)
	_goal_x = goal
	_after_move()


func _move_page(dir: int, extend: bool) -> void:
	var lines: int = maxi(1, int(size.y / maxf(1.0, float(base_font_size) * 1.6)) - 1)
	for _i in lines:
		_move_vertical(dir, extend)


## Start or end of the VISUAL line, so Home on a wrapped paragraph goes to the
## start of the row you are looking at rather than the top of the paragraph.
func _line_edge(to_end: bool) -> int:
	if _vlines.is_empty():
		return 0
	var vl: Dictionary = _vlines[_vline_index(_caret)]
	var b: Dictionary = _blocks[int(vl["bi"])]
	var vis: int = int(vl["to"]) if to_end else int(vl["from"])
	return _src_index(b, vis)


func _after_move() -> void:
	_blink_t = 0.0
	_blink_on = true
	_ensure_caret_visible()
	queue_redraw()
	caret_moved.emit()


## Enter continues a list: the next line starts with the same marker, with an
## ordered list's number bumped. Enter on an EMPTY item leaves the list instead
## of making another one, which is the behaviour every editor has trained
## people to expect.
func _newline() -> void:
	var bi: int = _block_at(_caret)
	if bi >= 0 and not has_selection():
		var b: Dictionary = _blocks[bi]
		var kind: int = int(b["kind"])
		if kind == QMarkdown.Block.BULLET or kind == QMarkdown.Block.ORDERED:
			if str(b["text"]).strip_edges() == "":
				replace_range(int(b["src_from"]), int(b["src_to"]), "")
				return
			insert_text("\n" + _next_list_prefix(b))
			return
	insert_text("\n")


func _next_list_prefix(b: Dictionary) -> String:
	var from: int = int(b["src_from"])
	var prefix: String = _source.substr(from, int(b["body_from"]) - from)
	if int(b["kind"]) != QMarkdown.Block.ORDERED:
		return prefix
	# Bump the number the writer actually typed, not the rendered one, so
	# `1. 1. 1.` keeps its style while still numbering correctly on screen.
	var digits: String = ""
	for c in prefix:
		if c >= "0" and c <= "9":
			digits += c
		elif digits != "":
			break
	if digits == "":
		return prefix
	return prefix.replace(digits, str(int(digits) + 1))


func _tab_indents() -> bool:
	var bi: int = _block_at(_caret)
	if bi < 0:
		return false
	var kind: int = int(_blocks[bi]["kind"])
	return kind == QMarkdown.Block.BULLET or kind == QMarkdown.Block.ORDERED \
			or kind == QMarkdown.Block.CODE


func _indent(deeper: bool) -> void:
	var bi: int = _block_at(_caret)
	if bi < 0:
		return
	var from: int = int(_blocks[bi]["src_from"])
	if deeper:
		replace_range(from, from, "  ")
		return
	var line: String = _source.substr(from, int(_blocks[bi]["src_to"]) - from)
	var strip: int = 0
	while strip < 2 and strip < line.length() and line[strip] == " ":
		strip += 1
	if strip > 0:
		replace_range(from, from + strip, "")


## One button, six levels: press again to go deeper, and again past h6 to drop
## the heading. Six buttons would have cost a whole toolbar row.
func cycle_heading() -> void:
	var bi: int = _block_at(_caret)
	if bi < 0:
		return
	var b: Dictionary = _blocks[bi]
	var from: int = int(b["src_from"])
	var to: int = int(b["src_to"])
	var line: String = _source.substr(from, to - from)
	var level: int = QMarkdown.heading_level(line)
	var next_level: int = 0 if level >= 6 else level + 1
	var body: String = QMarkdown.heading_text(line) if level > 0 \
			else line.strip_edges(true, false)
	replace_range(from, to,
			body if next_level == 0 else "#".repeat(next_level) + " " + body)


## A one-line selection becomes a code span; anything spanning lines becomes a
## fence, because backticks around a newline are not code in any Markdown
## dialect.
func toggle_code() -> void:
	if has_selection() and not selected_text().contains("\n"):
		toggle_wrap("`")
		return
	var sel: Vector2i = selection()
	var body: String = selected_text()
	replace_range(sel.x, sel.y, "```\n" + body + "\n```\n")
	if body == "":
		# Park the caret on the empty line between the fences.
		set_caret(sel.x + 4)


func set_caret(index: int) -> void:
	_caret = _canonical(clampi(index, 0, _source.length()))
	_anchor = -1
	_goal_x = -1.0
	_after_move()


## Word/character/line counts come from the document model, but the editor owns
## the text while it is being typed, so this is the honest place to ask.
func line_count() -> int:
	return _blocks.size()


# ── What the toolbar asks ───────────────────────────────────────────────────


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


## The formatting in force at the caret, for a toolbar that shows its state
## the way a word processor does — B lit while the caret sits in bold text.
##
## Returns {bold, italic, code, link, kind, level}.
##
## With a selection, an inline style counts as ON only if it holds across the
## WHOLE selection; that is the Office convention and the useful one, because
## it makes the button answer "will pressing this turn it off?". With no
## selection the style is taken from the character BEFORE the caret, which is
## the one the writer just typed and the one the next character will inherit.
func format_at_caret() -> Dictionary:
	var out: Dictionary = {"bold": false, "italic": false, "code": false,
			"link": "", "kind": QMarkdown.Block.PARA, "level": 0}
	if _blocks.is_empty():
		return out

	var bi: int = _block_at(_caret)
	var b: Dictionary = _blocks[bi]
	out["kind"] = int(b["kind"])
	out["level"] = int(b["level"])

	if not has_selection():
		var vis: int = _vis_index(b, _caret)
		var run: Dictionary = _run_at(b, vis - 1 if vis > 0 else 0)
		if not run.is_empty():
			out["bold"] = bool(run["bold"])
			out["italic"] = bool(run["italic"])
			out["code"] = bool(run["code"])
			out["link"] = str(run["link"])
		return out

	var sel: Vector2i = selection()
	var all_bold: bool = true
	var all_italic: bool = true
	var all_code: bool = true
	var seen: bool = false
	for i in range(_block_at(sel.x), _block_at(sel.y) + 1):
		var blk: Dictionary = _blocks[i]
		var from: int = _vis_index(blk, sel.x)
		var to: int = _vis_index(blk, sel.y)
		var at: int = 0
		for run in blk["runs"]:
			var length: int = str(run["text"]).length()
			# Only runs the selection actually overlaps have a vote.
			if at < to and at + length > from:
				seen = true
				all_bold = all_bold and bool(run["bold"])
				all_italic = all_italic and bool(run["italic"])
				all_code = all_code and bool(run["code"])
			at += length
	if seen:
		out["bold"] = all_bold
		out["italic"] = all_italic
		out["code"] = all_code
	return out


static func _run_at(b: Dictionary, vis: int) -> Dictionary:
	var at: int = 0
	for run in b["runs"]:
		at += str(run["text"]).length()
		if vis < at:
			return run
	var runs: Array = b["runs"]
	return {} if runs.is_empty() else runs[runs.size() - 1]


## Replace each touched line's block marker with `prefix` — "## " for a
## heading, "> " for a quote, "" for plain text. This SETS rather than toggles,
## which is what a style dropdown means: picking "Heading 2" twice leaves you
## in Heading 2.
##
## Fence lines and the code inside them are left alone: restyling a line of
## code would change what the code says.
func set_line_prefix(prefix: String) -> void:
	var sel: Vector2i = selection()
	var first: int = _block_at(sel.x)
	var last: int = _block_at(sel.y)
	if first < 0:
		return

	# Remember where the caret is as an offset into its own block's visible
	# text, so it lands on the same CHARACTER afterwards rather than the same
	# source index — the marker in front of it is about to change length.
	var caret_block: int = _block_at(_caret)
	var caret_vis: int = _vis_index(_blocks[caret_block], _caret)

	var lines: PackedStringArray = PackedStringArray()
	var changed: bool = false
	for i in range(first, last + 1):
		var b: Dictionary = _blocks[i]
		var from: int = int(b["src_from"])
		var to: int = int(b["src_to"])
		if int(b["kind"]) == QMarkdown.Block.CODE:
			lines.append(_source.substr(from, to - from))
			continue
		lines.append(prefix + _source.substr(int(b["body_from"]),
				to - int(b["body_from"])))
		changed = true
	if not changed:
		return

	var from_src: int = int(_blocks[first]["src_from"])
	var to_src: int = int(_blocks[last]["src_to"])
	_push_undo(false)
	_source = _source.substr(0, from_src) + "\n".join(lines) + _source.substr(to_src)
	_anchor = -1
	_relayout()
	_caret = _src_index(_blocks[clampi(caret_block, 0, _blocks.size() - 1)], caret_vis)
	_ensure_caret_visible()
	queue_redraw()
	source_changed.emit()


## The marker a style dropdown selection puts in front of a line.
static func prefix_for_style(kind: int, level: int) -> String:
	match kind:
		QMarkdown.Block.HEADING:
			return "#".repeat(clampi(level, 1, 6)) + " "
		QMarkdown.Block.QUOTE:
			return "> "
		QMarkdown.Block.BULLET:
			return "- "
		QMarkdown.Block.ORDERED:
			return "1. "
	return ""

