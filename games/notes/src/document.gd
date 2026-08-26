class_name QNoteDocument
extends RefCounted

## The open note: its text, where it came from, and whether it differs from
## what is on disk. Pure — no Node, no FileAccess, no autoloads (QNoteStore
## owns all IO). That split is what lets the whole editing model be exercised
## headless in tests/run.gd.
##
## `changed` fires on any mutation the UI cares about. Object carries signals,
## so a RefCounted model can emit them without dragging in a Node.

signal changed()

## Shown in the title bar until the note has a heading or a filename.
const UNTITLED: String = "Untitled"

const EXT: String = ".md"

## Filesystem-hostile characters. Windows is not a target, but user:// on
## Android is a real filesystem and a note called "a/b" would silently create a
## directory that the file list can never show.
const _ILLEGAL: String = "/\\:*?\"<>|\n\r\t"

var text: String = ""

## Bare filename inside the notes directory ("shopping.md"), or "" while the
## note has never been saved. Never a path — the store owns the directory.
var filename: String = ""

var dirty: bool = false


func _init(initial_text: String = "", initial_filename: String = "") -> void:
	text = initial_text
	filename = initial_filename


## Single mutation point. Returns true if anything actually changed — TextEdit
## fires `text_changed` for caret-only edits like an undo that restores the
## original string, and marking the document dirty for those would nag the user
## on exit for no reason.
func set_text(new_text: String) -> bool:
	if new_text == text:
		return false
	text = new_text
	dirty = true
	changed.emit()
	return true


## Called by the store after a successful write. Also used after a load, where
## the "saved" state is trivially true.
func mark_saved(saved_filename: String) -> void:
	filename = saved_filename
	dirty = false
	changed.emit()


func word_count() -> int:
	return QMarkdown.word_count(text)


## Raw source length, including Markdown syntax — the number that answers "how
## big is this file", which is what the sibling word count is not.
func char_count() -> int:
	return text.length()


func line_count() -> int:
	return text.split("\n").size()


## First heading wins, then the filename, then UNTITLED. The heading is the
## title the writer actually chose; the filename is only where it landed.
func title() -> String:
	var heading: String = QMarkdown.first_heading(text)
	if heading != "":
		return heading
	if filename != "":
		return base_name()
	return UNTITLED


## Filename without the .md extension.
func base_name() -> String:
	if filename.ends_with(EXT):
		return filename.substr(0, filename.length() - EXT.length())
	return filename


func is_new() -> bool:
	return filename == ""


## The filename a Save of a never-saved note should propose: derived from the
## title so "# Shopping list" saves as shopping-list.md without asking.
func suggest_filename() -> String:
	if filename != "":
		return filename
	return sanitize_filename(title())


## Turn arbitrary user text into a safe bare filename ending in .md. Lowercase
## with dashes because these files are typed at by hand on a phone keyboard.
## Never returns "" — an empty or wholly illegal name becomes "note.md".
static func sanitize_filename(raw: String) -> String:
	var name: String = raw.strip_edges()
	if name.ends_with(EXT):
		name = name.substr(0, name.length() - EXT.length())

	var out: String = ""
	for i in range(name.length()):
		var c: String = name[i]
		if _ILLEGAL.contains(c):
			continue
		if c == " ":
			out += "-"
		else:
			out += c.to_lower()

	# Collapse dash runs and trim leading/trailing dashes and dots. A leading
	# dot would create a hidden file the picker never lists.
	while out.contains("--"):
		out = out.replace("--", "-")
	while out.begins_with("-") or out.begins_with("."):
		out = out.substr(1)
	while out.ends_with("-") or out.ends_with("."):
		out = out.substr(0, out.length() - 1)

	if out == "":
		out = "note"
	return out + EXT


## True when `raw` names a file this app is willing to create.
static func is_valid_filename(raw: String) -> bool:
	var name: String = raw.strip_edges()
	if name == "" or name == "." or name == "..":
		return false
	for i in range(name.length()):
		if _ILLEGAL.contains(name[i]):
			return false
	return not name.begins_with(".")
