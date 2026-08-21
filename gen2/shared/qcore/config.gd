extends Node

## Layered per-environment config. Autoload as "QConfig".
##
##   baked defaults  <  res://build_config.cfg  <  user://config.cfg  <  env
##
## res://build_config.cfg is written at EXPORT time by tools/bake_config.sh and
## travels inside the .pck. It is what lets a shipped game reach the broker with
## no environment set up on the target machine at all — which matters on Android,
## where there is no shell to export a variable from, and on a desktop launcher,
## which does not inherit your shell environment either. It is absent in a
## source checkout, and its absence is harmless.
##
## user:// resolves to app-private storage on Android and
## ~/.local/share/godot/app_userdata/<project> on Linux, so one code path
## covers both. Environment overrides are for dev and CI only — Android does
## not meaningfully expose them.

const CONFIG_PATH := "user://config.cfg"

## Written into the export by tools/bake_config.sh; never in the repository.
## HOLDS CREDENTIALS in a shipped build — see that script's header.
const BUILD_CONFIG_PATH := "res://build_config.cfg"

const DEFAULTS := {
	# MQTT is ON by default. The broker and credentials are NOT baked in — they
	# come from the environment or user://config.cfg, and a blank broker still
	# means "publish nowhere", silently. So this switch turning on changes
	# nothing for a machine that has not been told where to publish, and means
	# a machine that has been told needs no further per-game setup.
	"mqtt/enabled": true,
	"mqtt/broker": "",
	"mqtt/port": 1883,
	"mqtt/username": "",
	"mqtt/password": "",
	"mqtt/topic_prefix": "qGames",
	"telemetry/enabled": true,
	# Override for the MQTT namespace, qGames/<game_id>/... Normally left empty:
	# the id is declared per game in project.godot under [telemetry], because it
	# is a build-time fact rather than a per-machine setting. This key exists so
	# tests and CI can retarget a game without editing the project. Deriving the
	# id from application/config/name — the old behaviour — meant renaming a game
	# silently repointed every Home Assistant sensor at a topic nobody publishes.
	"telemetry/game_id": "",
	"telemetry/perf_interval_sec": 0.0,  # 0 disables perf sampling
	# Debug HUD (QDebug). "auto" = on in debug builds only; "on" forces it into
	# release exports, which is how you profile the artifact you actually ship.
	"debug/hud": "auto",                 # "auto" | "on" | "off"
	"debug/hud_start": "compact",        # "off" | "compact" | "full"
	"debug/hud_hz": 4.0,                 # sample rate; drawing cost, not accuracy
	"debug/hud_stdout": false,           # also print one line/sec — headless, CI, ssh
	# Per-app appearance. Games ignore it; the notes editor reads it.
	"ui/theme": "light",
	# How big everything is drawn, independent of window size. Every game
	# honours it (QGameRoot), and Ctrl +/-/0 changes it at runtime.
	"ui/scale": 1.0,
	# Stamped into the export by tools/bake_config.sh. A source checkout keeps
	# these defaults, which is how you tell a dev run from a shipped build.
	"build/version": "0.0.0-dev",
	"build/commit": "",
	"build/built_at": "",
}

## MQTT settings also answer to their bare names, so one exported environment
## holds the broker for every game without a QGAMES_ prefix on each line:
##
##   MQTT_BROKER, MQTT_PORT, MQTT_USERNAME, MQTT_PASSWORD, MQTT_TOPIC_PREFIX
##
## QGAMES_-prefixed names still win, so a single game can be pointed elsewhere
## without disturbing the rest.
const BARE_ENV: Dictionary = {
	"mqtt/broker": "MQTT_BROKER",
	"mqtt/port": "MQTT_PORT",
	"mqtt/username": "MQTT_USERNAME",
	"mqtt/password": "MQTT_PASSWORD",
	"mqtt/topic_prefix": "MQTT_TOPIC_PREFIX",
}

var _values: Dictionary = {}
## Only what set_value() was given: the subset save() is allowed to write.
var _written: Dictionary = {}


func _ready() -> void:
	reload()


func reload() -> void:
	_values = DEFAULTS.duplicate(true)
	_merge_file(BUILD_CONFIG_PATH)
	_merge_file(CONFIG_PATH)

	for key in BARE_ENV.keys():
		var bare: String = str(BARE_ENV[key])
		if OS.has_environment(bare):
			_values[key] = _coerce(OS.get_environment(bare), _values[key])

	for key in _values.keys():
		var env_name: String = "QGAMES_" + String(key).replace("/", "_").to_upper()
		if OS.has_environment(env_name):
			_values[key] = _coerce(OS.get_environment(env_name), _values[key])


## Overlay one ConfigFile onto the current values. A missing file is normal:
## the baked one only exists in an export, and the user one only after someone
## has changed a setting.
func _merge_file(path: String) -> void:
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return
	for section in cf.get_sections():
		for key in cf.get_section_keys(section):
			_values["%s/%s" % [section, key]] = cf.get_value(section, key)


## Version of the running build: a semver from git tags, or "0.0.0-dev" in a
## source checkout that has never been exported.
func version() -> String:
	return str(get_value("build/version", "0.0.0-dev"))


func build_info() -> Dictionary:
	return {
		"version": version(),
		"commit": str(get_value("build/commit", "")),
		"built_at": str(get_value("build/built_at", "")),
	}


func get_value(key: String, fallback = null):
	return _values.get(key, fallback)


## Remember a setting for next launch.
##
## Only keys passed through here are ever written. Writing the whole value set
## would copy the MQTT password out of the environment and into a file on disk
## — a credential moving somewhere nobody asked it to go, which is precisely
## the kind of thing that is never noticed until it leaks.
func set_value(key: String, value) -> void:
	_values[key] = value
	_written[key] = value


## Merge the remembered settings into user://config.cfg, preserving whatever
## else is already in the file. Returns false if the write failed.
func save() -> bool:
	if _written.is_empty():
		return true
	var cf := ConfigFile.new()
	cf.load(CONFIG_PATH)  # a missing file is fine; we are about to create it
	for key in _written.keys():
		var parts: PackedStringArray = String(key).split("/", false, 1)
		if parts.size() != 2:
			continue
		cf.set_value(parts[0], parts[1], _written[key])
	return cf.save(CONFIG_PATH) == OK


func platform() -> String:
	if OS.has_feature("android"):
		return "android"
	return "linux"


## True on the Pi — used to dial back effects. Checked once, cheap to call.
func is_low_power() -> bool:
	if OS.has_feature("android"):
		return false
	return OS.get_processor_name().to_lower().contains("cortex")


static func _coerce(raw: String, like):
	if like is bool:
		return raw.to_lower() in ["1", "true", "yes", "on"]
	if like is int:
		return int(raw)
	if like is float:
		return float(raw)
	return raw
