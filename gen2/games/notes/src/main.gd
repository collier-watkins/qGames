extends QGameRoot

## Notes — a small Markdown word processor.
##
## Shape: QNoteDocument holds the text and the dirty flag, QNoteStore does the
## file IO, QMarkdown turns source into BBCode. This file only builds Controls,
## dispatches, and puts the result on screen.
##
## Both input paths, as required by QCORE_API.md:
##   touch/mouse — every action is a Button; the file picker is a list of them.
##   key/pad     — Tab and the arrow keys traverse the toolbars (Godot finds
##                 focus neighbours geometrically, so no wiring is needed for a
##                 row of buttons), ui_accept presses. Escape/ui_cancel is the
##                 way OUT of the text editor, because a focused TextEdit eats
##                 the arrow keys for caret movement and would otherwise be a
##                 focus trap with no keyboard exit.

const SPLIT_MIN_WIDTH: int = 900          ## Below this a split view is two useless columns.
const SPLIT_MIN_ASPECT: float = 1.2       ## Portrait never splits; see _split_allowed().
const MARGIN: int = 12
const GAP: int = 8

## Square toolbar buttons, sized for a fingertip as well as a mouse.
const RIBBON_BTN: int = 32

## Two palettes, same keys. Light is the default because this is a word
## processor: every one people have used since 1990 opens on a white page, and
## a note is a document rather than a game screen. The other games stay dark.
##
## Every colour the app draws is in here — nothing is hardcoded at a call site,
## which is what makes switching a matter of swapping one dictionary. The
## accent differs by more than lightness on purpose: amber carries a dark UI
## and turns muddy on white, where a blue reads as the familiar
## document-application highlight.
const PALETTES: Dictionary = {
	"light": {
		"bg": Color("#eef1f5"),
		"panel": Color("#ffffff"),
		"panel_line": Color("#d3dae2"),
		"text": Color("#1b2026"),
		"dim": Color("#5c6774"),
		"accent": Color("#1a6fd4"),
		"scrim": Color(0.1216, 0.1451, 0.1765, 0.4706),
		"error": Color("#c4261f"),
		"code": Color("#0a6e60"),
		"code_bg": Color(0.0784, 0.1020, 0.1255, 0.0549),
		"link": Color("#1257a8"),
		"selection": Color(0.1020, 0.4353, 0.8314, 0.2353),
		"rule": Color("#c9d1da"),
		"scroll_track": Color(0, 0, 0, 0.0392),
		"scroll_grip": Color(0, 0, 0, 0.1961),
		"hover": Color(0, 0, 0, 0.0549),
		"toggle_fill": Color(0.1020, 0.4353, 0.8314, 0.1373),
		"toggle_line": Color(0.1020, 0.4353, 0.8314, 0.4314),
		"field": Color(0, 0, 0, 0.0235),
	},
	"dark": {
		"bg": Color("#19233c"),
		"panel": Color("#121a2e"),
		"panel_line": Color("#3c4e78"),
		"text": Color("#e0e8f7"),
		"dim": Color("#a0b9e6"),
		"accent": Color("#f0c832"),
		"scrim": Color(0.0196, 0.0314, 0.0588, 0.7451),
		"error": Color("#f0786e"),
		"code": Color("#8fd3c0"),
		"code_bg": Color(1, 1, 1, 0.0471),
		"link": Color("#7ebefc"),
		"selection": Color(0.2588, 0.4392, 0.7059, 0.5490),
		"rule": Color("#3c4e78"),
		"scroll_track": Color(1, 1, 1, 0.0392),
		"scroll_grip": Color(1, 1, 1, 0.1961),
		"hover": Color(1, 1, 1, 0.0863),
		"toggle_fill": Color(0.9412, 0.7843, 0.1961, 0.1961),
		"toggle_line": Color(0.9412, 0.7843, 0.1961, 0.4706),
		"field": Color(1, 1, 1, 0.0314),
	},
}

const DEFAULT_THEME: String = "light"


## RICH is the editor proper — the rendered document, typed into directly.
## SOURCE is the raw Markdown, kept because a rendered surface cannot show you
## a stray backtick or a mis-nested marker, and sometimes that is exactly what
## you need to see. It is hidden until asked for.
enum View { RICH, SOURCE, SPLIT }

var _doc: QNoteDocument
var _store: QNoteStore

var _theme_name: String = DEFAULT_THEME
var _palette: Dictionary = PALETTES[DEFAULT_THEME]
var _theme_button: RibbonButton

var _view: View = View.RICH
## What the user last chose. _view is what fits on screen; this is what they
## asked for, so widening the window restores their split instead of stranding
## them in the narrow-screen fallback.
var _wanted_view: View = View.RICH

var _rich: QRichEdit
var _editor: TextEdit
var _rich_pane: Control
var _edit_pane: Control
var _panes: HBoxContainer

## Guards the two-way sync between the rich editor and the source pane. Both
## edit the same document, so an unguarded update would echo back and forth.
var _syncing: bool = false
## The source pane holds a stale string while it is hidden — pushing every
## keystroke into an invisible TextEdit only to fight its caret is pure waste.
var _source_stale: bool = true
## Which surface a toolbar press should act on. Pressing a button moves focus
## to the button, so "whoever has focus" is not answerable at that moment.
var _source_active: bool = false

var _title_label: Label
var _status_label: Label
var _view_button: Button
var _first_toolbar_button: Button

var _style_picker: OptionButton
var _undo_button: RibbonButton
var _redo_button: RibbonButton
var _bold_button: RibbonButton
var _italic_button: RibbonButton
var _code_button: RibbonButton
var _bullet_button: RibbonButton
var _number_button: RibbonButton
var _quote_button: RibbonButton

var _overlay: Control
var _overlay_title: Label
var _overlay_body: VBoxContainer
var _overlay_buttons: HBoxContainer



func _game_ready() -> void:
	# The window's X button must go through the same unsaved-changes guard as
	# Escape and the Android back button. Without this, Godot accepts the close
	# request itself and NOTIFICATION_WM_CLOSE_REQUEST arrives too late to stop.
	get_tree().set_auto_accept_quit(false)

	_theme_name = str(QConfig.get_value("ui/theme", DEFAULT_THEME))
	if not PALETTES.has(_theme_name):
		_theme_name = DEFAULT_THEME
	_palette = PALETTES[_theme_name]

	_store = QNoteStore.new()
	_store.ensure_dir()
	_doc = QNoteDocument.new()

	_build_ui()
	resized.connect(_on_resized)
	QInput.device_changed.connect(_on_device_changed)

	# Opens on the empty, unsaved document QNoteDocument.new() already made:
	# a word processor starts on a blank page, not on whatever it found on
	# disk. Saved notes are one Files press away.
	_push_document()
	_apply_view()
	_refresh_chrome()
	_refresh_toolbar()
	_rich.grab_focus()


# ── Construction ────────────────────────────────────────────────────────────


## Every colour the app draws comes through here.
func _c(key: String) -> Color:
	return _palette[key]


## Switch palettes by rebuilding the interface.
##
## Godot has no "restyle everything" call: colours live inside StyleBox
## resources and per-control theme overrides scattered across the tree, and
## walking that tree to patch each one is how a control gets missed and stays
## the wrong colour. The whole UI is built in code and costs a couple of
## milliseconds, so it is thrown away and rebuilt instead — which cannot
## desynchronise, because there is nothing left over to desynchronise with.
##
## The document is not part of the UI, so nothing about it is at risk; the
## caret, the chosen view and the scroll position are carried across by hand.
func _set_theme(name: String, persist: bool = true) -> void:
	if not PALETTES.has(name):
		return
	_theme_name = name
	_palette = PALETTES[name]

	var caret: int = _rich.caret_index() if _rich != null else 0
	var wanted: View = _wanted_view
	var was_source: bool = _source_active

	for child in get_children():
		remove_child(child)
		child.queue_free()

	_build_ui()
	_wanted_view = wanted
	_source_active = was_source
	_push_document()
	_rich.set_caret(caret)
	_apply_view()
	_refresh_chrome()
	_refresh_toolbar()
	if not was_source or not _edit_pane.visible:
		_rich.grab_focus()
	else:
		_editor.grab_focus()

	if persist:
		QConfig.set_value("ui/theme", name)
		QConfig.save()
	_set_status("%s theme" % name)


func _on_theme_pressed() -> void:
	_set_theme("dark" if _theme_name == "light" else "light")


func _build_ui() -> void:
	# The background is the viewport's CLEAR COLOUR, not a full-screen ColorRect.
	#
	# They look identical and cost wildly different amounts. A ColorRect is a
	# canvas item: every frame the GPU rasterises and alpha-blends one quad over
	# the whole window. A clear is free on a tile-based GPU — it just marks the
	# tile buffer, with no memory read at all. MEASURED on the Pi 4 (V3D 4.2,
	# 1920x1053 maximized, gl_compatibility): one full-screen quad was costing
	# 9 ms of a 38 ms frame, a third of the budget, to draw a flat colour.
	#
	# project.godot sets the same colour so the frames before _ready() match.
	# _build_ui() runs again on every theme change, so the clear colour follows
	# the palette without _set_theme() needing to know about it.
	RenderingServer.set_default_clear_color(_c("bg"))

	# Children may anchor full-rect even though the root must not: QGameRoot
	# guarantees the root's `size` is already the viewport in _game_ready().
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, MARGIN)
	add_child(margin)

	var shell := VBoxContainer.new()
	shell.add_theme_constant_override("separation", GAP)
	margin.add_child(shell)

	shell.add_child(_build_file_bar())
	shell.add_child(_build_format_bar())

	_panes = HBoxContainer.new()
	_panes.add_theme_constant_override("separation", GAP)
	_panes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	shell.add_child(_panes)

	_rich_pane = _build_rich_pane()
	_edit_pane = _build_edit_pane()
	_panes.add_child(_rich_pane)
	_panes.add_child(_edit_pane)

	shell.add_child(_build_status_bar())

	# Added last: sibling order is draw order for Controls, so the overlay is
	# only guaranteed to cover the editor if it is the last child of the root.
	_overlay = _build_overlay()
	add_child(_overlay)



func _build_file_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", GAP)

	_first_toolbar_button = _make_button("Files", _on_files_pressed, "Open another note")
	bar.add_child(_first_toolbar_button)
	bar.add_child(_make_button("New", _on_new_pressed, "Start an empty note"))
	bar.add_child(_make_button("Save", _on_save_pressed, "Write to user://notes"))
	bar.add_child(_make_button("Rename", _on_rename_pressed, "Rename this note"))
	bar.add_child(_make_button("Delete", _on_delete_pressed, "Delete this note"))

	_title_label = Label.new()
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title_label.add_theme_color_override("font_color", _c("text"))
	_title_label.add_theme_font_size_override("font_size", 18)
	bar.add_child(_title_label)

	_view_button = _make_button("Rich", _on_view_pressed, "Rich / Source / Split")
	bar.add_child(_view_button)

	# Shows the theme you would switch TO, which is the convention every app
	# with this button uses.
	_theme_button = _ribbon("moon" if _theme_name == "light" else "sun",
			_on_theme_pressed,
			"Switch to %s theme" % ("dark" if _theme_name == "light" else "light"),
			false)
	bar.add_child(_theme_button)
	return bar


## One toolbar button, drawing its own icon.
##
## Godot ships no icon set to a running game — the editor's icons are not
## available at runtime — and a font of glyphs would have to be licensed,
## bundled and hinted. These are half a dozen lines of vector drawing each,
## they scale with the button, and they recolour with the state, which is the
## thing that actually matters: an active toggle has to LOOK active.
class RibbonButton extends Button:
	var glyph: String = ""
	var ink: Color = Color(0.8784, 0.9098, 0.9686)
	var ink_active: Color = Color(0.9412, 0.7843, 0.1961)
	var letter_font: Font

	# Diagonals and curves are drawn antialiased. Without it, at 32x32 the sun's
	# rays break into detached squares and the arcs step visibly; the straight
	# horizontal rules in the list icons look the same either way.
	func _draw() -> void:
		var c: Color = ink_active if button_pressed else ink
		if disabled:
			c = Color(c, 0.30)
		var box: float = 18.0
		var o: Vector2 = (size - Vector2(box, box)) * 0.5

		match glyph:
			"bold":
				var fs: int = 17
				var w: float = letter_font.get_string_size("B", 0, -1, fs).x
				var asc: float = letter_font.get_ascent(fs)
				var desc: float = letter_font.get_descent(fs)
				draw_string(letter_font,
						Vector2((size.x - w) * 0.5, (size.y + asc - desc) * 0.5),
						"B", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)
			"italic":
				# Drawn rather than typed. A synthesised italic capital I is
				# just a leaning bar, indistinguishable from a slash at this
				# size; the serifs at top and bottom are what make it read as
				# the italic button every word processor has.
				var cx: float = size.x * 0.5
				var cy: float = size.y * 0.5
				var half: float = 6.5
				var lean: float = 2.3
				var serif: float = 3.3
				var top := Vector2(cx + lean, cy - half)
				var bottom := Vector2(cx - lean, cy + half)
				draw_line(top, bottom, c, 1.9, true)
				draw_line(top + Vector2(-serif, 0), top + Vector2(serif, 0), c, 1.9)
				draw_line(bottom + Vector2(-serif, 0), bottom + Vector2(serif, 0), c, 1.9)
			"bullet", "number":
				# Three rows in eighteen pixels leaves each row six pixels
				# tall, which is not enough for a legible digit — so the
				# numbered variant uses two rows and a wider gap.
				var rows: int = 3 if glyph == "bullet" else 2
				var step: float = 6.5 if glyph == "bullet" else 9.0
				var top_y: float = o.y + 2.5 if glyph == "bullet" else o.y + 4.0
				for i in rows:
					var y: float = top_y + float(i) * step
					if glyph == "bullet":
						draw_circle(Vector2(o.x + 2.0, y), 1.7, c)
					else:
						var d: String = str(i + 1)
						var dw: float = letter_font.get_string_size(d, 0, -1, 10).x
						draw_string(letter_font, Vector2(o.x + 2.5 - dw * 0.5, y + 3.6),
								d, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, c)
					draw_line(Vector2(o.x + 8.0, y), Vector2(o.x + box, y), c, 1.7)
			"quote":
				draw_rect(Rect2(o.x + 1.0, o.y + 1.5, 2.6, box - 3.0), c)
				for i in 3:
					var y: float = o.y + 2.5 + float(i) * 6.5
					draw_line(Vector2(o.x + 8.0, y), Vector2(o.x + box, y), c, 1.7)
			"code":
				var mid: float = o.y + box * 0.5
				draw_polyline([Vector2(o.x + 6.5, o.y + 2.0),
						Vector2(o.x + 1.0, mid),
						Vector2(o.x + 6.5, o.y + box - 2.0)], c, 1.8, true)
				draw_polyline([Vector2(o.x + box - 6.5, o.y + 2.0),
						Vector2(o.x + box - 1.0, mid),
						Vector2(o.x + box - 6.5, o.y + box - 2.0)], c, 1.8, true)
			"sun":
				var ctr: Vector2 = size * 0.5
				draw_circle(ctr, 4.2, c, true)
				for i in 8:
					var a: float = TAU * float(i) / 8.0
					var dir := Vector2(cos(a), sin(a))
					draw_line(ctr + dir * 6.2, ctr + dir * 8.4, c, 1.6, true)
			"moon":
				# A crescent is one disc minus another, and subtracting means
				# knowing the colour behind the button — so it is drawn as a
				# single polygon instead: out along the visible arc of the
				# disc, back along the bite the second disc takes out of it.
				# An arc of constant width, which is what this used to be,
				# has no cusps and reads as a "C".
				var ctr: Vector2 = size * 0.5
				var r_out: float = 7.0
				var r_in: float = 6.5
				var gap: float = 4.0
				# Tilted so the horns point up-right, the way a moon is drawn.
				var tilt: float = -0.6
				# Where the two circles cross — the cusps — solved for x on the
				# line between the centres, then read as an angle on each.
				var xc: float = (r_out * r_out - r_in * r_in + gap * gap) / (2.0 * gap)
				var yc: float = sqrt(maxf(r_out * r_out - xc * xc, 0.0))
				var a_out: float = atan2(yc, xc)
				var a_in: float = atan2(yc, xc - gap)
				var pts := PackedVector2Array()
				for i in 15:
					var a: float = lerpf(a_out, TAU - a_out, float(i) / 14.0)
					pts.push_back(ctr + (Vector2(cos(a), sin(a)) * r_out).rotated(tilt))
				for i in 15:
					var a: float = lerpf(TAU - a_in, a_in, float(i) / 14.0)
					pts.push_back(ctr + (Vector2(gap, 0.0)
							+ Vector2(cos(a), sin(a)) * r_in).rotated(tilt))
				draw_colored_polygon(pts, c)
				# The polygon fill is not antialiased; tracing its own outline
				# is what keeps the horns from looking chewed at 18 px.
				draw_polyline(pts + PackedVector2Array([pts[0]]), c, 1.0, true)
			"undo", "redo":
				var ctr: Vector2 = o + Vector2(box * 0.5, box * 0.62)
				var r: float = box * 0.36
				var back: bool = glyph == "undo"
				# The hook past horizontal is what stops the arc reading as a
				# rainbow: it turns the far end downward, into a tail.
				if back:
					draw_arc(ctr, r, PI, TAU + 0.7, 24, c, 1.8, true)
				else:
					draw_arc(ctr, r, PI - 0.7, TAU, 24, c, 1.8, true)
				var tip: Vector2 = ctr + Vector2(-r if back else r, 0.0)
				draw_colored_polygon(PackedVector2Array([
						tip + Vector2(-3.4, -1.2), tip + Vector2(3.4, -1.2),
						tip + Vector2(0.0, 4.4)]), c)


## The paragraph styles the dropdown offers, in order. Code blocks are not here
## on purpose: restyling a line INTO code would change what the line means, so
## that stays on its own button where it reads as an action.
static func _paragraph_styles() -> Array:
	return [
		{"name": "Normal text", "kind": QMarkdown.Block.PARA, "level": 0},
		{"name": "Heading 1", "kind": QMarkdown.Block.HEADING, "level": 1},
		{"name": "Heading 2", "kind": QMarkdown.Block.HEADING, "level": 2},
		{"name": "Heading 3", "kind": QMarkdown.Block.HEADING, "level": 3},
		{"name": "Heading 4", "kind": QMarkdown.Block.HEADING, "level": 4},
		{"name": "Heading 5", "kind": QMarkdown.Block.HEADING, "level": 5},
		{"name": "Heading 6", "kind": QMarkdown.Block.HEADING, "level": 6},
		{"name": "Quote", "kind": QMarkdown.Block.QUOTE, "level": 1},
	]


func _build_format_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)

	_undo_button = _ribbon("undo", _on_undo_pressed, "Undo  (Ctrl+Z)", false)
	_redo_button = _ribbon("redo", _on_redo_pressed, "Redo  (Ctrl+Shift+Z)", false)
	bar.add_child(_undo_button)
	bar.add_child(_redo_button)
	bar.add_child(_group_break())

	_style_picker = _build_style_picker()
	bar.add_child(_style_picker)
	bar.add_child(_group_break())

	_bold_button = _ribbon("bold", func() -> void: _wrap_selection("**"),
			"Bold  (Ctrl+B)", true)
	_italic_button = _ribbon("italic", func() -> void: _wrap_selection("*"),
			"Italic  (Ctrl+I)", true)
	_code_button = _ribbon("code", _on_code_pressed,
			"Code span, or a fenced block for whole lines", true)
	bar.add_child(_bold_button)
	bar.add_child(_italic_button)
	bar.add_child(_code_button)
	bar.add_child(_group_break())

	_bullet_button = _ribbon("bullet", func() -> void: _prefix_lines("- "),
			"Bulleted list", true)
	_number_button = _ribbon("number", func() -> void: _prefix_lines("1. "),
			"Numbered list", true)
	_quote_button = _ribbon("quote", func() -> void: _prefix_lines("> "),
			"Block quote", true)
	bar.add_child(_bullet_button)
	bar.add_child(_number_button)
	bar.add_child(_quote_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(spacer)
	return bar


func _ribbon(glyph: String, on_press: Callable, tip: String,
		toggles: bool) -> RibbonButton:
	var b := RibbonButton.new()
	b.glyph = glyph
	b.tooltip_text = tip
	b.toggle_mode = toggles
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(RIBBON_BTN, RIBBON_BTN)
	b.ink = _c("text")
	b.ink_active = _c("accent")
	b.letter_font = _button_font(glyph)
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(state, _ribbon_box(state))
	# `pressed` fires for toggles too. The action runs, then _refresh_toolbar
	# re-derives the real state from the document — so a toggle can never drift
	# out of step with the text it describes.
	b.pressed.connect(func() -> void:
		on_press.call()
		_refresh_toolbar())
	return b


## Bold and italic buttons wear their own style, the way every word processor
## draws them. Godot's default font has neither face, so both are synthesised —
## the same FontVariation trick the editor itself uses.
func _button_font(glyph: String) -> Font:
	var base: Font = get_theme_default_font()
	if base == null:
		base = ThemeDB.fallback_font
	match glyph:
		"bold":
			return QRichEdit.make_variation(base, QRichEdit.BOLD_EMBOLDEN, 0.0)
		"italic":
			return QRichEdit.make_variation(base, 0.0, QRichEdit.ITALIC_SKEW)
	return base


func _ribbon_box(state: String) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(6)
	match state:
		"hover":
			sb.bg_color = _c("hover")
		"pressed":
			sb.bg_color = _c("toggle_fill")
			sb.border_color = _c("toggle_line")
			sb.set_border_width_all(1)
		"focus":
			sb.bg_color = Color(1, 1, 1, 0.0392)
			sb.border_color = _c("accent")
			sb.set_border_width_all(1)
		_:
			sb.bg_color = Color(0, 0, 0, 0)
	return sb


## A hairline between groups of buttons, the way a real toolbar separates
## "what the text looks like" from "what the paragraph is".
func _group_break() -> Control:
	var wrap := MarginContainer.new()
	for side in ["left", "right"]:
		wrap.add_theme_constant_override("margin_" + side, 5)
	var line := ColorRect.new()
	line.color = _c("panel_line")
	line.custom_minimum_size = Vector2(1, RIBBON_BTN - 10)
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(line)
	return wrap


func _build_style_picker() -> OptionButton:
	var picker := OptionButton.new()
	picker.custom_minimum_size = Vector2(146, RIBBON_BTN)
	picker.focus_mode = Control.FOCUS_ALL
	picker.tooltip_text = "Paragraph style"
	picker.add_theme_font_size_override("font_size", 15)
	picker.add_theme_color_override("font_color", _c("text"))
	picker.add_theme_color_override("font_hover_color", _c("text"))
	picker.add_theme_color_override("font_focus_color", _c("text"))
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		picker.add_theme_stylebox_override(state, _picker_box(state))
	for style in _paragraph_styles():
		picker.add_item(str(style["name"]))
	picker.item_selected.connect(_on_style_selected)
	return picker


func _picker_box(state: String) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 9.0
	sb.content_margin_right = 9.0
	sb.bg_color = _c("hover") if state != "normal" else _c("field")
	sb.border_color = _c("accent") if state == "focus" else _c("panel_line")
	sb.set_border_width_all(1)
	return sb


func _on_style_selected(index: int) -> void:
	var styles: Array = _paragraph_styles()
	if index < 0 or index >= styles.size():
		return
	var style: Dictionary = styles[index]
	var prefix: String = QRichEdit.prefix_for_style(int(style["kind"]), int(style["level"]))
	if _on_source():
		_set_source_line_prefix(prefix)
	else:
		_rich.set_line_prefix(prefix)
		_after_rich_edit()
	_refresh_toolbar()


func _on_undo_pressed() -> void:
	if _on_source():
		_editor.undo()
	else:
		_rich.undo()
		_after_rich_edit()
	_refresh_toolbar()


func _on_redo_pressed() -> void:
	if _on_source():
		_editor.redo()
	else:
		_rich.redo()
		_after_rich_edit()
	_refresh_toolbar()


## Set (not toggle) the block marker on every line the source pane's selection
## touches — the dropdown's meaning, applied to the plain-text surface.
func _set_source_line_prefix(prefix: String) -> void:
	var first: int = _editor.get_caret_line()
	var last: int = first
	if _editor.has_selection():
		first = _editor.get_selection_from_line()
		last = _editor.get_selection_to_line()
	_editor.begin_complex_operation()
	for line in range(first, last + 1):
		var text: String = _editor.get_line(line)
		var level: int = QMarkdown.heading_level(text)
		var body: String = text
		if level > 0:
			body = QMarkdown.heading_text(text)
		else:
			body = QMarkdown.toggle_line_prefix(text, "> ")
			if body == text:
				body = text.strip_edges(true, false)
			else:
				body = QMarkdown.toggle_line_prefix(text, "> ")
		_editor.set_line(line, prefix + body.strip_edges(true, false))
	_editor.end_complex_operation()
	_after_edit()


## Push the toolbar's appearance back into line with the document.
##
## This is the whole point of the redesign: in a word processor the buttons
## REPORT as well as command — B is lit while the caret sits in bold text, and
## the dropdown reads "Heading 2" when you are in one. Everything here is
## derived from the document; nothing is remembered, so the toolbar cannot
## drift out of step with the text.
func _refresh_toolbar() -> void:
	if _undo_button == null:
		return

	if _on_source():
		# The source pane is plain text with no notion of "the caret is in
		# bold", so the toggles report nothing rather than lying.
		for b in [_bold_button, _italic_button, _code_button, _bullet_button,
				_number_button, _quote_button]:
			b.set_pressed_no_signal(false)
			b.queue_redraw()
		_style_picker.select(-1)
		_undo_button.disabled = not _editor.has_undo()
		_redo_button.disabled = not _editor.has_redo()
		_undo_button.queue_redraw()
		_redo_button.queue_redraw()
		return

	var f: Dictionary = _rich.format_at_caret()
	_bold_button.set_pressed_no_signal(bool(f["bold"]))
	_italic_button.set_pressed_no_signal(bool(f["italic"]))
	_code_button.set_pressed_no_signal(bool(f["code"])
			or int(f["kind"]) == QMarkdown.Block.CODE)
	_bullet_button.set_pressed_no_signal(int(f["kind"]) == QMarkdown.Block.BULLET)
	_number_button.set_pressed_no_signal(int(f["kind"]) == QMarkdown.Block.ORDERED)
	_quote_button.set_pressed_no_signal(int(f["kind"]) == QMarkdown.Block.QUOTE)

	_undo_button.disabled = not _rich.can_undo()
	_redo_button.disabled = not _rich.can_redo()
	for b in [_bold_button, _italic_button, _code_button, _bullet_button,
			_number_button, _quote_button, _undo_button, _redo_button]:
		b.queue_redraw()

	# A list or a code line is not a paragraph style the dropdown can name, so
	# it shows nothing rather than something wrong.
	var index: int = -1
	var styles: Array = _paragraph_styles()
	for i in styles.size():
		if int(styles[i]["kind"]) == int(f["kind"]):
			if int(f["kind"]) != QMarkdown.Block.HEADING \
					or int(styles[i]["level"]) == int(f["level"]):
				index = i
				break
	_style_picker.select(index)


func _build_edit_pane() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_box())
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var inner := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		inner.add_theme_constant_override("margin_" + side, 6)
	panel.add_child(inner)

	_editor = TextEdit.new()
	# Wrapping, not a horizontal scrollbar: prose, and a phone screen.
	_editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_editor.scroll_smooth = true
	_editor.caret_blink = true
	_editor.add_theme_font_size_override("font_size", 17)
	_editor.add_theme_color_override("font_color", _c("text"))
	_editor.add_theme_color_override("caret_color", _c("accent"))
	_editor.add_theme_color_override("selection_color", _c("selection"))
	_editor.add_theme_stylebox_override("normal", _flat_box(_c("panel")))
	_editor.add_theme_stylebox_override("focus", _flat_box(_c("panel")))
	_editor.text_changed.connect(_on_text_changed)
	_editor.focus_entered.connect(func() -> void:
		_source_active = true
		_refresh_toolbar()
		_refresh_chrome())
	_editor.caret_changed.connect(_refresh_toolbar)
	inner.add_child(_editor)
	return panel


func _build_rich_pane() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_box())
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_rich = QRichEdit.new()
	_rich.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rich.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rich.col_bg = _c("panel")
	_rich.col_text = _c("text")
	_rich.col_dim = _c("dim")
	_rich.col_accent = _c("accent")
	_rich.col_caret = _c("accent")
	_rich.col_rule = _c("rule")
	_rich.col_code = _c("code")
	_rich.col_code_bg = _c("code_bg")
	_rich.col_link = _c("link")
	_rich.col_sel = _c("selection")
	_rich.col_scroll_track = _c("scroll_track")
	_rich.col_scroll_grip = _c("scroll_grip")
	_rich.source_changed.connect(_on_rich_changed)
	_rich.caret_moved.connect(_refresh_toolbar)
	_rich.focus_entered.connect(func() -> void:
		_source_active = false
		_refresh_toolbar()
		_refresh_chrome())
	# Opening a browser mid-note is a hostile surprise on a handheld; a link
	# reports its target in the status bar instead.
	_rich.link_clicked.connect(func(url: String) -> void: _set_status("link: %s" % url))
	panel.add_child(_rich)
	return panel


func _build_status_bar() -> Control:
	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", _c("dim"))
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return _status_label


## One reusable modal: a scrim that swallows input, a titled panel, a body the
## caller fills, and a button row. Built once and repopulated, so opening a
## dialog never allocates a node graph mid-gesture.
func _build_overlay() -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.visible = false

	var scrim := ColorRect.new()
	scrim.color = _c("scrim")
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP  # blocks the editor beneath
	root.add_child(scrim)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(centre)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_box())
	panel.custom_minimum_size = Vector2(360, 0)
	centre.add_child(panel)

	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", GAP)
	pad.add_child(col)

	_overlay_title = Label.new()
	_overlay_title.add_theme_color_override("font_color", _c("accent"))
	_overlay_title.add_theme_font_size_override("font_size", 20)
	col.add_child(_overlay_title)

	var scroll := ScrollContainer.new()
	# Tall enough to be a list, short enough to leave the buttons on screen.
	scroll.custom_minimum_size = Vector2(0, 220)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(scroll)

	_overlay_body = VBoxContainer.new()
	_overlay_body.add_theme_constant_override("separation", 4)
	_overlay_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_overlay_body)

	_overlay_buttons = HBoxContainer.new()
	_overlay_buttons.add_theme_constant_override("separation", GAP)
	_overlay_buttons.alignment = BoxContainer.ALIGNMENT_END
	col.add_child(_overlay_buttons)
	return root


## Flat, rounded, and lit only on hover — the same treatment as the ribbon
## below it, so the two rows read as one toolbar instead of two widgets.
func _make_button(text: String, on_press: Callable, tip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(0, RIBBON_BTN)
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", _c("text"))
	b.add_theme_color_override("font_hover_color", _c("text"))
	b.add_theme_color_override("font_pressed_color", _c("accent"))
	b.add_theme_color_override("font_focus_color", _c("text"))
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var box: StyleBoxFlat = _ribbon_box(state)
		box.content_margin_left = 11.0
		box.content_margin_right = 11.0
		b.add_theme_stylebox_override(state, box)
	b.pressed.connect(on_press)
	return b


func _panel_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = _c("panel")
	sb.border_color = _c("panel_line")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	return sb


func _flat_box(fill: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	return sb


# ── View mode ───────────────────────────────────────────────────────────────


func _on_resized() -> void:
	_apply_view()


## Split is only offered when there is room for two readable columns; below
## that the toggle degrades to Edit/Preview, which is the whole reason _view
## and _wanted_view are separate.
##
## The aspect test is not decoration, it is the whole check. Under this
## project's stretch settings (canvas_items + expand, base 1280x720) the
## LOGICAL viewport width never falls below the base width: the scale is
## min(w/1280, h/720), so a 720x1440 phone reports a 1280x2560 viewport, not a
## narrow one. Measuring size.x alone would enable split on every portrait
## screen in the world. Aspect survives the stretch, and the width floor still
## catches an genuinely tiny viewport if the stretch settings ever change.
func _split_allowed() -> bool:
	return size.x >= float(SPLIT_MIN_WIDTH) and size.x >= size.y * SPLIT_MIN_ASPECT


func _apply_view() -> void:
	_view = _wanted_view
	if _view == View.SPLIT and not _split_allowed():
		_view = View.RICH

	_rich_pane.visible = _view == View.RICH or _view == View.SPLIT
	_edit_pane.visible = _view == View.SOURCE or _view == View.SPLIT
	_view_button.text = ["Rich", "Source", "Split"][int(_view)]

	if _edit_pane.visible:
		_flush_source_pane()

	# Move focus only when the pane holding it just disappeared. _apply_view
	# runs on every resize, so grabbing focus unconditionally would yank the
	# keyboard out of an open modal.
	var focused: Control = get_viewport().gui_get_focus_owner()
	if focused == _rich and not _rich_pane.visible:
		_editor.grab_focus()
	elif focused == _editor and not _edit_pane.visible:
		_rich.grab_focus()
	_refresh_toolbar()


func _on_view_pressed() -> void:
	match _view:
		View.RICH:
			_wanted_view = View.SOURCE
		View.SOURCE:
			_wanted_view = View.SPLIT if _split_allowed() else View.RICH
		_:
			_wanted_view = View.RICH
	_apply_view()
	_refresh_chrome()


# ── Text and preview ────────────────────────────────────────────────────────


## The source pane changed: push it into the model and the rich editor.
func _on_text_changed() -> void:
	if _syncing:
		return
	_syncing = true
	_doc.set_text(_editor.text)
	_rich.set_source(_doc.text, true)
	_syncing = false
	_refresh_chrome()
	_refresh_toolbar()


## The rich editor changed: push it into the model, and into the source pane
## only if anyone can see it.
func _on_rich_changed() -> void:
	if _syncing:
		return
	_syncing = true
	_doc.set_text(_rich.get_source())
	_source_stale = true
	if _edit_pane.visible:
		_flush_source_pane()
	_syncing = false
	_refresh_chrome()
	_refresh_toolbar()


## Copy the document into the TextEdit, putting its caret back where it was.
## Assigning `text` resets the caret to the top, which in a split view would
## yank the source pane to line 0 on every keystroke.
func _flush_source_pane() -> void:
	if not _source_stale or _editor == null:
		return
	_source_stale = false
	var line: int = _editor.get_caret_line()
	var col: int = _editor.get_caret_column()
	var scroll: float = _editor.scroll_vertical
	_editor.text = _doc.text
	_editor.set_caret_line(mini(line, maxi(0, _editor.get_line_count() - 1)))
	_editor.set_caret_column(mini(col, _editor.get_line(_editor.get_caret_line()).length()))
	_editor.scroll_vertical = scroll


## Push the document into both surfaces after a load, a new note, or an undo
## that happened outside them.
func _push_document(keep_caret: bool = false) -> void:
	_syncing = true
	_rich.set_source(_doc.text, keep_caret)
	_source_stale = true
	if _edit_pane.visible:
		_flush_source_pane()
	_syncing = false


func _refresh_chrome() -> void:
	var mark: String = " •" if _doc.dirty else ""
	var where: String = _doc.filename if _doc.filename != "" else "unsaved"
	_title_label.text = "%s%s   —   %s" % [_doc.title(), mark, where]
	_set_status("%d words · %d chars · %d lines    %s    Esc leaves the editor, Esc again quits" % [
		_doc.word_count(), _doc.char_count(), _doc.line_count(),
		"editing source" if _on_source() else "editing rich text",
	])


func _set_status(msg: String) -> void:
	_status_label.add_theme_color_override("font_color", _c("dim"))
	_status_label.text = msg


func _set_error(msg: String) -> void:
	_status_label.add_theme_color_override("font_color", _c("error"))
	_status_label.text = msg


func _on_device_changed(_device: String) -> void:
	# Focus rings are drawn by the default theme; nothing to redraw here, but
	# the hint is only useful to someone holding a keyboard.
	_refresh_chrome()


# ── Formatting actions ──────────────────────────────────────────────────────


## Wrap (or unwrap) the selection. With no selection, the markers are inserted
## empty and the caret is parked between them, which is what a writer means by
## pressing Bold before typing.
func _wrap_selection(marker: String) -> void:
	if not _on_source():
		_rich.toggle_wrap(marker)
		_after_rich_edit()
		return
	_editor.begin_complex_operation()
	if _editor.has_selection():
		var from_line: int = _editor.get_selection_from_line()
		var from_col: int = _editor.get_selection_from_column()
		var wrapped: String = QMarkdown.toggle_wrap(_editor.get_selected_text(), marker)
		_editor.delete_selection()
		_editor.set_caret_line(from_line)
		_editor.set_caret_column(from_col)
		_editor.insert_text_at_caret(wrapped)
		_editor.select(from_line, from_col, _editor.get_caret_line(), _editor.get_caret_column())
	else:
		_editor.insert_text_at_caret(marker + marker)
		_editor.set_caret_column(_editor.get_caret_column() - marker.length())
	_editor.end_complex_operation()
	_after_edit()


## Toggle a block prefix on every line the selection touches.
func _prefix_lines(prefix: String) -> void:
	if not _on_source():
		_rich.toggle_line_prefix(prefix)
		_after_rich_edit()
		return
	var first: int = _editor.get_caret_line()
	var last: int = first
	if _editor.has_selection():
		first = _editor.get_selection_from_line()
		last = _editor.get_selection_to_line()

	_editor.begin_complex_operation()
	for line in range(first, last + 1):
		_editor.set_line(line, QMarkdown.toggle_line_prefix(_editor.get_line(line), prefix))
	_editor.end_complex_operation()
	_editor.set_caret_line(last)
	_editor.set_caret_column(_editor.get_line(last).length())
	_after_edit()


## One button, six levels: press again to go deeper, and again past h6 to
## remove the heading. Six buttons would have cost a whole toolbar row.
func _on_heading_pressed() -> void:
	if not _on_source():
		_rich.cycle_heading()
		_after_rich_edit()
		return
	var line: int = _editor.get_caret_line()
	var text: String = _editor.get_line(line)
	var level: int = QMarkdown.heading_level(text)
	var next_level: int = 0 if level >= 6 else level + 1

	var body: String = QMarkdown.heading_text(text) if level > 0 else text.strip_edges(true, false)
	var replacement: String = body if next_level == 0 else "#".repeat(next_level) + " " + body

	_editor.begin_complex_operation()
	_editor.set_line(line, replacement)
	_editor.end_complex_operation()
	_editor.set_caret_line(line)
	_editor.set_caret_column(replacement.length())
	_after_edit()


## A one-line selection becomes a code span; anything spanning lines (or an
## empty caret on an empty line) becomes a fence, because backticks around a
## newline are not code in any Markdown dialect.
func _on_code_pressed() -> void:
	if not _on_source():
		_rich.toggle_code()
		_after_rich_edit()
		return
	var selection: String = _editor.get_selected_text()
	if _editor.has_selection() and not selection.contains("\n"):
		_wrap_selection("`")
		return

	_editor.begin_complex_operation()
	if _editor.has_selection():
		var from_line: int = _editor.get_selection_from_line()
		var from_col: int = _editor.get_selection_from_column()
		_editor.delete_selection()
		_editor.set_caret_line(from_line)
		_editor.set_caret_column(from_col)
		_editor.insert_text_at_caret("```\n" + selection + "\n```\n")
	else:
		_editor.insert_text_at_caret("```\n\n```\n")
		_editor.set_caret_line(_editor.get_caret_line() - 2)
		_editor.set_caret_column(0)
	_editor.end_complex_operation()
	_after_edit()


## set_line() and friends mutate the buffer without emitting text_changed, so
## every programmatic edit has to push the model itself or the dirty flag and
## the preview silently fall a revision behind.
func _after_edit() -> void:
	_syncing = true
	_doc.set_text(_editor.text)
	_rich.set_source(_doc.text, true)
	_syncing = false
	_refresh_chrome()
	_editor.grab_focus()


## Which surface a toolbar press acts on. Pressing the button moved focus to
## the button itself, so this remembers the last surface the writer was in
## rather than asking who has focus now.
func _on_source() -> bool:
	return _source_active and _edit_pane.visible


func _after_rich_edit() -> void:
	_syncing = true
	_doc.set_text(_rich.get_source())
	_source_stale = true
	if _edit_pane.visible:
		_flush_source_pane()
	_syncing = false
	_refresh_chrome()
	_rich.grab_focus()


# ── File actions ────────────────────────────────────────────────────────────


func _on_files_pressed() -> void:
	_guard_dirty(_show_file_list)


func _show_file_list() -> void:
	var names: PackedStringArray = _store.list()
	var body: VBoxContainer = _open_overlay("Notes")

	if names.is_empty():
		var empty := Label.new()
		empty.text = "No notes saved yet."
		empty.add_theme_color_override("font_color", _c("dim"))
		body.add_child(empty)
	else:
		for file_name in names:
			var b := _make_button(file_name, func() -> void:
				_close_overlay()
				_open_file(file_name)
				_editor.text = _doc.text
				_after_load())
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			body.add_child(b)

	_add_overlay_button("Close", _close_overlay)
	_focus_first_in_overlay()


## Loads into the model. The caller pushes the text into the TextEdit, because
## assigning TextEdit.text fires text_changed and would immediately re-dirty a
## document that was just loaded clean.
func _open_file(filename: String) -> void:
	var text: String = _store.load_text(filename)
	if _store.last_error != "":
		_set_error(_store.last_error)
		return
	_doc = QNoteDocument.new(text, filename)


func _after_load() -> void:
	_doc.dirty = false
	_push_document()
	_refresh_chrome()
	_set_status("opened %s" % _doc.filename)
	_rich.grab_focus()


func _on_new_pressed() -> void:
	_guard_dirty(func() -> void:
		_doc = QNoteDocument.new()
		_doc.dirty = false
		_push_document()
		_refresh_chrome()
		_set_status("new note")
		_rich.grab_focus())


func _on_save_pressed() -> void:
	if _doc.is_new():
		_prompt("Save as", _doc.suggest_filename(), func(name: String) -> void:
			_save_as(_store.unique_name(QNoteDocument.sanitize_filename(name))))
		return
	_save_as(_doc.filename)


func _save_as(filename: String) -> bool:
	if not _store.save_text(filename, _doc.text):
		_set_error(_store.last_error)
		return false
	_doc.mark_saved(filename)
	_refresh_chrome()
	_set_status("saved %s" % filename)
	# The common schema: a save is this game's finished round. score is the
	# word count because that is the number a writer recognises; the raw
	# character count rides along as an extra topic.
	# The note's own text rides along, retained, so a dashboard can show what
	# was written and not merely that something was. It goes out before the
	# scalars, and ts still lands last, so a subscriber reacting to ts sees a
	# body, a word count and a filename that all describe the same save.
	Telemetry.report_result(Telemetry.RESULT_DONE, _doc.word_count(), "words",
			[["chars", _doc.char_count()], ["title", _doc.title()],
			["filename", _doc.filename]],
			[["content", _doc.text]])
	return true


func _on_rename_pressed() -> void:
	if _doc.is_new():
		_on_save_pressed()
		return
	_prompt("Rename note", _doc.filename, func(name: String) -> void:
		var target: String = QNoteDocument.sanitize_filename(name)
		if target == _doc.filename:
			return
		if not _store.rename(_doc.filename, target):
			_set_error(_store.last_error)
			return
		_doc.mark_saved(target)
		_refresh_chrome()
		_set_status("renamed to %s" % target))


func _on_delete_pressed() -> void:
	if _doc.is_new():
		_set_error("nothing to delete — this note has never been saved")
		return
	var doomed: String = _doc.filename
	_confirm("Delete %s?" % doomed, "Delete", func() -> void:
		if not _store.delete(doomed):
			_set_error(_store.last_error)
			return
		_doc = QNoteDocument.new()
		_doc.dirty = false
		_push_document()
		_refresh_chrome()
		_set_status("deleted %s" % doomed)
		_rich.grab_focus())


# ── Overlays: file list, prompt, confirm ────────────────────────────────────


func _open_overlay(title: String) -> VBoxContainer:
	for child in _overlay_body.get_children():
		child.queue_free()
		_overlay_body.remove_child(child)
	for child in _overlay_buttons.get_children():
		child.queue_free()
		_overlay_buttons.remove_child(child)
	_overlay_title.text = title
	_overlay.visible = true
	return _overlay_body


func _add_overlay_button(text: String, on_press: Callable) -> Button:
	var b: Button = _make_button(text, on_press)
	_overlay_buttons.add_child(b)
	return b


func _close_overlay() -> void:
	_overlay.visible = false
	_editor.grab_focus()


func _overlay_open() -> bool:
	return _overlay != null and _overlay.visible


## A single-field prompt. Enter submits, which is the only way to type a
## filename on a phone without hunting for a button.
func _prompt(title: String, initial: String, on_accept: Callable) -> void:
	var body: VBoxContainer = _open_overlay(title)
	var field := LineEdit.new()
	field.text = initial
	field.custom_minimum_size = Vector2(320, 0)
	field.add_theme_font_size_override("font_size", 17)
	body.add_child(field)

	var submit := func() -> void:
		var value: String = field.text
		_close_overlay()
		on_accept.call(value)

	field.text_submitted.connect(func(_t: String) -> void: submit.call())
	_add_overlay_button("Cancel", _close_overlay)
	_add_overlay_button("OK", submit)
	field.grab_focus()
	field.select_all()


func _confirm(message: String, accept_text: String, on_accept: Callable) -> void:
	var body: VBoxContainer = _open_overlay("Confirm")
	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", _c("text"))
	body.add_child(label)
	_add_overlay_button("Cancel", _close_overlay)
	_add_overlay_button(accept_text, func() -> void:
		_close_overlay()
		on_accept.call())
	_focus_first_in_overlay()


## Run `action`, but not at the cost of unsaved work. Three answers, because
## "Save" is what the writer usually wants and a two-button dialog would make
## them cancel, save, and try again.
func _guard_dirty(action: Callable) -> void:
	if not _doc.dirty:
		action.call()
		return
	_open_overlay("Unsaved changes")
	var label := Label.new()
	label.text = "\"%s\" has unsaved changes." % _doc.title()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", _c("text"))
	_overlay_body.add_child(label)

	_add_overlay_button("Cancel", _close_overlay)
	_add_overlay_button("Discard", func() -> void:
		_close_overlay()
		action.call())
	_add_overlay_button("Save", func() -> void:
		_close_overlay()
		if _doc.is_new():
			# Saving needs a filename, which needs another prompt; chain the
			# original action onto it so "Save" still means "…and then go".
			_prompt("Save as", _doc.suggest_filename(), func(name: String) -> void:
				if _save_as(_store.unique_name(QNoteDocument.sanitize_filename(name))):
					action.call())
			return
		if _save_as(_doc.filename):
			action.call())
	_focus_first_in_overlay()


## Keyboard users must land somewhere inside a modal the moment it opens, or
## the next arrow key moves focus in the editor behind the scrim.
func _focus_first_in_overlay() -> void:
	for child in _overlay_body.get_children():
		if child is Control and (child as Control).focus_mode == Control.FOCUS_ALL:
			(child as Control).grab_focus()
			return
	if _overlay_buttons.get_child_count() > 0:
		(_overlay_buttons.get_child(0) as Control).grab_focus()


# ── Input ───────────────────────────────────────────────────────────────────


## ui_cancel is intercepted before QGameRoot sees it, because Escape has three
## jobs here and only the last one is "quit": close a modal, leave the editor
## (both editing surfaces consume every arrow key, so this is the only
## keyboard way out of either), then quit.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _overlay_open():
			_close_overlay()
		elif _editor.has_focus() or _rich.has_focus():
			_first_toolbar_button.grab_focus()
		else:
			quit_game()
		return
	super._unhandled_input(event)


## Shortcuts run after Control._gui_input, so these only fire on combinations
## the focused TextEdit did not claim for itself.
func _shortcut_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	var key: InputEventKey = event
	if not key.ctrl_pressed:
		return
	var handled: bool = true
	match key.keycode:
		KEY_S:
			_on_save_pressed()
		KEY_O:
			_on_files_pressed()
		KEY_N:
			_on_new_pressed()
		KEY_E:
			_on_view_pressed()
		KEY_B:
			_wrap_selection("**")
		KEY_I:
			_wrap_selection("*")
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()


## Overridden so Escape, the Android back button and the window's X all pass
## through the same unsaved-changes guard. `super` is unavailable inside a
## lambda, so the quit is spelled out.
func quit_game() -> void:
	_guard_dirty(func() -> void: get_tree().quit())
