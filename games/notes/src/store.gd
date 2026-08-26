class_name QNoteStore
extends RefCounted

## All file IO for the notes app, kept out of QNoteDocument so the document
## model stays pure. RefCounted rather than a Node: FileAccess and DirAccess
## are plain objects, nothing here needs the scene tree.
##
## Everything lives in one flat directory of `.md` files — no subdirectories,
## because the code-first picker only draws a list and a directory the user
## cannot open is worse than one they cannot create. `user://` resolves to
## app-private storage on Android and
## ~/.local/share/godot/app_userdata/<project>/ on Linux; nothing here ever
## touches res://, which is read-only in an export.

const DEFAULT_DIR: String = "user://notes"
const EXT: String = ".md"

var dir_path: String = DEFAULT_DIR

## Last failure, for the status bar. "" when the last operation succeeded.
var last_error: String = ""


func _init(directory: String = DEFAULT_DIR) -> void:
	dir_path = directory


## Idempotent. make_recursive() returns ERR_ALREADY_EXISTS on a second call,
## which is success as far as this app is concerned.
func ensure_dir() -> bool:
	if DirAccess.dir_exists_absolute(dir_path):
		return true
	var err: int = DirAccess.make_dir_recursive_absolute(dir_path)
	if err != OK and err != ERR_ALREADY_EXISTS:
		last_error = "cannot create %s (error %d)" % [dir_path, err]
		return false
	return true


func path_for(filename: String) -> String:
	return dir_path.path_join(filename)


## Bare filenames of every note, sorted case-insensitively. Directories and
## non-.md files are skipped rather than reported: a stray file in the notes
## folder is not an error the writer can act on.
func list() -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir_path):
		return names
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		last_error = "cannot open %s" % dir_path
		return names
	d.list_dir_begin()
	var entry: String = d.get_next()
	while entry != "":
		if not d.current_is_dir() and entry.to_lower().ends_with(EXT):
			names.append(entry)
		entry = d.get_next()
	d.list_dir_end()

	var as_array: Array = Array(names)
	as_array.sort_custom(func(a: String, b: String) -> bool: return a.to_lower() < b.to_lower())
	return PackedStringArray(as_array)


func exists(filename: String) -> bool:
	return FileAccess.file_exists(path_for(filename))


## Returns the file's contents, or "" with last_error set. "" is also a legal
## empty note, so callers that must tell the difference check last_error.
func load_text(filename: String) -> String:
	last_error = ""
	var f: FileAccess = FileAccess.open(path_for(filename), FileAccess.READ)
	if f == null:
		last_error = "cannot read %s (error %d)" % [filename, FileAccess.get_open_error()]
		return ""
	var text: String = f.get_as_text()
	f.close()
	return text


func save_text(filename: String, text: String) -> bool:
	last_error = ""
	if not ensure_dir():
		return false
	var f: FileAccess = FileAccess.open(path_for(filename), FileAccess.WRITE)
	if f == null:
		last_error = "cannot write %s (error %d)" % [filename, FileAccess.get_open_error()]
		return false
	f.store_string(text)
	# close() flushes. Letting the handle fall out of scope would too, but only
	# at an unspecified time — a save must be on disk before the UI says so.
	f.close()
	return true


func delete(filename: String) -> bool:
	last_error = ""
	var err: int = DirAccess.remove_absolute(path_for(filename))
	if err != OK:
		last_error = "cannot delete %s (error %d)" % [filename, err]
		return false
	return true


## Rename refuses to clobber. Overwriting another note silently is the one
## failure mode in a notes app that loses work with no trace.
func rename(from_name: String, to_name: String) -> bool:
	last_error = ""
	if from_name == to_name:
		return true
	if exists(to_name):
		last_error = "%s already exists" % to_name
		return false
	var err: int = DirAccess.rename_absolute(path_for(from_name), path_for(to_name))
	if err != OK:
		last_error = "cannot rename to %s (error %d)" % [to_name, err]
		return false
	return true


## "note.md" -> "note-2.md" -> "note-3.md" until nothing is in the way, so New
## and Save-as never overwrite. Bounded: a writer with 999 identically named
## notes has a different problem.
func unique_name(desired: String) -> String:
	if not exists(desired):
		return desired
	var stem: String = desired
	if stem.ends_with(EXT):
		stem = stem.substr(0, stem.length() - EXT.length())
	for n in range(2, 1000):
		var candidate: String = "%s-%d%s" % [stem, n, EXT]
		if not exists(candidate):
			return candidate
	return "%s-%d%s" % [stem, Time.get_ticks_msec(), EXT]
