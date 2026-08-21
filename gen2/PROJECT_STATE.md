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

**No tags exist yet.** Cut the first with `git tag -a v0.1.0 -m "..."`.

### Android, when it comes

Nothing here blocks it and one thing actively helps: `res://build_config.cfg`
travels in the `.pck`, so an APK gets its broker settings the same way a desktop
build does, with no per-device setup. What is still missing is unchanged — JDK
17, the Android SDK, and an export preset. `install.sh` is Linux-only by nature;
Android installs through the APK.

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
