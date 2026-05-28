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


def publish_image(subtopic: str, image_path: str, followup: list = None) -> None:
    """Publish a PNG as raw binary (retain=True), then any followup (subtopic, value) pairs.

    All messages are sent in one connection so they arrive at the broker in order —
    image first, then followup topics. This prevents automations triggered by a
    followup topic from firing before the image entity has updated.
    """
    cfg = _load_config()
    if not cfg["MQTT_BROKER"]:
        return

    def _send():
        try:
            import paho.mqtt.publish as mqtt_pub
            with open(image_path, "rb") as f:
                payload = f.read()
            prefix = cfg["MQTT_TOPIC_PREFIX"]
            auth   = None
            if cfg["MQTT_USERNAME"]:
                auth = {"username": cfg["MQTT_USERNAME"], "password": cfg["MQTT_PASSWORD"]}
            msgs = [{"topic": f"{prefix}/{subtopic}", "payload": payload, "retain": True}]
            for sub, val in (followup or []):
                msgs.append({"topic": f"{prefix}/{sub}", "payload": str(val), "retain": False})
            mqtt_pub.multiple(
                msgs,
                hostname=cfg["MQTT_BROKER"],
                port=int(cfg["MQTT_PORT"]),
                auth=auth,
            )
        except Exception:
            pass

    threading.Thread(target=_send, daemon=True).start()


def publish(subtopic: str, value) -> None:
    """Fire-and-forget MQTT publish of a single scalar value. Silent no-op if unconfigured or paho absent."""
    cfg = _load_config()
    if not cfg["MQTT_BROKER"]:
        return

    def _send():
        try:
            import paho.mqtt.publish as mqtt_pub
            topic = f"{cfg['MQTT_TOPIC_PREFIX']}/{subtopic}"
            auth = None
            if cfg["MQTT_USERNAME"]:
                auth = {"username": cfg["MQTT_USERNAME"], "password": cfg["MQTT_PASSWORD"]}
            mqtt_pub.single(
                topic,
                payload=str(value),
                hostname=cfg["MQTT_BROKER"],
                port=int(cfg["MQTT_PORT"]),
                auth=auth,
                retain=False,
            )
        except Exception:
            pass

    threading.Thread(target=_send, daemon=True).start()
