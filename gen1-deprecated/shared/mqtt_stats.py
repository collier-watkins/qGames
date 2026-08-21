import os
import threading

_XDG_CONFIG = os.path.expanduser("~/.config/qgames/mqtt.env")
_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_DEV_CONFIG = os.path.join(_PROJECT_ROOT, "mqtt.env")

_DEFAULTS = {
    "MQTT_BROKER":       "",
    "MQTT_PORT":         "1883",
    "MQTT_USERNAME":     "",
    "MQTT_PASSWORD":     "",
    "MQTT_TOPIC_PREFIX": "qGames",
}

# Hard wall-clock bound on any single publish attempt. A broker that is down,
# half-open (accepts TCP but never completes the MQTT handshake), or on a
# blackholed network can otherwise leave a publish thread — and its open
# socket/file-descriptor — hanging forever. Over days of saves that leaks FDs
# and threads until the process (and the desktop) become unstable.
_MQTT_TIMEOUT = 10.0  # seconds

# Belt-and-suspenders: never let more than this many publish attempts be
# in flight at once. Stats/images are non-critical, so if the broker is slow
# enough to back them up we drop new ones rather than spawn unbounded threads.
_MAX_INFLIGHT = 8
_inflight = threading.BoundedSemaphore(_MAX_INFLIGHT)


def _load_config() -> dict:
    cfg = dict(_DEFAULTS)
    for path in (_XDG_CONFIG, _DEV_CONFIG):
        try:
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, _, v = line.partition("=")
                        k = k.strip()
                        if k in cfg:
                            cfg[k] = v.strip().strip('"').strip("'")
            break
        except FileNotFoundError:
            continue
    return cfg


def _send_bounded(cfg: dict, msgs: list) -> None:
    """Connect, publish each {topic, payload, retain} in order, disconnect.

    Every network wait is bounded by _MQTT_TIMEOUT and teardown runs in a
    finally, so the thread and its socket are always released — even if the
    broker is unreachable or never completes the handshake. Messages are sent
    over one connection in list order.
    """
    client = None
    try:
        import paho.mqtt.client as mqtt

        client = mqtt.Client()
        if cfg["MQTT_USERNAME"]:
            client.username_pw_set(cfg["MQTT_USERNAME"], cfg["MQTT_PASSWORD"])

        connected = threading.Event()

        def _on_connect(_client, _userdata, _flags, rc, *_):
            if rc == 0:
                connected.set()

        client.on_connect = _on_connect
        # Bound the TCP connect itself (paho attribute) as well as the handshake
        # wait below, so neither phase can block indefinitely.
        client._connect_timeout = _MQTT_TIMEOUT
        client.connect_async(
            cfg["MQTT_BROKER"], int(cfg["MQTT_PORT"]), keepalive=int(_MQTT_TIMEOUT)
        )
        client.loop_start()
        try:
            if connected.wait(_MQTT_TIMEOUT):
                infos = [
                    client.publish(m["topic"], m["payload"], retain=m["retain"])
                    for m in msgs
                ]
                for info in infos:
                    info.wait_for_publish(_MQTT_TIMEOUT)
        finally:
            client.loop_stop()
            client.disconnect()
    except Exception:
        # Best effort: unconfigured, paho absent, or an unexpected paho API.
        if client is not None:
            try:
                client.loop_stop()
            except Exception:
                pass


def _dispatch(cfg: dict, msgs: list) -> None:
    """Run _send_bounded in a daemon thread, capped at _MAX_INFLIGHT."""
    if not _inflight.acquire(blocking=False):
        return  # too many publishes already in flight — drop this one

    def _run():
        try:
            _send_bounded(cfg, msgs)
        finally:
            _inflight.release()

    threading.Thread(target=_run, daemon=True).start()


def publish_image(subtopic: str, image_path: str, followup: list = None) -> None:
    """Publish a PNG as raw binary (retain=True), then any followup (subtopic, value) pairs.

    All messages are sent in one connection so they arrive at the broker in order —
    image first, then followup topics. This prevents automations triggered by a
    followup topic from firing before the image entity has updated.
    """
    cfg = _load_config()
    if not cfg["MQTT_BROKER"]:
        return
    try:
        with open(image_path, "rb") as f:
            payload = f.read()
    except OSError:
        return
    prefix = cfg["MQTT_TOPIC_PREFIX"]
    msgs = [{"topic": f"{prefix}/{subtopic}", "payload": payload, "retain": True}]
    for sub, val in (followup or []):
        msgs.append({"topic": f"{prefix}/{sub}", "payload": str(val), "retain": False})
    _dispatch(cfg, msgs)


def publish_many(pairs: list) -> None:
    """Fire-and-forget publish of several (subtopic, value) pairs in one connection.

    All messages go out over a single connection in list order. Put any topic
    that triggers a Home Assistant automation LAST, so the automation sees
    fully-updated data. Silent no-op if unconfigured or paho absent.
    """
    cfg = _load_config()
    if not cfg["MQTT_BROKER"]:
        return
    prefix = cfg["MQTT_TOPIC_PREFIX"]
    msgs = [
        {"topic": f"{prefix}/{sub}", "payload": str(val), "retain": False}
        for sub, val in pairs
    ]
    _dispatch(cfg, msgs)


def publish(subtopic: str, value) -> None:
    """Fire-and-forget MQTT publish of a single scalar value. Silent no-op if unconfigured or paho absent."""
    cfg = _load_config()
    if not cfg["MQTT_BROKER"]:
        return
    topic = f"{cfg['MQTT_TOPIC_PREFIX']}/{subtopic}"
    _dispatch(cfg, [{"topic": topic, "payload": str(value), "retain": False}])
