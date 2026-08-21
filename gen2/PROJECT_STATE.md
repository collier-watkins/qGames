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

**Godot 4.7.2, GDScript, Compatibility (OpenGL) renderer, code-first.**

Why, against each requirement:

| Requirement | Mechanism | VERIFIED |
|---|---|---|
| ARM Linux native | Official precompiled arm64 *and* arm32 export templates; an official arm64 editor also exists | yes — godotengine.org/download/linux, 4.7.2 dated 18 Aug 2026 |
| Android native | First-class APK/AAB export, per-preset architecture toggles | yes — EditorExportPlatformAndroid docs |
| Touch + keypad | `InputMap` binds one named action to keyboard, gamepad and touch at once; `TouchScreenButton` drives actions via `Input.action_press()`; *Emulate Touch From Mouse* exercises the touch path on a desktop | yes — Godot input docs |
| Lightweight/calm | 2D only, Compatibility renderer, no physics, low node counts | design discipline, not a guarantee |
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
mqtt.yaml             the consuming side: Home Assistant sensors for the schema.
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
buy nothing. `mqtt.yaml` at the repo root is the consuming side.

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

**Three games built, all tests green** (2026-08-21): memory 43/43, notes 130/130,
sequence 27/27 — 200 tests, 0 failures. Nothing is committed for `notes` or
`sequence`; both are untracked in the working tree, alongside edits to
`PROJECT_STATE.md`, `mqtt.yaml` and `tools/new_game.sh`.

The project began as a spike — port `memory` (the old suite's smallest game, 281
lines) to prove the workflow before committing to a full rewrite. The spike's
questions are now answered except one: the code-first loop holds up across three
games of different shapes, keypad-plus-touch works on all three, GDScript suits
the work, and the Linux x86_64 and arm64 exports come out clean. **Android is
still unanswered** — the SDK is not installed, so no APK has ever been built.

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

## Open threads

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
- **Old suite** at `~/Projects/qGames` stays as-is and keeps running on the Pi. No
  migration is planned until this platform earns it.
