# qGames2 — Project State

_Started 2026-08-20. Successor to `~/Projects/qGames` (Python/pygame, Pi-only).
Facts marked VERIFIED were checked against docs or a command on 2026-08-20;
anything else is judgment and is labelled._

## What this is

A platform for a suite of small, calm, single-player games for kids, plus the
shared infrastructure they run on. Several games are developed in parallel in one
repo; each ships as its own installable app with its own identity.

## Goal (stated by the owner, 2026-08-20)

1. **ARM Linux and Android as native targets**, future-proofed. Not Raspberry-Pi-specific
   — the Pi is one ARM Linux machine among others, not the design centre.
2. **Touch AND keypad both first-class**, in the manner of Android Minecraft — not a
   desktop game with a touch fallback, and not a touch game with keys bolted on.
3. Simple, lightweight, calming, small.
4. Easy to work on alone or with an LLM.
5. CI/CD as needed — staged, not built out ahead of demand.

## Stack

**Godot 4.7.2, GDScript, code-first.** Renderer: Forward Mobile (Vulkan) on
desktop and the Pi, Compatibility (OpenGL) on Android.

Why, against each requirement:

| Requirement | Mechanism | VERIFIED |
|---|---|---|
| ARM Linux native | Official precompiled arm64 *and* arm32 export templates; an official arm64 editor also exists | yes — godotengine.org/download/linux, 4.7.2 dated 18 Aug 2026 |
| Android native | First-class APK/AAB export, per-preset architecture toggles | yes — EditorExportPlatformAndroid docs |
| Touch + keypad | `InputMap` binds one named action to keyboard, gamepad and touch at once; `TouchScreenButton` drives actions via `Input.action_press()`; *Emulate Touch From Mouse* exercises the touch path on a desktop | yes — Godot input docs |
| Lightweight/calm | 2D only, no physics, low node counts. Renderer is **Forward Mobile (Vulkan)** on desktop/Pi as of 2026-08-25 and Compatibility on Android — see "Framerate on the Pi" | measured on a Pi 4 |
| LLM-workable | Every artifact Godot writes is text: `project.godot` (INI), `.tscn`, `.tres`, `.gd` | yes |
| CI/CD | Headless CLI: `--headless --import`, `--script`, `--export-release` | yes |

**Code-first is a deliberate house rule, not a limitation.** UI is built in code;
each game has exactly one near-empty `.tscn`. This keeps every artifact authorable
by an LLM and keeps diffs readable. It is the right call for small games and would
NOT survive a content-heavy game (see Open threads).

### Rejected, with reasons

- **Stay on pygame** — Android is effectively unavailable. pygbag reaches Android only
  through a browser; there is no installable app. Fails requirement 1. VERIFIED.
- **Unity** — Unity's own system requirements state Desktop Linux supports x64 only.
  There is no ARM64 Linux desktop player, so it cannot target ARM Linux at all.
  This single fact eliminates Unity and GameMaker. VERIFIED (docs.unity3d.com).
- **Löve2D** — genuinely lighter (5–10 MB runtime vs Godot's ~40–70 MB per game) and
  very LLM-friendly, but ships no `Control`/`Theme` UI system, no `InputMap`, no export
  presets, and needs a hand-rolled Android pipeline. You would rebuild precisely the
  batteries that make touch-plus-keypad and per-game identity cheap. Judgment call.
- **Flutter + Flame** — strong Android, but ARM Linux desktop is the weak link and was
  never verified. Canvas games as widgets is an awkward fit.
- **Web + Capacitor** — no Capacitor Linux desktop target; "native" degrades to a
  browser wrapper. Fails requirement 1.

### Accepted costs

- **Binary size.** The old pygame games are 16–17 MB each (measured). Godot exports for
  a small 2D game land around 40–70 MB, and every game embeds its own engine copy.
  Shrinking that means compiling custom export templates with modules disabled — a
  real project, not a flag.
- **Android APKs can never be built on ARM Linux.** Google ships no linux-arm64 `aapt2`;
  it is an x86_64-only ELF. The x86_64 laptop is the Android build host, permanently.
  Workarounds exist (Box64, QEMU, third-party rebuilt binaries) but are not the plan.
  VERIFIED.
- **Rewrite.** None of the ~3,800 lines of pygame in `~/Projects/qGames` port.

## Architecture

```
shared/qcore/         the shared addon — single source of truth
  config.gd           QConfig autoload: defaults < user://config.cfg < QGAMES_* env
  input_manager.gd    QInput autoload: which device is in hand; drives HUD swap
  telemetry.gd        Telemetry autoload: MQTT reporting, enforces ts-last ordering
  mqtt_client.gd      QMqttClient: hand-rolled MQTT 3.1.1 QoS-0 publisher, no deps
  telemetry_schema.gd QTelemetrySchema: the wire schema, pure and unit-tested
  debug_hud.gd        QDebug autoload: the debug HUD, CanvasLayer 128
  debug_stats.gd      QDebugStats: the sampler behind it, pure and unit-tested
  game_root.gd        QGameRoot: base Control — quit/back, safe area, pointer signals
games/<name>/
  project.godot       own name, icon, autoloads, and Android package identity
  addons/qcore        SYMLINK -> ../../../shared/qcore
  src/                pure model classes (RefCounted) + view nodes
  tests/run.gd        dependency-free headless SceneTree test runner
QCORE_API.md          the frozen API contract + house rules. Read before writing a game.
homeassistant/        the consuming side: the Home Assistant config actually running.
```

**Sharing is by symlink inside a monorepo** — one source of truth, edits land in every
game immediately, and `actions/checkout` preserves symlinks on Linux. Rejected: git
submodules (per-game version pinning not worth the ceremony yet), separate repos.

**MQTT is hand-rolled**, ~150 lines over `StreamPeerTCP`: QoS 0, publish only,
non-blocking state machine polled each frame. Carries forward the one invariant that
mattered in the old suite — the `<game>/ts` topic is always published LAST in a single
ordered connection, so a Home Assistant automation triggered by `ts` sees every other
value already updated. In qGames that invariant was a comment repeated in five games;
here it is enforced inside `Telemetry.report()`.

**The debug HUD is platform infrastructure, not a game feature** (added
2026-08-20). Every game gets QDebug from the autoload list and contains no
profiling code of its own. It exists to answer one question — is anything
running away — so it reports rates and deltas rather than instantaneous values:
a least-squares slope of RSS in MB/min, object and node counts against a
re-zeroable baseline, orphan node count, and worst frame time since reset.
MQTT counters sit in the same panel because a stalled publisher and a memory
leak look identical from outside (a queue that only grows).

Two measurement decisions worth keeping:

- **Frame time is measured from the wall clock here, not taken from
  `Performance.TIME_PROCESS`.** VERIFIED 2026-08-20 on this box: with the
  memory game running, TIME_PROCESS reads 30.0 ms while frames are genuinely
  16.4 ms apart at 59–60 fps (probe: 120 frames, `Time.get_ticks_usec()` deltas
  vs the monitor). It is not a wall-clock frame duration and must not be shown
  as one. It is kept in `QDebugStats.proc_ms` and left off the HUD.
- **CPU% comes from `/proc/self/stat`** (utime+stime, USER_HZ assumed 100).
  Godot exposes no process-CPU monitor. /proc is present on Linux and Android
  alike, which is the whole target set; anywhere else the readers return -1 and
  the HUD says "unavailable" rather than inventing a number. VERIFIED.

**One MQTT schema across all games** (added 2026-08-20). Every game publishes
the same core through `Telemetry.report_result()` — `result`, `score`,
`score_unit`, `duration_s`, then `ts` last — so one Home Assistant card works
for any game with no per-game templates. Game-specific topics still go
alongside it, which is how `memory` keeps emitting its historical `moves`
topic. Flat scalar topics, not a JSON payload: an HA MQTT sensor binds one
topic to one state, so JSON would force a `value_template` on every sensor and
buy nothing. `homeassistant/` is the consuming side.

The schema lives in `QTelemetrySchema` rather than in the Telemetry autoload,
for a non-obvious reason worth keeping: `telemetry.gd` references `QConfig`,
and autoload identifiers are not in scope when a preload chain compiles under
`--script`. Preloading it from the headless test runner makes the whole script
fail to compile and its static functions silently cease to exist — the call
fails at runtime with "Nonexistent function". Pure schema logic in its own
autoload-free class is what makes it testable at all. VERIFIED 2026-08-20.

**The game id is declared, not derived** (fixed 2026-08-20). It now comes from
`[telemetry] game_id` in `project.godot`, falling back to the display name only
when unset. Deriving it from `application/config/name` was an active defect:
"Memory Match" published to `qGames/memory_match/`, orphaning every
`qGames/memory/` sensor in the old suite's `mqtt.yaml` with no error anywhere.
`memory` is kept as the id so the existing Home Assistant config keeps working.
Note this means the ported game publishes to the same topics as the old Python
game still running on the Pi — deliberate (same game, same meaning, last one
played wins), but worth knowing if both ever run at once.

**Rejected for MQTT:** the `godot-mqtt` third-party addon (unvetted dependency for
publish-only needs), and MQTT-over-WebSockets (only earns its keep if web export
returns to scope).

## House rules

1. Code-first UI; one bare `.tscn` per game.
2. Typed GDScript everywhere — cheaper now than retrofitted later, and faster.
3. Simulation separate from rendering. Pure `RefCounted` models import no Node and are
   unit-testable headless. This is the rule the old suite broke — state and drawing were
   fused inside one `main()`, which is exactly why none of it could be tested.
4. Games never branch on OS. They ask `QInput` or `QConfig`.
5. Every action reachable by touch is reachable by `ui_*` actions (keyboard + d-pad).

## Current state

**Five games built, all tests green** (2026-08-23): chess 193/193, memory 74/74,
notes 332/332, paint 56/56, sequence 27/27 — 682 tests, 0 failures.

The project began as a spike — port `memory` (the old suite's smallest game, 281
lines) to prove the workflow before committing to a full rewrite. The spike's
questions are now answered except one: the code-first loop holds up across three
games of different shapes, keypad-plus-touch works on all three, GDScript suits
the work, and the Linux x86_64 and arm64 exports come out clean. **Android is
still unanswered** — the SDK is not installed, so no APK has ever been built.

**Second chess polish pass** (2026-08-22), on the owner's report that the
sounds were annoying and a question about editing the pieces.

**Half of "annoying" was mixing, not synthesis.** `_finish` normalised every
cue to the same peak, so the pick-up tick was exactly as loud as the win chime
— the sound heard forty times a game as prominent as the one heard once. Each
cue is now peaked to its own level, and tests assert the ordering: the tick is
under 40% of a move, a capture is louder than a move, nothing exceeds a capture
by much.

The other half was that they RANG. The first set used pitched sinusoids
decaying over a tenth of a second, which turns every move into a musical event.
Measured, before and after:

| cue | before | after |
|---|---|---|
| move | 100 ms audible, peak 0.72 | **66 ms, peak 0.34, centroid 1.1 kHz** |
| capture | 150 ms, peak 0.72 | **94 ms, peak 0.46** |
| pick-up | 40 ms, peak 0.72 | **26 ms, peak 0.08** |
| check | two-note rise, 300 ms | **knock plus one tone, 227 ms** |
| win | four-note fanfare, 720 ms | **two notes, 767 ms decaying** |

Three changes did it:

- **The noise burst is low-passed now.** White noise is the sound of a hiss,
  not of wood. Rolling it off a couple of kHz up with a one-pole filter is what
  turns a "tss" into a "tok", and it was the single biggest improvement.
- **Melodies came out.** Check was a two-note rise and the win a four-note
  fanfare; both are charming once and grating by the third game. Check is a
  harder knock with one tone laid over it, and the result cues are two notes.
- **Decays are a third of what they were**, and the tests now assert the
  *audible* length — time until the envelope falls below 1% of peak — rather
  than the buffer length. A move must be over inside a tenth of a second.

**The pieces are editable as SVG files, without a rebuild** (asked for
2026-08-22). `src/piece_art.gd` resolves the set from `user://pieces/*.svg`,
then `res://assets/pieces/*.svg`, then the built-in drawn artwork.

- **Resolution is per PIECE, not per set.** Replacing only `wN.svg` gives you
  your knight and the built-in everything else, because a half-finished set is
  a normal state to be in while drawing one.
- Filenames are the universal convention — `wK wQ wR wB wN wP` and the `b*`
  equivalents — so any standard set (Cburnett's, for one) drops in unrenamed.
- `--dump-pieces`, or `make chess-pieces`, writes the built-in artwork out as
  twelve editable SVGs plus a README explaining them. The exported viewBox is
  the fitted art box, so a replacement drawn against the same box needs no
  transform. The installed binary understands the flag too.
- **Dumping is deliberately NOT automatic on first run.** The files would then
  shadow the built-in art forever, and a later improvement to the drawn set
  would never reach anyone who had launched the game once.
- SVGs are rasterised at bucketed sizes (48…384 px) at or above the size
  actually drawn, so a piece is downscaled and never up. A bucket change clears
  the cache; a resize inside a bucket costs nothing. A file that fails to
  rasterise is dropped and that piece falls back, because a file the game
  cannot read is worse than no file — it looks like the edit did nothing.
- The same trap as the boot splash applies and is handled: `load_svg_from_string`
  scales the file's OWN intrinsic size, so it is read at 1.0 first.

⚠ **A repository piece set does not survive an export without help**, and the
way it fails is silent. `res://assets/pieces/*.svg` was supported from the
start of this feature and was BROKEN: `.svg` has an importer, so
`export_filter="all_resources"` exports the imported TEXTURE and strips the
source text — which is the thing the game actually reads. It works perfectly
in the editor and is absent from every shipped build.

`include_filter` does not rescue it on its own; naming the files there was
tried, in three syntaxes, and the bytes still were not in the pack. Each file
also needs a `.import` containing `importer="keep"`, which is what makes the
engine treat it as plain bytes. BOTH are required. All of this was established
by grepping an export for a path fragment and then by reading the resolved set
out of a running exported binary — `chess: pieces currently from
res://assets/pieces (12 of 12)`.

`make chess-pieces-repo` writes the set with its stubs. `make chess-pieces`
writes it to `user://` and deliberately does not, because a user set is not
packed and stubs there would be litter. A test asserts every export preset
names the files and that any committed `.svg` has its keep stub, since that is
the only moment it can go wrong.

**The set IS committed** (owner's call, 2026-08-23: nothing untracked). It
lives at `games/chess/assets/pieces/` — twelve SVGs, twelve `.import` stubs and
a README — and is what a shipped build now draws with; VERIFIED by reading
`chess: pieces currently from res://assets/pieces (12 of 12)` out of a running
export.

The objection to committing it was real and is handled rather than dropped: a
committed set SHADOWS the artwork in `src/pieces.gd`, so an improvement to the
drawn set would silently never be seen again. Every generated file carries one
marker comment, and a test regenerates each file that still has it and fails
naming the command to run. VERIFIED by nudging the drawn artwork and watching
the guard name all twelve files. Editing a piece means deleting its marker
line, and the check then leaves that file alone — which is what makes the guard
compatible with the feature it guards.

**Getting output out of an exported build needs a clean exit.** Godot flushes
stdout on exit, so a release binary killed mid-run prints nothing at all — a
plain `timeout 10 ./chess` produced an empty log and looked like the print had
been stripped. `--dump-pieces` reports the resolved set before it quits, which
is what made this observable.

**Chess got a polish pass** (2026-08-22): Bezier piece artwork, animation, and
sound. All three were asked for together and all three turned out to be the
same problem — the game was correct and read as a diagram.

**The pieces are Bezier outlines now, not polygons.** `src/pieces.gd` holds
SVG-style path data in a 100x100 box, tessellated ONCE per piece into polygons
and cached; only the transform is per-draw. The straight-edged first version
read as a set of road signs, because a chess set is nothing but curves. The
shapes are Staunton: ball-headed pawn, crenellated rook, slit mitre, coronet,
cross-topped king, and a knight with an ear and a mane.

Three things that were established by rendering them and looking, not by
reasoning:

- **A stack of rings reads as a wedding cake.** The first base was a band plus
  a foot, and with the collar above it every piece had three horizontal bars
  that merged into a smudge at 32px — which is the size a phone draws. One
  flared base fixed it.
- **The knight is the whole set.** Two bumps read as a rabbit and a rounded
  head read as a dog; it took an explicit notch for the ear, a muzzle that
  actually points, and a mane stroke down the back before it read as a horse.
- **The king's crown has to be NARROWER than the body under it.** Drawn the
  same width it merged with the collar into one mass and the piece was a bell
  with a cross stuck on top.

**Pieces are fitted to the artwork's measured bounds, not to the nominal box.**
The tallest piece reaches y=1 and every base ends at y=88, so fitting the
100x100 box left a tenth of every square empty underneath and the set looked
undersized. `ART_MIN`/`ART_MAX` are the UNION across all six — per-piece bounds
would scale a pawn up to the size of a king — and a test asserts every piece
stays inside them and stands on the same baseline, so editing the art cannot
silently break the fit.

A GDScript trap, from the polygon version and still worth knowing:
**`const X := PackedVector2Array([...])` is not a constant expression** and
fails to compile.

`icon.svg` is now GENERATED from the knight's own path data rather than being a
second drawing that happens to look similar. `tests/render_pieces.gd` renders
the whole set at 96, 56 and 32px on both square colours; it needs a display and
is not part of `make test-all`.

**Everything that moves, moves.** Pieces slide between squares over 200 ms with
a cubic ease-out, the rook travels with the king when castling, a captured
piece fades rather than vanishing, a promoted piece swells into place with a
slight overshoot, the last-move wash and the selection dots come up rather than
snapping on, and the check glow breathes. Dialogs fade and lift; a flip fades,
because every piece changes square at once and there is nothing to slide.

The reason for the slide is not decoration: **the computer's reply is now SEEN
rather than discovered.** A child playing their first games cannot spot what
changed between two still frames of a chess position, and an adult barely can.

Two decisions inside it worth keeping:

- **The slide is a lie told over the top of the model.** By the time it runs
  the piece is already on its destination square, so `_draw` suppresses that
  square until the slide lands — otherwise the same piece is drawn twice, once
  travelling and once already arrived.
- **What is captured has to be read BEFORE the move is made.** Afterwards the
  piece is simply gone and there is nothing left to fade. En passant takes a
  piece that is not on the destination square, which is the case a naive
  `board[to]` misses.
- **Idle animation is throttled to 24 Hz, moves are not.** The check glow is
  the only thing moving between moves and does not need sixty repaints a second
  to breathe — the same measurement that caught sequence idling at 52% CPU. The
  view stops processing entirely when nothing is animating.

**Sound is synthesised at load, not shipped as files.** Ten short cues as .wav
would be a licence to check, a folder to import and a few hundred kilobytes in
each of four architecture builds. `src/audio.gd` is modal synthesis instead: a
noise burst to excite the body plus a few damped sinusoids to ring, which is
genuinely how a wooden piece on a wooden board sounds and is why the cues read
as wood rather than as beeps. Moves, captures, castling (two knocks, because
two pieces moved), check, promotion, pick-up, an illegal tap, and win/loss/draw.
The noise burst is seeded, so the same move sounds the same on every launch.

- **A cue that is still ringing when its buffer ends is CUT, and the cut is
  audible.** Plotting the envelopes showed check, promotion and all three
  result cues being chopped at about 29% of peak. Buffers now run about four
  and a half decay constants past the last note, and a test asserts the last 3%
  of every cue is below 2% of its peak.
- **The fade at the two ends is not the same length.** A knock IS its attack,
  and a 3 ms fade-in across the transient rounds it off into a thud. Half a
  millisecond kills the discontinuity without being heard.
- **Cues that follow another cue are delayed, not layered.** Check lands 180 ms
  after the move that gave it and the result cue 300 ms after the last move.
  Two sounds at one instant are heard as one confused sound.
- Sound is on by default with a **Sound** toggle in the panel, saved to
  `chess/sound`.

⚠ **Creating an `AudioStreamPlayer` under `--headless` with a real audio driver
HANGS the process.** VERIFIED — a probe that added one never returned, and
`--audio-driver Dummy` fixes it. `tests/run.gd` therefore tests only the
synthesis, which is pure arithmetic and is the part that can be wrong; the
interactive test covers the player, and it runs with a display.

⚠ **The sound engine belongs in qcore and is not there.** It is in the game
because `QCORE_API.md` is frozen and a consumer does not get to redesign the
shared library. Nothing about `src/audio.gd` is chess-specific except the list
of cues. Moving it is the orchestrator's call.

**Nobody has heard any of this.** The cues were designed, measured and plotted
— peak, RMS, edge silence, tail decay and envelope shape are all checked — but
they were never played through a speaker by anyone who could judge them. The
shapes are right; whether they are pleasant is unverified.

**Fifth game, new: `chess`** (2026-08-22). A full game of chess against the
machine, with a clock, a move list, takeback and hints. Every rule is
implemented, including the ones people forget: castling and all three ways it
is forbidden, en passant including the pin that makes it illegal, promotion to
any of four pieces, the fifty-move rule, threefold repetition, dead positions,
and a flag fall against bare material being a draw rather than a win.

**The opponent is written in GDScript, and Stockfish is deliberately not
bundled.** The decision was made on measurements taken before any of it was
written, not on preference:

- A naive 0x88 move generator in GDScript runs **~190k nodes/sec** on this box.
  With material-plus-piece-square evaluation, MVV-LVA ordering, killers,
  history and a quiescence search it settles at **~60-70k nodes/sec** — the
  extra work per node buys far more than it costs. From the start position that
  is **depth 5 in 200 ms, depth 6 in one second** (measured), which is roughly
  club strength and already stronger than anyone in this house.
- Debian's Stockfish 16 is **33.5 MB packed, 39.5 MB installed, per
  architecture**, because the NNUE net is embedded (measured from the apt
  index). `dist/` is already ~810 MB across four games and four architectures.
- Android is the harder half. `OS.execute_with_pipe` exists in 4.7.2 (VERIFIED
  by ClassDB probe) and the docs list Android among its platforms, but since
  API 29 a binary in app-writable storage cannot be executed at all — it would
  have to ship as a jniLib inside a custom Gradle build, in a project that has
  never built an APK. (That last point is inferred from the W^X rule, not
  verified on a device.)

So `src/uci.gd` speaks UCI over a pipe and is used **only if a Stockfish binary
is already on the machine** and `chess/external_engine` is turned on. Nothing is
bundled, nothing is downloaded, and the native search is the one that ships.

**Correctness is established by perft, not by playing it.** `tests/run.gd`
runs the six standard positions — start, Kiwipete, the rook-and-pawn endgame,
the promotion position, the tactical position and the middlegame position — and
compares node counts against the published values at depths 1-3, and depth 4
where it is cheap enough:

    startpos    20 / 400 / 8902 / 197281
    kiwipete    48 / 2039 / 97862
    endgame     14 / 191 / 2812 / 43238

A move generator is either exactly right or quietly wrong, and these numbers are
the only test that catches "quietly wrong". They are what proves castling
through check, the en passant that exposes a king along a rank, and the
underpromotion to a knight. Every one of the six also asserts the position is
unchanged afterwards, which is what catches a broken unmake.

**Legality is decided by make-and-test, not by pin detection.** Generating
pseudo-legal moves and asking whether the king is attacked afterwards is slower
than tracking pins during generation, and it is the version that cannot get en
passant wrong: BOTH pawns leave the rank in one move, so a rook that pinned
neither of them can end up giving check. There is a test for exactly that
position, asserting the capture IS generated pseudo-legally and IS rejected as
illegal — so it tests the filter rather than an absence.

**The search runs on a worker Thread and is handed a FEN, never the board.**
Two threads on one mutable position is the obvious way to corrupt it, and
copying through FEN costs microseconds against a search measured in hundreds of
milliseconds. The alternative, a time-sliced search on the main thread, was
rejected because the deepest level wants two or three seconds and slicing that
across frames means the board stops answering a child's finger while the
machine thinks.

**Difficulty is noise on the root scores, not a shallower search.** Each of the
nine levels caps depth and time, and then adds a uniform random bonus of up to
`noise` centipawns to every root move before the best is taken. A level made
weak by searching one ply plays moves that are stupid in a boring, uniform way;
a full search plus noise develops sensibly and then hangs a piece, which is
what a human beginner does and what a child can learn to punish. Anything
decisive — a mate found or a mate to be avoided, ±900 cp or more — is exempt,
because a level that walks into mate at random reads as broken rather than
weak, and one that MISSES a mate it has already found refuses to end the game.

**Level 1 "Child" is the exception, and is uniform selection rather than
noise** (added 2026-08-25). The obvious implementation — level 1 with a very
wide `noise` — was built first and MEASURED not to work: at noise 1500 against
Beginner's 320 it scored 46% over 14 games, i.e. no weaker at all. The reason
is saturation. Both sit at depth 1, and past roughly 500 cp the window already
spans the entire depth-1 score spread, so every larger number yields the same
near-random player. `uniform: true` draws the root move from a flat
distribution instead, which is a different mechanism rather than a bigger
number and is the actual floor — there is nothing below "any legal move".

Two guarantees are kept at that level anyway. The ±900 cp exemption still
applies, so Child takes a mate, dodges one, and snaps off a hanging queen; a
game a child cannot finish reads as broken, not as weak. And its time budget is
LARGER than Beginner's (80 ms against 60) despite being weaker, because an
aborted search truncates `scored`, and drawing uniformly from a truncated list
draws only from the best-ordered moves — accidentally stronger, and erratically
so. `native_only: true` also keeps it off any external UCI engine: Stockfish's
floor is Skill Level 0 / UCI_Elo 1320, an order of magnitude too strong.

Inserting a level at the BOTTOM renumbers every stored preference, so
`chess/level` is migrated once against `chess/level_scale` in `src/main.gd` —
scale 1 is the original eight, scale 2 adds Child and shifts every remembered
number up by one. Without it, everyone's saved difficulty silently drops a
notch. The setup grid is 3x3 now rather than 4-to-a-row, because nine divides
by three and four leaves an orphan on a third row.

**The pieces are drawn in code.** Godot's default font carries none of the
chess glyphs — VERIFIED, `Font.has_char()` is false across the whole
U+2654..U+265F block on Open Sans SemiBold — and the system fonts that do have
them (DejaVu, FreeSerif, Noto Sans Symbols 2) are present on this desktop and
absent on Android, so depending on one would make the pieces vanish on a target
we intend to ship to. Bundling a symbol font means a licence and half a
megabyte for twelve glyphs. `src/pieces.gd` is polygons in a 100x100 box: no
atlas, any square size, and the colour is an argument, which is what lets one
knight serve as the board piece, the promotion button and `icon.svg`.

A GDScript trap worth remembering: **`const X := PackedVector2Array([...])` is
not a constant expression** and every such line fails to compile. The geometry
is held as `const Array[Vector2]` and packed once per draw inside `_xf()`,
which allocates exactly what it already allocated.

**The game goes out as PGN in chess.com's shape**, RETAINED and FIRST, then the
scalars, with `ts` last — the same ordering notes uses for a saved document.
Headers are the seven-tag roster in its mandated order followed by
`TimeControl`, `EndTime` and `Termination`, and every move carries
`{[%clk H:MM:SS.t]}` with the mover's remaining time. VERIFIED on the wire
against a real `eclipse-mosquitto:2` in Docker: the PGN arrived complete, the
scalars followed, `ts` landed last, and a fresh subscriber replayed only
`qGames/chess/pgn` and `qGames/chess/fen` — proving those two are retained and
nothing else is. `Site` is "qGames Chess" and not chess.com; claiming a game
was played somewhere it was not is the sort of small lie that makes an archive
untrustworthy.

`Termination` is plain language and is the same string the end card shows the
player — "Player won by checkmate", "Game drawn by the 50-move rule". A child
can be told that; `1/2-1/2` cannot.

**Three layout defects, all surfaced by the reading size rather than caused by
it** — the same lesson paint already paid for:

1. The new-game dialog did not fit. At 1280x720 with the reading size at 1.6x
   the logical viewport is 800x450, and a stacked dialog is taller than 450 —
   the Start button was simply off the bottom of the screen, unreachable, with
   nothing to say so. It is now three groups in an `HFlowContainer` that go
   side by side when there is width and stack when there is not, inside a
   `ScrollContainer` as the backstop.
2. **An `HFlowContainer` reports the width of its WIDEST CHILD as its minimum**,
   so inside a `CenterContainer` it always asks for one column and always
   wraps to one. It will use extra width but never request it. The setup card
   now sets `custom_minimum_size.x` to the width of the column count that fits.
3. **An `HFlowContainer` reports the height of ONE row**, whatever it actually
   wraps to, because width is not known when minimum sizes are asked for. The
   panel's button row therefore got one row's worth of space and drew its
   second row outside the panel. `get_line_count()` knows the answer once the
   layout has run, so the minimum is corrected afterwards — every frame, because
   a single deferred call after a resize can still read the pre-wrap answer.

**A defect in `tools/new_game.sh`, found by using it.** The splash generator
rasterised `icon.svg` at `ICON / 256.0`, hardcoding an assumption that every
icon is 256px. A 512px icon was rasterised at 1024 and then only its top-left
quarter was blended into the canvas — a visibly wrong splash with no error
anywhere. The scale is now derived from the icon's own intrinsic size, and the
result is resized if the rasteriser rounds it off by a pixel. The four existing
icons are all 256px, so no other game was affected.

**`tests/interactive.gd` drives the real game with real clicks and keys**, and
is deliberately NOT in `make test-all`, which is headless. It covers the half
the unit tests cannot: that a tap on a square selects a piece, that the
keyboard cursor plays a move, that reviewing a past move makes the board
read-only, that the promotion picker appears and promotes, and that resigning
ends the game with the right sentence. It runs green at **1280x720, 1024x600
and 720x1180, at reading sizes 0.7, 1.0, 1.6 and 2.4** — twelve combinations,
which is how all three layout defects above were found.

Two things it taught about testing Godot on this machine:

- **Input events carry WINDOW pixels, not viewport coordinates.** The two
  coincide only when the stretch scale is 1:1, which it was at 1280x720 — so
  the conversion looked unnecessary until the window was made portrait and
  every click missed. `Viewport.get_screen_transform()` is the conversion.
- **A vsynced buffer swap blocks for about a second in this session.** Under
  XWayland with nothing actually on screen the whole run drops to one frame per
  second, which turns every wait into a hang; with `VSYNC_DISABLED` the same
  run measures over a thousand frames a second. Waits in the test are therefore
  wall-clock and not frame counts, because the frame rate here is not a
  constant.

Untested: Android, ARM hardware, and the external Stockfish path — no engine is
installed on this box, so `src/uci.gd` has never spoken to one. The native
search is what every test and every screenshot exercises.

**Fourth game, new: `paint`** (2026-08-21). A drawing pad that saves PNGs.
Three tools (brush, rubber, fill), twelve colours, four brush sizes, undo,
clear, save. Deliberately no layers, shapes or text — a child should be able to
use all of it without being shown.

**It exists because the gen1 version crashed the Pi, and the cause was looked
up rather than guessed at.** gen1's `games/paint/main.py` held
`deque(maxlen=20)` for undo AND another for redo — bounded by COUNT, but each
entry was a full-resolution `Surface.copy()`. Forty copies at roughly 6 MB
apiece on a 1080p screen is about **240 MB of "bounded" history**. So the fix
was never "add a cap"; it was cap the BYTES and stop storing raw pixels.

- History is capped at 24 steps **and** 8 MB, whichever bites first, and every
  entry is a PNG rather than raw pixels. A painting is mostly flat colour and
  compresses enormously — measured, a typical picture is 3.52 MB raw and
  0.02 MB as PNG.
- There is exactly ONE `Image` and ONE `ImageTexture` for the life of the game.
  The texture is `update()`d in place; building an `ImageTexture` per change is
  the standard way to leak in Godot and would put the crash straight back.
- The canvas is a FIXED 1280x720, scaled to fit the window. Reallocating the
  image on every resize would churn megabytes for nothing, and it means a
  picture drawn on a laptop and one drawn on a Pi are the same picture.

VERIFIED by soak, not by argument: **300 strokes with fills, undos, redos and
clears mixed in, RSS oscillating 196-205 MB with no trend**, history pinned at
24 steps and 1-1.7 MB throughout. (The debug HUD's slope reads +12 MB/min on
this run and is wrong: its least-squares window is fitting noise on a signal
that bounces a few MB. The absolute readings are the evidence, not the slope —
worth remembering the next time that number is quoted.)

**Three performance problems, all found by measuring rather than guessing:**

1. `set_pixel` per pixel made the biggest brush cost **30 ms per 100 px of
   drag** — below 60 fps while drawing, and five times worse on a Pi. A round
   dab is 2r+1 contiguous ROWS, so it is now that many `fill_rect` calls
   instead of pi*r^2 pixel writes: 69 calls rather than 3600 at the largest
   size. Strokes also step by half a brush radius rather than every pixel,
   since a round dab covers everything within r. Measured 30 ms -> 0.1 ms.
2. A full-canvas flood fill took **737 ms** through `get_pixel`/`set_pixel`,
   and 784 ms through a `PackedByteArray` — indexing bytes in GDScript costs
   about as much as a Color, four times over. Viewing the buffer as int32s
   makes a pixel test one integer compare: **170 ms**. Still the slowest thing
   in the game, and a beat on a Pi, but it is a deliberate one-off action.
   The int32 packing depends on byte order, so a test compares a filled pixel
   against one drawn the ordinary way rather than assuming it.
3. Every dab reported a change and the view uploaded the whole 3.5 MB texture
   each time — dozens of GPU uploads for one drag, at 47 ms frames. Uploads
   are now coalesced to one per frame, since the screen can only show one
   anyway: 47 ms -> 18 ms, CPU 91% -> 58%.

The PNG snapshot for undo costs ~29 ms, and it is taken when a stroke ENDS
rather than when it begins. Same cost either way, but at touch-down it lands
in the middle of a child starting to draw, which is the worst possible moment.

**The eraser rubs out a BLOCK**, not a circle — one `fill_rect` per dab, so it
is also the cheapest tool in the game. It matters because the pointer shows a
square: drawing a square while erasing a circle is a small lie a child finds
the first time they try to clear a corner. The round dab is untouched; only the
eraser asks for a square, and a test checks both (the square reaches its corner,
the circle does not).

**The tool buttons carry icons** (`assets/tool_*.svg`), authored at button size.
An earlier attempt reused the 64px cursor art and it simply never appeared —
worth knowing before reaching for `expand_icon` again. The picture matters more
than the word here: a four-year-old who cannot read still knows which one is the
brush.

**The pointer IS the tool** (2026-08-21). Over the paper the OS cursor is
hidden and the tool drawn in its place, at the ON-SCREEN scale — so what is
outlined is exactly what will be marked, which an OS cursor could not manage
because the canvas is scaled to fit the window. A circle the size of the brush,
a white block for the eraser, a tipped bucket for fill with a drop of the
chosen colour where the paint will land. The mouse mode is restored on mouse
exit, on window focus loss and on tree exit: a hidden cursor that escapes onto
the desktop is a genuinely alarming bug.

The fixed crosshair is gone. A keyboard pointer is still drawn, but only when
`QInput.wants_focus_ui()` says somebody is actually driving with keys or a pad,
and never at the same time as the mouse one — a crosshair parked in the middle
of the paper for a mouse user is just a smudge they cannot rub out.

Undo and redo are SVG icons (`assets/undo.svg`, `assets/redo.svg`); the bucket
is an SVG too, drawn both on the Fill button and as the cursor. The palette is
twelve colours with the plain primaries rather than muted designer versions — a
child asking for "blue" means blue — plus pink. "Rubber" is now "Eraser".

**Paint update (2026-11-20).**
- Clear and Save keep their words and gain icons (`assets/clear.svg`, a red X; `assets/save.svg`, a floppy disk).
- Square brushes: a second row of four size buttons drawing squares (`SizeButton.square`). One choice across all
  eight; `_square_brush` plus `brush_square()` (true for the eraser too) feed `canvas.dab/stroke(..., square)`,
  and the pointer outline is a square to match.
- Colour mixing: "+" after the swatches opens a `ColorPicker` in a `PopupPanel` (RGB sliders, hex field, HSV
  rectangle; no mode tabs, intensity slider, presets or screen sampler). "Add colour" appends a swatch and chooses
  it; a colour already present is chosen instead of duplicated. Up to `MAX_CUSTOM` 12, oldest dropped, stored in
  `paint/custom_colours` (hex strings) and reloaded at start.
- Arrow-key pointer fix. Was: with the mouse resting on the paper, the tool stayed drawn under the mouse while
  the arrows moved an invisible cursor, so Space painted away from the shown pointer. Now whichever moved last
  owns the pointer (`_keys_active`; real mouse motion or a click hands it back), the keys pick up from the
  mouse's spot, and the key pointer is drawn at its pixel's middle, where the dab centres.
- **The eraser tool is gone** (owner: redundant). White plus a square brush rubs out the same block, and the paper
  is white. `Tool` is `{BRUSH, FILL}`; `assets/eraser.svg` and `tool_eraser.svg` were deleted. The "eraser rubs out
  a block" notes above are history; `canvas.dab(..., square)` and its test remain, used by square brushes.
- Toolbar layout (owner's call): sizes are a 2-row grid, round over square; colours a 2-row grid (columns grow
  with mixed colours, "+" last); undo and redo side by side, then Clear and Save side by side (stacked versions came first and were changed).
  The tool buttons are top-aligned (`SIZE_SHRINK_BEGIN`). Single-row groups (tools, separators) are
  `SIZE_SHRINK_CENTER`. Side by side, the bar ran past 1024 and wrapped; the interactive test now checks it fits
  one line at the design size.
- `tests/interactive.gd` is new for paint (needs a display): icons, square brush paints its corners, picker adds
  and chooses a slot, mouse-then-arrows-then-Space paints at the keys' pointer, mouse takes it back. Restores the
  player's `paint/custom_colours`. Shots `p1`-`p4` in `user://shots`.

**Paint: shapes, colour dropper, Open (2026-11-20).**
- Tools are six icon-only toggle buttons in a 3-wide grid (`Tool` enum order = grid order): Brush, Fill, Colour
  dropper / Line, Box, Oval. Names are tooltips. The words went because six labelled buttons do not fit 1024.
- **Shapes** (`PaintCanvas.Shape`, `shape_points`, `shape`, `constrain`): drag from one corner to the other, the
  preview follows (`CanvasView._draw_shape_preview`, the same points the canvas will stroke, joints drawn like
  dabs), and the shape lands on release as one undo step. Drawn with the current brush: size, round or square
  tip, colour. Outline only, MS Paint's way: the bucket fills a closed box or oval, and a test checks that
  the fill stays inside. Shift squares a box, rounds an oval and snaps a line to 45 degrees, for mouse drags
  only, because with the keys Shift already means bigger steps. Keyboard: Space sets the first corner, the
  arrows move the other, and Space again lands the shape.
- **Dropper**: tap the paper and it takes that colour (its swatch if one exists, otherwise a new custom slot
  via `_adopt_colour`), then hands back the previous tool (`_before_dropper`), as MS Paint does. The pointer is
  `assets/dropper.svg` (64px, tip at (4,60)) plus a disc showing the colour under the tip.
- **Open**: lists `user://paintings/painting_*.png` newest first, at most `GALLERY_MAX` 24, as thumbnails
  (176x99). The thumbnails are decoded one per frame in `_process`, because a full PNG decode each would stall a
  Pi if done all at once. They are freed when the window closes. Choosing one: `PaintCanvas.load_picture()`
  copies it into the one Image (fitted if the size differs) as ONE undoable step, so the replaced picture is
  one Undo away. The window uses the toolbar's light chrome.
- Tests: 76 unit (shapes, constrain, pick, load_picture incl. same-Image check); interactive adds a box drag
  (preview leaves the paper untouched, release lands it), the dropper by its real button, and Open, using a
  future-dated fake painting it deletes afterwards. **Test gotcha:** a PopupPanel is its own embedded Window,
  so a control's global rect inside it is in the popup's space; add `popup.position` to click it.

Pictures are written to `user://paintings/` — app-private on Android,
`~/.local/share/godot/app_userdata/Paint/paintings/` on Linux. MQTT VERIFIED
on the wire, and not just that it published — the bytes were pulled back off
the broker and decoded, giving a 1280x720 PNG of the actual painting. The
picture goes to `qGames/paint/image` RETAINED and FIRST, then the scalars, with
`ts` last, so anything reacting to ts already has the image. Home Assistant
needs an MQTT *camera* for it; a sensor state cannot carry binary at all.

**It is sent at full size, and copying gen1 here was a mistake.** gen1 scaled to
800px wide before publishing, so this did too — until it was measured:

| painting | full PNG | 800px bilinear | 800px nearest |
|----------|---------:|---------------:|--------------:|
| simple   |    12 KB |          20 KB |          6 KB |
| busy     |    63 KB |         128 KB |         39 KB |
| dense    |    87 KB |         167 KB |         53 KB |

A bilinear downscale blurs flat colour into gradients, which is precisely what
PNG compresses well — so the "thumbnail" came out roughly TWICE the size of the
original. The full picture now goes out as-is: smaller than the scaled version
and at full quality. A cap remains as a safety net, and steps down with NEAREST
(which keeps flat areas flat) only if a picture ever exceeds it, because a
broker that refuses an oversized packet drops the publish silently. A test
asserts the bilinear result is larger, so nobody reintroduces the scaling as an
optimisation. gen1 also wrote its thumbnail to a file in ~/Pictures and left it
there; this publishes bytes and leaves nothing behind.

**Third game, new: `notes`** (2026-08-20, rewritten as a WYSIWYG editor
2026-08-21). A small Markdown word processor. Not a port; nothing like it
existed in the old suite. Files live in `user://notes/*.md`, so app-private
storage on Android and `~/.local/share/godot/app_userdata/Notes/` on Linux,
with no repo involvement.

**You type in the rendered text.** The rich view is the editing surface and is
what opens by default; the raw Markdown is a second pane, hidden until asked
for (the toolbar button cycles Rich → Source → Split).

- **Godot has no rich-text editing control.** RichTextLabel displays BBCode and
  nothing else — no caret, no text input, no editing API — and there is no
  other candidate. So `src/richedit.gd` (`QRichEdit`) is a text editor built
  from the layout primitives underneath it: `TextParagraph` shapes and wraps,
  `TextServer` draws the glyphs, and caret, selection, hit testing, input,
  undo and scrolling are all implemented here. VERIFIED against 4.7.2 by
  probing the API before any of it was written.
- **The document is Markdown source, always; the caret is an index into that
  source.** Every visible character records which source character produced it
  (`QMarkdown.parse_blocks` builds the map during the scan), so a click becomes
  a source index and an edit is a string splice plus a reparse. Nothing ever
  converts rendered text back to Markdown — the reverse step is what makes most
  WYSIWYG editors lossy, and there is none of it.
- **The caret therefore cannot enter a marker.** `**` produces no visible
  character, so it has no map entry and no caret position resolves into it.
  Stepping right through `**bold**` goes b, o, l, d, then out past the closing
  asterisks. VERIFIED by a test that walks every caret stop.
- **One source line is always one block**, fenced code included. Markdown
  proper joins consecutive lines into a paragraph; an editor must not, because
  the writer pressed Return. It also means no block contains a newline, so
  every block is exactly one TextParagraph — which is what keeps the caret
  arithmetic simple enough to be correct.
- **``` fence lines stay visible**, as dim code rows. Hiding a structural
  marker in a Markdown editor makes it unremovable: there would be no way to
  put the caret on it and take it out.
- **Backspace at the start of a line strips that line's marker** before it will
  join lines. Without this a stray `- ` or `# ` could never be deleted at all,
  for exactly the reason above — no caret position maps into it. Found by the
  interactive test, not by the unit tests.
- Per-run colour is why the editor draws glyph by glyph rather than calling
  `TextParagraph.draw()`, which paints a whole paragraph in one colour. Each
  glyph reports its `span_index`, so the lookup is direct.
- 302/302 tests pass, including: every visible character verified against the
  source character its map names, across a deliberately awkward corpus; every
  caret stop round-tripped through its on-screen rectangle (a caret drawn one
  character from where a click resolves would fail here); and a cached parse
  compared field-for-field against a cold one.
- `tests/interactive.gd` drives the REAL game with real key events and is
  deliberately NOT in `make test-all`, which is headless — it needs a display.
  It covers what the unit tests cannot: that keys actually arrive through
  `_gui_input`, focus, the toolbar and the file store. It is what caught the
  marker-backspace bug.
- **The old keyboard trap is gone.** The previous TextEdit surface ate Tab and
  the arrow keys, so the toolbar was unreachable until you pressed Escape
  first. The rich editor indents on Tab only where an indent is what Tab means
  — inside a list or a code block — and moves focus everywhere else. VERIFIED
  interactively; Escape still leaves the editor, and again quits.
- Telemetry VERIFIED on the wire: a save is the "round", `score` is the word
  count with `score_unit=words`, and `chars` rides along.

**Notes opens on a blank page** (2026-08-21). The welcome template is gone and
the app no longer auto-opens whatever it found on disk — a word processor
starts on an empty document with the caret ready, and saved notes are one
Files press away. VERIFIED on a cold launch: empty text, no filename, not
dirty, "Untitled", focus already in the editor, and the existing note still on
disk untouched.

**The toolbar is a word processor's, not a game's** (2026-08-21). The point is
not the icons — it is that the buttons REPORT as well as command, which is what
separates a toolbar from a row of shortcuts:

- **B is lit while the caret is in bold text**, the dropdown reads "Heading 2"
  when you are in one, and the list buttons light in a list. Everything is
  derived from the document on every caret move, nothing is remembered, so the
  toolbar cannot drift out of step with the text. For a selection an inline
  style counts as on only if it holds THROUGHOUT — the Office rule, and the
  useful one, because it makes the button answer "will pressing this turn it
  off?".
- **A paragraph-style dropdown** replaces the old "H" button that cycled
  through six levels. It SETS rather than toggles: picking Heading 2 twice
  leaves you in Heading 2. A list is not a nameable paragraph style, so the
  dropdown shows blank there rather than something wrong.
- Undo/redo, greyed when there is nothing to undo. Groups separated by
  hairlines. Tooltips carry the shortcut.
- **The icons are drawn in code.** Godot ships no icon set to a running game —
  the editor's own icons are not available at runtime — and a glyph font would
  have to be licensed, bundled and hinted. Each icon is a few lines of vector
  drawing, so it scales with the button and recolours with the state, which is
  the part that actually matters. The italic `I` is drawn rather than typed: a
  synthesised italic capital I is just a leaning bar, indistinguishable from a
  slash, until it gets serifs.

**Light and dark themes, light by default** (2026-08-21). Every colour lives in
one of two palettes with identical keys; nothing is hardcoded at a call site.
Light is the default because this is a word processor — every one people have
used since 1990 opens on a white page — while the other games stay dark. The
accent differs by more than lightness on purpose: amber carries a dark UI and
turns muddy on white, where a blue reads as the familiar document-application
highlight.

Switching **rebuilds the whole interface** rather than walking the tree
patching colours. Godot has no "restyle everything" call: colours live inside
StyleBox resources and per-control overrides scattered across the tree, and
walking that is how one control gets missed and stays the wrong colour. The UI
is built in code and costs a couple of milliseconds, so it is thrown away and
rebuilt — which cannot desynchronise, because nothing is left over. The
document is not part of the UI; the caret, view and focus are carried across by
hand. VERIFIED: toggling preserves text, caret and view, and the choice
survives a restart.

`QConfig` grew `set_value()` and `save()` for this. **Only keys passed through
`set_value` are ever written.** Writing the whole value set would copy the MQTT
password out of the environment into a file on disk — a credential moving
somewhere nobody asked it to go. VERIFIED: after toggling the theme,
`user://config.cfg` contains `[ui] theme` and nothing else.

**A pre-existing Markdown bug, made visible.** `***word***` (bold AND italic)
was rendering as bold `*word` followed by a stray `*`: the `**` branch took two
of the three opening asterisks and two of the three closing ones, stranding one
inside the emphasis and one outside. The old BBCode path had the same bug —
nobody saw it while the rendered text was only a preview. It became two visible
asterisks the moment the rendered text was the thing being typed into. Fixed by
matching `***`/`___` before `**`, with tests.

**Performance, measured 2026-08-21.** Every keystroke reparses the document, so
this was measured rather than assumed, on unique (non-repeating) text with the
caret in the MIDDLE so every line below shifts:

| note size | per keystroke |
|-----------|---------------|
| 1 KB      | 0.38 ms       |
| 3 KB      | 0.95 ms       |
| 7.7 KB    | 2.31 ms       |
| 15 KB     | 4.81 ms       |

That is ~0.31 ms/KB, after three fixes worth 4.5x. The first draft was 1.4
ms/KB — 33 ms per keystroke on a 10 KB note, which is 30 fps while typing:

1. `parse_blocks` takes a caller-owned line cache, so typing reparses the one
   line that changed. This is why block maps hold offsets RELATIVE to their
   line: an unchanged line that merely shifted is still a cache hit.
2. The inline scanner's source map is built in a plain `Array`, not a
   `PackedInt32Array`. A packed array stored in a Dictionary is a VALUE —
   reading copies, appending grows the copy, writing back copies again — so
   merging character by character was O(n^2) per line. Plain arrays are
   references and append in place. Literal runs are also consumed in bulk
   rather than one character per loop turn.
3. Identical lines share one shaped `TextParagraph`. A paragraph holds shaped
   text and nothing positional, so this is safe — and a document with sixty
   identical list items was re-shaping all sixty on every keystroke.

Untested: nothing here has run on Android or ARM. At ~5x slower a 15 KB note
would be ~24 ms per keystroke, which would be felt; a normal note would not.

**Two Godot details that had to be measured, not reasoned about.** Both were
established by rendering the alternatives and looking at them, and both would
have been silent-but-wrong:

- `shaped_text_get_grapheme_bounds(rid, v)` returns the bounds of the grapheme
  ENDING at `v`, so its `y` is the caret x for visible index `v` — except at
  the first index of a line, where the answer is 0. Wrapped lines take
  ABSOLUTE paragraph indices, not line-relative ones.
- Fake italic goes in the x axis's Y component, `Transform2D(Vector2(1, 0.22),
  Vector2(0, 1), ...)`. The intuitive reading — shear x by y, in the y axis's
  X component — renders as sagging, jittery text rather than a lean, and a
  negative coefficient leans it backwards. The first draft shipped the broken
  one; a zoomed screenshot is what exposed it.

**Second game ported: `sequence`** (2026-08-20). "What comes next in the
pattern?", for 3–4 year olds. Ported from the pygame original with its
generation rules kept exactly — the pattern library, the AB/AAB/ABB types, the
2-periods-minimum visible run, the distractors-from-the-pattern-first rule, and
the 5/7/10 star thresholds — so the difficulty the kids know does not shift.

- `src/round.gd` — `SequenceRound`, pure RefCounted. Seeded rounds are
  reproducible, which is what makes the generator testable: 27/27 tests pass,
  including 300 generated questions walked through the invariants.
- `src/main.gd` — code-first view. Shapes are drawn with `draw_colored_polygon`
  and `draw_circle`; no assets at all, so nothing to import or scale.
- Keyboard-only play VERIFIED: all four options reachable by d-pad, a full
  10-question round played with Enter alone, focus lands on "Play again" at the
  end. Touch path is the same `_gui_input` handler.
- MQTT VERIFIED against a live broker: publishes the common core plus the
  historical `sequence/total` topic, so the old Home Assistant sensors for
  `sequence/score` and `sequence/total` keep working unchanged.
- Exports clean for Linux x86_64 and arm64 (a genuine `ELF ARM aarch64`).

A visual pass followed the first play session: option buttons are now the same
size as the sequence cells rather than half (they are the only thing anyone
touches, and they were a smaller target than the things you only look at);
shapes are scaled per-shape because equal bounding boxes do not look equal —
a square fills its box, a circle 79%, a triangle 43%, a star about 30%, so a
star drawn "the same size" reads much smaller; press, correct and wrong all
animate; the focus ring is rounded to match the controls it surrounds.

That pass also cost CPU, which the debug HUD caught: idle process CPU went from
~24% to ~52%, because the breathing animations forced a full repaint of the
board every frame and each rounded rect allocated a StyleBoxFlat. Throttling
the idle pulses to 20 Hz and sharing two mutable StyleBoxFlat instances brought
it back to ~25-30%, below where it started. VERIFIED 2026-08-20.

Two things the port fixed rather than copied: the round-over panel hides the
question instead of floating translucently over it, and `Array.shuffle()` is
not used anywhere in the model — it draws from the global RNG, which would make
a seeded round non-reproducible and the tests meaningless.

**`tools/new_game.sh` now rewrites `game_id`.** It copied `project.godot`
verbatim, so every scaffolded game would have published MQTT to
`qGames/memory/` — silently, since nothing validates the id. The script now
rewrites the line and aborts if it is missing.

**Spike is built and verified end to end** (2026-08-20):

- `shared/qcore/` — parses and runs under 4.7.2; MQTT publisher verified against a live
  mosquitto broker, producing `moves`, `result`, then `ts` last, in one connection.
  Packet encoding checked against the MQTT 3.1.1 spec.
- `games/memory/` — code-first port. 43/43 tests pass headless (19 model, 15
  QDebugStats, 9 QTelemetrySchema). Renders correctly, zero runtime warnings. Keypad focus
  navigation confirmed visible on screen.
- Exports clean for **both** Linux x86_64 (71 MB) and Linux arm64 (64 MB) from this
  x86_64 laptop. The arm64 artifact is a genuine `ELF ARM aarch64` executable — no
  cross-compiler, no ARM hardware involved. The exported binary runs and links only
  system libraries.
- `Makefile`, `.github/workflows/ci.yml`, `tools/new_game.sh` in place. CI is written
  but has never executed on GitHub — there is no remote yet.

**Added 2026-08-20, after the first play session:**

- **Debug HUD (`QDebug`), platform-wide.** Off/compact/full, bottom-right so it
  stays clear of game HUDs, on CanvasLayer 128 so nothing can cover it. F3
  cycles, F4 pops it into a separate OS window, F5 re-baselines; a "dbg" chip
  is the touch path and gamepad Select is the pad path. `debug/hud_stdout`
  prints the same one-line summary at 1 Hz, which is the only readout available
  over ssh on the Pi. On in debug builds by default; `debug/hud=on` forces it
  into a release export.
  VERIFIED end to end 2026-08-20: real run reports ~56 fps / 17–20 ms frames /
  ~22% CPU / flat 182 MB RSS with the slope converging to ~0; MQTT rows read
  live against a stub broker (msgs 19/19, batches 5, out 892 B, in 20 B,
  fails 0, rtt 137 ms) and the ts-last ordering was re-confirmed in the broker
  log. Detached-window open/close verified, including restoring
  `gui_embed_subwindows`.
- **Memory game text was drawn behind the cards.** Sibling order is draw order
  for Controls and the labels were added to the tree first. Labels now come
  after the cards and both carry a filled, rounded StyleBox so they read over
  whatever they land on; the HUD sizes itself to its own text, centres, and
  shrinks its font to fit narrow screens rather than clipping.

Three defects were found and fixed during the join, none of which the tests caught:
1. `QGameRoot` laid out against a 0x0 root — the game drew nothing while tests, import,
   and runtime logs were all clean. Only a screenshot exposed it.
2. `Makefile` passed export paths relative to the repo root; Godot resolves them against
   the project dir, so exports failed outright.
3. `make new-game` used a `DISPLAY` variable, which Make imports from the environment
   (`:0` on a desktop session) — it would have silently titled a new game ":0".

## Packaging and install

**`make dist` produces a directory you copy anywhere and run.** No toolchain,
no package manager, no environment setup on the target:

```
dist/VERSION            0.1.0+4.gab12cd
dist/install.sh         per-user installer, no sudo
dist/<game>/meta        id, display name, version
dist/<game>/icon.svg
dist/<game>/<game>-{x86_64,arm64,x86_32,arm32}
```

`dist/install.sh` detects the CPU, installs the matching binary under
`~/.local/share/qgames/`, and writes an XDG launcher, icon and `.desktop` entry.
`--uninstall` removes all of it and deliberately leaves saved notes and settings
in `~/.local/share/godot/app_userdata/`. VERIFIED by installing, running the
installed binary, and uninstalling: `desktop-file-validate` clean, launcher
works, and the saved note survived removal.

**Four architectures, on purpose.** Raspberry Pi OS still ships a 32-bit (armhf)
image and an arm64 binary will not run on it at all. Storage is the cheaper side
of that trade: the whole `dist/` is ~810 MB for three games.

**`embed_pck=true`: one self-contained file per game per arch.** With a separate
`.pck`, Godot locates it by matching the executable's BASENAME — so renaming the
binary during install silently breaks the game. Embedding removes the failure
mode and costs only the pack's own size (~90 KB).

### Settings ride inside the executable

`tools/bake_config.sh` writes `games/<g>/build_config.cfg` immediately before an
export. `QConfig` layers it:

```
defaults  <  res://build_config.cfg  <  user://config.cfg  <  environment
```

**This exists because a `.desktop` launcher does not inherit your shell
environment, and Android has no shell at all.** Without it, a game started from
a menu icon reaches no broker and publishes nothing — which looks exactly like
everything working. Baking is the only mechanism that behaves identically on a
desktop launcher, a Pi autostart and an APK, which is why it was chosen over a
wrapper script that exports variables.

VERIFIED end to end: an exported binary run under `env -i` — a completely empty
environment — authenticated to a real mosquitto in Docker and published its
telemetry. A device can still override a baked value in `user://config.cfg`, and
a dev shell still beats both; both checked.

**The trap this nearly shipped with:** `export_filter="all_resources"` means
imported RESOURCES. `build_config.cfg` is a plain file, so it was silently left
out of the pack and the game fell back to its defaults — no broker, version
`0.0.0-dev`, telemetry publishing nowhere while looking healthy. Naming it in
`include_filter` fixes it. Caught by grepping the artifact for the broker
address rather than trusting that the export "worked".

⚠ **A baked build contains the broker password in plain text** — `strings` will
show it. That is the trade for zero-setup installs on a private LAN. Use
`tools/bake_config.sh --no-secrets` for anything leaving the house. Both
`dist/` and `games/*/build_config.cfg` are gitignored, so neither reaches the
repository.

### Versioning

`tools/version.sh` derives semver from git tags:

| state | version |
|---|---|
| on tag `v1.2.3` | `1.2.3` |
| 4 commits past it | `1.2.3+4.gab12cd` |
| with local changes | `1.2.3+4.gab12cd.dirty` |
| no tags yet (today) | `0.0.0+gab12cd` |

Everything after `+` is semver build metadata, which is ignored for precedence —
the honest encoding, since a build four commits past `v1.2.3` is not `v1.2.4`
(nobody has decided what the next version is) but must still be distinguishable
from the tagged release. Only `v[0-9]*.[0-9]*.[0-9]*` tags count, so a stray tag
cannot become a version. The version is baked into the artifact and readable at
runtime via `QConfig.version()` / `build_info()`.

**v0.1.0 is cut.** `tools/release.sh patch|minor|major` (or
`make release BUMP=minor`) computes the next version from the latest tag,
writes the commits since as the tag message, and refuses a dirty tree — a
release has to be reproducible from its tag. Rebuild afterwards so the
artefacts carry it; `make dist` bakes the version in and the debug readout
shows it.

### Android, when it comes

Nothing here blocks it and one thing actively helps: `res://build_config.cfg`
travels in the `.pck`, so an APK gets its broker settings the same way a desktop
build does, with no per-device setup. What is still missing is unchanged — JDK
17, the Android SDK, and an export preset. `install.sh` is Linux-only by nature;
Android installs through the APK.

## Turning the debug readout on

**Ctrl+Shift+D** cycles it off / compact / full. **Ctrl+Shift+W** pops it into
its own window, **Ctrl+Shift+M** re-baselines the memory slope. F3/F4/F5 still
work, and the "dbg" chip in the corner is the touch path.

Ctrl+Shift+letter is the primary binding because function keys cannot be the
only way in: half the compact keyboards in the house need Fn held to reach F3,
and some have no F row at all. Shift is part of every combination on purpose —
games bind plain Ctrl+letter freely and mostly do not check shift — and D, W
and M are bound by no game regardless. The HUD listens on `_input`, so it sees
keys before any Control and a focused text field cannot swallow the toggle.

**The toggle works in a SHIPPED build**, which it did not before. `debug/hud`
used to mean "debug builds only", so the hotkey did nothing in the export people
actually run — and asking someone to reinstall a debug build to look at a frame
time is not a debug tool. Now only `off` removes it: the key works everywhere,
and it is the DISPLAY that differs, starting hidden in a release export unless
`debug/hud=on`. VERIFIED by running the installed release binary with default
settings and seeing the readout live.

**The readout leads with the build.** Compact shows `v0.1.0` (or `dev`); full
shows the game name, the full version including build metadata, and when it was
built. The first thing to establish about a bug report is which version produced
it, so it goes first rather than hiding in a corner.

## Reading size (Ctrl +/-/0)

**Every game can be scaled at runtime, platform-wide** (2026-08-21). Ctrl and
`+`, `-` or `0` — the combination every browser already uses. A brief toast
says "Size 130%", the choice is saved to `ui/scale` and survives a restart, and
the range is 0.6x to 2.4x in tenths.

It lives in `QGameRoot` because every game inherits it: a reading size that only
some games honoured would be worse than none. The mechanism is Godot's
`Window.content_scale_factor`, which multiplies the stretch — at 1.5 the logical
viewport shrinks from 1280 wide to 853, so every control, font and drawn pixel
comes out half again as big. That is the honest knob for "too small on the telly,
too big on the laptop": it moves the whole interface at once rather than being a
font setting that leaves the artwork behind.

The scale is applied BEFORE the first viewport sync, so a game lays out once at
the size it will actually have instead of laying out twice and flashing.

**It exposed a latent layout bug in paint.** Turning the size up shrinks the
logical viewport, and paint's toolbar — three tools, four sizes, twelve colours,
four actions — did not fit one row, so the `HBoxContainer` overflowed and shoved
the paper off screen. It is now an `HFlowContainer`, which wraps. The same would
have happened on any sufficiently narrow window; scaling just made it easy to
reach. VERIFIED at 0.7x, 1.0x and 1.6x in all four games, with the hotkeys,
clamping and persistence each checked on a real run.

KNOWN, not fixed: at 1.6x in a short window, sequence's four answer tiles wrap
to two rows and the lower one clips. That is the same clipping a genuinely small
window produces — surfaced by scaling rather than caused by it — and the fix is
in that game's layout, not here.

Untested: Android. There is no keyboard there, so the size can only be changed
by editing `user://config.cfg` until a gesture or a settings control exists.

## Boot splash

**The Godot logo is gone from all three games** (2026-08-21). Each game boots
to its own mark on its own background colour, so the splash and the first
drawn frame are the same colour and there is no flash between them.

Verified against this binary rather than from memory — `application/boot_splash/*`
has exactly six keys: `image`, `bg_color`, `show_image`, `stretch_mode`,
`use_filter`, `minimum_display_time`.

- **`image` is PNG only.** The FILE hint is `*.png`; an SVG is rejected. Each
  game therefore carries a generated `boot_splash.png` (864x864: a 512px icon
  centred, surround filled opaque in `bg_color`). The padding is deliberate —
  under `stretch_mode=1` (Keep, fit to the smaller dimension) it is what pins
  the mark at ~59% of the window instead of letting it fill edge to edge at
  every resolution.
- `bg_color` per game is read from that game's own background constant:
  memory `#19233c`, sequence `#161e34`, notes `#eef1f5` (notes defaults to the
  light theme).
- `minimum_display_time` is left at 0, so the splash lasts only as long as the
  boot (~0.6s). Set it to ~800-1200ms if it should actually register.

**Removing the logo is permitted.** Read from the shipped binary via
`Engine.get_license_text()`: standard MIT, containing no occurrence of splash,
logo, trademark, attribution or advertising. The only obligation is that the
copyright and permission notice accompany copies. Attribution belongs in an
about/credits screen, and the runtime already supplies what it needs —
`Engine.get_license_text()`, `get_license_info()` (19 third-party licences),
`get_copyright_info()` (102 entries). Not built yet.

**Two pre-existing defects surfaced doing this**, both confirmed against the
committed tree rather than taken on report:

1. `games/sequence` had **no `icon.svg` at all**, while its `project.godot`
   declared `config/icon="res://icon.svg"` — a dangling reference nothing
   validated. It now has its own mark.
2. `games/notes/icon.svg` was **byte-identical to memory's** (same md5). "Each
   game's own icon" was fiction until this was fixed; notes now has a document
   mark.
3. `tools/new_game.sh` copied **no** `icon.svg`, so every scaffolded game was
   born with the same dangling `config/icon`. It now writes a deliberately
   blank placeholder — a dashed hollow frame, obviously unset rather than a
   copy of memory's artwork — generates the splash from it, and gained a
   `--regen-splash <name>` mode for after you edit an icon. It aborts if the
   template loses its `boot_splash/image=` line, matching the existing
   `game_id=` guard.

**How the splash was actually seen** — worth recording, because the usual
method fails. External capture is unreliable here: `ffmpeg -f x11grab` and
`xwd -root` return black under Wayland, and GNOME's screenshot D-Bus returns
`AccessDenied`. But **`xwd -id <window-id>` against the XWayland window returns
real pixels.** Combined with `minimum_display_time` set high enough to hold the
splash on screen, that is a working capture path for anything that happens
before the main scene loads — including an exported release binary, not just an
editor run. VERIFIED this way for sequence and notes independently of the agent
that did the work.

Untested: Android (which has its own splash/theme interaction), the arm64
export, and the native Wayland display driver — every capture used
`--display-driver x11`.

## Environment

- Dev box: Ubuntu 24.04, x86_64, 12 cores, 62 GB RAM, 655 GB free. `/dev/kvm` present,
  so a KVM-accelerated Android emulator is comfortable. VERIFIED.
- Godot 4.7.2 editor: `~/.local/opt/godot-4.7.2/`, symlinked to `~/.local/bin/godot`.
- Export templates: `~/.local/share/godot/export_templates/4.7.2.stable/`.
- VS Code at `/snap/bin/code` with the official `godot-tools` extension (LSP on port
  6005, DAP debugging). Godot is configured to use it as external editor.
- Missing and needed only when Android work starts: JDK 17 (Java 21 *runtime* is present,
  no `javac`), Android SDK, `adb`.
- MQTT config lives at `user://config.cfg` — app-private storage on Android,
  `~/.local/share/godot/app_userdata/<project>/` on Linux. Never in the repo.

## Window mode: maximized (2026-08-25)

Every game's `project.godot` carries `[display] window/size/mode=2` (Maximized —
the value is the engine's own enum, hint string "Windowed,Minimized,Maximized,
Fullscreen,Exclusive Fullscreen"). Maximized rather than fullscreen on purpose:
the target Pi has its panel at the top, and fullscreen would swallow it.

**The project setting alone is not enough.** VERIFIED 2026-08-25 by screenshot on
the Pi: under labwc/Wayland (Raspberry Pi OS trixie) the window still came up
windowed at 1280x720 in the top-left corner. `QGameRoot._apply_window_mode()`
re-asserts it from `_ready()` once the window exists, reading the value back out
of ProjectSettings so `project.godot` stays the single place the intent is
expressed. That is a no-op on backends that already honoured the setting.

## The Pi (2026-08-25)

- Host `10.118.25.17` (eth0, TRUSTED VLAN 25) — user **`q`**, Debian 13 trixie,
  aarch64 → `arm64` builds. labwc + `wf-panel-pi`. VERIFIED.
- **Updates go over `10.118.25.17` — `make deploy`, no arguments.** `PI` now
  defaults to the ssh alias `qpi` (`Host qpi` in `~/.ssh/config` →
  `q@10.118.25.17`), so the target is not something to remember or mistype.
  `make deploy GAME=paint` for one game, `make deploy PI=<user>@<host>` for
  anywhere else. It reads the target's `uname -m` and builds only that arch, so
  a wrong-architecture binary is not a way this can fail.
- All five gen2 games install under `~/.local/share/qgames/`, launchers at
  `~/.local/share/applications/qgames-<id>.desktop`.
- **Taskbar = qdock (2026-11-18), not wf-panel-pi launchers.** See "## The Pi's dock (qdock)". wf-panel-pi still
  runs (the system labwc autostart respawns it; no root to change that) but its `widgets_left=` is now empty, so it
  shows only volume, clock, power. Its `launchers=` key is unused. Backups: `~/.config/wf-panel-pi/wf-panel-pi.ini.bak-20261118`
  (the old launchers + window list) and `~/.config/labwc/autostart.bak-20261118`. There is a second, stale
  `~/.config/wf-panel-pi.ini` (no directory) that nothing reads.
- The gen1 games (battleship, letters, memory, paint, sequence, simon) are still
  installed there under bare `<id>.desktop` names. Left alone; they no longer
  appear on the taskbar but are still in the applications menu.
- **The rsync gotcha is GONE as of 2026-08-27.** `wlan0` is down — `ip -4 addr`
  on the Pi shows only `lo` and `eth0 10.118.25.17/24` — so TRUSTED is the only
  path and the asymmetric-routing drop cannot happen. A full deploy to
  `10.118.25.17` moved 336 MB at ~15 MB/s. VERIFIED.

  Kept for the day `wlan0` comes back: the Pi used to be dual-homed, `eth0` on
  TRUSTED and `wlan0` on the LAN as `192.168.1.197`. A laptop on the LAN reached
  it *through* OPNsense while the Pi replied straight out `wlan0`, so pf saw one
  direction only, could not track the peer's window, and dropped once the sender
  exceeded the initial window. ssh, ping and `mkdir` worked; a bulk transfer
  moved 36 KB in ten minutes and hung. If that returns, deploy to
  `192.168.1.197` or take `wlan0` down again.

## The chess piece set, redrawn (2026-08-25)

Redrawn against a reference Staunton set the owner supplied. `src/pieces.gd` is
still the single source: path data in a 100x100 box, tessellated for the screen
and exported to `assets/pieces/*.svg` by `make chess-pieces-repo`.

**The bug that was actually making the pieces look wrong:** `to_svg()` never
emitted the `circles` array. The drawn set has a ball on the pawn, a finial on
the bishop and five pearls on the queen; the EXPORTED set had none of them, and
a committed set shadows the drawn one — so the game shipped headless pawns while
every test and every in-editor run looked correct. Fixed; circles are emitted
first, ahead of the fills.

What changed in the artwork, and why, in case it is ever revisited:

- **Contrast at the joint** is the governing rule. Where two parts are within a
  few units of the same width they fuse at board size and the piece loses its
  name. Every neck is now much narrower than what sits on it.
- **Knight**: rebuilt four times before it stopped reading as a dog. What fixed
  it, in order of effect — the head is BIG (head and neck are one mass filling
  the upper square); ONE ear, not two peaks; the face is a steep DISHED diagonal
  to a blunt nose at the far left; and a throat notch cut as a wedge. It was
  traced from the reference, not drawn from memory, which is what the four
  failures were.
- **King**: the reference's figure-eight crown is a STROKE, not fills. Two
  overlapping filled ellipses is the obvious approach and gives two eggs — fills
  have no holes. A stroke can cross itself, and the crossing is the shape.
- **Base**: `BASE`/`BASE_WIDE` widened and given a lip.

**The icon is now GENERATED** from the same knight — `ChessPieces.to_icon_svg()`,
written by `make chess-pieces-repo` alongside the set (repo dumps only; a
user:// dump must not reach into res://). It was hand-drawn before and had
drifted a whole redesign behind the piece it was traced from. `tests/run.gd`
holds it to the same drift rule as the pieces. After changing it, regenerate the
splash: `./tools/new_game.sh --regen-splash chess`.

Iterating on this artwork means LOOKING at it. Godot rasterises SVG headless via
`Image.load_svg_from_string`, so a throwaway `SceneTree` script that blits the
twelve files onto a board and saves a PNG is the whole feedback loop — no
rasteriser needs installing, and it renders through the same code path the game
uses. Scale is relative to the file's own intrinsic size (312x356), not to the
viewBox.

## Taskbar icons on the Pi (2026-08-25)

While a game was open the panel showed a generic placeholder instead of the
game's icon. The window-list matches a window back to its launcher by Wayland
app_id, and the generated `.desktop` files carried no `StartupWMClass`.

**Godot sets the app_id to `application/config/name` VERBATIM** — measured, not
assumed: `WAYLAND_DEBUG=1 ./chess` on the Pi prints
`xdg_toplevel#51.set_app_id("Chess")`. Capital letter, and "Memory Match" keeps
its space. `tools/install.sh` now writes `StartupWMClass=$name` (the `name` from
`meta`, NOT the `id`). Verified by screenshot on the Pi.

`WAYLAND_DEBUG=1` is the tool for any question of this shape — it dumps every
protocol request, and no inspection utility (`lswt`, `wlrctl`, `wayland-info`)
is installed on the Pi.

## Framerate on the Pi (2026-08-25)

Maximizing the window dropped every game to 20–27 fps on the Pi 4. All five now
hold a vsync-locked 60. Measured on the shipped arm64 exports, maximized on the
1080p panel, median of the per-second `[qdebug]` samples:

| game | before | after |
|---|---|---|
| chess | 21 | **60** in play, 57–59 on the New-game card |
| memory | 26 | **60** |
| notes | 20 | **60** |
| paint | 21 | **60** at rest and while drawing |
| sequence | 27 | **60** |

**Chess is not actually the heaviest — that was a measurement artefact.** In play
it is a flat 60 fps / 16.7 ms with zero variance across 18 samples. The only
screen that dips is the modal New-game card, which lays a full-screen alpha
dimmer over the whole board; that is a screen you look at for two seconds.

It read as "the heaviest" because it was the only game whose benchmark ran on a
modal dialog — the Pi has no way to inject a click, so the game could not be
measured in play at all. `--bench` (see `BENCH_FLAG` in `games/chess/src/main.gd`)
now deals a game immediately and closes that gap permanently. Use it before
concluding anything about this game's cost.

**Root cause.** Frame time is proportional to the window's PIXEL COUNT and to
essentially nothing else — ~18.9 ms per megapixel through Godot's
`gl_compatibility` 2D path on V3D, established by sweeping the display mode with
`wlr-randr` and watching frame time track it linearly from 0.92 Mpx (16.7 ms) to
2.07 Mpx (39.2 ms). The old 1280x720 window was 0.92 Mpx and comfortably at 60; a
maximized 1920x1053 window is 2.02 Mpx and cannot reach it however little is
drawn. Maximizing is what tripped it.

**Three changes, all needed:**

1. **Full-screen background `ColorRect` → `RenderingServer.set_default_clear_color()`,
   in all five games.** A ColorRect is a canvas item — every frame the GPU
   rasterises and alpha-blends one quad over the whole window. A clear is free on
   a tile-based GPU. One flat-coloured quad cost 9 ms of a 38 ms frame.
   `project.godot` carries `environment/defaults/default_clear_color` so the
   frames before `_ready()` match; `src/main.gd` re-asserts it from the colour
   constant, which stays the source of truth. Chess had the same thing as a
   `draw_rect()` over its whole control; that `_draw()` is gone.
2. **Renderer → Forward Mobile (Vulkan)** on desktop/Pi. Roughly 2x the 2D
   throughput at no image-quality cost. `renderer/rendering_method.mobile` (the
   ANDROID override) stays `gl_compatibility`, so Android is untouched.
   **Safe where Vulkan is absent** — VERIFIED by pointing `VK_DRIVER_FILES` at a
   nonexistent ICD: the game logs "switching to OpenGLES", comes up on the
   Compatibility renderer and keeps running.
3. **`window/stretch/mode="viewport"`**, so the design resolution is what gets
   rasterised and the window is reached by one cheap blit. memory and sequence
   hold 60 at 1280x720; **chess, notes and paint needed their design resolution
   dropped to 1024x576** (exactly 16:9, nothing distorts) to get there. Those
   three now draw their interface ~25% larger relative to the screen and upscale
   1.875x rather than 1.5x. Screenshotted on the Pi: nothing clips, paint's
   toolbar wraps to two rows, which is what its `HFlowContainer` is for.

**The cost is softness, and notes is where it shows** — it is a text editor being
bilinear-upscaled. If crispness matters more there than a locked 60, put
`viewport_width/height` back to 1280x720 (48 fps) or `stretch/mode` back to
`"disabled"` (39 fps). Both measured.

**notes overrides the stretch mode on Android** (`window/stretch/mode.android="disabled"`).
This is not cosmetic: with any stretch mode on, the logical viewport is a fixed
width whatever the screen is, so every width test reads that fixed width and
`_split_allowed()` in `src/main.gd` stops being responsive — which is the reason
stretch was off in that game to begin with. The desktop wants the framerate and a
phone wants the responsiveness, so the two are split rather than traded.

**Ruled out, each by measurement:**
- **The `EGL 12297` error is benign.** The GL path resolves to a real hardware
  `OpenGL ES 3.1 Mesa 25.0.7 — V3D 4.2.14.0` context. Desktop GL 3.3 does not
  exist on V3D, so the GLES fallback is correct, not a degradation.
- **Not the compositor**: `vkcube` at 1900x1000 holds 58 fps vsynced on the same
  output. **Not vsync**: `--disable-vsync`, mailbox and adaptive all measure the
  same, and "FIFO protocol not found" is a red herring. **Not CPU or redraw
  storms**: 15–25% of one core, main thread parked in a GPU fence wait. **Not
  content**: chess draws far more than memory and was only 20% slower.

**Gotchas for anyone measuring this again:**
- **Godot buffers stdout when it is not a TTY, and flushes on exit** — so a game
  you `pkill` prints NOTHING. Run it under `stdbuf -oL`. The readout simply looks
  broken otherwise.
- The stdout readout needs BOTH `QGAMES_DEBUG_HUD=on` and
  `QGAMES_DEBUG_HUD_STDOUT=true` in a release build; `hud_stdout` alone is silent
  because a shipped export starts the HUD off.
- **First run on Vulkan builds a pipeline cache and is not representative** —
  chess and notes produced no samples at all in a 26-second window. Discard it.
- **`pkill -x` is not enough between runs.** Chess ignores SIGTERM long enough to
  outlive the pause and sit on top of the next game, which then renders
  unpresented and reports nonsense (105 fps at 9.6 ms was one such reading).
  SIGKILL and then PROVE nothing survived — and note that
  `pgrep -x chess,memory,notes,paint,sequence` silently matches NOTHING, because
  that is one 31-character pattern, not five names. Loop over the names.
- V3D returns garbage from GPU timer queries, so `--gpu-profile` is useless here.
  The per-pixel cost above is empirical; WHY Godot's GL path is ~9x slower per
  pixel than `vkcube` on the same GPU was never established, and that gap is
  honest rather than closed.
- **Measure chess with `--bench`, not on its opening screen.** Its New-game card
  is a full-screen alpha dimmer over the board and reads 2–3 fps below the game
  itself, with much wider variance (the card fades in on a tween, so short runs
  catch the fade). Benchmarking a modal dialog is what made chess look like the
  slow one for a whole afternoon.

## Chess: what the per-frame trim actually found (2026-08-25)

Asked "why is chess the heaviest, can we trim it", the answer turned out to be
that it is not — see above. It did surface two pieces of genuine per-frame waste,
both now fixed, both worth about 1 fps on the card and nothing at all in play:

- **`_fit_setup()` and `_fit_buttons()` ran on EVERY frame, for ever.** The
  reason they existed is sound — a container's combined minimum size is not
  final until its children have been laid out, so a single deferred call after
  building one reads a stale answer, and the "New game" button really did end up
  half off the bottom edge. Running them for ever was the fix. They now run until
  they SETTLE: each pass reports whether it changed anything, refills the budget
  if it did, and `_relayout()` / `_show_setup()` refill it too. Strictly more
  robust than the single deferred call, because it keeps going until the answer
  stops moving rather than guessing how many frames that takes.
  MEASURED with a temporary switch that disabled both: 59 -> 60 median on the
  card, floor 56 -> 58. Verified by screenshot that the setup card still lays out
  in three columns and the button row still reserves two rows.
- **`_refresh_clocks()` wrote both clock colours unconditionally, every frame.**
  `Label.set_text` early-outs on an identical string, but
  `add_theme_color_override` does not — it fires a theme-changed notification
  that dirties the label and walks its parents. That was 120 notifications a
  second to display a string that changes about once a second. Now guarded on the
  low/normal state actually flipping.

## Paint was unplayable on the Pi — it was the undo snapshot (2026-08-25)

Reported as "so sluggish it was unplayable". It was not the framerate: paint
idles at a locked 60. It was a **116 ms freeze on every stroke release**.

`PaintCanvas.end_stroke()` snapshots the picture for undo, and that snapshot was
`image.save_png_to_buffer()`. PNG is the wrong codec for this: it filters every
row before deflating. MEASURED on the Pi 4, 1280x720 RGBA8 (3.6 MB), on a
scribbled canvas rather than a blank one — a blank canvas flatters every codec:

| codec | encode | decode | size |
|---|---|---|---|
| PNG | **116.0 ms** | 17.3 ms | 62 KB |
| ZSTD | **7.0 ms** | 4.2 ms | 76 KB |
| FastLZ | 8.1 ms | 11.0 ms | 115 KB |

Now `get_data().compress(COMPRESSION_ZSTD)` — 16x faster to write, 4x faster to
read back, 23% larger. The size costs nothing real: `MAX_STEPS` (24) binds long
before `MAX_BYTES` (8 MB) at either size. `save_png()` and `publish_png()` still
write real PNGs; they are file/telemetry paths, not the hot one.

A history entry is now `{data, w, h, raw}` rather than a bare buffer. The
dimensions travel WITH the snapshot because decompression needs the exact byte
count and `resize()` can change it between snapshots — a bare buffer would have
failed to restore after a window resize, silently, and only for someone who had
resized.

### ...and then it was still slow, and that was the UPLOAD SHAPE

Fixing the snapshot was necessary and not sufficient: paint was still 5 fps while
drawing. The picture lives in one Image on the CPU and has to reach the GPU, and
**Godot cannot update part of a texture** — `ImageTexture.update()` always sends
the whole thing. One texture for the whole canvas therefore means re-sending
3.6 MB on every frame of a drag.

MEASURED on the Pi 4, same binary, same synthetic drag, only the upload shape and
the renderer differing:

| upload shape | Vulkan, drawing | Compatibility, drawing |
|---|---|---|
| whole canvas (3.6 MB) | **5 fps**, 190 ms, cpu 107% | 49 fps, 20 ms |
| one texture + a patch | 29 fps, floor 14 | — |
| **tile grid (256 KB)** | **60 fps, floor 58** | — |

The cost scales with BYTES — proved by uploading a fixed 256 KB region instead of
the whole canvas and watching the same drag go from 5 fps to 60. So this was
never really a renderer choice; paint spent an afternoon on `gl_compatibility`
before the actual fix landed, and is back on Vulkan with the others.

**The design, and it is the one Windows XP's Paint used.** GDI kept the picture
in a bitmap, mutated it in place, and then `InvalidateRect` + `BitBlt`ed ONLY the
rectangle that changed — a few hundred pixels for a brush stroke. Same idea here:
the canvas reaches the GPU as a grid of 256px tiles, a dab dirties one or two,
and only those are re-sent. The quantisation to a grid is the concession to
Godot: GDI could blit an arbitrary rectangle into a DC, and `ImageTexture` cannot,
so the dirty rect is rounded out to tiles instead.

**The rejected middle option is worth knowing about**, because it looks cleverer
and is worse: keep one big texture, upload the region changed since the last full
refresh, draw it over the top. It measures 29 fps with a floor of 14, because
that region is a BOUNDING BOX — it grows as the stroke travels, and once it
passes about a third of the canvas a full upload is cheaper again, so every later
frame of a long stroke pays for one. A tile's cost does not depend on how far the
stroke has gone. That is the property worth having.

Two things that follow from tiles and are easy to get wrong:
- **Nothing needs refreshing when a stroke ends.** Every dab already marked the
  tiles it touched and they were uploaded on the frame it happened. An earlier
  version refreshed everything at stroke end and it cost 16 fps off the floor for
  nothing.
- **Tile rects are placed from integer canvas coordinates**, so one tile's right
  edge lands on exactly the float its neighbour starts at and the grid cannot
  seam. Verified by screenshot on a long diagonal stroke crossing many tiles.

**The trap that made this hard to see: `ImageTexture.update()` only QUEUES the
upload.** Timed from GDScript it reads 3.4 ms on BOTH renderers, because the real
work happens on the render thread — which is why the process showed over 100%
CPU. An earlier note in this file wrongly concluded from that number that the
upload "is not felt on its own". If a frame costs 190 ms and the parts you can
time add up to 4 ms, the cost is on another thread; do not go looking for it in
the script.

**What could NOT be taken from XP Paint: it had no frame loop at all.** A GDI
window repaints only when something invalidates it, so idle cost was zero. Godot
renders the main window every frame unconditionally and has no on-demand mode for
it, which is why paint still burns ~45% of a core sitting still. That is a Godot
limitation, not something the game can fix.

NOT a staging-buffer tuning problem: `texture_upload_region_size_px` 64 -> 1024
and `block_size_kb` 256 -> 4096 changed nothing. Tested and reverted.

**`--paintdrag`** drives a drag through the real drawing path so the HUD reports
the framerate WHILE DRAWING. The Pi cannot inject a pointer event, and drawing is
the only expensive thing this game does — measuring it at rest says nothing, and
measuring it at rest is exactly how this went unnoticed for a day.

**Measurement note:** two wrong numbers came out of this investigation before a
right one — "212 ms per drag frame" (the loop drew a 1000-pixel stroke every
frame, which no drag does) and "3.47 ms per upload" (the enqueue, not the work).
Both came from benchmarking something that was not the real path.

## Chess: the capture animation ghosted (2026-08-25)

`_draw()` drew a captured piece with `_pop_rect(square_rect(sq), 1.0)`. At
`t = 1.0` that function's factor works out to exactly `1.0` —
`lerpf(0.55, 1.0, 1.0) + 0.10 * sin(PI)` — so the call was a no-op and the taken
piece sat at FULL SIZE, dissolving on the spot. `CAPTURE_SEC` (0.22) was also
LONGER than `MOVE_SEC` (0.20), so it was still visible underneath the capturing
piece after that piece had landed. Two full-size pieces on one square is what
read as a ghost.

Now `_capture_rect()` collapses it to 0.52 of full size, eased out so most of the
shrink happens in the first third, with `_capture_alpha()` fading as `(1-t)^2` —
faster than linear, because a straight fade leaves the piece at half opacity
exactly when the capturing piece is halfway across it. `CAPTURE_SEC` is 0.16, so
the square is clear before the arriving piece lands.

Verified by rendering the sequence as a filmstrip: a throwaway `SceneTree` script
that rasterises the piece SVGs at the scale and alpha the code computes for a
series of `t`, and blits them onto a square. Animation curves can be LOOKED at
without a display; there is no need to guess at them.

## Home Assistant, rewired for gen2 (2026-08-27)

Home Assistant was still consuming the gen1 suite: sensors for Battleship and
Simon, which gen2 does not have, no sensors for Notes or Chess, which it does,
and nothing at all for the common core (`result` / `score` / `duration_s`) that
was the point of the 2026-08-20 schema. Sixteen qGames entities had been
sitting `unavailable` since at least 2026-08-25.

**The reason nothing was arriving was not Home Assistant.**
`~/.config/qgames/mqtt.env` still read `MQTT_BROKER=192.168.1.4`, the pre-
renumber address of the broker, which now answers on **10.118.20.4**.
`tools/bake_config.sh` reads that file, so every installed build has the dead
address inside its `.pck` — confirmed with `strings` on all five. Games
published into a socket that never connected, and because `QMqttClient` fails
silently by design ("a blank broker means publish nowhere"), a machine pointed
at a *wrong* broker looks exactly like a machine pointed at no broker.

Fixed on this laptop two ways: `mqtt.env` corrected so the next export bakes
the right address, and a `[mqtt] broker="10.118.20.4"` override written into
each installed game's `user://config.cfg`, which wins over the baked value
without a rebuild. VERIFIED: 10.118.20.4:1883 accepts the `qgamestest`
credentials from this laptop. NOT VERIFIED: a real round from a real game —
that needs someone to play one. Watch `qGames/#` on the broker.

**Any other machine running a baked build has the same stale address.** The Pi
is the obvious one; it rejects our SSH key, so it was not checked. `dist/` now
holds corrected arm64 binaries for it — `make deploy` (see the Pi section;
this was done the same day).

### Shipped, and made self-evident (2026-08-27)

Re-baked and re-exported all five games for all four architectures and
installed the x86_64 set on this laptop (694 tests green first). VERIFIED:
`strings` shows 10.118.20.4 in every installed binary, and each one publishes
successfully — see the self-test below. The `user://config.cfg` overrides used
as a stopgap earlier the same day were removed, so the baked value is once
again the single source of truth.

Version strings on this build read `0.1.0+13.g2cf1dd5.dirty` because the tree
carried uncommitted work while it was cut. Commit and re-run `make install` for
a clean one.

**`--telemetry-selftest` (new, in `Telemetry`).** The reason this defect lived
so long is that a WRONG broker and NO broker are indistinguishable from outside
the process: both publish nothing, silently, by design. Every build now answers

    make selftest GAME=memory
    ~/.local/share/qgames/memory/memory --headless -- --telemetry-selftest

which publishes one message to `<prefix>/_selftest/<game_id>` — deliberately
NOT a game topic, so Home Assistant never sees a round that did not happen —
prints the endpoint it tried and the client's own counters, and exits nonzero
if nothing left the machine. It needs no GUI, no round to finish, and no shell
environment, so it works over ssh on the Pi, which is exactly where this will
be needed next. `QMqttClient.endpoint_label()` was added for its log line.

VERIFIED end to end: all five installed binaries report OK, and a subscriber on
the broker saw `qGames/_selftest/memory` and `qGames/_selftest/chess` arrive.

STILL NOT VERIFIED: a real round through `report_result()`. Every link is
proven — QConfig layering, the schema builder's unit tests, and the client's
socket — but nobody has finished a game since the fix. Play one and watch
`qGames/#`.

### The Pi, fixed the same way (2026-08-27)

A painting saved on the Pi at 11:49 published nothing, which is the same defect:
`strings` on all five of its binaries showed the pre-renumber `192.168.1.4`.
The file itself is fine —
`~/.local/share/godot/app_userdata/Paint/paintings/painting_2026-08-27_11-49-36.png`
— it was only the telemetry that went nowhere.

Ruled out first, because it was the more expensive possibility: the Pi is on
TRUSTED (VLAN 25) and the broker is on SERVICES (VLAN 20), so a firewall rule
would have looked identical from the game's side. It is not blocked —
`10.118.20.4:1883` opens from the Pi. VERIFIED.

Redeployed with `tools/deploy.sh q@10.118.25.17`; all five arm64 binaries now
report `[selftest] OK` against `10.118.20.4:1883`. VERIFIED, each game.

**Gen1 on the Pi is deliberately left pointing at the dead broker.**
`~/.config/qgames/mqtt.env` there still reads `192.168.1.4` (and a different
broker user, `qgames`). Correcting it would be one line, and it is the wrong
move: gen1 publishes the OLD topic shape to the SAME namespace, so a gen1
memory round would update `qGames/memory/result` and `ts` while leaving the new
`score` sensor showing the previous game — a half-updated reading is worse than
a silent one. Gen1's Battleship and Simon also no longer have Home Assistant
sensors. The gen1 `.desktop` entries (`battleship`, `letters`, `memory`,
`paint`, `sequence`, `simon`) are still in the applications menu though off the
taskbar; deleting them is the real fix, and is the owner's call.

### What is on the HA side now

`/config/mqtt.yaml` was a 180-line list mixing backup drives, a UPS and five
games. It is now two `!include_dir_merge_list` lines over `mqtt_sensors/` and
`mqtt_cameras/`. That split is what makes YAML anchors usable — they are
file-local, so nothing could be shared while every MQTT sensor in the house
lived in one file.

`homeassistant/` in this repo holds the four files that are actually running,
copied back out of `/config`. See its README for the per-file detail and for
the gotchas (`ha core check` does not validate MQTT entity schema;
`has_entity_name` is rejected there; `isoformat` is a method, not a filter).

32 sensors and one camera, five devices, one per game. Every entity that could
keep a gen1 `unique_id` kept it — that is the identity HA keys history and
dashboard references on, and inventing new ones is part of how gen1 accumulated
dead entities. `sensor.qgames_memory_moves` now reads `qGames/memory/score`
rather than `qGames/memory/moves`; the values are identical by definition and
the history is continuous. **Nothing consumes the legacy `moves` topic any
more.**

Deleted from the entity registry: three Battleship, two Simon, and three
orphans with no config behind them. **Assumption worth knowing:** this is only
safe because gen1 is not publishing. Nothing has been on those topics for at
least two days and the suite is out of this repo, but the Pi could not be
checked. If Battleship or Simon is still alive there, its sensors need
recreating.

The Games dashboard moved out of `.storage` into `dashboards/games.yaml`,
registered from `packages/qgames.yaml` the same way the Network dashboard is
registered from `packages/observability.yaml` — YAML so it diffs and restores.
One section per game, all the same shape, because the common schema means a
section is boilerplate and only the extras differ.

### Defects this turned up, still open

- **`paint` publishes `duration_s` hard-coded to 0** (`games/paint/src/main.gd`).
  A drawing pad has no round to time, but publishing a lie is worse than
  publishing nothing — either send the time since the previous save, as `notes`
  does, or drop the key. There is deliberately no Duration entity for paint.
- **`chess` can report `result: draw`**, which is not one of the four values in
  `QTelemetrySchema.RESULTS` and was not in any documentation. Either add it to
  the schema or map it. Anything matching on `result` has to allow it today.
- **`memory` publishes `score` and `moves` with the same number.** Harmless,
  but the game-specific topic now has no consumer.
- **`score_unit` has no consumer.** Every game publishes it; nothing reads it,
  because each sensor's unit is set statically. It stays on the wire for
  automations.


## The Pi's dock (qdock) (2026-11-18)

Source `pi/qdock/` (C, GTK3 + gtk-layer-shell + wlr-foreign-toplevel-management; protocol XML vendored from
wlr-protocols). Built for arm64 in Docker (`pi/qdock/Dockerfile`, Debian trixie = the Pi's OS): `make -C pi/qdock`;
`make -C pi/qdock install` copies it to `qpi:~/.local/bin/qdock`, writes `~/.config/qdock/pinned` the first time only,
and kills the running one (lwrespawn restarts it within 1 s). Started from `~/.config/labwc/autostart`:
`/usr/bin/lwrespawn /home/q/.local/bin/qdock &`. One per session (flock on `$XDG_RUNTIME_DIR/qdock.lock`).

Behaviour (user asked for GNOME/macOS style, one window per app type to save RAM/GPU): pinned icons from
`~/.config/qdock/pinned` (.desktop ids). Not running → click starts it (icon greys while starting; further clicks are
ignored until a window appears or 40 s pass — never a second copy). Running → short bar under the icon; focused →
shaded with a blue bar. Click a running app → focus (unminimizes); click the focused one → minimize; several windows →
cycle. Right-click → Close. Unpinned apps get an icon while they run. VERIFIED on the Pi with a wlrctl virtual pointer:
focus/minimize/restore of Paper Map and Chess, three quick clicks on Notes → one process, right-click Close.
Idle cost: ≈0.13 % CPU, 32 MB RSS.

Matching windows to icons: by Wayland app_id against the .desktop StartupWMClass / id / Exec basename / Name
(case-insensitive), then by window title. The title fallback exists because exported Godot games report a generic
app_id (`Godot_Engine` under Xwayland, `org.godotengine.Godot` natively; chess showed `Chess` once) — so **game window
titles must equal their .desktop Name** (Chess, Memory Match, Notes, Paint, Sequence). Paper Map's Chromium window is
`chrome-10.118.20.5__-Default` (its .desktop carries that; rafterw-paper-map deploy/qpi). `QDOCK_DEBUG=1` prints
every window's app_id and title.

It sits over the left end of wf-panel-pi (top layer, exclusive zone -1, 52 px, background #deddda = the panel's
colour); a respawned panel would cover it, so it re-maps itself when wf-panel-pi's pid changes. If the panel's
height or theme changes, adjust PANEL_HEIGHT / QDOCK_BG. `make deploy` still rewrites `qgames-*.desktop` — harmless,
the dock reads them as they are.

Measured with Paper Map + all five games open, memory focused, idle (2026-11-18, after the idle-rendering work below):
V3D render 0 % (was 71 % before it), 2.4 GB RAM used of 7.8.

## Idle and background rendering (2026-11-18)

**Problem.** Every game rendered 60 full frames a second for as long as it was
open, whether it was idle, focused or not. On V3D a frame costs ~12 ms of GPU
whatever is in it (see "Framerate on the Pi"), so one idle focused game held the
render queue ~80% busy and ~45-65% of a core.

**What changed.** All of it is shared code, except where a game had its own idle
animation:

1. **On-demand rendering.** `application/run/low_processor_mode=true` in all
   five `project.godot`. The engine draws only when something on screen changed
   (`RenderingServer.has_changed()`: queue_redraw, tweens, property changes).
   Anything that animates still runs at full rate. QGameRoot re-applies it from
   `QConfig render/on_demand` (default true). **Benchmark framerate with
   `QGAMES_RENDER_ON_DEMAND=false`**: with on-demand on, the engine's FPS
   monitor counts loop iterations, not frames. QDebug now shows `drawn N/s`
   beside fps for that reason (`QDebugStats.drawn_fps`).
2. **Background cap.** `QGameRoot` sets `Engine.max_fps` to
   `render/background_fps` (default 10) on `NOTIFICATION_APPLICATION_FOCUS_OUT`
   and restores the project's own value on FOCUS_IN. The decision is pure and
   tested: `shared/qcore/power_policy.gd` (`QPowerPolicy.decide`), tests in
   `games/memory/tests/run.gd`. 10 rather than lower because it is also the
   worst-case delay before a background game notices it was clicked.
3. **The silent games use the Dummy audio driver.** `[audio]
   driver/driver="Dummy"` in memory, notes, paint and sequence. The PulseAudio
   driver mixes silence on its own thread for as long as the game is open: ~8%
   of a core per game on the Pi, measured per thread. Chess has sound and keeps
   PulseAudio, which is why it idles a few percent above the others.
4. **Per-game idle animations.**
   - sequence: the question cell and the progress strip breathe at 20 Hz. Each
     kept a private accumulator, and they drift out of phase because each stops
     while its own animation is hidden. Under on-demand rendering that means up
     to 40 frames a second instead of 20. They now share one wall-clock tick,
     latched once per process frame, and both pause on application focus-out.
   - notes: the editor caret stops blinking and hides on application focus-out,
     as in any desktop editor, and comes back solid on focus-in.

**Measured** on the Pi 4 (labwc, 1080p, display forced on with `wlopm --on`,
Paper Map open underneath). Games launched with `DISPLAY=:0` as the taskbar
does, so they run under **Xwayland**. 15 s settle, then a 10 s window. GPU =
Δruntime/Δwall of the `render` queue in `/sys/class/drm/card0/device/gpu_stats`.
CPU = Δ(utime+stime) from `/proc/<pid>/stat`. Old = the build installed
2026-08-27, new = this change. Old and new were measured back to back.

| condition | render busy old → new | game CPU old → new | RSS |
|---|---|---|---|
| map only | 5.6% → 2.8% | — | — |
| chess alone, idle (New-game card) | 86.6% → 0.4% | 48.0% → 16.6% | 178 MB |
| memory alone, idle | 78.5% → 0.4% | 44.3% → 11.6% | 170 → 169 MB |
| notes alone, idle | 85.8% → 3.6% | 44.5% → 14.9% | 182 → 180 MB |
| paint alone, idle | 82.3% → 0.4% | 49.5% → 11.6% | 177 → 175 MB |
| sequence alone, idle | 77.9% → 25.5% | 67.1% → 42.5% | 174 → 172 MB |
| all five, memory focused | 81.9% → 0.3% | focused 45.5 → 9.9; each background 8-10 → 4-7 | |
| all five, sequence focused | 81.6% → 26.7% | focused 74.0 → 46.1; each background 9-10 → 4.5-8 | |

The 10 s windows have noise of a few percent. Notes' 3.6% is its caret blinking,
2 frames a second. RSS did not change: on-demand rendering frees no memory.

**Under Xwayland, the BACKGROUND games were already cheap before this.** With
five open, the covered ones measured 8-10% CPU each and added nearly nothing to
the GPU. That suggests Xwayland stops completing their presents while they are
covered (inferred, not traced). The big win is the FOCUSED idle game, which
always drew 60 frames a second.

**Where the rest goes, for anyone continuing.**
- **sequence, focused:** 20 frames/s of breathing costs ~25% GPU and ~30% of a
  core. Every frame re-renders the whole viewport, and Godot's 2D renderer does
  not redraw only the damaged part. `PULSE_HZ` is the knob: 10 would roughly
  halve this. It was left at 20 because that changes how the game looks.
- **A focused idle game's ~11% CPU** is the 145 Hz idle loop plus the Xwayland
  event and audio threads. `low_processor_mode_sleep_usec=16666` measured
  memory at 11.7% → 7.9%. It was NOT adopted: a 60 Hz sleep cadence beats
  against 60 Hz vsync during animation (a judder risk), and it adds up to
  10 ms of input latency. Test it with an `override.cfg` next to the binary,
  `[application] run/low_processor_mode_sleep_usec=16666`. That file is how the
  variants here were tried without rebuilding.
- **Native Wayland** (`display/display_server/driver.linuxbsd="wayland"`, or
  launch with no `DISPLAY`) was measured and NOT adopted:

  | | Xwayland | native Wayland |
  |---|---|---|
  | memory focused idle: game / labwc / Xwayland CPU | 11.7 / 0.2 / 2.7 | 3.6 / 4.0 / 0 |
  | sequence focused: render busy | 26.3% | 33.6% |
  | sequence focused: game / labwc / Xwayland CPU | 43.7 / 3.0 / 2.8 | 34.7 / 5.6 / 0 |
  | all five, background games each | 4-8% | ~1.2% |

  So Wayland is cheaper on CPU, but costs more GPU while animating. Godot's
  Wayland backend also commits the surface on every idle iteration under
  low-processor mode (`DisplayServerWayland::process_events`), which is
  probably labwc's 4% (inferred from the source, not traced). It also changes
  the app_id from `Godot_Engine` (Xwayland) to `org.godotengine.Godot`; titles
  are unchanged. Paint's cursor hiding, notes' IME and clipboard, and input in
  general are untested there. It renders correctly: maximized, decorated, same window title
  (screenshot). Revisit it if the CPU matters more than the GPU.

**Verified on the Pi:** every number above; the background cap engages (memory's
HUD reads 145 → 10 loop/s when another game takes focus); the paint drag bench
(`--paintdrag`) holds 60 drawn/s at 16.6 ms under on-demand, the same as
before; sequence played by keyboard through XTEST: input lands, transitions
draw at ~60/s and then fall back to the 20/s breath; screenshots of sequence
and paint look as before. `make test-all` passes. **Not verified:** chess piece
slides and memory card flips were not driven, because there was no input
injection for mouse. They use the same tween and queue_redraw paths that were
exercised.

**Deployed 2026-11-18** to `qpi`, all five. The binaries were swapped in place
under `~/.local/share/qgames/<id>/` (atomic `mv`). `make deploy` was NOT used,
because its `install.sh` rewrites `~/.local/share/applications/qgames-*.desktop`,
and that directory was off-limits while the new dock was being built. The
installed builds measure the same as the table above. `--telemetry-selftest`
passes from the installed memory and chess (broker 10.118.20.4:1883).

**Window title is unchanged** and must stay equal to the .desktop Name. The new
dock identifies games by title.

## Chess: Cburnett piece set and Training mode (2026-11-18)

**Pieces.** The owner asked for a free classic set, with a cross on the king and
a real crown on the queen. Shipped: Colin M.L. Burnett's set from Wikimedia
Commons (`Chess_{k,q,r,b,n,p}{l,d}t45.svg`). It is the one Wikipedia and lichess
use. Wikimedia offers it under four licences, and we use the **3-clause BSD**
option (VERIFIED on the Commons file page). The repo is public with no licence of
its own, so a GPL-only or NC set (most of lichess's sets) was the wrong fit.
- Files: `games/chess/assets/pieces/*.svg`, each with an attribution comment.
  Full text is in `assets/pieces/LICENSE.txt`, which every export preset now
  carries via `include_filter`, so binaries meet BSD clause 2.
- **Bishops are modified at the owner's request:** the cross on the mitre is
  replaced by the classic diagonal slit, a narrow filled wedge from the upper
  right. Black on the white bishop, white on the black one.
- Merida (GPLv2+) was the alternative compared.
- The files carry no `GENERATED_MARK`, so the drift test treats them as
  hand-made and leaves them alone.
- ⚠ **`make chess-pieces-repo` would overwrite them with the drawn set** from
  `src/pieces.gd`. Don't run it unless replacing this set is the point.
- `icon.svg` is still the drawn knight; it was not changed.
- Godot rasterises these files correctly. VERIFIED: a sheet rendered via
  `Image.load_svg_from_string`, plus interactive screenshots.

Small fix found on the way: SVG pieces ignored the capture fade's alpha, because
`draw_texture_rect` had no modulate. Now `piece_art.gd` passes the fill's alpha.

**Training mode.** A "Training" button in the panel opens a card with a master
switch and one switch per aid. Aids keep their own setting while the master is
off.
- Prefs: `chess/training` (default off) and `chess/training_danger` (default on).
- The button reads "Training: on" while the master switch is on.

The first aid is **danger squares**. **Redefined the same day by the owner:**
not just "your pieces that can be taken" but EVERY square where the computer
could take a piece of yours, i.e. its take squares. That includes empty squares
and its own protected pieces, since taking one gets you taken back.
- `ChessBoard.danger_squares(victim)`, for each square: a cheap `is_attacked`
  prefilter, then a stand-in `victim` pawn is placed on the square and the
  opponent's captures onto it are tested for legality. So a pinned attacker
  doesn't count, and a king can't "take" a protected square. `capturable()` is
  merged in for en passant.
- Cost on the desktop is 0.9–1.6 ms per call (start position, a middlegame,
  kiwipete). On the Pi 4 it is inferred at about 10–20 ms, once per position
  change; selecting a piece recomputes only the hang dots. Not measured on the
  Pi.
- **Superseded first version:** the human's pieces that the opponent can LEGALLY
  take are washed red. Alpha is
  0.34 on light squares and 0.50 on dark, because red over the green mixes to
  olive at 0.34 (swatch-checked).
- When a piece is selected, any destination where it could be taken straight
  back shows a red dot instead of grey.
- It covers the human's pieces only. Shading the computer's hanging pieces
  would be playing for the child.
- The model functions are `ChessBoard.capturable(victim)` and `move_hangs(m)` in
  `board.gd`. They are legal rather than attacked, so a pinned attacker doesn't
  count, en passant does, and kings are excluded (check has its own glow).
- They are recomputed on `show_position` and `select` only, never per frame.
- Tests: `tests/run.gd` `_test_danger_squares` covers pinned, en passant, both
  turns, no mutation and move_hangs. `tests/interactive.gd` drives the card and
  checks a light and a dark danger square plus the hang dot. Results: 217
  headless pass, interactive all pass (2026-11-18).
**Second aid, attack squares (2026-11-18):** the same question asked the other
way round, `danger_squares(-human)`, shaded blue.
- Its switch is `chess/training_attack` (default on).
- Alpha is 0.38 on light squares and 0.56 on dark (blue over green reads teal
  below that; swatch-checked).
- A square that is both red and blue is split on the diagonal, red top-left and
  blue bottom-right. Stacking the two washes gives an unreadable purple.
- Own protected pieces count as attack squares, mirroring the danger rule.
- The owner's note: both maps are deliberately noisy for now, and they plan to
  "logically trim the noise later".
- The training card does not scroll. It fits at 1280x720 at reading size 1.0.
  Unverified at larger reading sizes.

**Point at a piece (2026-11-18).** The owner's goal: "help a student learn which
squares are safe and which are not". Pointing at a piece narrows the maps to
that ONE piece: a computer piece shows its take squares in red, one of the
player's shows its take squares in blue.
- "Pointing" means any of three things: mouse hover; the keyboard cursor; or the
  last piece tapped, of either colour, since touch has no hover (house rule 5).
  The board view tracks it in `_inspect` and updates it via `set_inspect`.
- It works on a read-only board too, e.g. when reviewing a finished game.
- The third switch, "Only the piece I point at" (`chess/training_hover_only`,
  default on), decides what shows when nothing is pointed at: on shows nothing,
  off shows the whole-board maps.
- Model: `danger_squares(victim, from_sq)` and `capturable(victim, from_sq)`;
  `pseudo_moves(captures_only, only_from)` generates moves for one piece only.
- The maps are recomputed only when the pointed-at square changes.
- The training card now scrolls, the same way as the setup card
  (`_fit_training`).
- Interactive test stages 06c/06d move a real mouse over d5 (the computer's)
  and g5 (the player's) and check both sets. Results: 228 headless pass,
  interactive all pass.

**Danger badges and take chains (2026-11-18).** The fourth switch is "Take
chains" (`chess/training_chains`, default on).
- **Badge:** a "!" in the top-right corner of each of the player's pieces that
  the computer can take without losing on the exchange. Red when the taker
  wins material, amber for an even trade. A protected piece the taker would
  lose on gets no badge. Badges show all the time; they do not need pointing.
- **Chain:** pointing at any piece that can be taken shows its capture
  sequence: an arrow from each taker, a numbered disc on the taker for the
  order, red for the computer and blue for the player. Steps past where a
  sensible player stops are faded (alpha 0.28). A pill on the square gives the
  verdict: "lose N", "win N", "even trade", "safe" or "protected". The panel
  shows the same thing in a sentence, in the `_explain` label under the status
  (the status line is rewritten every frame while the computer thinks).
- **Model:** `ChessBoard.take_chain(sq)` plays the exchange out with make/unmake,
  each side taking with its least valuable LEGAL capturer. Pins, kings and
  x-rays come out right without special cases. A promotion counts as a queen
  only. The worth is computed by backward induction with stand-pat:
  `v[d] = gain[d] - max(0, v[d+1])`, and `played` is the first d with `v[d] < 0`.
  Values are P1 N3 B3 R5 Q9 (`TRADE_VALUE`). `pieces_in_danger(owner)` returns
  the pieces where the taker's worth >= 0.
- **Text:** `ChessBoardView.explain_chain()` is static, so it is unit-tested.
- **Tests:** `_test_take_chains` covers a hanging piece, an even trade, a
  protected piece, an x-ray queen, a pinned recapturer and a king target.
  Interactive stage 06e checks the badges on both knights, the chain on e4 and
  the panel sentence. Results: 243 headless pass, interactive all pass.
- **Cost on the desktop:** `pieces_in_danger` takes 0.05–0.77 ms and
  `take_chain` 0.15 ms or less. The Pi is not measured.
- **Training card:** the aids now sit two to a row when the window is at least
  860 px wide (logical). Four in one column put Done below the fold at
  1280x720. When the card scrolls, the scrollbar gets its own width.

- **The dev laptop is the owner's play/test machine for chess (2026-11-18).**
  Every chess change also gets an x86_64 export, installed to
  `~/.local/share/qgames/chess/chess` with an atomic `mv`. The app menu's
  `qgames-chess.desktop` runs that path. The Pi is updated only on request.
- **The take-squares version is installed only on the desktop**
  (`~/.local/share/qgames/chess`). The Pi still has the first version.
- `tests/interactive.gd` now saves and restores the player's training prefs. It
  writes the real `user://config.cfg`, and an earlier version of it switched
  the owner's training setting off.
- **Deployed to `qpi` 2026-11-18 16:15** using the same in-place swap as the
  earlier deploy (arm64 export, scp, atomic `mv`; sha256 matches the local
  build). The installed binary reports `pieces from res://assets/pieces (12 of
  12)`, and `--telemetry-selftest` is OK.
- Not yet measured on the Pi: the cost of `capturable` per move (one legal-move
  generation, flip side; `move_hangs` per target when selecting). Inferred
  cheap, under about 30 ms.

**Knight arrows bend (2026-11-19).**
- Any arrow between squares a knight's jump apart, hint or take chain, is drawn as the classic L: the long leg
  first, then the short leg into the target (`_arrow_points`, `_draw_arrow_path` in `board_view.gd`).
- The bent shaft is one mitred polygon, not two lines, so a faded (translucent) step has no darker patch at the
  bend. Polygons are not antialiased, unlike the straight shafts' `draw_line(..., true)`.
- VERIFIED by screenshot `06e_take_chain` (Ng5 to e4 bends at e5). The hint arrow uses the same path, but no
  screenshot shows a knight hint.
- The verdict pill sits above the target, so it can overlap the short leg's bend.

**Why check (2026-11-19).** A fifth training aid, "Why check", pref `chess/training_checks`, default true. It
covers either side's check: the one the player gets and the one the player gives.
- **Model.**
  - `ChessBoard.checkers()` returns the checking pieces. Each has its `line`: the squares between it and the king,
    listed from the checker's end. The line is empty for a pawn, a knight, or a piece standing next to the king.
  - `check_info()` sorts every legal move into `king_moves`, `blocks` and `takers`. Reading from the legal moves
    means pins, and en passant of a checking pawn, come out right.
  - `ChessBoardView.explain_check()` puts it into words: who attacks the king and how, then the ways out. A
    knight's check also says it cannot be blocked. Double check says only the king can move.
- **Board.** Over the pieces, an arrow from each checker to the king (an L for a knight), after the move's slide
  lands. The king's pulsing glow says "check".
- **Panel.** The board's signal is now `explained` (was `chain_explained`). It carries the check text, then the
  pointed-at piece's take chain.
- **Hold.** When the player gives check, the computer waits `CHECK_HOLD_MS` (3000 ms) on top of its thinking floor
  (`ChessOpponent.think(..., hold_ms)`), or the picture would be gone within half a second. Its clock runs
  meanwhile. During that wait the status reads "You have given check", not "Thinking...".
- **Training card.** It has five aids, and the descriptions were cut to two lines each so the card fits 1280x720 with Done visible and no scrollbar (screenshot `06a_training_card`).
- **Ways out on the board (2026-11-19, reworked the same day), in green, for either side's check:**
  - At rest, only the pieces: a soft green disc under each piece with a legal move (in check every legal move
    is a way out), a green ring round the king if it can step. `_answers` maps from-square to targets.
  - Pointing at one (hover, tap or keyboard cursor, i.e. `_inspect`) shows its ways out: arrows to its block or
    take squares, dots (rings for a take) for the king. Not for the selected piece: its move dots already are
    exactly those squares.
  - Rejected: every block square boxed, every king step dotted and every taker arrowed at once. The owner found
    it noisy and could not tell which piece a green box was for.
  - While the check aid is up, the danger/attack washes, take chains and "!" badges go quiet.
- **Checkmate as a trap (2026-11-19).**
  - `ChessBoard.king_trap()` takes each square round the mated king and records whether its own piece is in the
    way, and which enemy pieces cover it. It asks with the king lifted off the board, so the square behind the king
    on the checker's line counts as covered. `attackers(sq, by)` is `is_attacked()`, collecting instead of stopping.
  - On the board: a red X on each covered square, an amber box on each square the king's own piece fills, and a
    thin ring on each enemy piece that helps the checker. An attacking piece next to the king gets no mark: an X
    (then a corner X badge) on the winner's own piece read as "this piece is wrong" (owner, 2026-11-19). The ring
    on its protector carries the "why can't the king take it".
  - In the panel: "Checkmate! ... It is a trap: their rook on a8 covers f8 and h8, your own pawns fill f7, g7 and
    h7, and nothing can block the rook or take it."
  - The trap shows on every checkmate, with the aid on or off.
- **Checkmate show (2026-11-19).**
  - On mate `_on_game_over` calls `ChessBoardView.celebrate_mate(won)`, and the end card waits for the `mate_done`
    signal (`_mate_pending`).
  - Timeline from when the mating move lands: the trap at once. At `MATE_TOPPLE_AT` 1.4 s the mated king tips
    over (78°, away from the checker), the result sound plays, and a "Checkmate!" banner pops on the half of the
    board away from the king ("You won!" in green, "The computer won" in red). For a win, about 160 confetti
    pieces also burst from the mating piece and both top corners.
  - The end card comes at `MATE_DWELL` 6 s, or on a tap or `ui_accept` after `MATE_SKIP_AFTER` 0.8 s.
  - The toppled king stays down under the card and in "Look at the game"; `show_position()` resets it.
  - Other endings (resign, flag, draw) still show the card at once.
- **Noise pass (2026-11-19), gallery-reviewed over 16 positions (`tests/gallery_checks.gd`).** Removed:
  - the red wash on the line of attack (it repeated the arrow, read brown on dark squares, and fought the green
    block boxes on the same squares);
  - the box round the checker (the arrow's tail already points at it, on top of the last-move highlight);
  - the "check"/"double check"/"checkmate" pill (it covered the piece above the king, and the glow, the panel and
    the mate banner say it);
  - the guard lines to each X in the trap (on ladder and queen mates they crossed the king and each other; the
    panel names who covers what);
  - the "!" danger badges while the check aid is up;
  - the "Check! " lead of the explanation (the status line above says it; "Double check!" and "Checkmate!" stay);
  - the mated king's glow, which now fades out as it topples.
- **Demo mode (2026-11-20): `chess -- --demo`.** `src/demo.gd` (`ChessDemo`) plays a fixed line through the real
  view, looping: 1.e4 e5 2.d4 Bb4+ (the player is in check: glows, then the c2 pawn "pointed at", then 3.c3)
  ... 5.Qh5 Nf6 6.Qxf7# (trap, topple, confetti, end card). White's side, every aid on, in memory only:
  `_save_prefs()` and `_publish()` are no-ops while `_demo` is set, and the computer never thinks.
  `demo.gd` holds main untyped: naming `ChessView` makes it depend on main.gd, which needs the autoloads that a
  `--script` tool lacks. `tests/demo_shots.gd` runs it here with timed screenshots. On the Pi:
  `ssh qpi 'XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 setsid nohup ~/.local/share/qgames/chess/chess -- --demo >/tmp/chess-demo.log 2>&1 </dev/null &'`
  (the ssh hangs on exit; the game survives it). "X11 Display is not available" in its log is the harmless
  X11-first probe before Wayland.
  - A demo holds the screen awake (`DisplayServer.screen_set_keep_on(true)`, demo only): nobody touches it, so
    the Pi's 5-minute swayidle blank turned it off within minutes of the first run.
  - Wake the Pi's screen remotely: `ssh qpi 'XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 wlopm --on "*"'`;
    `wlopm` alone prints the state.
  - Do not `pkill -f "chess -- --demo"` inside `ssh qpi '...'`: the pattern matches that ssh's own bash command
    line and kills it. Use `pgrep -f "^/home/q/.local/share/qgames/chess/chess -- --demo"` or the pid.
- **Test gotcha:** `_clear_overlay()` uses `queue_free`, so a just-closed card's veil still swallows clicks parsed
  in the same frame. Start the new game in one stage and play in the next.
- **Tests.** `tests/run.gd` `_test_check_why`: back-rank, smothered and protected-checker mates (270 pass). Interactive mate stages: `mate_trap`, `mate_party`, `mate_card` (card only after the dwell) and `mate_skip` (a tap brings the card); shots `06h`-`06j`. `tests/interactive.gd` stages `check_shown` (Ra1-a8+
  played through the board; the computer's reply is still pending after 1.2 s), `check_answered` and
  `check_received`; screenshots `06f_check_given` and `06g_check_received`. All pass.

## Pi screen never turned off: Godot's idle inhibitor (2026-11-19)

**Symptom.** The Pi's screen stayed on past the 5-minute blank.

**Not the cause.** The blank itself is fine. `~/.config/labwc/autostart` runs
`swayidle -w timeout 300 'wlopm --off \*' resume 'wlopm --on \*'`, and it was running (VERIFIED, ps).

**Cause, VERIFIED.**
- Godot's `display/window/energy_saving/keep_screen_on` defaults to true. On native Wayland, which is how the games
  run on the Pi (no `DISPLAY` in their environ), that sends `zwp_idle_inhibit_manager_v1.create_inhibitor` on the
  main surface. Seen with `WAYLAND_DEBUG=1` on the Pi.
- labwc 0.9.2 sets the session inhibited while any inhibitor exists, whatever the surface's visibility
  (`src/idle.c`, `handle_idle_inhibitor_new` / `_destroy`).
- So one open game, even minimised, holds the screen on forever. A probe on the Pi
  (`swayidle timeout 5 'echo IDLE'` for 15 s, with notes and paint open) never fired.

**Fix.** `window/energy_saving/keep_screen_on=false` in all five `project.godot` files. That includes memory's,
which `tools/new_game.sh` copies for new games. Checked on the laptop under GNOME Wayland: the old chess build sends
1 `create_inhibitor`; the new build sends none.

**Pending.**
- Deployed to the Pi 2026-11-19 (`0.1.0+21.gbd544c6.dirty`). On the Pi the new chess binary sends 0
  `create_inhibitor` (VERIFIED, `WAYLAND_DEBUG`). Notes and Paint processes started before the deploy were still
  open; they keep their inhibitors until they exit.
- Confirmed 2026-11-19 after the owner closed the games: the probe (`swayidle timeout 5`) fired in 5 s. That means
  the idle notifier is no longer inhibited. The real 300 s `wlopm --off` was not watched; inferred to work, since it
  uses the same notifier.
- Paper Map was also closed for that probe, so whether its chromium inhibits is still unchecked.
- The old Notes process (pid 15486, exe `(deleted)`) was still alive after the owner closed it. Idle fired anyway,
  so its surface, and with it the inhibitor, is gone. Why the process outlived its window was not investigated.

## Open threads

- **Friends play from a git clone (2026-11-18).** The repo is public (github.com/collier-watkins/qGames, checked
  via the API). README "Play them at home": install Godot 4.7.2, clone, Import + ▶ or `make run GAME=<g>`.
  VERIFIED on a fresh clone: `make run` used to fail with parse errors (no `.godot` → no class_name registry), so
  `run` now imports first like `test`; `--rendering-driver opengl3` and `--rendering-method gl_compatibility` both
  start Compatibility mode. Windows needs Developer Mode + `core.symlinks=true` (`addons/qcore` is a symlink) —
  inferred, not tried on Windows. Not yet: packaged builds for Windows/macOS (templates for both are installed;
  `dist` bakes the broker password — friends' builds need `bake_config.sh --no-secrets`). No LICENSE file.
- **Android is the last unanswered spike question.** Needs JDK 17 and the
  Android SDK before an export preset can even be written. Everything else the
  spike set out to test has held across three games.
- **MQTT is ON by default for every game** (owner's call, 2026-08-21). Two
  switches now exist because they mean different things: `telemetry/enabled` is
  "this game should not report", `mqtt/enabled` is "this machine should not talk
  to a broker". Both default to true. Nothing is baked into the repo — with no
  broker named the games discard telemetry silently, exactly as before, so the
  default is safe rather than surprising.

  The broker and credentials come from the environment. Both spellings work:
  `MQTT_BROKER`, `MQTT_PORT`, `MQTT_USERNAME`, `MQTT_PASSWORD`,
  `MQTT_TOPIC_PREFIX`, or the same names with a `QGAMES_` prefix, which win.
  The bare names exist so one exported environment covers every game.
  `user://config.cfg` still works and still overrides the environment's bare
  names. Credentials are never in this repository.

  **The queue is now bounded, which it had to be before this default flipped.**
  `poll()` returns early with no broker configured, so anything queued would
  never leave — an unconfigured machine would have grown that queue for the life
  of the process, and note bodies would have made it fast. Messages are now
  discarded at `enqueue()` when no broker is set, and a configured-but-backed-up
  queue is cleared entirely past 256 messages rather than trimmed: dropping the
  oldest few would eventually publish some of a round's values with a `ts`
  claiming they are current, and a subscriber cannot tell that from the truth.
  A `dropped` counter feeds the debug HUD, because "telemetry is broken" and
  "telemetry has nowhere to go" are different problems.

- **Notes publishes the note itself** (2026-08-21). On save, the Markdown source
  goes to `qGames/notes/content` RETAINED, before the round's scalars, with
  `title` and `filename` alongside and `ts` still last. Retained because the
  point of putting a document on a broker is that a dashboard restarting an hour
  later still has it — a reading is a fact about a moment and would be stale,
  but the note is the current note until it changes. Bodies over 128 KB are
  truncated with a warning rather than handed to a broker that may drop the
  connection and take the round's scalars with it.

  A Home Assistant sensor STATE is capped at 255 characters, so `mqtt.yaml`
  truncates it deliberately and documents that the full Markdown is on the topic
  for Markdown cards and templates.

  VERIFIED end to end against a real `eclipse-mosquitto:2` in Docker with
  anonymous access refused and a password file: all three games authenticated
  (CONNECT flags `0xc2` — username, password, clean session) and published; the
  note arrived byte-exact including multi-byte characters; `ts` landed last; and
  a fresh subscriber replayed ONLY `qGames/notes/content` with `retain=1`,
  proving the broker stored the body and nothing else.

- **`make test` now imports on a fresh checkout** (2026-08-21). `games/<g>/.godot`
  is generated and correctly gitignored, so a clone has no global class
  registry — every `class_name` fails to resolve and the whole suite dies with
  "Parse error" that says nothing about the real cause. Found by cloning the
  repo and running the suite from the clone, which is the only way this shows
  up; the working copy always has the cache. CI was already unaffected (it runs
  `make import` per game first).

- **Retained bodies are truncated on a character boundary** (2026-08-21). A byte
  limit knows nothing about characters: cutting a 4-byte emoji after two bytes
  publishes an incomplete sequence, which decodes to a replacement character and
  logs a warning on the way out. `QTelemetrySchema.utf8_boundary()` walks back
  off continuation bytes (10xxxxxx) to a character start. It lives in
  telemetry_schema.gd rather than telemetry.gd for the usual reason — telemetry.gd
  names the QConfig autoload and therefore cannot be preloaded under `--script`,
  so a pure function that needs testing has to live somewhere testable. The
  first version indexed one past the end when nothing needed cutting; its own
  test caught that.

- **Chess: the external engine path has never run.** No Stockfish is installed
  on this box, so `src/uci.gd` is written, compiled and unexercised. Turning it
  on is `chess/external_engine=true` plus a binary on PATH or beside the game;
  `chess/engine_path` names one explicitly. If it is ever used in anger, the
  first thing to check is that a dead engine cannot hang the worker thread —
  the read loop is bounded, but the bound has never been hit.
- **Chess strength is estimated, not measured.** "Roughly club strength" comes
  from depth and node rate, not from a match against rated opposition. Nobody
  has played the nine levels against anything that could put a number on them,
  and the noise values that separate them were chosen by argument. If they turn
  out wrong the fix is one table in `src/opponent.gd`. The only numbers that do
  exist are relative, from level-vs-level self-play on 2026-08-25 (colours
  alternating, native search, no book): Child scored **38%** over 16 games
  against Beginner, and **42%** over 6 games against Gentle. Both samples are
  far too small to separate anything — ±25% at n=16 — and the second is
  suspiciously high for a random mover against a depth-4 search, which is what
  turned up the bug below.

- **BUG, pre-existing and significant: root scores handed to the level system
  are alpha bounds, not values** (found 2026-08-25, NOT introduced by the Child
  work, NOT fixed). `ChessSearch.search()` searches each root move with
  `-_negamax(depth - 1, -INF, -alpha, 1)`. Every move that fails to improve on
  the running best fails high in the child and comes back at approximately
  `alpha` — so `scored` records one value for all of them, and its own docstring
  ("every root move with its value") is wrong. MEASURED on a quiet middlegame,
  `r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4`:

      depth 1: 33 root moves, 1 distinct score
      depth 2: 33 root moves, 1 distinct score
      depth 4: 33 root moves, 1 distinct score
      depth 6: 33 root moves, 2 distinct scores (31 of 33 tied)

  The consequence is that `ChessOpponent.choose()` is adding noise to a FLAT
  list, so every level with `noise > 0` — that is, 2 through 8 — picks close to
  uniformly at random in any position without a decisive move, whatever its
  noise setting. That is why the levels do not separate, and it means the ladder
  is far weaker and far flatter than the table in `src/opponent.gd` describes.
  Level 9 is unaffected (`noise` 0 takes the first entry, which `_order_root`
  has already put the true best move at) and so is level 1 (`uniform` draws
  deliberately rather than accidentally).

  The fix is to search root moves on a full window — `-_negamax(depth - 1,
  -INF, INF, 1)` — so every root value is exact. That costs the root's
  alpha-beta cutoffs, which is a real slowdown on the Pi at levels 8 and 9, and
  it will change the strength of every level. Both are judgement calls about the
  product rather than about the code, so it is written down here rather than
  fixed in passing.
- **Chess has no opening book.** At the top levels it plays the same first few
  moves every game, because a deterministic search from a fixed position is
  deterministic. The lower levels vary because of the noise; the higher ones do
  not. A small book, or a few centipawns of noise applied only in the opening,
  would fix it.

- **Availability is unimplemented and deferred** (owner's call, 2026-08-20).
  Nothing tells Home Assistant whether a game is running; every sensor is "last
  known value" with no way to distinguish live from stale. A normal MQTT Last
  Will does not work here — `QMqttClient` connects per batch and disconnects
  cleanly after every publish, so an LWT would fire seconds after every report.
  The plan is a retained `state` topic (`playing` on launch, `exited` in
  `QGameRoot.quit_game()`), which is cheap and survives an HA restart but
  cannot notice a hard kill or a power cut. The alternative — holding the
  connection open with a keepalive for a real LWT — was rejected as turning a
  fire-and-forget publisher into a socket that needs babysitting.
- **The debug HUD's memory slope needs a long soak to be trusted.** It is
  verified correct on synthetic series (a 0.5 MB/s climb reports 30 MB/min) and
  reads ~0 on a flat process, but nothing has yet run long enough to see it
  catch a real leak.
- **CPU% assumes USER_HZ is 100.** True on every kernel Godot ships for, but it
  is asserted in `QDebugStats.CLK_TCK`, not read — there is no sysconf() from
  GDScript. If a target ever disagrees the percentage scales wrong.
- **The HUD has never run on Android or on ARM hardware.** /proc is there, so
  the readers should work, but "should" is the operative word.
- **Shared theming is not built yet.** "Each game feels distinct" is currently unserved
  by qcore; the intended mechanism is a `Theme` built in code from a small per-game
  palette. Deliberately deferred so it is designed against a real game rather than
  speculatively.
- **Android export preset unwritten** — needs the SDK installed first. Linux x86_64 and
  arm64 presets exist.
- **CI is staged**: tests plus both Linux exports on push, self-contained, no secrets.
  Android debug APK and release signing are deliberately not enabled.
- **Code-first does not scale to a content-heavy game.** If the Stardew-like idea is ever
  picked up, that project goes editor-first (tilemaps, atlases, animation, dialogue data)
  and the division of labour inverts: systems in code, content in the editor. Everything
  else here — qcore, CI, export matrix, monorepo shape — transfers.
- **Old suite.** Gen2 was promoted to the repo root in `2cf1dd5`, so
  `~/Projects/qGames` is now THIS suite, not the old one — the gen1 tree is no
  longer in this repository. It is believed to still run on the Pi, which
  rejects our SSH key, so that is unverified as of 2026-08-27. Nothing has
  published a gen1-only topic (`battleship`, `simon`) to the broker in at least
  two days, and Home Assistant's sensors for them were deleted on that basis.
