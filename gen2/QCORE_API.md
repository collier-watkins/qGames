# qcore API contract — FROZEN for the memory spike

Do not change these signatures. If something here is wrong or missing, say so in
your report; do not silently redesign. Owner of this file and of `shared/qcore/`:
the orchestrator. Everyone else is a consumer.

## Autoloads

Registered per game in `project.godot` under `[autoload]`, prefixed with `*`:

    QConfig="*res://addons/qcore/config.gd"
    QInput="*res://addons/qcore/input_manager.gd"
    Telemetry="*res://addons/qcore/telemetry.gd"
    QDebug="*res://addons/qcore/debug_hud.gd"

Autoload order matters: QConfig first (everything reads it on ready), then
Telemetry, then QDebug (it reads Telemetry).

### QConfig
    QConfig.get_value(key: String, fallback = null)   # "mqtt/broker", "telemetry/enabled", ...
    QConfig.platform() -> String                      # "linux" | "android"
    QConfig.reload() -> void
Layers: baked defaults < user://config.cfg < QGAMES_* env vars.

Keys: mqtt/broker, mqtt/port, mqtt/username, mqtt/password, mqtt/topic_prefix,
telemetry/enabled, telemetry/perf_interval_sec, debug/hud, debug/hud_start,
debug/hud_hz, debug/hud_stdout.

### QInput
    QInput.last_device -> String        # "key" | "pad" | "touch" | "mouse"
    QInput.is_touch_primary() -> bool
    QInput.wants_focus_ui() -> bool     # true for key/pad — show focus rings
    signal QInput.device_changed(device: String)

### Telemetry
    Telemetry.report(pairs: Array) -> void
        # pairs is an Array of [subtopic: String, value]
        # "<game>/ts" is appended automatically, LAST. Never add it yourself.
        # Example: Telemetry.report([["moves", 14], ["result", "win"]])
    Telemetry.report_result(result: String, score: int, score_unit: String,
                            extra: Array = []) -> void
        # THE call for a finished round. Publishes the common schema:
        #   result, score, score_unit, duration_s, <extra...>, ts
        # duration_s is measured from the previous report_result (or launch).
        # Example:
        #   Telemetry.report_result(Telemetry.RESULT_WIN, board.moves, "moves",
        #           [["moves", board.moves]])
    Telemetry.report(pairs: Array) -> void        # escape hatch, see above
    Telemetry.report_image(subtopic: String, png: PackedByteArray, pairs: Array = []) -> void
    Telemetry.io_stats() -> Dictionary   # for QDebug; games do not need it
    Telemetry.RESULT_WIN | RESULT_LOSS | RESULT_QUIT | RESULT_DONE

The game id is DECLARED, not derived. Set it per game in project.godot:

    [telemetry]
    game_id="memory"

It only falls back to application/config/name (lowercased, spaces to
underscores) when unset — and that fallback is a trap: renaming the game then
silently repoints every Home Assistant sensor at a topic nobody publishes.

### QDebug
The debug HUD. Every game gets it from the autoload; no game contains
profiling code. Enabled in debug builds by default (`debug/hud` = "auto").

    QDebug.cycle() -> void                  # off -> compact -> full
    QDebug.set_mode(m: QDebug.Mode) -> void  # Mode.OFF | COMPACT | FULL
    QDebug.get_mode() -> QDebug.Mode
    QDebug.is_enabled() -> bool
    QDebug.toggle_window() -> void          # pop out to a separate OS window
    QDebug.reset_baseline() -> void         # re-zero deltas and peaks
    QDebug.note(key: String, value = null) -> void   # add a game-specific row
    QDebug.stats -> QDebugStats             # the raw numbers
    signal QDebug.mode_changed(mode: Mode)

Controls: F3 cycle, F4 detach window, F5 re-baseline, gamepad Select cycles,
and the "dbg" chip in the bottom-right corner is the touch path.

Shows FPS and worst frame time (measured wall clock, not TIME_PROCESS), process
CPU%, RSS with a least-squares MB/min slope, object/node deltas, orphan nodes,
draw calls, and MQTT I/O. Colours: green fine, amber watch, red bad.

## Classes (class_name, not autoloads)

### QGameRoot extends Control
Base class for a game's main scene root.
    func _game_ready() -> void      # override this instead of _ready()
    func quit_game() -> void
    var safe_area: Rect2i           # DisplayServer.get_display_safe_area()
    signal pointer_down(pos: Vector2)
    signal pointer_up(pos: Vector2)
    signal pointer_move(pos: Vector2)
Handles Escape, Android back button, and window close automatically.

**Sizing guarantee.** `size` is already equal to the viewport when `_game_ready()`
runs, so it is safe to lay out immediately. This is not free behaviour — a Control
scene root is 0x0 during `_ready()` and never emits `resized` to recover, which
silently renders an empty screen. QGameRoot anchors top-left and drives `size` from
the viewport itself. Do not set full-rect anchors on the root; connect to `resized`
for relayout and it will fire on every viewport change.

### QTelemetrySchema extends RefCounted
The wire schema, pure and unit-tested. Games do not call it — they call
Telemetry — but this is where the contract lives.
    const CORE_KEYS = ["result", "score", "score_unit", "duration_s"]
    static func resolve_game_id(declared: String, display_name: String) -> String
    static func build_result_pairs(result, score, score_unit, duration_s,
                                   extra: Array = []) -> Array

Topics are flat scalars — one value per topic, no JSON — because a Home
Assistant MQTT sensor binds one topic to one state. `ts` is never in the pair
list; `Telemetry.report()` appends it last, which is the whole ordering
guarantee. See `mqtt.yaml` at the repo root for the consuming side.

### QDebugStats extends RefCounted
The sampler behind QDebug. Pure — no Node, no drawing, unit-tested headless.
Read `QDebug.stats` rather than constructing one.
    stats.fps, frame_ms, worst_frame_ms, min_fps      # frame_ms is wall clock
    stats.cpu_pct, cores                              # -1 where /proc is absent
    stats.rss_mb, static_mb, video_mb
    stats.objects, nodes, resources, orphans
    func mem_slope_mb_per_min() -> float              # NAN until it has evidence
    func leak_level() -> int                          # 0 fine, 1 watch, 2 bad

### QMqttClient extends RefCounted
Used by Telemetry. Games never touch it directly. Carries cumulative I/O
counters (messages_queued/sent, bytes_out/in, failures, last_error) surfaced
through `Telemetry.io_stats()`.

## House rules

1. **Code-first.** Build UI in code. Each game has exactly one `.tscn`: a bare
   root node with the main script attached. No visual scene composition.
2. **Typed GDScript everywhere.** `var x: int = 0`, `func f(a: String) -> bool:`.
3. **Simulation separate from rendering.** Pure model classes extend RefCounted,
   import no Node, and are unit-testable headless. Nodes only draw and dispatch.
4. **Never branch on OS in a game.** Ask QInput or QConfig.
5. **Both input paths always work.** Every action reachable by touch must also be
   reachable via ui_up/ui_down/ui_left/ui_right/ui_accept (keyboard + gamepad
   d-pad, free via Control focus). Test both.
6. Godot 4.7.2. Compatibility renderer. 60 FPS cap.
