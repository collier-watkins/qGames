extends SceneTree

## Interactive test: drives the REAL game with real input events.
##
##   godot --path games/notes --resolution 1280x720 --script res://tests/interactive.gd
##
## Deliberately NOT part of `make test-all`, which is headless — this one needs
## a display and a GPU, because it exercises the half that tests/run.gd cannot
## reach. run.gd calls the editor's methods directly; this pushes keys through
## _gui_input, focus, the toolbar and the file store, and it is the only thing
## that would notice if a key stopped arriving at all.
##
## It also writes screenshots to user://shots, which under Wayland is the only
## reliable way to see the layout: an external x11grab returns black, but the
## viewport texture is always correct.

const SHOT_DIR := "user://shots"
const SAVE_NAME := "_interactive_check.md"

var _n := 0
var _game: Node
var _rich: Control
var _fail := 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_game = load("res://src/main.tscn").instantiate()
	root.add_child(_game)


func _ck(label: String, got: Variant, want: Variant) -> void:
	var ok: bool = str(got) == str(want)
	if not ok:
		_fail += 1
	print(("PASS  " if ok else "FAIL  ") + label + ("" if ok
			else "   got=%s want=%s" % [JSON.stringify(str(got)), JSON.stringify(str(want))]))


## A real press and release, routed through Input the way the OS would.
func _key(code: Key, uni: int = 0, shift: bool = false, ctrl: bool = false) -> void:
	for down in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = down
		e.shift_pressed = shift
		e.ctrl_pressed = ctrl
		e.unicode = uni if down else 0
		Input.parse_input_event(e)
	Input.flush_buffered_events()


func _typ(s: String) -> void:
	for c in s:
		_key(KEY_A, c.unicode_at(0))


func _shot(name: String) -> void:
	root.get_texture().get_image().save_png("%s/%s.png" % [SHOT_DIR, name])


func _process(_delta: float) -> bool:
	_n += 1
	match _n:
		4:
			_rich = _game._rich
			# The app opens like a word processor: a blank, unsaved page. It
			# must not seed sample text, and must not adopt whatever note
			# happens to sort first in the notes directory.
			_ck("startup opens a document that was never saved",
					_game._doc.is_new(), true)
			_ck("startup opens an empty document", _game._doc.text, "")
			_ck("a brand-new document is not dirty", _game._doc.dirty, false)
			_ck("the title bar calls it Untitled", _game._doc.title(), "Untitled")
			_game._doc.set_text("# Title\n\nplain")
			_game._push_document()
			_rich.grab_focus()
			_rich.set_caret(_game._doc.text.length())
		8:
			_ck("the rich editor takes keyboard focus", _rich.has_focus(), true)
			_typ(" words")
		12:
			_ck("typed characters reach the document through _gui_input",
					_game._doc.text, "# Title\n\nplain words")
			_ck("the model saw the edit", _game._doc.dirty, true)
			_key(KEY_ENTER)
			_typ("- a")
			_key(KEY_ENTER)
			_typ("b")
		16:
			_ck("Enter continues a bullet list",
					_game._doc.text, "# Title\n\nplain words\n- a\n- b")
			for _i in 3:
				_key(KEY_BACKSPACE)
		20:
			# Three backspaces: the "b", then the "- " marker (which no caret
			# position maps into), then the newline joining the lines.
			_ck("backspace strips the list marker before joining lines",
					_game._doc.text, "# Title\n\nplain words\n- a")
			_rich.set_caret(_game._doc.text.find("plain"))
			_key(KEY_END, 0, true)
		24:
			_ck("shift+End selects to the end of the visual line",
					_rich.selected_text(), "plain words")
			_key(KEY_B, 0, false, true)
		28:
			_ck("ctrl+B bolds the selection",
					_game._doc.text, "# Title\n\n**plain words**\n- a")
			_key(KEY_Z, 0, false, true)
		32:
			_ck("ctrl+Z undoes it", _game._doc.text, "# Title\n\nplain words\n- a")
			_shot("01-rich")
			_key(KEY_ESCAPE)
		36:
			_ck("Escape leaves the editor for the toolbar rather than quitting",
					root.gui_get_focus_owner() == _game._first_toolbar_button, true)
			_game._on_view_pressed()
		40:
			_ck("the view toggles to Source", _game._view_button.text, "Source")
			_ck("the source pane shows the same text",
					_game._editor.text, _game._doc.text)
			_shot("02-source")
			_game._on_view_pressed()
		44:
			_shot("03-split")
			_game._wanted_view = _game.View.RICH
			_game._apply_view()
			_game._doc.set_text("- item\n\nprose")
			_game._push_document()
			_rich.grab_focus()
			_rich.set_caret(_game._doc.text.find("item"))
			_key(KEY_TAB)
		46:
			# Tab indents where an indent is what it means, and moves focus
			# everywhere else — so the toolbar stays keyboard-reachable without
			# the Escape-first handshake the old TextEdit surface required.
			_ck("Tab indents inside a list", _game._doc.text, "  - item\n\nprose")
			_ck("Tab in a list keeps focus in the editor", _rich.has_focus(), true)
			_rich.set_caret(_game._doc.text.find("prose"))
			_key(KEY_TAB)
		48:
			_ck("Tab in prose leaves the editor instead of typing a tab",
					_rich.has_focus(), false)
			_ck("Tab in prose changed no text",
					_game._doc.text, "  - item\n\nprose")
			# ── saving ──
			_game._doc = QNoteDocument.new()
			_game._push_document()
			_game._rich.grab_focus()
			_typ("# Live")
			_key(KEY_ENTER)
			_typ("two words")
		50:
			_ck("a new note types cleanly", _game._doc.text, "# Live\ntwo words")
			_ck("the word count counts rendered words, not markup",
					_game._doc.word_count(), 3)
			_game._save_as(SAVE_NAME)
		54:
			_ck("saving clears the dirty flag", _game._doc.dirty, false)
			_ck("the file on disk holds the Markdown SOURCE, markers and all",
					QNoteStore.new().load_text(SAVE_NAME), "# Live\ntwo words")
			_game._open_file(SAVE_NAME)
			_game._after_load()
		58:
			_ck("reopening rebuilds the editor from disk",
					_game._rich.get_source(), "# Live\ntwo words")
			_ck("a freshly loaded note is clean", _game._doc.dirty, false)
			QNoteStore.new().delete(SAVE_NAME)
			print("")
			print("interactive: %s" % ("all passed" if _fail == 0
					else "%d FAILED" % _fail))
			print("screenshots in %s" % ProjectSettings.globalize_path(SHOT_DIR))
			return true
	return false
