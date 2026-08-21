class_name QMqttClient
extends RefCounted

## Minimal MQTT 3.1.1 publisher. QoS 0 only, no subscribe.
##
## Deliberately dependency-free: StreamPeerTCP + ~150 lines of packet encoding,
## so it ships identically on Linux and Android with nothing to vendor.
##
## Semantics match the old Python shared/mqtt_stats.py: one connection per
## batch, messages sent in list order, then DISCONNECT. Ordering is the whole
## point — a Home Assistant automation triggered by the last topic must see
## every earlier value already updated.
##
## Non-blocking: drive it by calling poll() every frame. Never blocks the
## render thread, so a dead broker costs frames, not the game.

enum State { IDLE, CONNECTING, AWAIT_CONNACK, PUBLISHING, DONE }

const PROTOCOL_LEVEL := 0x04  # MQTT 3.1.1
const TIMEOUT_SEC := 10.0

var host: String = ""
var port: int = 1883
var username: String = ""
var password: String = ""
var client_id: String = "qgames"

var _tcp: StreamPeerTCP = null
var _state: State = State.IDLE
var _queue: Array[Dictionary] = []
var _batch: Array[Dictionary] = []
var _elapsed: float = 0.0

# ── I/O counters ─────────────────────────────────────────────────────────────
# Cumulative for the life of the process, surfaced by the debug HUD. A publish
# that silently never leaves is the classic failure mode of a fire-and-forget
# QoS-0 publisher, so "bytes actually written" is counted, not "messages asked
# for": the gap between messages_queued and messages_sent IS the bug report.
var messages_queued: int = 0
var messages_sent: int = 0
var batches_sent: int = 0
var bytes_out: int = 0
var bytes_in: int = 0
var connect_attempts: int = 0
var failures: int = 0
var last_error: String = ""
var last_sent_msec: int = -1
var last_batch_ms: float = -1.0

signal batch_sent(count: int)
signal failed(reason: String)


## Ceiling on unsent messages. A failed batch is already discarded rather than
## retried, so this only bites while messages are arriving faster than they can
## be delivered.
##
## Over the ceiling the queue is cleared ENTIRELY rather than trimmed. Dropping
## the oldest few would eventually send a torn report — some of a round's
## values with a `ts` that claims they are current — and a subscriber cannot
## tell that from a real one. Losing a whole stale report is recoverable;
## publishing a plausible lie is not.
const MAX_QUEUE: int = 256

## Messages thrown away rather than sent, for the debug HUD. A number climbing
## here is the difference between "telemetry is broken" and "telemetry has
## nowhere to go", which are not the same problem.
var dropped: int = 0


## Queue one message. topic is the full topic; payload may be String or
## PackedByteArray (for images).
func enqueue(topic: String, payload, retain: bool = false) -> void:
	if host == "":
		# No broker: publish nowhere, and say so by discarding. poll() returns
		# early without a host, so anything queued here would never leave —
		# and with MQTT on by default, an unconfigured machine would grow this
		# queue for the life of the process. That is a memory leak with a slow
		# fuse, and note bodies would make it a fast one.
		dropped += 1
		return

	var data: PackedByteArray
	if payload is PackedByteArray:
		data = payload
	else:
		data = str(payload).to_utf8_buffer()
	_queue.append({"topic": topic, "data": data, "retain": retain})
	messages_queued += 1

	if _queue.size() > MAX_QUEUE:
		dropped += _queue.size()
		_queue.clear()


func has_pending() -> bool:
	return _queue.size() > 0 or _state != State.IDLE


func poll(delta: float) -> void:
	if _state == State.IDLE:
		if _queue.is_empty() or host == "":
			return
		_begin()
		return

	_elapsed += delta
	if _elapsed > TIMEOUT_SEC:
		_abort("timeout")
		return

	if _tcp == null:
		_abort("no socket")
		return

	_tcp.poll()
	var status := _tcp.get_status()
	if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		_abort("socket error")
		return

	match _state:
		State.CONNECTING:
			if status == StreamPeerTCP.STATUS_CONNECTED:
				var connect_packet := _encode_connect()
				if _tcp.put_data(connect_packet) == OK:
					bytes_out += connect_packet.size()
				_state = State.AWAIT_CONNACK
		State.AWAIT_CONNACK:
			if _tcp.get_available_bytes() >= 4:
				var res := _tcp.get_data(4)
				var err: int = res[0]
				var buf: PackedByteArray = res[1]
				bytes_in += buf.size()
				if err != OK or buf.size() < 4 or buf[0] != 0x20 or buf[3] != 0x00:
					_abort("connack refused")
					return
				_state = State.PUBLISHING
		State.PUBLISHING:
			var sent: int = 0
			for msg in _batch:
				var packet := _encode_publish(msg["topic"], msg["data"], msg["retain"])
				if _tcp.put_data(packet) == OK:
					bytes_out += packet.size()
					sent += 1
			_tcp.put_data(PackedByteArray([0xE0, 0x00]))  # DISCONNECT
			bytes_out += 2
			messages_sent += sent
			batches_sent += 1
			last_sent_msec = Time.get_ticks_msec()
			last_batch_ms = _elapsed * 1000.0
			var n := _batch.size()
			_finish()
			batch_sent.emit(n)
		_:
			pass


func _begin() -> void:
	_batch = _queue.duplicate()
	_queue.clear()
	_elapsed = 0.0
	connect_attempts += 1
	_tcp = StreamPeerTCP.new()
	var err := _tcp.connect_to_host(host, port)
	if err != OK:
		_abort("connect_to_host failed")
		return
	_state = State.CONNECTING


func _finish() -> void:
	if _tcp != null:
		_tcp.disconnect_from_host()
	_tcp = null
	_batch.clear()
	_state = State.IDLE
	_elapsed = 0.0


func _abort(reason: String) -> void:
	failures += 1
	last_error = reason
	_finish()
	failed.emit(reason)


## Snapshot for the debug HUD. Never called on the hot path.
func stats() -> Dictionary:
	return {
		"state": State.keys()[_state].to_lower(),
		"queued": _queue.size(),
		"in_flight": _batch.size(),
		"messages_queued": messages_queued,
		"dropped": dropped,
		"messages_sent": messages_sent,
		"batches_sent": batches_sent,
		"bytes_out": bytes_out,
		"bytes_in": bytes_in,
		"connect_attempts": connect_attempts,
		"failures": failures,
		"last_error": last_error,
		"last_sent_msec": last_sent_msec,
		"last_batch_ms": last_batch_ms,
		"endpoint": ("%s:%d" % [host, port]) if host != "" else "",
	}


# ── packet encoding (pure, unit-tested) ───────────────────────────────────────

static func encode_remaining_length(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	var x := n
	while true:
		var b := x & 0x7F
		x >>= 7
		if x > 0:
			b |= 0x80
		out.append(b)
		if x == 0:
			break
	return out


static func encode_string(s: String) -> PackedByteArray:
	var b := s.to_utf8_buffer()
	var out := PackedByteArray([(b.size() >> 8) & 0xFF, b.size() & 0xFF])
	out.append_array(b)
	return out


static func encode_publish(topic: String, data: PackedByteArray, retain: bool) -> PackedByteArray:
	var body := encode_string(topic)
	body.append_array(data)
	var out := PackedByteArray([0x30 | (0x01 if retain else 0x00)])
	out.append_array(encode_remaining_length(body.size()))
	out.append_array(body)
	return out


func _encode_publish(topic: String, data: PackedByteArray, retain: bool) -> PackedByteArray:
	return encode_publish(topic, data, retain)


func _encode_connect() -> PackedByteArray:
	var body := encode_string("MQTT")
	body.append(PROTOCOL_LEVEL)
	var flags := 0x02  # clean session
	if username != "":
		flags |= 0x80
	if password != "":
		flags |= 0x40
	body.append(flags)
	var keepalive := int(TIMEOUT_SEC)
	body.append((keepalive >> 8) & 0xFF)
	body.append(keepalive & 0xFF)
	body.append_array(encode_string(client_id))
	if username != "":
		body.append_array(encode_string(username))
	if password != "":
		body.append_array(encode_string(password))
	var out := PackedByteArray([0x10])
	out.append_array(encode_remaining_length(body.size()))
	out.append_array(body)
	return out
