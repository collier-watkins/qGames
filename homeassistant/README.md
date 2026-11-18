# Home Assistant

The consuming side of the telemetry schema. These four files are what is
running on `homeassistant` (10.118.20.4) as of 2026-08-27 — copied out of
`/config`, not written from memory.

| file here | goes to |
| --- | --- |
| `mqtt_sensors-qgames.yaml` | `/config/mqtt_sensors/qgames.yaml` |
| `mqtt_cameras-qgames.yaml` | `/config/mqtt_cameras/qgames.yaml` |
| `packages-qgames.yaml` | `/config/packages/qgames.yaml` |
| `dashboards-games.yaml` | `/config/dashboards/games.yaml` |

The sensor and camera files are reached through `/config/mqtt.yaml`, which is
now two lines:

```yaml
sensor: !include_dir_merge_list mqtt_sensors/
camera: !include_dir_merge_list mqtt_cameras/
```

A fresh install needs those two lines, `mqtt: !include mqtt.yaml` in
`configuration.yaml`, and `homeassistant: packages: !include_dir_named
packages/`. The package file registers the dashboard; nothing else is needed.

## What each file is for

**`mqtt_sensors-qgames.yaml`** — 32 sensors, five devices, one per game. Every
game contributes the same core (`result` / `score` / `duration_s` / `ts`) plus
its own extras. YAML anchors carry the repeated shapes: `<<: [*chess,
*duration]` merges the game's device block and the duration shape, so no entity
repeats a `device_class` or an icon. Anchors are file-local, which is why the
qGames sensors had to leave the house-wide `mqtt.yaml` to exist at all.

**`packages-qgames.yaml`** — `sensor.qgames_last_activity` (the newest `ts`
across every game, with the game's name as an attribute, so a card or an
automation does not have to know which games exist) and the dashboard
registration.

**`dashboards-games.yaml`** — one section per game, all the same shape. YAML
rather than the UI editor so it diffs and restores.

## Gotchas, each of which cost time

- **`ha core check` does not validate MQTT entity schema.** It is applied when
  the config entry sets up or reloads. A bad option passes the check and then
  silently drops *every* MQTT sensor in the house — one invalid item
  invalidates the whole list, and the old entities come back as `restored:
  true` ghosts that look identical to a broker outage. Verify with the
  `mqtt.reload` service and read the log.
- **`has_entity_name` is not accepted here.** A `device:` block already makes
  the friendly name `<device> <entity>`, so `name: Result` under device
  `qGames Chess` yields *qGames Chess Result*.
- **`isoformat` is a method, not a filter.** `(value | int | as_datetime |
  as_local).isoformat()`.
- **Reuse `unique_id`, never invent a new one for an existing topic.** The
  unique_id is the identity Home Assistant keys history and dashboard
  references on. Gen1's suite ended with 16 dead entities partly this way.
- **Dashboard url paths must contain a hyphen** — hence `q-games`.

## `qGames/_selftest/<game>` has no sensor, on purpose

Every build answers `--telemetry-selftest`, which publishes one message there to
prove it can reach the broker. It is not a game topic and Home Assistant should
never grow a sensor for it — a self-test is not a round, and the whole point of
the separate namespace is that running one cannot fake a game nobody played.

```bash
~/.local/share/qgames/memory/memory --headless -- --telemetry-selftest
```

## Not implemented

**Availability.** Nothing on the wire says whether a game is running, so every
entity is "last known value" with no way to tell live from stale. The planned
fix is a retained `qGames/<game>/state` — `playing` on launch, `exited` in
`QGameRoot.quit_game()`. Deliberately *not* an MQTT Last Will: `QMqttClient`
connects per batch and disconnects cleanly after every publish, so a will would
fire seconds after every report. See `PROJECT_STATE.md`, Open threads.
