class_name QPowerPolicy
extends RefCounted

## How hard the main loop runs, decided from window state and config. Pure — no
## Node, no singletons — so the decision is unit-testable headless; QGameRoot
## applies the answer to OS / Engine.
##
## Two levers, both measured on the Pi 4 (see PROJECT_STATE.md, "Idle and
## background rendering"):
##
##   on_demand   OS.low_processor_usage_mode. The engine only renders a frame
##               when something on screen changed. Without it every game drew
##               60 full frames a second while sitting still, and on V3D a frame
##               is ~12 ms of GPU whatever is in it: one idle game held the
##               render queue ~80% busy.
##   max_fps     Engine.max_fps while the application does NOT have focus. On
##               demand already stops idle drawing; this also slows the loop
##               itself (input poll, _process, MQTT poll) and caps any animation
##               still running behind another window. It is also the worst-case
##               delay before a background game notices it was clicked, which is
##               why it is not lower.

## Default cap for an unfocused game, frames (and loop iterations) per second.
const BACKGROUND_FPS: int = 10


## Returns {"low_processor": bool, "max_fps": int}.
##
##   on_demand       config render/on_demand. false = classic continuous
##                   rendering — what a framerate benchmark wants.
##   focused         the application has focus.
##   background_fps  config render/background_fps. <= 0 disables the cap.
##   project_max_fps application/run/max_fps, restored when focused.
static func decide(on_demand: bool, focused: bool, background_fps: int,
		project_max_fps: int = 0) -> Dictionary:
	var cap: int = maxi(0, project_max_fps)
	if not focused and background_fps > 0:
		cap = background_fps if cap == 0 else mini(cap, background_fps)
	return {"low_processor": on_demand, "max_fps": cap}
