class_name ChessAudio
extends Node

## Sound effects, synthesised at load rather than shipped as files.
##
## Ten short sounds as .wav would be a licence to check, a folder to import and
## a few hundred kilobytes in every one of the four architecture builds. They
## are a few lines of arithmetic instead, which also means one place to change
## the character of the whole set and no asset that can go missing from a pack.
##
## Everything here is modal synthesis: a burst of noise to excite the body, and
## a handful of damped sinusoids to ring. That is genuinely how a wooden piece
## on a wooden board sounds — a broadband knock plus a couple of resonances
## that die away in a few tens of milliseconds — and it is why these read as
## wood rather than as beeps.
##
## NOTE FOR THE ORCHESTRATOR: this belongs in qcore once a second game wants
## sound. It is here because QCORE_API.md is frozen and a consumer does not get
## to redesign the shared library. Nothing about it is chess-specific except
## the list of cues.

## 22.05 kHz is enough for a knock whose energy is all below 5 kHz, and halves
## the buffer against 44.1.
const MIX_RATE: int = 22050
## Voices. A capture that cut off the move before it would sound like a fault;
## four is more than any position can trigger at once.
const VOICES: int = 4

## Cue names. The view asks for these; how they are made is nobody else's
## business.
const MOVE: String = "move"
const CAPTURE: String = "capture"
const CASTLE: String = "castle"
const CHECK: String = "check"
const PROMOTE: String = "promote"
const SELECT: String = "select"
const ILLEGAL: String = "illegal"
const WIN: String = "win"
const LOSS: String = "loss"
const DRAW: String = "draw"

var enabled: bool = true

var _streams: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _next: int = 0


func _ready() -> void:
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)
	_build_all()


func play(cue: String) -> void:
	if not enabled or not _streams.has(cue):
		return
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = _streams[cue]
	p.play()


func set_enabled(on: bool) -> void:
	enabled = on
	if not on:
		for p in _players:
			p.stop()


# --------------------------------------------------------------- the cue list

func _build_all() -> void:
	# A piece set down: a knock with two body resonances, gone in 90 ms.
	_streams[MOVE] = _knock(0.10, [[430.0, 0.55, 0.030], [1180.0, 0.22, 0.016]], 0.42, 0.006)
	# A capture is the same knock lower and harder — one piece displacing
	# another, not one piece landing.
	_streams[CAPTURE] = _knock(0.26, [[196.0, 0.62, 0.055], [520.0, 0.30, 0.028],
			[1450.0, 0.14, 0.012]], 0.60, 0.010)
	# Castling is two pieces, so it is two knocks. The gap is what says "that
	# was one move, and two things moved".
	_streams[CASTLE] = _sequence([
		[0.000, _knock(0.10, [[430.0, 0.50, 0.030], [1180.0, 0.20, 0.016]], 0.40, 0.006)],
		[0.085, _knock(0.10, [[360.0, 0.45, 0.032], [990.0, 0.18, 0.016]], 0.36, 0.006)],
	], 0.20)
	# Check is the only cue that is a note rather than a knock — it is
	# information, not an event on the board, and it has to cut through.
	_streams[CHECK] = _tones(0.52, [[0.00, 659.25, 0.34, 0.10], [0.09, 987.77, 0.30, 0.10]])
	_streams[PROMOTE] = _tones(0.78, [
		[0.00, 523.25, 0.26, 0.11], [0.09, 659.25, 0.26, 0.11],
		[0.18, 783.99, 0.28, 0.13],
	])
	# A tick, not a click: the same knock at a tenth of the level and a third
	# of the length. Picking a piece up should be felt more than heard.
	_streams[SELECT] = _knock(0.04, [[760.0, 0.16, 0.010]], 0.10, 0.003)
	_streams[ILLEGAL] = _knock(0.24, [[132.0, 0.42, 0.050], [176.0, 0.22, 0.040]], 0.14, 0.014)
	_streams[WIN] = _tones(1.30, [
		[0.00, 523.25, 0.26, 0.13], [0.10, 659.25, 0.26, 0.13],
		[0.20, 783.99, 0.26, 0.13], [0.30, 1046.50, 0.30, 0.22],
	])
	# Falling, and minor, but not funereal — a child loses most of these games
	# and the sound has to stay friendly.
	_streams[LOSS] = _tones(1.16, [
		[0.00, 587.33, 0.24, 0.14], [0.12, 493.88, 0.24, 0.14],
		[0.24, 392.00, 0.26, 0.20],
	])
	_streams[DRAW] = _tones(0.92, [
		[0.00, 523.25, 0.24, 0.14], [0.13, 523.25, 0.24, 0.17],
	])


# ------------------------------------------------------------------ synthesis

static func _knock(seconds: float, modes: Array, noise_amp: float,
		noise_decay: float) -> AudioStreamWAV:
	## `modes` is [[hz, amplitude, decay_seconds], ...] — the resonances. The
	## noise burst is the strike itself and dies far faster than the body does,
	## which is the whole difference between a knock and a beep.
	var n: int = int(seconds * MIX_RATE)
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(n)
	# Fixed seed: the noise burst must be the same every launch, or the same
	# move sounds subtly different each time and the set stops feeling like one
	# instrument.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EED
	for i in n:
		var t: float = float(i) / MIX_RATE
		var v: float = noise_amp * rng.randf_range(-1.0, 1.0) * exp(-t / noise_decay)
		for m: Array in modes:
			v += float(m[1]) * exp(-t / float(m[2])) * sin(TAU * float(m[0]) * t)
		samples[i] = v
	return _finish(samples)


static func _tones(seconds: float, notes: Array) -> AudioStreamWAV:
	## `notes` is [[start_seconds, hz, amplitude, decay_seconds], ...]. Each is
	## a plucked sine with a touch of second harmonic — a pure sine reads as a
	## test tone, and the harmonic is what makes it a note.
	var n: int = int(seconds * MIX_RATE)
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(n)
	for note: Array in notes:
		var start: int = int(float(note[0]) * MIX_RATE)
		var hz: float = float(note[1])
		var amp: float = float(note[2])
		var decay: float = float(note[3])
		for i in range(start, n):
			var t: float = float(i - start) / MIX_RATE
			var env: float = exp(-t / decay)
			if env < 0.0005:
				break
			samples[i] += amp * env * (sin(TAU * hz * t) + 0.25 * sin(TAU * hz * 2.0 * t))
	return _finish(samples)


static func _sequence(parts: Array, seconds: float) -> AudioStreamWAV:
	## Lays already-rendered cues onto one timeline: [[start_seconds, wav], ...].
	var n: int = int(seconds * MIX_RATE)
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(n)
	for part: Array in parts:
		var start: int = int(float(part[0]) * MIX_RATE)
		var src: PackedFloat32Array = to_floats(part[1] as AudioStreamWAV)
		for i in range(src.size()):
			var j: int = start + i
			if j >= n:
				break
			samples[j] += src[i]
	return _finish(samples)


## Peak the finished buffer to this. Headroom below 1.0 because these are
## summed with nothing and clipped by everything — and because a game for
## children should not be the loudest thing on the machine.
const PEAK: float = 0.72
## Fades at the ends. A buffer that starts or ends on a non-zero sample makes
## an audible tick on its own, which would put a click in front of every click.
## The two are not the same length on purpose: a knock IS its attack, and a
## 3 ms fade-in across the transient rounds it off into a thud. Half a
## millisecond is eleven samples — enough to kill the discontinuity, too short
## to be heard as a fade.
const FADE_IN_SEC: float = 0.0005
const FADE_OUT_SEC: float = 0.004


static func _finish(samples: PackedFloat32Array) -> AudioStreamWAV:
	var n: int = samples.size()
	var peak: float = 0.0
	for v in samples:
		peak = maxf(peak, absf(v))
	var gain: float = (PEAK / peak) if peak > 0.0001 else 0.0
	var fade_in: int = maxi(1, int(FADE_IN_SEC * MIX_RATE))
	var fade_out: int = maxi(1, int(FADE_OUT_SEC * MIX_RATE))
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var v: float = samples[i] * gain
		if i < fade_in:
			v *= float(i) / fade_in
		if i >= n - fade_out:
			v *= float(n - 1 - i) / fade_out
		var s: int = clampi(int(round(v * 32767.0)), -32768, 32767)
		data.encode_s16(i * 2, s)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_DISABLED
	wav.data = data
	return wav


static func to_floats(wav: AudioStreamWAV) -> PackedFloat32Array:
	## Reads a rendered cue back as samples. Used by _sequence to layer cues,
	## and by tests/run.gd to assert the envelopes are the shape they claim.
	var data: PackedByteArray = wav.data
	var out := PackedFloat32Array()
	out.resize(data.size() / 2)
	for i in range(out.size()):
		out[i] = data.decode_s16(i * 2) / 32768.0
	return out
