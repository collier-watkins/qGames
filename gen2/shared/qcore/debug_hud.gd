extends CanvasLayer

## Platform-wide debug HUD. Autoload as "QDebug" — every game gets it for free
## and no game contains a line of profiling code.
##
## Answers one question: is anything running away? FPS and worst frame time for
## runaway processing, RSS slope / object deltas / orphan nodes for leaks, and
## MQTT counters because a stalled publisher looks exactly like a memory leak
## from the outside (a queue that only grows).
##
## Controls — keyboard, gamepad and touch, per house rule 5:
##   F3           cycle off -> compact -> full
##   F4           pop the stats out into a separate OS window (desktop only)
##   F5           re-baseline deltas and peaks
##   the "dbg" chip in the bottom-right   tap to cycle (this is the touch path)
##
## Set debug/hud_stdout to print the same one-line summary once a second, which
## is the only readout you get over ssh on a headless box.
##   Select/Back on a gamepad          cycle
##
## Lives on CanvasLayer 128, so no game can draw over it.

enum Mode { OFF, COMPACT, FULL }

const LAYER: int = 128
const MARGIN: float = 10.0
const FONT_SIZE: int = 12
const TARGET_FPS: float = 60.0

const COL_DIM := "#8b98b0"
const COL_TEXT := "#dce6f5"
const COL_OK := "#7fdc93"
const COL_WARN := "#ffcf5c"
const COL_BAD := "#ff7a7a"

signal mode_changed(mode: Mode)

var stats: QDebugStats = QDebugStats.new()

var _mode: Mode = Mode.OFF
var _enabled: bool = false
var _hz: float = 4.0
var _accum: float = 0.0
var _started_msec: int = 0
var _notes: Dictionary = {}
var _stdout: bool = false
var _stdout_accum: float = 0.0
var _tag_re: RegEx = null

var _panel: PanelContainer
var _text: RichTextLabel
var _chip: Button
var _window: Window
var _window_text: RichTextLabel
var _font: Font = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # keep sampling through a paused tree
	layer = LAYER
	_started_msec = Time.get_ticks_msec()

	var cfg: Node = get_node_or_null("/root/QConfig")
	var want: String = str(cfg.get_value("debug/hud", "auto")) if cfg != null else "auto"
	_enabled = want == "on" or (want != "off" and OS.is_debug_build())
	if not _enabled:
		set_process(false)
		set_process_input(false)
		return

	if cfg != null:
		_hz = maxf(0.5, float(cfg.get_value("debug/hud_hz", 4.0)))
		_stdout = bool(cfg.get_value("debug/hud_stdout", false))

	_build_ui()

	var start: String = str(cfg.get_value("debug/hud_start", "compact")) if cfg != null else "compact"
	match start:
		"full":
			set_mode(Mode.FULL)
		"off":
			set_mode(Mode.OFF)
		_:
			set_mode(Mode.COMPACT)


# ── public API ───────────────────────────────────────────────────────────────

func set_mode(m: Mode) -> void:
	if not _enabled:
		return
	_mode = m
	_panel.visible = _mode != Mode.OFF
	_chip.modulate.a = 1.0 if _mode != Mode.OFF else 0.45
	if _mode != Mode.OFF:
		_refresh()
	mode_changed.emit(_mode)


func cycle() -> void:
	set_mode(((_mode + 1) % Mode.size()) as Mode)


func get_mode() -> Mode:
	return _mode


func is_enabled() -> bool:
	return _enabled


## Re-baseline every delta and peak. Zero it immediately before the thing you
## want to measure and the numbers mean what you think they mean.
func reset_baseline() -> void:
	stats.reset(_now())


## Pin a game-specific row into the HUD, e.g. QDebug.note("cards", 16).
## Pass null to remove. Kept deliberately dumb — it is a debug readout, not a
## metrics system.
func note(key: String, value = null) -> void:
	if value == null:
		_notes.erase(key)
	else:
		_notes[key] = value


# ── sampling ─────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	stats.tick_frame()
	_accum += delta
	if _accum < 1.0 / _hz:
		return
	_accum = 0.0
	stats.sample(_now())
	if _mode != Mode.OFF or _window != null:
		_refresh()
	if _stdout:
		_stdout_accum += 1.0 / _hz
		if _stdout_accum >= 1.0:
			_stdout_accum = 0.0
			print("[qdebug] %s" % _strip_tags(_compact()))


func _now() -> float:
	return float(Time.get_ticks_msec() - _started_msec) / 1000.0


func _input(event: InputEvent) -> void:
	if not _enabled:
		return
	var handled: bool = false
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F3:
				cycle()
				handled = true
			KEY_F4:
				toggle_window()
				handled = true
			KEY_F5:
				reset_baseline()
				handled = true
	elif event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_BACK:
			cycle()
			handled = true
	if handled:
		get_viewport().set_input_as_handled()


# ── UI ───────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	_font = _mono_font()

	_chip = Button.new()
	_chip.text = "dbg"
	_chip.focus_mode = Control.FOCUS_NONE
	_chip.add_theme_font_size_override("font_size", FONT_SIZE)
	if _font != null:
		_chip.add_theme_font_override("font", _font)
	_chip.add_theme_color_override("font_color", Color(COL_TEXT))
	_chip.add_theme_color_override("font_hover_color", Color(COL_OK))
	for s in ["normal", "hover", "pressed", "focus", "disabled"]:
		_chip.add_theme_stylebox_override(s, _box(Color(0.0, 0.0, 0.0, 0.55)))
	_chip.pressed.connect(cycle)
	_anchor_bottom_right(_chip, MARGIN)
	add_child(_chip)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", _box(Color(0.043, 0.063, 0.102, 0.88)))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor_bottom_right(_panel, MARGIN + 30.0)
	add_child(_panel)

	_text = _make_text_label()
	_panel.add_child(_text)


## Anchored to the bottom-right and grown up and to the left, so the readout
## hugs the corner at any resolution without the game laying it out — and stays
## clear of the top of the screen, where game HUDs live.
func _anchor_bottom_right(c: Control, bottom: float) -> void:
	c.anchor_left = 1.0
	c.anchor_right = 1.0
	c.anchor_top = 1.0
	c.anchor_bottom = 1.0
	c.offset_right = -MARGIN
	c.offset_bottom = -bottom
	c.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	c.grow_vertical = Control.GROW_DIRECTION_BEGIN


func _make_text_label() -> RichTextLabel:
	var t := RichTextLabel.new()
	t.bbcode_enabled = true
	t.fit_content = true
	t.scroll_active = false
	t.autowrap_mode = TextServer.AUTOWRAP_OFF
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.add_theme_font_size_override("normal_font_size", FONT_SIZE)
	t.add_theme_color_override("default_color", Color(COL_TEXT))
	if _font != null:
		t.add_theme_font_override("normal_font", _font)
		t.add_theme_font_override("bold_font", _font)
	return t


## Columns only line up in a monospace face. SystemFont resolves "monospace"
## through fontconfig on Linux and through the platform font list on Android;
## if neither has one we fall back to the theme font and lose alignment only.
func _mono_font() -> Font:
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray([
		"monospace", "DejaVu Sans Mono", "Noto Sans Mono", "Liberation Mono",
		"Droid Sans Mono", "Courier New",
	])
	if sf.get_face_count() <= 0:
		return null
	return sf


static func _box(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(1)
	sb.border_color = Color(1.0, 1.0, 1.0, 0.10)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 5.0
	sb.content_margin_bottom = 5.0
	return sb


# ── detached window ──────────────────────────────────────────────────────────

## Pop the readout into its own OS window so it does not sit on top of the game
## — useful when you are watching the numbers and playing at the same time.
## Desktop only; Android has no subwindows and silently keeps the overlay.
func toggle_window() -> void:
	if _window != null:
		_close_window()
		return
	if not DisplayServer.has_feature(DisplayServer.FEATURE_SUBWINDOWS):
		push_warning("[qdebug] no subwindow support on this display server; overlay only")
		set_mode(Mode.FULL)
		return

	# Godot embeds subwindows inside the main viewport by default; that would
	# give a fake window drawn over the game, which is exactly what we are
	# trying to avoid.
	get_tree().root.gui_embed_subwindows = false

	_window = Window.new()
	_window.title = "%s — debug" % ProjectSettings.get_setting("application/config/name", "qGames")
	_window.size = Vector2i(460, 320)
	_window.unresizable = false
	_window.close_requested.connect(_close_window)
	add_child(_window)

	var bg := ColorRect.new()
	bg.color = Color(0.043, 0.063, 0.102)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_window.add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	_window.add_child(margin)

	_window_text = _make_text_label()
	margin.add_child(_window_text)
	_refresh()


func _close_window() -> void:
	if _window == null:
		return
	# Hide before restoring the embed flag: queue_free() is deferred, so the
	# window is still displayed at this point and Viewport refuses the change
	# while any child window is on screen.
	_window.hide()
	_window.queue_free()
	_window = null
	_window_text = null
	get_tree().root.gui_embed_subwindows = true


func _exit_tree() -> void:
	if _window != null:
		_window.queue_free()
		_window = null


# ── rendering ────────────────────────────────────────────────────────────────

func _refresh() -> void:
	var mqtt: Dictionary = _mqtt_stats()
	if _panel.visible:
		_text.text = _compact() if _mode == Mode.COMPACT else _full(mqtt)
	if _window_text != null:
		_window_text.text = _full(mqtt)


func _mqtt_stats() -> Dictionary:
	var t: Node = get_node_or_null("/root/Telemetry")
	if t == null or not t.has_method("io_stats"):
		return {}
	return t.io_stats()


func _compact() -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append(_c("%.0f fps" % stats.fps, _lvl_col(stats.fps_level(TARGET_FPS))))
	parts.append("%.1fms" % stats.frame_ms)
	if stats.cpu_pct >= 0.0:
		parts.append(_c("cpu %.0f%%" % stats.cpu_pct, _lvl_col(stats.cpu_level())))
	if stats.rss_mb >= 0.0:
		parts.append(_c("rss %.0fMB" % stats.rss_mb, _lvl_col(stats.leak_level())))
	parts.append(_c(_slope_text(), _lvl_col(stats.leak_level())))
	var m: Dictionary = _mqtt_stats()
	if not m.is_empty():
		parts.append(_c("mqtt %s" % _mqtt_short(m), _lvl_col(_mqtt_level(m))))
	return "  ".join(parts)


func _full(m: Dictionary) -> String:
	var out: PackedStringArray = PackedStringArray()
	out.append(_row("FPS", "%s  min %s   frame %.2f ms  worst %.1f ms" % [
		_c("%5.1f" % stats.fps, _lvl_col(stats.fps_level(TARGET_FPS))),
		"%.0f" % stats.min_fps if stats.min_fps > 0.0 else "-",
		stats.frame_ms, stats.worst_frame_ms,
	]))
	out.append(_row("CPU", "%s of %d cores   phys %.2f ms" % [
		_c("%5.1f%%" % stats.cpu_pct, _lvl_col(stats.cpu_level())) if stats.cpu_pct >= 0.0 else _c("  n/a", COL_DIM),
		stats.cores, stats.physics_ms,
	]))
	if stats.rss_mb >= 0.0:
		out.append(_row("MEM", "rss %s  %s   %s" % [
			_c("%.1f MB" % stats.rss_mb, _lvl_col(stats.leak_level())),
			_delta_text(stats.rss_delta_mb(), "MB"),
			_c(_slope_text(), _lvl_col(stats.leak_level())),
		]))
	else:
		out.append(_row("MEM", _c("rss unavailable (no /proc)", COL_DIM)))
	out.append(_row("", "godot %.1f MB (peak %.1f)  video %.1f MB" % [
		stats.static_mb, stats.static_peak_mb, stats.video_mb,
	]))
	out.append(_row("OBJ", "objects %d %s  nodes %d %s  orphans %s  res %d" % [
		stats.objects, _delta_text(float(stats.objects - stats.base_objects), ""),
		stats.nodes, _delta_text(float(stats.nodes - stats.base_nodes), ""),
		_c(str(stats.orphans), COL_BAD if stats.orphans > 0 else COL_OK),
		stats.resources,
	]))
	out.append(_row("DRAW", "calls %d  items %d" % [stats.draw_calls, stats.draw_items]))
	out.append_array(_mqtt_rows(m))
	for k in _notes.keys():
		out.append(_row(str(k).to_upper().substr(0, 4), str(_notes[k])))
	out.append(_c("F3 mode · F4 window · F5 reset · up %s" % _dur(stats.uptime_sec), COL_DIM))
	return "\n".join(out)


func _mqtt_rows(m: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if m.is_empty():
		out.append(_row("MQTT", _c("no Telemetry autoload", COL_DIM)))
		return out
	if not bool(m.get("enabled", false)):
		out.append(_row("MQTT", _c("telemetry disabled in config", COL_DIM)))
		return out
	var endpoint: String = str(m.get("endpoint", ""))
	if endpoint == "":
		out.append(_row("MQTT", _c("no broker configured", COL_DIM)))
		return out

	out.append(_row("MQTT", "%s  %s  queue %s  inflight %d" % [
		endpoint,
		_c(str(m.get("state", "?")), _lvl_col(_mqtt_level(m))),
		_c(str(m.get("queued", 0)), COL_WARN if int(m.get("queued", 0)) > 0 else COL_TEXT),
		int(m.get("in_flight", 0)),
	]))
	out.append(_row("", "msgs %d/%d  batches %d  out %s  in %s" % [
		int(m.get("messages_sent", 0)), int(m.get("messages_queued", 0)),
		int(m.get("batches_sent", 0)),
		_bytes(int(m.get("bytes_out", 0))), _bytes(int(m.get("bytes_in", 0))),
	]))
	var fails: int = int(m.get("failures", 0))
	out.append(_row("", "fails %s  last send %s  rtt %s" % [
		_c(str(fails), COL_BAD if fails > 0 else COL_OK),
		_ago(int(m.get("last_sent_msec", -1))),
		("%.0f ms" % float(m.get("last_batch_ms", -1.0))) if float(m.get("last_batch_ms", -1.0)) >= 0.0 else "-",
	]))
	if str(m.get("last_error", "")) != "":
		out.append(_row("", _c("last error: %s" % m.get("last_error"), COL_BAD)))
	return out


func _mqtt_level(m: Dictionary) -> int:
	if m.is_empty() or not bool(m.get("enabled", false)):
		return 0
	if int(m.get("failures", 0)) > 0:
		return 2
	# A queue that never drains is the interesting case: messages asked for but
	# never written to a socket.
	if int(m.get("messages_queued", 0)) - int(m.get("messages_sent", 0)) > 8:
		return 1
	return 0


func _mqtt_short(m: Dictionary) -> String:
	if not bool(m.get("enabled", false)) or str(m.get("endpoint", "")) == "":
		return "off"
	return "q%d e%d %s" % [
		int(m.get("queued", 0)), int(m.get("failures", 0)),
		_bytes(int(m.get("bytes_out", 0))),
	]


# ── formatting helpers ───────────────────────────────────────────────────────

static func _row(tag: String, body: String) -> String:
	return "[color=%s]%-4s[/color] %s" % [COL_DIM, tag, body]


static func _c(s: String, colour: String) -> String:
	return "[color=%s]%s[/color]" % [colour, s]


static func _lvl_col(level: int) -> String:
	match level:
		2:
			return COL_BAD
		1:
			return COL_WARN
		_:
			return COL_OK


func _slope_text() -> String:
	var slope: float = stats.mem_slope_mb_per_min()
	if is_nan(slope):
		return "slope …"
	return "%+.2f MB/min" % slope


static func _delta_text(d: float, unit: String) -> String:
	if is_nan(d):
		return ""
	var s: String = ("%+.1f%s" % [d, unit]) if unit != "" else ("%+d" % int(d))
	return _c(s, COL_DIM if absf(d) < 0.05 else COL_TEXT)


static func _bytes(n: int) -> String:
	if n < 1024:
		return "%d B" % n
	if n < 1048576:
		return "%.1f KB" % (n / 1024.0)
	return "%.1f MB" % (n / 1048576.0)


static func _ago(msec: int) -> String:
	if msec < 0:
		return "never"
	return "%.0fs ago" % ((Time.get_ticks_msec() - msec) / 1000.0)


## bbcode -> plain text, for the stdout line. Built lazily; only ever runs at
## 1 Hz, so the cost is irrelevant.
func _strip_tags(s: String) -> String:
	if _tag_re == null:
		_tag_re = RegEx.new()
		_tag_re.compile("\\[/?[a-z][^\\]]*\\]")
	return _tag_re.sub(s, "", true)


static func _dur(sec: float) -> String:
	if sec < 60.0:
		return "%ds" % int(sec)
	if sec < 3600.0:
		return "%dm%02ds" % [int(sec) / 60, int(sec) % 60]
	return "%dh%02dm" % [int(sec) / 3600, (int(sec) % 3600) / 60]
