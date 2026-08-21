class_name QMarkdown
extends RefCounted

## Markdown -> BBCode, plus the pure text operations the editor toolbar needs.
##
## Pure by rule: no Node, no file access, and — critically — no autoload
## identifier anywhere in the file or in anything it preloads. An autoload name
## is not in scope while a preload chain compiles under `--script`, which makes
## the whole test runner fail to compile and its statics silently disappear
## (see PROJECT_STATE.md). Keeping this file autoload-free is what makes it
## testable at all.
##
## THE trap this file exists to get right: BBCode and Markdown share `[`.
## Every run of literal document text is passed through escape_bbcode() at the
## moment it is emitted, never before and never after — so a note containing a
## literal `[b]` renders as the four characters `[b]`, and the `[b]` this file
## emits for `**bold**` is never double-escaped.

## Rendered heading sizes, index = level - 1. RichTextLabel's default font is
## ~16px, so h6 stays only slightly above body text.
const HEADING_SIZES: Array[int] = [30, 26, 23, 21, 19, 17]

## RichTextLabel has no horizontal-rule tag. A run of box-drawing characters is
## the honest substitute and survives copy/paste.
const RULE: String = "────────────────────────────────"

const BULLET: String = "•"

## Godot's default theme has no separate monospace face, so RichTextLabel's
## [code] tag renders identically to body text — code in the preview would be
## indistinguishable from prose. Tinting it is the only lever available without
## shipping a font.
const CODE_COLOR: String = "#8fd3c0"

## Characters a backslash may escape, per CommonMark's ASCII punctuation set
## trimmed to what a note actually contains.
const _ESCAPABLE: String = "\\`*_{}[]()#+-.!>~|\"'"

## Deepest list nesting that still indents. Beyond this the rows would march
## off a phone screen.
const _MAX_LIST_LEVEL: int = 5

## Characters that can start inline markup. Anything else is literal text and
## can be consumed in bulk — see the tail of scan_inline().
const _INLINE_SPECIAL: String = "\\`![*_"

## A tab in list indentation counts as this many spaces.
const _TAB_WIDTH: int = 4


# ── Markdown -> BBCode ──────────────────────────────────────────────────────


## The whole document. Blocks are separated by a blank line in the output, so
## paragraphs, headings and lists breathe without the caller adding margins.
static func to_bbcode(src: String) -> String:
	var lines: PackedStringArray = _split_lines(src)
	var blocks: PackedStringArray = PackedStringArray()
	var i: int = 0

	while i < lines.size():
		var line: String = lines[i]

		if line.strip_edges() == "":
			i += 1
			continue

		var fence: String = _fence(line)
		if fence != "":
			var body: PackedStringArray = PackedStringArray()
			i += 1
			while i < lines.size() and _fence(lines[i]) != fence:
				body.append(lines[i])
				i += 1
			# An unterminated fence swallows the rest of the document, which is
			# what CommonMark specifies and what a writer mid-sentence expects.
			i += 1
			blocks.append(code_bbcode(escape_bbcode("\n".join(body))))
			continue

		# Rules are tested before lists: "---" is both a valid rule and a
		# would-be bullet, and the rule reading wins.
		if _is_rule(line):
			blocks.append(RULE)
			i += 1
			continue

		var level: int = heading_level(line)
		if level > 0:
			blocks.append(_heading_bbcode(level, heading_text(line)))
			i += 1
			continue

		if _quote_depth(line) > 0:
			var quoted: PackedStringArray = PackedStringArray()
			while i < lines.size() and _quote_depth(lines[i]) > 0:
				quoted.append(_inline(_strip_quote(lines[i])))
				i += 1
			blocks.append("[indent][i]" + "\n".join(quoted) + "[/i][/indent]")
			continue

		if not _list_item(line).is_empty():
			var rows: PackedStringArray = PackedStringArray()
			var counters: Dictionary = {}
			while i < lines.size():
				var item: Dictionary = _list_item(lines[i])
				if item.is_empty():
					break
				rows.append(_list_row(item, counters))
				i += 1
			blocks.append("\n".join(rows))
			continue

		# Paragraph. A single newline is kept as a line break rather than
		# folded into a space: in a notes app the writer meant the break.
		var para: PackedStringArray = PackedStringArray()
		while i < lines.size():
			var l: String = lines[i]
			if l.strip_edges() == "" or _starts_block(l):
				break
			para.append(_inline(l.strip_edges(true, false)))
			i += 1
		blocks.append("\n".join(para))

	return "\n\n".join(blocks)


## RichTextLabel treats only `[` as special and `[lb]` is its own escape for a
## literal bracket, so one replacement covers it. Escaping `]` as well would be
## harmless but would double the noise in the output for no gain.
static func escape_bbcode(s: String) -> String:
	return s.replace("[", "[lb]")


## Wrap already-escaped text as code. Public so tests can pin the shape in one
## place instead of repeating the colour in twenty expected strings.
static func code_bbcode(escaped: String) -> String:
	return "[code][color=%s]%s[/color][/code]" % [CODE_COLOR, escaped]


# ── Plain text and counting ─────────────────────────────────────────────────


## The document with Markdown structure removed: fence lines, heading hashes,
## list markers, blockquote arrows, emphasis/code markers, backslash escapes
## and link URLs all go; link text and fenced code CONTENT stay. Rules vanish
## entirely — they are punctuation, not prose.
static func to_plain_text(src: String) -> String:
	var lines: PackedStringArray = _split_lines(src)
	var out: PackedStringArray = PackedStringArray()
	var fence: String = ""

	for line in lines:
		var f: String = _fence(line)
		if fence != "":
			if f == fence:
				fence = ""
			else:
				out.append(line)
			continue
		if f != "":
			fence = f
			continue
		if _is_rule(line):
			continue

		var t: String = _strip_quote(line) if _quote_depth(line) > 0 else line
		var level: int = heading_level(t)
		if level > 0:
			t = heading_text(t)
		else:
			var item: Dictionary = _list_item(t)
			if not item.is_empty():
				t = item["text"]
		out.append(_strip_inline(t))

	return "\n".join(out)


## Word count rule, chosen so the number matches what a reader would say the
## note contains:
##   1. Markdown syntax is stripped first (to_plain_text above), so `#`, `**`,
##      `- ` and a link's URL never become words.
##   2. What is left is split on any whitespace.
##   3. A token counts only if it holds a word character: an ASCII letter or
##      digit, or a non-ASCII character outside the punctuation/symbol blocks —
##      so `é` and `日` count while a stray `—`, `•`, `…` or `|` does not.
## Fenced code content counts: the writer typed it and can see it.
static func word_count(src: String) -> int:
	var flat: String = to_plain_text(src).replace("\t", " ").replace("\n", " ")
	var count: int = 0
	for token in flat.split(" ", false):
		if _has_word_char(token):
			count += 1
	return count


## First ATX heading's text, or "" if the document has none. Fenced code is
## skipped so a `# comment` inside a code block never becomes the title.
static func first_heading(src: String) -> String:
	var fence: String = ""
	for line in _split_lines(src):
		var f: String = _fence(line)
		if fence != "":
			if f == fence:
				fence = ""
			continue
		if f != "":
			fence = f
			continue
		if heading_level(line) > 0:
			var t: String = _strip_inline(heading_text(line)).strip_edges()
			if t != "":
				return t
	return ""


# ── Editing helpers (pure; the toolbar is the only caller) ──────────────────


## Wrap a span in a marker, or unwrap it if it is already wrapped. Toggling is
## what a bold button is expected to do on a second press.
static func toggle_wrap(text: String, marker: String) -> String:
	var m: int = marker.length()
	if text.length() >= m * 2 and text.begins_with(marker) and text.ends_with(marker):
		return text.substr(m, text.length() - m * 2)
	return marker + text + marker


## Add `prefix` to a line, or remove it if present. Leading whitespace is
## preserved so toggling a bullet inside a nested list does not unindent it.
## An existing prefix of a DIFFERENT kind (e.g. "- " when asked for "## ") is
## replaced, so heading and bullet buttons never stack markers.
static func toggle_line_prefix(line: String, prefix: String) -> String:
	var indent: String = line.substr(0, line.length() - line.lstrip(" \t").length())
	var body: String = line.substr(indent.length())
	if body.begins_with(prefix):
		return indent + body.substr(prefix.length())
	var existing: String = _leading_marker(body)
	return indent + prefix + body.substr(existing.length())


## The block marker a line already carries ("# ".."###### ", "- ", "> ",
## "1. "), or "" — the part toggle_line_prefix replaces.
static func _leading_marker(body: String) -> String:
	var level: int = heading_level(body)
	if level > 0:
		var m: int = level
		while m < body.length() and body[m] == " ":
			m += 1
		return body.substr(0, m)
	var item: Dictionary = _list_item(body)
	if not item.is_empty():
		return body.substr(0, body.length() - item["text"].length())
	if body.begins_with(">"):
		var q: int = 1
		while q < body.length() and body[q] == " ":
			q += 1
		return body.substr(0, q)
	return ""


# ── Block classification ────────────────────────────────────────────────────


static func _split_lines(src: String) -> PackedStringArray:
	return src.replace("\r\n", "\n").replace("\r", "\n").split("\n")


## True when a line would start a block other than a paragraph — the paragraph
## accumulator's stop condition.
static func _starts_block(line: String) -> bool:
	return _fence(line) != "" or _is_rule(line) or heading_level(line) > 0 \
			or _quote_depth(line) > 0 or not _list_item(line).is_empty()


## "```" or "~~~" if this line opens/closes a fenced block, else "".
static func _fence(line: String) -> String:
	var t: String = line.strip_edges()
	if t.begins_with("```"):
		return "```"
	if t.begins_with("~~~"):
		return "~~~"
	return ""


## ATX heading level 1..6, or 0. `#tag` is deliberately not a heading — a hash
## needs a space after it, or every hashtag in a note becomes an h1.
static func heading_level(line: String) -> int:
	var t: String = line.strip_edges(true, false)
	var n: int = 0
	while n < t.length() and t[n] == "#":
		n += 1
	if n == 0 or n > 6:
		return 0
	if n < t.length() and t[n] != " ":
		return 0
	return n


## The text of an ATX heading, with the closing hashes of `## Title ##` removed.
static func heading_text(line: String) -> String:
	var t: String = line.strip_edges()
	var n: int = 0
	while n < t.length() and t[n] == "#":
		n += 1
	var body: String = t.substr(n).strip_edges()
	while body.ends_with("#"):
		body = body.substr(0, body.length() - 1)
	return body.strip_edges()


## Three or more of the same -, * or _ on their own line, spaces ignored.
static func _is_rule(line: String) -> bool:
	var t: String = line.strip_edges().replace(" ", "").replace("\t", "")
	if t.length() < 3:
		return false
	var c: String = t[0]
	if c != "-" and c != "*" and c != "_":
		return false
	for i in range(t.length()):
		if t[i] != c:
			return false
	return true


static func _quote_depth(line: String) -> int:
	var t: String = line.strip_edges(true, false)
	var d: int = 0
	while t.begins_with(">"):
		d += 1
		t = t.substr(1).strip_edges(true, false)
	return d


static func _strip_quote(line: String) -> String:
	var t: String = line.strip_edges(true, false)
	while t.begins_with(">"):
		t = t.substr(1)
		if t.begins_with(" "):
			t = t.substr(1)
	return t


## {} when the line is not a list item, else
## {ordered: bool, level: int, number: int, text: String, start: int}.
## `start` is the index just past the marker and its trailing space — where the
## item's own text begins, which the rich editor needs to map a caret back.
static func _list_item(line: String) -> Dictionary:
	var indent: int = 0
	var i: int = 0
	while i < line.length():
		if line[i] == " ":
			indent += 1
		elif line[i] == "\t":
			indent += _TAB_WIDTH
		else:
			break
		i += 1
	if i >= line.length():
		return {}

	var level: int = mini(indent / 2, _MAX_LIST_LEVEL)
	var c: String = line[i]

	if c == "-" or c == "*" or c == "+":
		if i + 1 < line.length() and line[i + 1] == " ":
			return {"ordered": false, "level": level, "number": 0, "start": i + 2,
					"text": line.substr(i + 2).strip_edges(true, false)}
		return {}

	if c >= "0" and c <= "9":
		var j: int = i
		while j < line.length() and line[j] >= "0" and line[j] <= "9":
			j += 1
		if j < line.length() and (line[j] == "." or line[j] == ")") \
				and j + 1 < line.length() and line[j + 1] == " ":
			return {"ordered": true, "level": level, "start": j + 2,
					"number": int(line.substr(i, j - i)),
					"text": line.substr(j + 2).strip_edges(true, false)}
	return {}


## One rendered list row. `counters` carries ordered-list numbering per nesting
## level: the first item at a level seeds from its own number, every following
## item increments — so `1. 1. 1.` renders 1, 2, 3 the way Markdown promises,
## and a deeper list restarts when it reappears.
static func _list_row(item: Dictionary, counters: Dictionary) -> String:
	var level: int = item["level"]
	for key in counters.keys():
		if int(key) > level:
			counters.erase(key)

	var prefix: String = ""
	if item["ordered"]:
		if not counters.has(level):
			counters[level] = int(item["number"])
		var n: int = counters[level]
		counters[level] = n + 1
		prefix = "%d.  " % n
	else:
		counters.erase(level)
		prefix = BULLET + "  "

	var depth: int = level + 1
	return "[indent]".repeat(depth) + prefix + _inline(item["text"]) + "[/indent]".repeat(depth)


static func _heading_bbcode(level: int, text: String) -> String:
	var size: int = HEADING_SIZES[clampi(level, 1, 6) - 1]
	return "[font_size=%d][b]%s[/b][/font_size]" % [size, _inline(text)]


# ── Inline scanning ─────────────────────────────────────────────────────────


## Render inline Markdown to BBCode. Thin now: the parse happens in
## scan_inline() and this only turns its tokens into tags.
static func _inline(text: String) -> String:
	return _tokens_to_bbcode(scan_inline(text))


## One left-to-right pass over inline Markdown, emitting a token stream.
##
## Two consumers need this parse: the BBCode renderer above and the rich
## editor's block layout. Two separate scanners would drift, and drift here is
## a nasty class of bug — the caret would sit somewhere other than the
## character the reader sees. So the scan happens once and both outputs are
## derived from it.
##
## A flat list of styled runs is the obvious shape and the wrong one: it cannot
## rebuild `[b]a[i]b[/i][/b]` without reopening tags, which would change
## to_bbcode's output. Push/pop keeps the nesting.
##
## Tokens:
##   {"op": "push", "tag": "b"|"i"|"code"|"url", "url": String}
##   {"op": "pop"}
##   {"op": "text", "text": String, "src": PackedInt32Array}
##
## src[k] is the index IN THE WHOLE DOCUMENT of the character that produced
## text[k]; `base` says where `text` starts in that document. That map is what
## turns a click into a caret position in the source, and it is why markers get
## skipped rather than sat inside: `**` produces no visible character, so it
## has no entry.
##
## Any marker without a partner falls through to the literal branch, so an
## unterminated `**` shows as two asterisks instead of eating the rest of the
## line.
static func scan_inline(text: String, base: int = 0) -> Array:
	var out: Array = []
	var n: int = text.length()
	var i: int = 0

	while i < n:
		var c: String = text[i]

		if c == "\\" and i + 1 < n and _ESCAPABLE.contains(text[i + 1]):
			_emit_text(out, text[i + 1], base + i + 1)
			i += 2
			continue

		# Code spans bind tighter than emphasis: `**x**` inside backticks stays
		# literal because the content is never rescanned.
		if c == "`":
			var run: int = _run_length(text, i, "`")
			var close: int = text.find("`".repeat(run), i + run)
			if close != -1:
				out.append({"op": "push", "tag": "code", "url": ""})
				_emit_text(out, text.substr(i + run, close - i - run), base + i + run)
				out.append({"op": "pop"})
				i = close + run
				continue
			_emit_text(out, c, base + i)
			i += 1
			continue

		if c == "!" and i + 1 < n and text[i + 1] == "[":
			var img: Array = _parse_link(text, i + 1)
			if not img.is_empty():
				# There is no image to load here — the alt text in italics is
				# the honest fallback, and it keeps the words countable.
				out.append({"op": "push", "tag": "i", "url": ""})
				out.append_array(scan_inline(img[0], base + i + 2))
				out.append({"op": "pop"})
				i = img[2]
				continue

		if c == "[":
			var link: Array = _parse_link(text, i)
			if not link.is_empty():
				out.append({"op": "push", "tag": "url", "url": link[1]})
				out.append_array(scan_inline(link[0], base + i + 1))
				out.append({"op": "pop"})
				i = link[2]
				continue
			_emit_text(out, c, base + i)
			i += 1
			continue

		# `***x***` is bold AND italic, and has to be tested BEFORE `**`.
		# Left to the `**` branch, the opener eats two of the three asterisks
		# and the closer eats two of the other three, so a stray `*` lands
		# inside the bold run and another outside it — which is exactly what
		# the rendered text showed before this branch existed.
		if (c == "*" or c == "_") and _run_length(text, i, c) >= 3:
			var triple: String = c.repeat(3)
			var opens: bool = i + 3 < n and text[i + 3] != " "
			if c == "_":
				opens = opens and (i == 0 or not _is_word_char(text[i - 1]))
			if opens:
				var close3: int = _find_closer(text, i + 3, triple)
				if close3 != -1 and (c != "_" or _can_close_underscore(text, close3 + 2)):
					out.append({"op": "push", "tag": "b", "url": ""})
					out.append({"op": "push", "tag": "i", "url": ""})
					out.append_array(scan_inline(
							text.substr(i + 3, close3 - i - 3), base + i + 3))
					out.append({"op": "pop"})
					out.append({"op": "pop"})
					i = close3 + 3
					continue

		if c == "*" and i + 1 < n and text[i + 1] == "*":
			if i + 2 < n and text[i + 2] != " ":
				var close_b: int = _find_closer(text, i + 2, "**")
				if close_b != -1:
					out.append({"op": "push", "tag": "b", "url": ""})
					out.append_array(scan_inline(
							text.substr(i + 2, close_b - i - 2), base + i + 2))
					out.append({"op": "pop"})
					i = close_b + 2
					continue
			_emit_text(out, c, base + i)
			i += 1
			continue

		if (c == "*" or c == "_") and _can_open_emphasis(text, i):
			var close_i: int = _find_closer(text, i + 1, c)
			if close_i != -1 and (c != "_" or _can_close_underscore(text, close_i)):
				out.append({"op": "push", "tag": "i", "url": ""})
				out.append_array(scan_inline(
						text.substr(i + 1, close_i - i - 1), base + i + 1))
				out.append({"op": "pop"})
				i = close_i + 1
				continue
			_emit_text(out, c, base + i)
			i += 1
			continue

		# Emit the whole run of ordinary characters at once. Falling through one
		# character per loop turn is correct but walks the string six times over
		# on a plain paragraph, which is most of a document.
		var run_end: int = i + 1
		while run_end < n and not _INLINE_SPECIAL.contains(text[run_end]):
			run_end += 1
		_emit_text(out, text.substr(i, run_end - i), base + i)
		i = run_end

	return out


## Append literal text, merging into the previous token when that is also text
## so a plain run stays one token instead of one per character.
##
## `src` is a plain Array, not a PackedInt32Array, and that is a performance
## decision rather than a stylistic one. A packed array stored in a Dictionary
## is a VALUE: reading it copies, appending grows the copy, and writing it back
## copies again — so merging character by character costs O(n^2) per line. A
## plain Array is a reference and appends in place. The packed form is built
## once at the end, where it is read from and never grown.
static func _emit_text(out: Array, s: String, src_start: int) -> void:
	if s == "":
		return
	var dst: Array
	if not out.is_empty() and str(out[-1]["op"]) == "text":
		out[-1]["text"] = str(out[-1]["text"]) + s
		dst = out[-1]["src"]
	else:
		dst = []
		out.append({"op": "text", "text": s, "src": dst})
	for k in s.length():
		dst.append(src_start + k)


## Token stream -> BBCode. The stack is what lets `pop` know which tag it is
## closing without the token carrying it.
static func _tokens_to_bbcode(tokens: Array) -> String:
	var out: String = ""
	var stack: Array[String] = []
	for t in tokens:
		match str(t["op"]):
			"push":
				var tag: String = str(t["tag"])
				stack.append(tag)
				if tag == "url":
					out += "[url=" + _escape_url(str(t["url"])) + "]"
				elif tag == "code":
					out += "[code][color=%s]" % CODE_COLOR
				else:
					out += "[" + tag + "]"
			"pop":
				var closing: String = stack.pop_back()
				if closing == "url":
					out += "[/url]"
				elif closing == "code":
					out += "[/color][/code]"
				else:
					out += "[/" + closing + "]"
			"text":
				out += escape_bbcode(str(t["text"]))
	return out


## Next `marker` that can legally close an emphasis span: after the opener, and
## not preceded by a space (`a * b * c` is arithmetic, not italics) or by a
## backslash.
static func _find_closer(text: String, from: int, marker: String) -> int:
	var j: int = from
	while true:
		j = text.find(marker, j)
		if j == -1:
			return -1
		if j > from and text[j - 1] != " " and text[j - 1] != "\\":
			return j
		j += marker.length()
	return -1


## An emphasis run may open only if it is followed by non-space. `_` has the
## extra rule that it may not open inside a word, or every snake_case
## identifier in a note turns italic halfway through.
static func _can_open_emphasis(text: String, i: int) -> bool:
	if i + 1 >= text.length() or text[i + 1] == " ":
		return false
	if text[i] == "_":
		return i == 0 or not _is_word_char(text[i - 1])
	return true


static func _can_close_underscore(text: String, j: int) -> bool:
	return j + 1 >= text.length() or not _is_word_char(text[j + 1])


static func _run_length(text: String, i: int, ch: String) -> int:
	var n: int = 0
	while i + n < text.length() and text[i + n] == ch:
		n += 1
	return n


## [label, url, index_after] for `[label](url)` at i, else []. Bracket nesting
## inside the label is counted so `[see [1]](u)` parses.
static func _parse_link(text: String, i: int) -> Array:
	var n: int = text.length()
	if i >= n or text[i] != "[":
		return []
	var depth: int = 0
	var j: int = i
	while j < n:
		var c: String = text[j]
		if c == "\\":
			j += 2
			continue
		if c == "[":
			depth += 1
		elif c == "]":
			depth -= 1
			if depth == 0:
				break
		j += 1
	if j >= n or depth != 0:
		return []
	if j + 1 >= n or text[j + 1] != "(":
		return []
	var k: int = text.find(")", j + 2)
	if k == -1:
		return []
	return [text.substr(i + 1, j - i - 1), text.substr(j + 2, k - j - 2).strip_edges(), k + 1]


## A URL sits inside a BBCode tag's parameter, where `[lb]` would be parsed as
## part of the URL rather than as an escape. Percent-encoding is the only
## representation that survives.
static func _escape_url(url: String) -> String:
	return url.replace("[", "%5B").replace("]", "%5D")


# ── Plain-text stripping ────────────────────────────────────────────────────


## Inline markers removed rather than translated. Kept separate from _inline()
## on purpose: counting words and rendering have different rules for a link
## (text counts, URL does not) and this stays a dozen lines instead of a flag.
static func _strip_inline(text: String) -> String:
	var out: String = ""
	var n: int = text.length()
	var i: int = 0
	while i < n:
		var c: String = text[i]
		if c == "\\" and i + 1 < n and _ESCAPABLE.contains(text[i + 1]):
			out += text[i + 1]
			i += 2
			continue
		if c == "!" and i + 1 < n and text[i + 1] == "[":
			i += 1
			continue
		if c == "[":
			var link: Array = _parse_link(text, i)
			if not link.is_empty():
				out += _strip_inline(link[0])
				i = link[2]
				continue
			out += c
			i += 1
			continue
		if c == "*" or c == "_" or c == "`":
			i += 1
			continue
		out += c
		i += 1
	return out


static func _is_word_char(c: String) -> bool:
	return _has_word_char(c) or c == "_"


## True if the token carries anything a reader would call a word.
##
## There is no Unicode-aware character class available here — GDScript's RegEx
## is PCRE2 but \w stays ASCII-only without the (*UCP) verb, and relying on an
## undocumented verb to decide a word count is worse than naming the ranges.
## So: ASCII alnum counts, and so does anything above it EXCEPT the blocks that
## are pure punctuation and symbols. That keeps accented Latin (é, U+00E9), CJK
## (U+4E00+) and emoji countable while dropping the em dash, the bullet, the
## ellipsis and the box-drawing characters this file emits for a rule.
static func _has_word_char(token: String) -> bool:
	for i in range(token.length()):
		var code: int = token.unicode_at(i)
		if (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
				or (code >= 97 and code <= 122):
			return true
		if code < 128:
			continue
		if code >= 0x00A0 and code <= 0x00BF:
			continue  # Latin-1 punctuation: ¡ « ° · ¿
		if code >= 0x2000 and code <= 0x2BFF:
			continue  # general punctuation through geometric shapes: — • … ─ →
		if code >= 0x3000 and code <= 0x303F:
			continue  # CJK punctuation: 、 。 「 」
		return true
	return false


# ── Block layout for the rich editor ────────────────────────────────────────


## What a block is. PARA covers plain lines and blank ones; CODE and RULE are
## the two kinds that carry no inline markup.
enum Block { PARA, HEADING, BULLET, ORDERED, CODE, QUOTE, RULE }


## The document as blocks the rich editor lays out, draws and edits.
##
## ONE SOURCE LINE IS ALWAYS ONE BLOCK — no exceptions, fenced code included.
## Two rules fall out of that and both matter:
##
##   1. Markdown proper joins consecutive lines into one paragraph. An editor
##      must not: the writer pressed Return and expects the break to stay where
##      they put it. Blank lines become empty PARA blocks so the caret has
##      somewhere to sit.
##   2. No block ever contains a newline, so every block is exactly one
##      TextParagraph. That is what keeps the editor's layout, hit-testing and
##      caret arithmetic simple enough to be correct.
##
## The ``` fence lines stay VISIBLE, as dim code blocks, rather than being
## hidden the way a WYSIWYG editor would hide them. Hiding a structural marker
## in a Markdown editor makes it unremovable — there would be no way to put the
## caret on it and take it out.
##
## Each block carries:
##   kind      one of Block
##   level     heading level 1..6, list depth, or quote depth
##   marker    gutter text the editor draws itself ("•", "3.")
##   number    ORDERED only: the number the writer actually typed
##   runs      [{text, bold, italic, code, link}] — the styled spans to lay out
##   text      the visible text: the run texts concatenated
##   map       map[k] = offset FROM src_from of the character that produced
##             text[k], plus one final entry for the caret position past the
##             end. Offsets are relative to the line, not the document — see
##             `cache` below.
##   src_from  index of the line's first character
##   src_to    index just past the line's last character
##   body_from index where the block's own text starts, past any line marker —
##             what the editor copies to continue a list on the next line
##   fence     CODE blocks only: true for a ``` delimiter line
##
## Markers produce no visible character and so get no entry in `map`. That one
## fact is what makes the caret step over `**` instead of getting stuck inside
## it, and it is why the map is built during the scan rather than reconstructed
## afterwards.
##
## `cache` is an optional caller-owned dictionary of already-parsed lines. It
## is what makes the editor usable on a long note: without it every keystroke
## rescans the whole document, which measured ~1.4 ms per kilobyte — fine for a
## short note, laggy at twenty. With it, typing reparses the one line that
## changed. The cache is keyed on the line's text and its fence state ONLY,
## which is exactly why `map` holds offsets relative to the line: an unchanged
## line that has merely SHIFTED, because something above it grew, is still a
## cache hit. The caller owns the dictionary so this function keeps no hidden
## state and stays a pure function of its arguments.
static func parse_blocks(src: String, cache: Dictionary = {}) -> Array:
	var blocks: Array = []
	var n: int = src.length()
	var pos: int = 0
	var fence: String = ""
	var counters: Dictionary = {}

	while true:
		var nl: int = src.find("\n", pos)
		var end: int = n if nl == -1 else nl
		var line: String = src.substr(pos, end - pos)
		# A CRLF file keeps its \r in the source but must not show it.
		if line.ends_with("\r"):
			line = line.substr(0, line.length() - 1)

		var f: String = _fence(line)
		var literal: bool = false
		var is_fence: bool = false
		if fence != "":
			literal = true
			if f == fence:
				fence = ""
				is_fence = true
		elif f != "":
			fence = f
			literal = true
			is_fence = true

		var key: String = ("F" if is_fence else ("L" if literal else "N")) + line
		var template: Dictionary
		if cache.has(key):
			template = cache[key]
		else:
			template = _literal_block(line, is_fence) if literal else _line_block(line)
			if cache.size() < BLOCK_CACHE_MAX:
				cache[key] = template

		# Shallow: runs and map are never mutated, so every line reading the
		# same text shares one copy of them.
		var block: Dictionary = template.duplicate()
		block["src_from"] = pos
		block["src_to"] = pos + line.length()
		block["body_from"] = pos + int(template["body_from"])

		# Ordered-list numbering is the one thing that cannot be cached: it
		# depends on the lines above, not on this line's text.
		var kind: int = int(block["kind"])
		if kind == Block.BULLET or kind == Block.ORDERED:
			block["marker"] = _list_marker(kind == Block.ORDERED,
					int(block["level"]), int(block["number"]), counters)
		elif kind == Block.HEADING or kind == Block.RULE \
				or (kind == Block.PARA and str(block["text"]).strip_edges() == ""):
			counters.clear()

		blocks.append(block)
		pos = end + 1
		if nl == -1:
			break

	return blocks


## Cap on the caller's line cache. A note long enough to exceed this is long
## enough that a few misses per keystroke do not matter.
const BLOCK_CACHE_MAX: int = 4000


## One ordinary line, with every offset relative to the start of the line so
## the result can be cached and reused wherever that line ends up.
static func _line_block(line: String) -> Dictionary:
	if line.strip_edges() == "":
		return _make_block(Block.PARA, 0, "", 0, line)

	if _is_rule(line):
		return _make_block(Block.RULE, 0, "", 0, line)

	var level: int = heading_level(line)
	if level > 0:
		var hs: int = _heading_body_start(line)
		return _make_block(Block.HEADING, level,
				_trim_closing_hashes(line.substr(hs)), hs, line)

	var depth: int = _quote_depth(line)
	if depth > 0:
		var qs: int = _quote_body_start(line)
		return _make_block(Block.QUOTE, depth, line.substr(qs), qs, line)

	var item: Dictionary = _list_item(line)
	if not item.is_empty():
		var start: int = int(item["start"])
		var kind: int = Block.ORDERED if bool(item["ordered"]) else Block.BULLET
		var b: Dictionary = _make_block(kind, int(item["level"]),
				line.substr(start), start, line)
		b["number"] = int(item["number"])
		return b

	return _make_block(Block.PARA, 0, line, 0, line)


## A line taken literally: fenced code content, and the fence lines themselves.
## Nothing is scanned, so `**` inside a code block stays two asterisks.
static func _literal_block(line: String, is_fence: bool) -> Dictionary:
	var map: PackedInt32Array = PackedInt32Array()
	map.resize(line.length() + 1)
	for k in line.length() + 1:
		map[k] = k
	var runs: Array = []
	if line != "":
		runs.append({"text": line, "bold": false, "italic": false,
				"code": true, "link": ""})
	return {"kind": Block.CODE, "level": 0, "marker": "", "number": 0,
			"runs": runs, "text": line, "map": map,
			"src_from": 0, "src_to": line.length(), "body_from": 0,
			"fence": is_fence}


static func _make_block(kind: int, level: int, body: String, body_at: int,
		line: String) -> Dictionary:
	var flat: Dictionary = _tokens_to_runs(scan_inline(body, body_at))
	var map: PackedInt32Array = flat["map"]
	# The caret may sit one past the last visible character; that position maps
	# to the end of the body, which is AFTER any closing marker. So typing at
	# the end of **bold** lands outside the emphasis, not inside.
	map.append(body_at + body.length())
	return {"kind": kind, "level": level, "marker": "", "number": 0,
			"runs": flat["runs"], "text": str(flat["text"]), "map": map,
			"src_from": 0, "src_to": line.length(), "body_from": body_at,
			"fence": false}


## Token stream -> flat styled runs plus the visible-to-source map. Adjacent
## runs with identical styling are merged, so a plain paragraph lays out as one
## run instead of one per token.
static func _tokens_to_runs(tokens: Array) -> Dictionary:
	var runs: Array = []
	var text: String = ""
	var map: PackedInt32Array = PackedInt32Array()
	var stack: Array[String] = []
	var urls: Array[String] = []

	for t in tokens:
		match str(t["op"]):
			"push":
				var tag: String = str(t["tag"])
				stack.append(tag)
				if tag == "url":
					urls.append(str(t["url"]))
			"pop":
				var closing: String = stack.pop_back()
				if closing == "url":
					urls.pop_back()
			"text":
				var s: String = str(t["text"])
				var style: Dictionary = {
					"bold": stack.has("b"),
					"italic": stack.has("i"),
					"code": stack.has("code"),
					"link": "" if urls.is_empty() else urls[urls.size() - 1],
				}
				if not runs.is_empty() and _same_style(runs[runs.size() - 1], style):
					runs[runs.size() - 1]["text"] = str(runs[runs.size() - 1]["text"]) + s
				else:
					style["text"] = s
					runs.append(style)
				text += s
				map.append_array(PackedInt32Array(t["src"]))

	return {"runs": runs, "text": text, "map": map}


static func _same_style(run: Dictionary, style: Dictionary) -> bool:
	return bool(run["bold"]) == bool(style["bold"]) \
			and bool(run["italic"]) == bool(style["italic"]) \
			and bool(run["code"]) == bool(style["code"]) \
			and str(run["link"]) == str(style["link"])


## Where a heading's own text starts: past the indent, the hashes, and the
## whitespace after them.
static func _heading_body_start(line: String) -> int:
	var i: int = 0
	while i < line.length() and (line[i] == " " or line[i] == "\t"):
		i += 1
	while i < line.length() and line[i] == "#":
		i += 1
	while i < line.length() and (line[i] == " " or line[i] == "\t"):
		i += 1
	return i


## Where a blockquote's text starts, past every `>` and the space after it.
## Mirrors _quote_depth, which strips all whitespace between markers.
static func _quote_body_start(line: String) -> int:
	var i: int = 0
	while i < line.length() and (line[i] == " " or line[i] == "\t"):
		i += 1
	while i < line.length() and line[i] == ">":
		i += 1
		while i < line.length() and (line[i] == " " or line[i] == "\t"):
			i += 1
	return i


## `## Title ##` -> `Title`. heading_text() does this for the BBCode path, but
## it also strips the leading hashes, and the layout path has already skipped
## those by offset — re-stripping would desynchronise the source map.
static func _trim_closing_hashes(body: String) -> String:
	var out: String = body.strip_edges(false, true)
	while out.ends_with("#"):
		out = out.substr(0, out.length() - 1)
	return out.strip_edges(false, true)


## The gutter text for a list row: "•", or the running number for an ordered
## list. The first item at a level seeds from its own number and every
## following item increments, so `1. 1. 1.` renders 1, 2, 3 the way Markdown
## promises. Deeper levels are dropped so a nested list restarts when it
## reappears.
static func _list_marker(ordered: bool, level: int, number: int,
		counters: Dictionary) -> String:
	for key in counters.keys():
		if int(key) > level:
			counters.erase(key)
	if ordered:
		if not counters.has(level):
			counters[level] = number
		var num: int = int(counters[level])
		counters[level] = num + 1
		return "%d." % num
	counters.erase(level)
	return BULLET
