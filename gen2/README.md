# qGames2

Small, calm games for kids. One repo, many games, shared infrastructure.
Native on ARM Linux, x86_64 Linux, and Android. Touch and keypad are both
first-class, everywhere.

Built with [Godot 4.7.2](https://godotengine.org) and GDScript, code-first.

## Layout

```
shared/qcore/      shared addon — config, input, telemetry (MQTT), game shell
games/<name>/      one Godot project per game; addons/qcore is a symlink
tools/             scaffolding
dist/              export output
```

`QCORE_API.md` is the contract between the shared library and the games.
Read it before writing a game. `PROJECT_STATE.md` is the handoff record —
what was decided, what was rejected, and why.

## Working on it

```bash
make help                  # list targets
make run GAME=memory       # launch in the editor's runtime
make test GAME=memory      # headless unit tests
make export-linux GAME=memory
make export-arm64 GAME=memory
make new-game NAME=foo
make chess-pieces          # dump chess's pieces as editable SVGs
```

Editing is text-first: `.gd`, `.tscn`, `.tres` and `project.godot` are all
plain text and diff cleanly. VS Code with the official `godot-tools`
extension gives LSP completion and breakpoint debugging; the Godot editor is
there when you want visual tooling, not required for day-to-day work.

## House rules

1. UI is built in code. One bare `.tscn` per game.
2. Typed GDScript everywhere.
3. Simulation is separate from rendering — pure `RefCounted` models, no Node
   imports, unit-testable headless.
4. Games never branch on the OS. Ask `QInput` or `QConfig`.
5. Anything reachable by touch is reachable by keyboard and d-pad.

## Telemetry

Games report to MQTT for Home Assistant. Configure at `user://config.cfg`;
blank broker means silent no-op, so an unconfigured machine costs nothing.
`Telemetry.report()` always publishes `<game>/ts` last, so automations keyed
on the timestamp see fully-updated values.
