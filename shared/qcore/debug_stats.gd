class_name QDebugStats
extends RefCounted

## Runtime performance sampler. Pure logic — no Node, no drawing — so it is
## unit-testable headless (house rule 3). QDebug (debug_hud.gd) owns the
## rendering; this owns the numbers.
##
## The question this exists to answer is narrow: *is something running away?*
## So it reports rates and deltas, not just instantaneous values —
##   - a least-squares slope of RSS over a rolling window (MB/min), which is
##     what a leak actually looks like; a single memory reading never is
##   - object / node counts as a delta against a baseline, plus orphan nodes,
##     which is what a leaked Node looks like in Godot specifically
##   - worst frame time since the last reset, which is what a stall looks like
##
## CPU comes from /proc/self/stat (Linux and Android both). Godot exposes no
## process-CPU monitor, and TIME_PROCESS only covers the main-thread script
## time, not the whole process.

const WINDOW_SEC: float = 60.0
const MAX_SAMPLES: int = 300

## Linux/Android USER_HZ. Constant at 100 on every kernel Godot ships for;
## there is no portable sysconf() from GDScript, so this is asserted, not read.
const CLK_TCK: float = 100.0

## Ignore the first frames: the window is still being created, the first frame
## costs hundreds of ms, and a "min 1 fps" that only ever reports startup makes
## the worst-case columns useless.
const WARMUP_FRAMES: int = 60

# ── instantaneous ────────────────────────────────────────────────────────────
var fps: float = 0.0
var frame_ms: float = 0.0          # wall clock between frames, measured here
var physics_ms: float = 0.0
## Godot's own TIME_PROCESS. Kept because it is the number the engine reports,
## but NOT displayed as frame time: measured on this box it reads 30.0 ms while
## frames are genuinely 16.4 ms apart (60 fps), so it is not a wall-clock frame
## duration and cannot be read as "work done per frame".
var proc_ms: float = 0.0
var draw_calls: int = 0
var draw_items: int = 0
var static_mb: float = 0.0         # Godot's own heap
var static_peak_mb: float = 0.0
var video_mb: float = 0.0
var rss_mb: float = -1.0           # whole process, -1 when /proc is unreadable
var cpu_pct: float = -1.0          # whole process, may exceed 100 (threads)
var objects: int = 0
var nodes: int = 0
var resources: int = 0
var orphans: int = 0
var cores: int = 1

# ── since last reset ─────────────────────────────────────────────────────────
var worst_frame_ms: float = 0.0
var min_fps: float = 0.0
var base_rss_mb: float = -1.0
var base_objects: int = 0
var base_nodes: int = 0
var uptime_sec: float = 0.0
var _last_reset_sec: float = 0.0

var _hist_t: PackedFloat32Array = PackedFloat32Array()
var _hist_mb: PackedFloat32Array = PackedFloat32Array()
var _last_frame_usec: int = 0
var _warm_frames: int = 0
var _last_cpu_sec: float = -1.0
var _last_cpu_wall: float = -1.0
var _have_baseline: bool = false


func _init() -> void:
	cores = maxi(1, OS.get_processor_count())


## Call every frame. Cheap: one clock read plus one monitor read.
func tick_frame() -> void:
	var now: int = Time.get_ticks_usec()
	if _last_frame_usec > 0:
		var ms: float = float(now - _last_frame_usec) / 1000.0
		# Light EMA for the displayed value; the raw sample drives the worst
		# case, because a single 300 ms stall is exactly what we are hunting.
		if frame_ms <= 0.0:
			frame_ms = ms
		else:
			frame_ms += (ms - frame_ms) * 0.1
		if _warm_frames >= WARMUP_FRAMES:
			if ms > worst_frame_ms:
				worst_frame_ms = ms
			var f: float = float(Performance.get_monitor(Performance.TIME_FPS))
			if f > 0.0 and (min_fps <= 0.0 or f < min_fps):
				min_fps = f
	_last_frame_usec = now
	if _warm_frames < WARMUP_FRAMES:
		_warm_frames += 1


## Call at the sample rate (a few Hz). now_sec is monotonic seconds.
func sample(now_sec: float) -> void:
	fps = float(Performance.get_monitor(Performance.TIME_FPS))
	proc_ms = float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
	physics_ms = float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	draw_calls = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	draw_items = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	static_mb = float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	static_peak_mb = float(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)) / 1048576.0
	video_mb = float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0
	objects = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	resources = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	orphans = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))

	rss_mb = read_rss_mb()
	_update_cpu(now_sec)

	if not _have_baseline:
		reset(now_sec)
	uptime_sec = now_sec - _last_reset_sec

	if rss_mb >= 0.0:
		push_mem_sample(now_sec, rss_mb)


## Re-baseline the deltas and peaks. Bound to a key in the HUD so you can zero
## it right before the thing you actually want to measure.
func reset(now_sec: float) -> void:
	_last_reset_sec = now_sec
	base_rss_mb = rss_mb
	base_objects = objects
	base_nodes = nodes
	worst_frame_ms = 0.0
	min_fps = 0.0
	uptime_sec = 0.0
	_warm_frames = WARMUP_FRAMES  # already running; do not re-warm
	_hist_t.clear()
	_hist_mb.clear()
	_have_baseline = true


## Append one memory sample and drop anything older than WINDOW_SEC.
## Separated from sample() so the slope maths can be tested without a process.
func push_mem_sample(t_sec: float, mb: float) -> void:
	_hist_t.append(t_sec)
	_hist_mb.append(mb)
	var cutoff: float = t_sec - WINDOW_SEC
	var drop: int = 0
	while drop < _hist_t.size() and _hist_t[drop] < cutoff:
		drop += 1
	if drop > 0:
		_hist_t = _hist_t.slice(drop)
		_hist_mb = _hist_mb.slice(drop)
	if _hist_t.size() > MAX_SAMPLES:
		_hist_t = _hist_t.slice(_hist_t.size() - MAX_SAMPLES)
		_hist_mb = _hist_mb.slice(_hist_mb.size() - MAX_SAMPLES)


## Least-squares slope of the memory window, in MB per minute.
## NAN when there is not yet enough spread to fit a line — the caller shows
## "…" rather than a number invented from two samples.
func mem_slope_mb_per_min() -> float:
	var n: int = _hist_t.size()
	if n < 4:
		return NAN
	var span: float = _hist_t[n - 1] - _hist_t[0]
	if span < 5.0:
		return NAN
	var sum_t: float = 0.0
	var sum_y: float = 0.0
	var sum_tt: float = 0.0
	var sum_ty: float = 0.0
	for i in range(n):
		var t: float = _hist_t[i] - _hist_t[0]
		var y: float = _hist_mb[i]
		sum_t += t
		sum_y += y
		sum_tt += t * t
		sum_ty += t * y
	var denom: float = float(n) * sum_tt - sum_t * sum_t
	if absf(denom) < 1e-9:
		return NAN
	return ((float(n) * sum_ty - sum_t * sum_y) / denom) * 60.0


func mem_sample_count() -> int:
	return _hist_t.size()


func rss_delta_mb() -> float:
	if rss_mb < 0.0 or base_rss_mb < 0.0:
		return NAN
	return rss_mb - base_rss_mb


## 0 = fine, 1 = watch, 2 = bad. Drives the HUD colours so the reading is
## glanceable rather than something you have to interpret.
func leak_level() -> int:
	if orphans > 0:
		return 2
	var slope: float = mem_slope_mb_per_min()
	if is_nan(slope):
		return 0
	if slope >= 5.0:
		return 2
	if slope >= 1.0:
		return 1
	return 0


func cpu_level() -> int:
	if cpu_pct < 0.0:
		return 0
	if cpu_pct >= 90.0:
		return 2
	if cpu_pct >= 50.0:
		return 1
	return 0


func fps_level(target: float) -> int:
	if fps <= 0.0:
		return 0
	if fps < target * 0.6:
		return 2
	if fps < target * 0.9:
		return 1
	return 0


func _update_cpu(now_sec: float) -> void:
	var cpu: float = read_cpu_seconds()
	if cpu < 0.0:
		cpu_pct = -1.0
		return
	if _last_cpu_sec >= 0.0:
		var d_wall: float = now_sec - _last_cpu_wall
		if d_wall > 0.001:
			cpu_pct = clampf((cpu - _last_cpu_sec) / d_wall * 100.0, 0.0, 100.0 * cores)
	_last_cpu_sec = cpu
	_last_cpu_wall = now_sec


# ── /proc readers (Linux + Android; -1.0 anywhere else) ──────────────────────

## Total CPU seconds this process has burned (user + system, all threads).
static func read_cpu_seconds() -> float:
	var f := FileAccess.open("/proc/self/stat", FileAccess.READ)
	if f == null:
		return -1.0
	var line: String = f.get_line()
	f.close()
	# Field 2 is the executable name in parentheses and may itself contain
	# spaces or ')', so the only safe split point is the LAST ')'.
	var close_paren: int = line.rfind(")")
	if close_paren < 0:
		return -1.0
	var rest: PackedStringArray = line.substr(close_paren + 1).split(" ", false)
	# rest[0] is field 3 (state), so field N is rest[N - 3]:
	# utime = field 14 -> rest[11], stime = field 15 -> rest[12].
	if rest.size() < 13:
		return -1.0
	return (float(rest[11]) + float(rest[12])) / CLK_TCK


## Resident set size of the whole process in MB — the number that matters for
## "is this leaking", since Godot's MEMORY_STATIC excludes driver and
## texture allocations.
static func read_rss_mb() -> float:
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)
	if f == null:
		return -1.0
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.begins_with("VmRSS:"):
			f.close()
			var parts: PackedStringArray = line.split(":", false)
			if parts.size() < 2:
				return -1.0
			var kb: PackedStringArray = parts[1].strip_edges().split(" ", false)
			if kb.is_empty():
				return -1.0
			return float(kb[0]) / 1024.0
	f.close()
	return -1.0
