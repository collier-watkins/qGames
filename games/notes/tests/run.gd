extends SceneTree

## Dependency-free headless test runner for the Notes model. Invoke as:
##   godot --headless --path games/notes --script res://tests/run.gd
##
## Only autoload-free classes are exercised here. An autoload identifier
## (QConfig, Telemetry, QInput) anywhere in a preload chain is not in scope
## while the chain compiles under --script: the whole script fails to compile
## and its statics silently cease to exist. That is why QMarkdown, QNoteDocument
## and QNoteStore never mention one, and why src/main.gd is not touched below.

const QMarkdownT := preload("res://src/markdown.gd")
const QDocumentT := preload("res://src/document.gd")
const QStoreT := preload("res://src/store.gd")
const QRichEditT := preload("res://src/richedit.gd")

## Store tests write to a scratch directory, not to the real user://notes —
## running the suite must never touch the writer's own files.
const TEST_DIR: String = "user://notes_selftest"

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	_test_escaping()
	_test_headings()
	_test_emphasis()
	_test_inline_code()
	_test_fenced_code()
	_test_lists()
	_test_quotes_and_rules()
	_test_links()
	_test_paragraphs_and_empty()
	_test_unterminated_markers()
	_test_nesting()
	_test_plain_text()
	_test_word_count()
	_test_editing_helpers()
	_test_document()
	_test_filenames()
	_test_store_roundtrip()

	_test_scan_inline()
	_test_blocks()
	_test_block_kinds()
	_test_rich_caret()
	_test_rich_editing()
	_test_rich_lists()
	_test_rich_undo()
	_test_rich_formatting()
	_test_rich_hit_testing()
	_test_rich_marker_backspace()
	_test_rich_canonical()
	_test_block_cache()
	_test_format_at_caret()
	_test_format_block_kind()
	_test_set_line_prefix()
	_test_undo_redo_availability()
	_test_bold_italic_triple()

	print("")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(test_name: String, condition: bool) -> void:
	if condition:
		_pass += 1
		print("PASS  %s" % test_name)
	else:
		_fail += 1
		print("FAIL  %s" % test_name)


## The expected rendering of a code span, built from the converter's own colour
## constant so a theme tweak does not rewrite a dozen assertions.
func _code(inner: String) -> String:
	return QMarkdownT.code_bbcode(inner)


func _check_eq(test_name: String, got: Variant, want: Variant) -> void:
	if got == want:
		_pass += 1
		print("PASS  %s" % test_name)
	else:
		_fail += 1
		print("FAIL  %s" % test_name)
		print("        want: %s" % str(want))
		print("        got:  %s" % str(got))


# ── BBCode escaping: the bug this converter exists to not have ──────────────


func _test_escaping() -> void:
	# A note that talks ABOUT BBCode must not become BBCode. [lb] is
	# RichTextLabel's own escape for a literal '[', so this renders as the
	# characters the writer typed.
	_check_eq("a literal [b] is escaped, not emitted as a tag",
			QMarkdownT.to_bbcode("[b]hello[/b]"), "[lb]b]hello[lb]/b]")
	_check_eq("escape_bbcode only touches the opening bracket",
			QMarkdownT.escape_bbcode("a[b]c"), "a[lb]b]c")
	_check_eq("an already-escaped [lb] escapes again rather than collapsing",
			QMarkdownT.escape_bbcode("[lb]"), "[lb]lb]")
	_check_eq("brackets inside emphasis are escaped, emphasis still emitted",
			QMarkdownT.to_bbcode("**[url]**"), "[b][lb]url][/b]")
	_check_eq("brackets inside a code span are escaped",
			QMarkdownT.to_bbcode("`[color=red]`"), _code("[lb]color=red]"))
	_check_eq("a heading's brackets are escaped",
			QMarkdownT.to_bbcode("# [i]x[/i]"),
			"[font_size=30][b][lb]i]x[lb]/i][/b][/font_size]")
	# The converter's own tags must survive untouched — the failure mode of
	# escaping too late is bold text rendering as the literal string "[b]".
	_check("emitted tags are never double-escaped",
			QMarkdownT.to_bbcode("**x**").begins_with("[b]"))


# ── Block syntax ────────────────────────────────────────────────────────────


func _test_headings() -> void:
	_check_eq("h1 gets the largest size",
			QMarkdownT.to_bbcode("# Title"), "[font_size=30][b]Title[/b][/font_size]")
	_check_eq("h6 gets the smallest size",
			QMarkdownT.to_bbcode("###### Six"), "[font_size=17][b]Six[/b][/font_size]")
	_check_eq("seven hashes is not a heading", QMarkdownT.heading_level("####### x"), 0)
	_check_eq("a hash with no space is a hashtag, not a heading",
			QMarkdownT.heading_level("#tag"), 0)
	_check_eq("closing hashes are trimmed", QMarkdownT.heading_text("## Title ##"), "Title")
	_check_eq("leading whitespace still parses as a heading",
			QMarkdownT.heading_level("  ## x"), 2)
	_check_eq("inline syntax inside a heading is converted",
			QMarkdownT.to_bbcode("## a **b**"),
			"[font_size=26][b]a [b]b[/b][/b][/font_size]")


func _test_emphasis() -> void:
	_check_eq("**x** is bold", QMarkdownT.to_bbcode("**x**"), "[b]x[/b]")
	_check_eq("*x* is italic", QMarkdownT.to_bbcode("*x*"), "[i]x[/i]")
	_check_eq("_x_ is italic", QMarkdownT.to_bbcode("_x_"), "[i]x[/i]")
	_check_eq("an underscore inside a word does not italicise",
			QMarkdownT.to_bbcode("snake_case_name"), "snake_case_name")
	_check_eq("a spaced asterisk is multiplication, not emphasis",
			QMarkdownT.to_bbcode("2 * 3 * 4"), "2 * 3 * 4")
	_check_eq("a backslash escapes a marker",
			QMarkdownT.to_bbcode("\\*not italic\\*"), "*not italic*")


func _test_inline_code() -> void:
	_check_eq("a code span carries the mono tag and the code colour verbatim",
			QMarkdownT.to_bbcode("`x`"),
			"[code][color=" + QMarkdownT.CODE_COLOR + "]x[/color][/code]")
	_check_eq("backticks make a code span",
			QMarkdownT.to_bbcode("`x`"), _code("x"))
	_check_eq("code spans win over emphasis inside them",
			QMarkdownT.to_bbcode("`**x**`"), _code("**x**"))
	_check_eq("a double-backtick span may contain a single backtick",
			QMarkdownT.to_bbcode("``a ` b``"), _code("a ` b"))


func _test_fenced_code() -> void:
	_check_eq("a fenced block is code, verbatim",
			QMarkdownT.to_bbcode("```\na\nb\n```"), _code("a\nb"))
	_check_eq("tildes fence too", QMarkdownT.to_bbcode("~~~\na\n~~~"), _code("a"))
	_check_eq("markdown inside a fence stays literal",
			QMarkdownT.to_bbcode("```\n# not a heading\n**not bold**\n```"),
			_code("# not a heading\n**not bold**"))
	_check_eq("an unterminated fence swallows the rest of the document",
			QMarkdownT.to_bbcode("```\nstill code"), _code("still code"))


func _test_lists() -> void:
	_check_eq("a dash bullet renders one indented row",
			QMarkdownT.to_bbcode("- a"), "[indent]•  a[/indent]")
	_check_eq("consecutive bullets form one block, not one block each",
			QMarkdownT.to_bbcode("- a\n- b"),
			"[indent]•  a[/indent]\n[indent]•  b[/indent]")
	_check_eq("asterisk and plus are bullets too",
			QMarkdownT.to_bbcode("* a\n+ b"),
			"[indent]•  a[/indent]\n[indent]•  b[/indent]")
	_check_eq("an ordered list keeps its start number",
			QMarkdownT.to_bbcode("3. a\n4. b"),
			"[indent]3.  a[/indent]\n[indent]4.  b[/indent]")
	_check_eq("ordered items renumber sequentially however they are written",
			QMarkdownT.to_bbcode("1. a\n1. b\n1. c"),
			"[indent]1.  a[/indent]\n[indent]2.  b[/indent]\n[indent]3.  c[/indent]")
	_check_eq("two spaces of indent nests one level",
			QMarkdownT.to_bbcode("- a\n  - b"),
			"[indent]•  a[/indent]\n[indent][indent]•  b[/indent][/indent]")
	_check_eq("inline syntax inside a list item is converted",
			QMarkdownT.to_bbcode("- **a**"), "[indent]•  [b]a[/b][/indent]")
	_check_eq("a dash with no space is not a list", QMarkdownT.to_bbcode("-a"), "-a")


func _test_quotes_and_rules() -> void:
	_check_eq("a blockquote is indented italics",
			QMarkdownT.to_bbcode("> a"), "[indent][i]a[/i][/indent]")
	_check_eq("consecutive quote lines merge into one block",
			QMarkdownT.to_bbcode("> a\n> b"), "[indent][i]a\nb[/i][/indent]")
	_check_eq("--- is a rule", QMarkdownT.to_bbcode("---"), QMarkdownT.RULE)
	_check_eq("*** and ___ are rules too",
			QMarkdownT.to_bbcode("***\n\n___"), QMarkdownT.RULE + "\n\n" + QMarkdownT.RULE)
	# The reading matters: "--" is too short for a rule and has no space, so it
	# is neither a rule nor a bullet — it is text.
	_check_eq("two dashes are not a rule", QMarkdownT.to_bbcode("--"), "--")


func _test_links() -> void:
	_check_eq("a link becomes a url tag",
			QMarkdownT.to_bbcode("[t](http://x)"), "[url=http://x]t[/url]")
	_check_eq("link text is itself converted",
			QMarkdownT.to_bbcode("[**t**](u)"), "[url=u][b]t[/b][/url]")
	_check_eq("a bracket in the URL is percent-encoded, not [lb]-escaped",
			QMarkdownT.to_bbcode("[t](http://x/[1])"), "[url=http://x/%5B1%5D]t[/url]")
	_check_eq("a bracket pair with no target stays literal text",
			QMarkdownT.to_bbcode("[just brackets]"), "[lb]just brackets]")
	_check_eq("an image falls back to its alt text",
			QMarkdownT.to_bbcode("![alt](u)"), "[i]alt[/i]")


func _test_paragraphs_and_empty() -> void:
	_check_eq("empty input renders as nothing", QMarkdownT.to_bbcode(""), "")
	_check_eq("whitespace-only input renders as nothing",
			QMarkdownT.to_bbcode("   \n\n\t\n"), "")
	_check_eq("a single newline inside a paragraph is kept as a line break",
			QMarkdownT.to_bbcode("a\nb"), "a\nb")
	_check_eq("a blank line separates blocks",
			QMarkdownT.to_bbcode("a\n\nb"), "a\n\nb")
	_check_eq("several blank lines still separate exactly one block",
			QMarkdownT.to_bbcode("a\n\n\n\nb"), "a\n\nb")
	_check_eq("CRLF input parses the same as LF",
			QMarkdownT.to_bbcode("# a\r\n\r\nb"), QMarkdownT.to_bbcode("# a\n\nb"))
	_check_eq("a heading ends the paragraph above it without a blank line",
			QMarkdownT.to_bbcode("text\n# h"), "text\n\n[font_size=30][b]h[/b][/font_size]")


func _test_unterminated_markers() -> void:
	_check_eq("an unterminated ** is two literal asterisks",
			QMarkdownT.to_bbcode("**bold"), "**bold")
	_check_eq("an unterminated * is a literal asterisk",
			QMarkdownT.to_bbcode("*italic"), "*italic")
	_check_eq("an unterminated backtick is a literal backtick",
			QMarkdownT.to_bbcode("`code"), "`code")
	_check_eq("an unterminated link is literal, with the bracket escaped",
			QMarkdownT.to_bbcode("[t](u"), "[lb]t](u")
	# An emphasis run with nothing but a space in it cannot open (the marker
	# must be followed by non-space), so both halves fall through as literals.
	# Note "** **" alone on a line is NOT this case — it is a thematic break,
	# four asterisks with the spaces ignored, which CommonMark also says.
	_check_eq("an empty emphasis run is literal",
			QMarkdownT.to_bbcode("a ** ** b"), "a ** ** b")
	_check_eq("asterisks with spaces between are a rule on their own line",
			QMarkdownT.to_bbcode("** **"), QMarkdownT.RULE)


func _test_nesting() -> void:
	_check_eq("italic inside bold",
			QMarkdownT.to_bbcode("**a *b* c**"), "[b]a [i]b[/i] c[/b]")
	_check_eq("code inside bold",
			QMarkdownT.to_bbcode("**a `b`**"), "[b]a " + _code("b") + "[/b]")
	_check_eq("a link inside a bullet inside a heading-led document",
			QMarkdownT.to_bbcode("# h\n\n- see [x](y)"),
			"[font_size=30][b]h[/b][/font_size]\n\n[indent]•  see [url=y]x[/url][/indent]")


# ── Plain text and counting ─────────────────────────────────────────────────


func _test_plain_text() -> void:
	_check_eq("heading hashes are stripped",
			QMarkdownT.to_plain_text("## Title"), "Title")
	_check_eq("emphasis markers are stripped",
			QMarkdownT.to_plain_text("**a** *b* `c`"), "a b c")
	_check_eq("a list marker is stripped but the text survives",
			QMarkdownT.to_plain_text("- item"), "item")
	_check_eq("link text survives, the URL does not",
			QMarkdownT.to_plain_text("[text](http://example.com)"), "text")
	_check_eq("a rule leaves nothing behind", QMarkdownT.to_plain_text("---"), "")
	_check_eq("fence lines go, fenced content stays",
			QMarkdownT.to_plain_text("```\ncode here\n```"), "code here")


func _test_word_count() -> void:
	_check_eq("empty document has no words", QMarkdownT.word_count(""), 0)
	_check_eq("plain prose counts as written",
			QMarkdownT.word_count("one two three"), 3)
	_check_eq("heading hashes are not words",
			QMarkdownT.word_count("# Title here"), 2)
	_check_eq("emphasis markers are not words",
			QMarkdownT.word_count("**bold** and *italic*"), 3)
	_check_eq("bullets are not words", QMarkdownT.word_count("- a\n- b"), 2)
	_check_eq("a link counts its text, not its URL",
			QMarkdownT.word_count("see [the docs](http://example.com/a/b)"), 3)
	_check_eq("a horizontal rule is not a word",
			QMarkdownT.word_count("a\n\n---\n\nb"), 2)
	_check_eq("punctuation alone is not a word",
			QMarkdownT.word_count("— • … | ..."), 0)
	_check_eq("accented Latin and CJK are words",
			QMarkdownT.word_count("café 日本語"), 2)
	_check_eq("runs of whitespace do not inflate the count",
			QMarkdownT.word_count("a   \t  b\n\n\nc"), 3)
	_check_eq("fenced code content counts",
			QMarkdownT.word_count("```\nprint hello\n```"), 2)
	_check_eq("first_heading finds the title",
			QMarkdownT.first_heading("intro\n\n# The Title\n\n# Later"), "The Title")
	_check_eq("a hash inside a fence is not the title",
			QMarkdownT.first_heading("```\n# fake\n```\n# real"), "real")
	_check_eq("no heading yields an empty title",
			QMarkdownT.first_heading("just prose"), "")


func _test_editing_helpers() -> void:
	_check_eq("toggle_wrap wraps", QMarkdownT.toggle_wrap("x", "**"), "**x**")
	_check_eq("toggle_wrap unwraps an already-wrapped span",
			QMarkdownT.toggle_wrap("**x**", "**"), "x")
	_check_eq("toggle_wrap on empty text still produces the markers",
			QMarkdownT.toggle_wrap("", "*"), "**")
	_check_eq("toggle_line_prefix adds", QMarkdownT.toggle_line_prefix("a", "- "), "- a")
	_check_eq("toggle_line_prefix removes", QMarkdownT.toggle_line_prefix("- a", "- "), "a")
	_check_eq("toggle_line_prefix preserves indentation",
			QMarkdownT.toggle_line_prefix("    a", "- "), "    - a")
	_check_eq("a different marker is replaced, not stacked",
			QMarkdownT.toggle_line_prefix("- a", "## "), "## a")
	_check_eq("an existing heading marker is replaced",
			QMarkdownT.toggle_line_prefix("### a", "- "), "- a")


# ── Document model ──────────────────────────────────────────────────────────


func _test_document() -> void:
	var d: QNoteDocument = QDocumentT.new()
	_check("a fresh document is clean", not d.dirty)
	_check_eq("a fresh document is Untitled", d.title(), QDocumentT.UNTITLED)
	_check("a fresh document is new", d.is_new())

	_check("set_text reports a real change", d.set_text("# Hello\n\nworld"))
	_check("set_text dirties the document", d.dirty)
	_check_eq("the title comes from the first heading", d.title(), "Hello")
	_check_eq("word count ignores the hash", d.word_count(), 2)
	_check_eq("char count is the raw source length", d.char_count(), len("# Hello\n\nworld"))
	_check_eq("line count includes blank lines", d.line_count(), 3)

	# TextEdit emits text_changed for edits that restore the original string;
	# re-dirtying on those would nag the writer on exit for nothing.
	_check("setting identical text is not a change", not d.set_text("# Hello\n\nworld"))

	d.mark_saved("hello.md")
	_check("mark_saved clears the dirty flag", not d.dirty)
	_check("a saved document is no longer new", not d.is_new())
	_check_eq("base_name drops the extension", d.base_name(), "hello")

	var untitled: QNoteDocument = QDocumentT.new("no heading here", "notes.md")
	_check_eq("without a heading the filename is the title", untitled.title(), "notes")


func _test_filenames() -> void:
	_check_eq("spaces become dashes and case is folded",
			QDocumentT.sanitize_filename("Shopping List"), "shopping-list.md")
	_check_eq("path separators are removed, not encoded",
			QDocumentT.sanitize_filename("a/b:c"), "abc.md")
	_check_eq("an existing extension is not doubled",
			QDocumentT.sanitize_filename("notes.md"), "notes.md")
	_check_eq("dash runs collapse and edges are trimmed",
			QDocumentT.sanitize_filename("  --a   b--  "), "a-b.md")
	_check_eq("an unusable name falls back rather than returning empty",
			QDocumentT.sanitize_filename("///"), "note.md")
	_check("a dotfile name is rejected", not QDocumentT.is_valid_filename(".hidden"))
	_check("a name with a slash is rejected", not QDocumentT.is_valid_filename("a/b.md"))
	_check("an ordinary name is accepted", QDocumentT.is_valid_filename("a-b.md"))


# ── Store (real IO, in a scratch directory) ─────────────────────────────────


func _test_store_roundtrip() -> void:
	var store: QNoteStore = QStoreT.new(TEST_DIR)
	_check("ensure_dir creates the notes directory", store.ensure_dir())
	_check("ensure_dir is idempotent", store.ensure_dir())

	for stale in store.list():
		store.delete(stale)

	_check("an empty store lists nothing", store.list().is_empty())
	_check("saving reports success", store.save_text("b.md", "# B\n\nbody"))
	_check("saving a second note reports success", store.save_text("a.md", "# A"))
	_check_eq("list is sorted and holds both notes",
			Array(store.list()), ["a.md", "b.md"])
	_check_eq("text round-trips byte for byte", store.load_text("b.md"), "# B\n\nbody")
	_check("exists is true for a saved note", store.exists("a.md"))

	_check_eq("unique_name leaves a free name alone", store.unique_name("free.md"), "free.md")
	_check_eq("unique_name sidesteps a collision", store.unique_name("a.md"), "a-2.md")

	_check("rename succeeds", store.rename("a.md", "c.md"))
	_check("the old name is gone after a rename", not store.exists("a.md"))
	_check("the new name is present after a rename", store.exists("c.md"))
	_check("rename refuses to clobber an existing note", not store.rename("c.md", "b.md"))
	_check("a refused rename reports why", store.last_error != "")

	_check("delete succeeds", store.delete("b.md"))
	_check("the deleted note is gone", not store.exists("b.md"))
	_check("reading a missing note fails rather than returning silence",
			store.load_text("gone.md") == "" and store.last_error != "")

	for leftover in store.list():
		store.delete(leftover)
	DirAccess.remove_absolute(TEST_DIR)


# ── Block layout ────────────────────────────────────────────────────────────


## The corpus every layout invariant is checked against. Deliberately awkward:
## markers that do not close, a code fence holding Markdown, a list whose
## numbers all say 1, and CRLF.
const LAYOUT_CORPUS: Array[String] = [
	"",
	"plain",
	"# Head\n\nBody **bold** and *it* and `co`.",
	"- one\n- two\n  1. a\n  1. b\n\n> quoted\n\n---",
	"```\nx = **not bold**\n```\ntail",
	"unterminated ** marker and a [link](u)",
	"crlf\r\nlines\r\n",
	"## Closed hashes ##\n\n\n\nblank runs",
]


func _test_blocks() -> void:
	for src in LAYOUT_CORPUS:
		var blocks: Array = QMarkdownT.parse_blocks(src)
		var label: String = JSON.stringify(src.substr(0, 22))

		# One block per source line, always. The editor's whole caret model
		# rests on this: no block may contain a newline.
		_check_eq("one block per line for %s" % label,
				blocks.size(), src.split("\n").size())
		for b in blocks:
			_check("no block holds a newline in %s" % label,
					not str(b["text"]).contains("\n"))

		for b in blocks:
			var text: String = str(b["text"])
			var map: PackedInt32Array = b["map"]
			_check_eq("map covers every visible char + 1 in %s" % label,
					map.size(), text.length() + 1)

			var monotonic: bool = true
			var in_range: bool = true
			for k in range(map.size()):
				if k > 0 and map[k] < map[k - 1]:
					monotonic = false
				if map[k] < 0 or int(b["src_from"]) + map[k] > src.length():
					in_range = false
			_check("map is monotonic in %s" % label, monotonic)
			_check("map stays inside the source in %s" % label, in_range)

			# THE invariant. Every visible character must be the source
			# character its map entry names — this is what guarantees a click
			# lands on the character the reader is pointing at.
			var faithful: bool = true
			for k in text.length():
				if src[int(b["src_from"]) + map[k]] != text[k]:
					faithful = false
			_check("every visible char matches its source char in %s" % label,
					faithful)


func _test_block_kinds() -> void:
	var b: Array = QMarkdownT.parse_blocks(
			"# H\n- one\n1. two\n> q\n---\n```\nc\n```\nplain")
	var kinds: Array = []
	for x in b:
		kinds.append(int(x["kind"]))
	_check_eq("block kinds are recognised in order", kinds, [
		QMarkdownT.Block.HEADING, QMarkdownT.Block.BULLET,
		QMarkdownT.Block.ORDERED, QMarkdownT.Block.QUOTE,
		QMarkdownT.Block.RULE, QMarkdownT.Block.CODE,
		QMarkdownT.Block.CODE, QMarkdownT.Block.CODE,
		QMarkdownT.Block.PARA,
	])
	_check("a fence line is flagged as one", bool(b[5]["fence"]))
	_check("fenced content is not flagged as a fence", not bool(b[6]["fence"]))
	_check_eq("fenced content is taken literally", str(b[6]["text"]), "c")

	var nums: Array = QMarkdownT.parse_blocks("1. a\n1. b\n1. c")
	var markers: Array = []
	for x in nums:
		markers.append(str(x["marker"]))
	_check_eq("`1. 1. 1.` numbers 1, 2, 3 the way Markdown promises",
			markers, ["1.", "2.", "3."])


func _test_scan_inline() -> void:
	# to_bbcode is now rendered FROM the token stream, so the stream has to
	# carry enough to rebuild it. These pin the shape the editor reads.
	var toks: Array = QMarkdownT.scan_inline("a **b** c")
	var ops: Array = []
	for t in toks:
		ops.append(str(t["op"]))
	_check_eq("emphasis brackets its text with push/pop",
			ops, ["text", "push", "text", "pop", "text"])
	_check_eq("the token stream still renders the same BBCode",
			QMarkdownT.to_bbcode("a **b** c"), "a [b]b[/b] c")


# ── The rich editor ─────────────────────────────────────────────────────────


func _new_editor(src: String) -> QRichEditT:
	var e: QRichEditT = QRichEditT.new()
	e.size = Vector2(600, 400)
	e.set_source(src)
	return e


func _test_rich_caret() -> void:
	var e: QRichEditT = _new_editor("a **bold** z")
	e.set_caret(0)
	var stops: Array = [0]
	for _i in 20:
		var n: int = e._next_caret_stop(e.caret_index())
		if n == e.caret_index():
			break
		e.set_caret(n)
		stops.append(n)
	# Visible text is "a bold z". The markers at 2,3 and 8,9 have no visible
	# character, so no caret position maps into them.
	_check_eq("the caret steps over markers, never into them",
			stops, [0, 1, 4, 5, 6, 7, 10, 11, 12])

	e.set_caret(12)
	e.insert_text("X")
	_check_eq("typing past the last visible char lands outside the emphasis",
			e.get_source(), "**bold**" if false else "a **bold** zX")
	e.free()


func _test_rich_editing() -> void:
	var e: QRichEditT = _new_editor("")
	for c in "Hello":
		e.insert_text(c, true)
	_check_eq("typing appends", e.get_source(), "Hello")
	_check_eq("the caret follows what was typed", e.caret_index(), 5)

	# Backspace takes ONE character, so an emphasis emptied by it leaves its
	# markers rather than half of one.
	e.set_source("a **b** c")
	e.set_caret(7)
	e._backspace()
	_check_eq("backspace removes the visible character", e.get_source(), "a **** c")

	e.set_source("ab\ncd")
	e.set_caret(3)
	e._backspace()
	_check_eq("backspace at the start of a line joins it to the one above",
			e.get_source(), "abcd")

	e.set_source("abc")
	e.set_caret(1)
	e._delete_forward()
	_check_eq("delete removes the character ahead", e.get_source(), "ac")
	e.free()


func _test_rich_lists() -> void:
	var e: QRichEditT = _new_editor("- one")
	e.set_caret(5)
	e._newline()
	_check_eq("Enter continues a bullet list", e.get_source(), "- one\n- ")
	e._newline()
	_check_eq("Enter on an empty item leaves the list", e.get_source(), "- one\n")

	e.set_source("3. three")
	e.set_caret(8)
	e._newline()
	_check_eq("Enter bumps an ordered item's number", e.get_source(), "3. three\n4. ")
	e.free()


func _test_rich_undo() -> void:
	var e: QRichEditT = _new_editor("base")
	e.set_caret(4)
	for c in "XYZ":
		e.insert_text(c, true)
	e.undo()
	_check_eq("undo steps back over a coalesced run", e.get_source(), "base")
	e.redo()
	_check_eq("redo reapplies it", e.get_source(), "baseXYZ")

	# A cleared history must not leave a coalescing group open, or the first
	# snapshot of the next document is swallowed and undo does nothing.
	e.set_source("fresh")
	e.set_caret(5)
	e.insert_text("!", true)
	e.undo()
	_check_eq("undo works on a document loaded after an edit", e.get_source(), "fresh")
	e.free()


func _test_rich_formatting() -> void:
	var e: QRichEditT = _new_editor("make me bold")
	e._anchor = 5
	e._caret = 7
	e.toggle_wrap("**")
	_check_eq("bold wraps the selection", e.get_source(), "make **me** bold")
	_check_eq("the same words stay selected afterwards", e.selected_text(), "**me**")

	e.set_source("plain line")
	e.set_caret(0)
	e.cycle_heading()
	_check_eq("heading cycles up a level", e.get_source(), "# plain line")
	for _i in 6:
		e.cycle_heading()
	_check_eq("heading cycles off past h6", e.get_source(), "plain line")
	e.free()


func _test_rich_hit_testing() -> void:
	var e: QRichEditT = _new_editor("# Head\n\nA **bold** word here.")
	# Round-trip every caret stop through its on-screen rectangle. If the
	# caret is drawn one character away from where a click resolves, this is
	# what catches it.
	var src: int = e._canonical(0)
	var checked: int = 0
	var wrong: int = 0
	while true:
		var r: Rect2 = e._caret_rect(src)
		var back: int = e._source_at_point(
				Vector2(r.position.x + 1.0, r.position.y + r.size.y * 0.5))
		if back != src:
			wrong += 1
		checked += 1
		var nxt: int = e._next_caret_stop(src)
		if nxt == src:
			break
		src = nxt
	_check("every caret position round-trips through its screen rect (%d stops)"
			% checked, wrong == 0)
	e.free()


## A shared line cache must not be able to change the answer. This edits a
## document in the MIDDLE, so every line below it shifts position while its
## text stays the same — the exact case relative maps exist to make a cache
## hit, and the exact case where an absolute map would return stale offsets.
func _test_block_cache() -> void:
	var cache: Dictionary = {}
	QMarkdownT.parse_blocks("# H\n\nfirst **bold**\n- x\n- y\n> q\n", cache)
	var edited: String = "# H\n\nfirst **bold** and more words\n- x\n- y\n> q\n"
	var warm: Array = QMarkdownT.parse_blocks(edited, cache)
	var cold: Array = QMarkdownT.parse_blocks(edited)

	_check_eq("a warm cache yields the same block count", warm.size(), cold.size())
	var same: bool = true
	for i in mini(warm.size(), cold.size()):
		for field in ["kind", "level", "marker", "text", "src_from", "src_to",
				"body_from", "fence"]:
			if str(warm[i][field]) != str(cold[i][field]):
				same = false
		if str(warm[i]["map"]) != str(cold[i]["map"]):
			same = false
	_check("a cached parse is identical to a cold one, field for field", same)

	# And the cache genuinely holds the unchanged lines.
	_check("the cache retained the lines that did not change", cache.size() >= 6)


func _test_rich_marker_backspace() -> void:
	# Markers have no visible character, so no caret position maps into one.
	# Backspace at the start of a block's text therefore has to strip the
	# marker deliberately, or a stray "- " could never be deleted at all.
	var e: QRichEditT = _new_editor("text\n- item")
	e.set_caret(e.get_source().find("item"))
	e._backspace()
	_check_eq("backspace at the start of an item strips its marker",
			e.get_source(), "text\nitem")
	e._backspace()
	_check_eq("backspace again joins the line to the one above",
			e.get_source(), "textitem")

	e.set_source("# Heading")
	e.set_caret(2)
	e._backspace()
	_check_eq("backspace at the start of a heading strips the hashes",
			e.get_source(), "Heading")

	e.set_source("> quoted")
	e.set_caret(2)
	e._backspace()
	_check_eq("backspace at the start of a quote strips the marker",
			e.get_source(), "quoted")
	e.free()


## Every source index — including the ones inside markers, which the caret can
## never occupy — must resolve to a legal caret stop.
func _test_rich_canonical() -> void:
	var src: String = "# Head\n\na **b** c\n- item"
	var e: QRichEditT = _new_editor(src)
	var bad: int = 0
	for i in range(src.length() + 1):
		var c: int = e._canonical(i)
		if e._canonical(c) != c:
			bad += 1
	_check("snapping a source index to a caret stop is idempotent", bad == 0)
	_check_eq("index 0 snaps past the heading hashes to the first letter",
			e._canonical(0), 2)
	e.free()


## What the toolbar reads to decide whether B is lit. A toolbar that reports
## the wrong state is worse than one that reports none, because it invites you
## to press a button that does the opposite of what it looks like.
func _test_format_at_caret() -> void:
	var e: QRichEditT = _new_editor("a **bold** and *it* and `co` end")
	var src: String = e.get_source()

	e.set_caret(src.find("bold") + 2)
	var f: Dictionary = e.format_at_caret()
	_check("inside bold, bold reads on", bool(f["bold"]))
	_check("inside bold, italic reads off", not bool(f["italic"]))

	e.set_caret(src.find("it") + 1)
	_check("inside italic, italic reads on", bool(e.format_at_caret()["italic"]))

	e.set_caret(src.find("co") + 1)
	_check("inside a code span, code reads on", bool(e.format_at_caret()["code"]))

	e.set_caret(src.find("end") + 1)
	f = e.format_at_caret()
	_check("in plain prose nothing reads on",
			not bool(f["bold"]) and not bool(f["italic"]) and not bool(f["code"]))

	# An inline style counts as ON for a selection only if it holds throughout,
	# so the button answers "will pressing this turn it off?".
	e.set_source("**all bold here**")
	e.select_all()
	_check("a fully bold selection reads bold", bool(e.format_at_caret()["bold"]))

	e.set_source("**bold** and plain")
	e.select_all()
	_check("a partly bold selection does NOT read bold",
			not bool(e.format_at_caret()["bold"]))
	e.free()


func _test_format_block_kind() -> void:
	var e: QRichEditT = _new_editor("### Third level\n\n- item\n\n1. numbered\n\n> quoted\n\nplain")
	var src: String = e.get_source()
	for probe in [["Third", QMarkdownT.Block.HEADING, 3],
			["item", QMarkdownT.Block.BULLET, 0],
			["numbered", QMarkdownT.Block.ORDERED, 0],
			["quoted", QMarkdownT.Block.QUOTE, 1],
			["plain", QMarkdownT.Block.PARA, 0]]:
		e.set_caret(src.find(str(probe[0])))
		var f: Dictionary = e.format_at_caret()
		_check_eq("the block kind at %s" % probe[0], int(f["kind"]), int(probe[1]))
		if int(probe[1]) == QMarkdownT.Block.HEADING:
			_check_eq("the heading level at %s" % probe[0],
					int(f["level"]), int(probe[2]))
	e.free()


## The style dropdown SETS rather than toggles — picking Heading 2 twice leaves
## you in Heading 2, which is what every word processor's style list does.
func _test_set_line_prefix() -> void:
	var e: QRichEditT = _new_editor("plain line")
	e.set_caret(3)
	e.set_line_prefix("## ")
	_check_eq("a style applies its marker", e.get_source(), "## plain line")
	e.set_line_prefix("## ")
	_check_eq("applying the same style again is a no-op, not a double marker",
			e.get_source(), "## plain line")
	e.set_line_prefix("### ")
	_check_eq("another style replaces the first", e.get_source(), "### plain line")
	e.set_line_prefix("")
	_check_eq("Normal text strips the marker", e.get_source(), "plain line")

	# The caret rides the same CHARACTER, not the same offset — the marker in
	# front of it changed length underneath.
	e.set_source("hello world")
	e.set_caret(6)
	e.set_line_prefix("# ")
	_check_eq("the caret stays on the character it was on",
			e.get_source().substr(e.caret_index(), 5), "world")

	# A code fence must not be restyled: it would change what the code says.
	e.set_source("```\ncode line\n```")
	e.select_all()
	e.set_line_prefix("> ")
	_check_eq("fenced code is left alone", e.get_source(), "```\ncode line\n```")
	e.free()


func _test_undo_redo_availability() -> void:
	var e: QRichEditT = _new_editor("text")
	_check("a freshly loaded document has nothing to undo", not e.can_undo())
	_check("and nothing to redo", not e.can_redo())
	e.set_caret(4)
	e.insert_text("!")
	_check("after an edit, undo is available", e.can_undo())
	e.undo()
	_check("after undoing, redo is available", e.can_redo())
	e.free()


## `***x***` is bold AND italic. It has to be matched before `**`, or the
## opener takes two of the three asterisks and the closer takes two of the
## other three, stranding one inside the emphasis and one outside it. That bug
## was invisible while the rendered text was only a preview; it became a
## visible pair of stray asterisks the moment the rendered text was the thing
## being typed into.
func _test_bold_italic_triple() -> void:
	_check_eq("*** is bold and italic",
			QMarkdownT.to_bbcode("a ***both*** b"), "a [b][i]both[/i][/b] b")
	_check_eq("___ likewise",
			QMarkdownT.to_bbcode("a ___both___ b"), "a [b][i]both[/i][/b] b")
	_check_eq("no asterisk leaks into the emphasis",
			QMarkdownT.to_plain_text("a ***both*** b"), "a both b")

	var blocks: Array = QMarkdownT.parse_blocks("A ***word*** here")
	_check_eq("and none leaks into the rendered text",
			str(blocks[0]["text"]), "A word here")
	var styled: bool = false
	for r in blocks[0]["runs"]:
		if str(r["text"]) == "word":
			styled = bool(r["bold"]) and bool(r["italic"])
	_check("the run really is both bold and italic", styled)

	# Still a horizontal rule when it is alone on a line — that is a block-level
	# decision and must not be swallowed by the inline scanner.
	_check_eq("*** alone on a line is still a rule",
			int((QMarkdownT.parse_blocks("***")[0])["kind"]), QMarkdownT.Block.RULE)
	_check_eq("an unmatched *** stays literal",
			QMarkdownT.to_bbcode("a ***loose b"), "a ***loose b")

