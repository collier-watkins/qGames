# qGames

Small, calm games for kids. One repo, many games, shared infrastructure.
Native on ARM Linux, x86_64 Linux, and Android. Touch and keypad are both
first-class, everywhere.

Built with [Godot 4.7.2](https://godotengine.org) and GDScript, code-first.

## Play them at home

The games run from this repository with the free Godot engine — Linux, macOS or Windows. Nothing to configure,
no account, nothing sent anywhere (the games' reporting only works when someone sets up a server for it).

| folder | game |
|---|---|
| `games/chess` | Chess |
| `games/memory` | Memory Match |
| `games/notes` | Notes (a simple notepad) |
| `games/paint` | Paint |
| `games/sequence` | Sequence |

**1. Install Godot 4.7.2** — the standard version, not ".NET":
[godotengine.org/download/archive/4.7.2-stable](https://godotengine.org/download/archive/4.7.2-stable/).
It is a single program; unzip it anywhere (macOS: drag Godot into Applications).

**2. Get the games** with [git](https://git-scm.com/downloads):

```bash
git clone https://github.com/collier-watkins/qGames.git
```

On **Windows**, clone like this instead, after turning on *Settings → System → For developers → Developer Mode*
(the games share code through a link that Windows only makes in that mode):

```bash
git clone -c core.symlinks=true https://github.com/collier-watkins/qGames.git
```

**3. Play.** Either way works on every system:

- *No terminal:* open Godot → **Import** → pick `qGames/games/<folder>/project.godot` → **Import & Edit**, then press
  **▶** (top right, or F5). The first open takes a minute while Godot prepares the files. Next time the game is in
  Godot's project list.
- *Terminal (Linux, macOS):* from the `qGames` folder, `make run GAME=memory`. If `godot` is not on your PATH, say
  where it is: `make run GAME=memory GODOT=~/Downloads/Godot_v4.7.2-stable_linux.x86_64` or, on macOS,
  `GODOT=/Applications/Godot.app/Contents/MacOS/Godot`.

**Updates:** `git pull` in the `qGames` folder, then play as before.

**If something goes wrong**

- *Lots of red "Parse Error" lines, or "addons/qcore" not found* — on Windows, the clone was made without Developer
  Mode: delete the folder and clone again as above. Elsewhere, open the game once through Godot's **Import** (step 3)
  so it prepares its files.
- *A Vulkan / graphics error on an older computer* — start it in compatibility mode: `make run GAME=memory
  GODOT="godot --rendering-driver opengl3"`, or in Godot: Project → Project Settings → Rendering → Renderer →
  *Compatibility*.

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

Games report to MQTT for Home Assistant. Settings come from
`~/.config/qgames/mqtt.env`, baked into the export by `tools/bake_config.sh`,
or from `user://config.cfg`, or from the environment. A blank broker means
silent no-op, so an unconfigured machine costs nothing. `Telemetry.report()`
always publishes `<game>/ts` last, so automations keyed on the timestamp see
fully-updated values.

Because "no broker" and "wrong broker" both publish nothing, silently, every
build answers a self-test:

```bash
make selftest GAME=memory
~/.local/share/qgames/memory/memory --headless -- --telemetry-selftest
```

`homeassistant/` is the consuming side: the Home Assistant config that reads
these topics, copied back out of the machine that runs it.
