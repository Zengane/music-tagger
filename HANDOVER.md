# Music Tagger v2 — Handover


## Ninth pass — 2026-09-05

Everything below was done in one long session. The theme, unfortunately, is
**pointers into memory that had already been handed back** — three separate bugs
of that shape, one of which cost three wrong fixes before it was measured rather
than reasoned about.

### The game box opened empty, and why that took four attempts

Clicking the pencil beside a folder's proposed game was supposed to open a box
with the guess already in it. It opened empty. It was "fixed" three times and
reported broken three times.

Every test passed. That was the problem.

`guess_game_for_tracks` builds a tag with `context.temp_allocator`, which is
emptied at the end of every frame. A guess for a game the taxonomy already knows
comes back as a compiled-in string and survives anything; a guess for a game it
has *never seen* — the new ones, the only ones worth proposing — was a pointer
into memory handed back one frame later. It still read as sixteen bytes long, so
nothing thought it was empty. The bytes had simply been zeroed.

A test does all its clicking inside one temp lifetime, where the pointer is
still good. It was measuring a state the user can never be in.

What found it was a breadcrumb written from the running program at the moment of
the click:

    open row=1 stored="\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"

Sixteen NUL bytes. `Wii-Sport-Resort` is sixteen letters.

The fix is `guess_arena` in `ui/tagging.odin`: the proposals get their own arena
that lives as long as the rows do, dropped and refilled on every rebuild.

**Two lessons worth keeping:**

- Emptiness is tested with `has_visible_text` (any byte above a space), never
  `trim_space`. Freed memory is NUL bytes, not spaces, and a dead string passed
  every `== ""` check in the program.
- Any test that spans a user action calls `free_all(context.temp_allocator)`
  where the frame would end — and is then proved to *fail* with the fix
  reverted. A test that has never failed has not been shown to test anything.

### The same shape of bug, twice more

**A blank tag on every file.** `add_tag_to_track` guarded `tag == ""` but not
whitespace, so a guess that came out blank put a nameless chip on every file it
was applied to. Guarded in three places now, and `apply_guessed_games` gates on
`game_guess_usable` rather than on `has_guess`.

**A segfault at the end of a filing run.** A rescan destroys `lib.arena` and
builds a new one, but `tagging.rows[*].dir` points into the old one, and
`invalidate_tagging` only set a flag — the rows stayed there, still readable,
and the rebuild walked them to restore which folders were open. It only bit once
a rescan actually changed the count.

`reset_tagging_rows` frees them now, and `forget_track_indices` in `ui/scan.odin`
drops everything else that remembers a track by position: the selection, the
map's dots, a running job's target list.

**The "Rescan this folder" button had the same hole all along.** It rarely bit
because a normal rescan finds the same files in the same order.

Reproduced headlessly rather than by asking someone to click:

    mtag-test.exe --rescancheck "H:\Media Browser\Mega Music Pack"

Old build: `Segmentation fault, EXIT=139` on pass 2. New build: `EXIT=0`.

### Deleting a tag now takes it off the files

It used to leave them carrying a tag that was gone from the rail — invisible,
unsearchable, and impossible to remove except one file at a time. Deleting a tag
means getting rid of it. Undoable, and shown in the Save count.

### Tagging went from 45 hours to 34 minutes

A run over 905 files was moving at just under **three minutes a file**. Not
stuck — the card was full:

    before:  7746 MiB of 8192   (95%, overflowing into system RAM)
    after:   5440 MiB of 8192

`FusionEncoder` loads three models and ran all three on each file in turn, so all
three had to be resident. Three do not fit on an 8 GiB card, and Windows serves
the shortfall out of system RAM rather than failing — at roughly forty times the
cost.

`FusionEncoder.prefill` does the same work **model-major**: load one part, embed
every file that needs it, hand the VRAM back, load the next. Peak use is one
model instead of three. `tag_job.py` calls it before the scoring loop, so by the
time that loop runs every part is cached and it is pure arithmetic.

Measured end to end: **934 files, three models, 34 minutes, zero failures.**

The three models run at very different speeds, so do not estimate the whole run
from whichever one is in front of you. That mistake was made twice, in both
directions.

### Filing into mood folders — the step that was never ported

The library is arranged by mood on disk, and tagging is supposed to end with the
track sitting in the folder it was tagged with. The old web front end did that.
The native one never learned to, so several hundred correctly tagged tracks
stayed in `Untagged/` wearing the right tags.

`mtag/organize.py` was there and tested the whole time. Nothing called it.

Now `organize_job.py` drives it as a job, with a button in the Tagging tab action
bar and an entry in the track context menu. **Always two passes**: a plan pass
that touches nothing and reports what each move would do, shown in a dialog, and
only then the move.

    792 files move on disk. Their sidecars go with them.
        142 to Chill
        141 to Adventure
        105 to Goofy
        and 404 more to 11 other folders
    Nothing is overwritten. The library is rescanned after.

Each move takes the sidecar with it, re-keys the embedding caches so nothing is
re-analysed, and refuses to land on an existing file.

`tests_filing.py` covers it end to end on a throwaway library. The cases that
matter are the refusals: a name clash must leave **both** files alone, and the
plan pass must move nothing at all.

### Moving files broke the map, and nothing said so

The map remembers each track's position by absolute path in
`model/soundmap.json`. Filing 1649 tracks orphaned 1649 points in one go.

The app did not report this. It saw most tracks as unplaced, silently fell back
to its *other* layout — the one built from measured audio — and the map came back
looking like a different feature, with sound-shape labels like Whoosh and Stab
and a caption reading "placed by what was measured".

`organize.rekey_soundmap` carries the points across now, in one pass at the end
of a run (the map is a single document; re-keying per move would be a rewrite per
move).

**Anything keyed by absolute path has to be listed in `organize.apply`'s wake.**
The sidecar and the embedding caches were already handled; the map was not, and
no test would have noticed. There is one now.

### Smaller things

- **Tag names may contain spaces.** They could not, because the search box split
  on them. It understands quotes now — `+"fire emblem"` is one term — so a tag
  can be called what it is called. Hyphens still work.
- **The game guesses are made when the rows are built**, not on a button press.
  It reads names, not audio, and takes 23 ms for 44 folders. The Detect button
  stays, for a folder renamed on disk.
- **The game box is never empty.** Three sources in order: the row's stored
  guess, a fresh read of the folder's files, then the folder's own name.
  `--prefill` opens the box on every folder and reports what lands in it — was 14
  empty, now 0.


## Where the library stands

    1786 music files
    1649 filed into mood folders
     133 still in Untagged/ — no *mood* tag, so nothing decides a folder
    1786 of 1786 placed on the map
       0 files missing an embedding

**24 music tracks carry no mood or sound tag at all.** Five of them did clear
their threshold, on tags that are not allowed to apply themselves — `Mysterious`
is suggestion-only, and `Wintery`, `Trappy`, `Romantic` and `Loss` are zero-shot
heads with no trained probe. Nine more are within 0.04 of their threshold. The
app already holds every score, sorted by margin, so they are one click each in
the side panel.

Thresholds sit at `TARGET_PRECISION = 0.60`. Lowering them to catch those 24
would add wrong tags to the ~900 that came out right. Not worth it.


## What is still wanted

- **Remember the library between runs.** The app rescans the whole folder on
  every launch — 1826 sidecars, then 1786 cached waveforms. Warm that is 3.4
  seconds; after a PC restart, with a cold external drive, about a minute. Agreed
  in principle: save the scan to one file, show it instantly, re-scan in the
  background to catch outside changes. **Not started.**
- **Marker editing** — add with M, move, name. Deferred repeatedly.
- **More answers in `drops.txt`.** Drop detection is tuned against three
  hand-checked timestamps. It wants more before further tuning means anything.
- **Tag by name with no training** — a zero-shot text tower, so a new tag is
  usable immediately. Discussed, never built.
- **37 tagged files sit outside `Untagged/` in a folder that is not one of their
  moods.** Filing deliberately leaves them alone: they were placed by hand, and
  moving them is not something to do without asking.
- **29 effects under `SFX/` carry no category.** Those go through the separate
  effects job, not the music one.


## Running the checks

Everything measurable has a mode. None of them need the window.

    mtag-test.exe --selftest "H:\Media Browser\Mega Music Pack"   the lot
    mtag-test.exe --rescancheck "<library>"    the crash above, on demand
    mtag-test.exe --filingcheck "<library>"    plan, move, rescan, rebuild
    mtag-test.exe --prefill "<library>"        what the game box opens with
    mtag-test.exe --windowcheck                layout at every width
    mtag-test.exe --games / --soundmap / --drops / --dropcheck / --benchmark

    venv\Scripts\python.exe tests_filing.py    moving files, on a throwaway copy
    venv\Scripts\python.exe tests.py           the Python side

**`build.bat` ends with `pause`.** Run it from a terminal, or call Odin directly
when scripting:

    C:\Odin\dist\odin.exe build ui -out:mtag-test.exe -o:speed
    C:\Odin\dist\odin.exe build ui -out:MusicTagger.exe -o:speed -subsystem:windows -resource:app.rc

**A running copy holds the .exe open** and the build fails on the link step,
which is one line in the middle of a lot of output. `build.bat` refuses outright
and says so. Close the app before building.


## Traps worth knowing before touching this

1. **`context.temp_allocator` is emptied every frame.** Anything stored past the
   current frame is cloned into an owned arena. See `guess_arena`.
2. **A rescan destroys `lib.arena`.** Anything holding a pointer *or an index*
   into `lib` is dropped in `poll_scan` — not marked stale, dropped. See
   `forget_track_indices`.
3. **Track tag strings live in `lib_allocator()`, an arena.** Never `delete` one
   with the heap allocator. That crash has happened twice.
4. **Anything keyed by absolute path breaks when a file moves.** Sidecar,
   embedding caches, soundmap. All three are handled in `organize.apply`'s wake;
   a fourth would need adding there.
5. **Reproduce headlessly.** A console mode that drives the real sequence gives a
   stack trace and an exit code. A window that vanishes gives nothing.


## Eighth pass — 2026-09-04, night

### The library disappeared, and that was my fault

Browsing showed only files sitting *directly* in the current folder. That is
how a file manager behaves, and it was the wrong default here: this library
keeps every track in a subfolder, so the top of the tree was empty and nothing
appeared at all until a tag was clicked.

It is recursive now — the top shows everything, and stepping into a folder
narrows to what is under it. A toggle in the breadcrumb switches to this-level-
only for when that is what is wanted. `--selftest` checks the top of the tree
shows the whole library, which is the assertion that would have caught it.

### Other fixes asked for

- **Clicking a tag in the rail replaces the query** rather than adding to it.
  Browsing for a tag is nearly always a fresh question. Ctrl adds, Alt excludes,
  for building one up deliberately.
- **Scrollbars no longer sit on top of content.** Panels that scroll now lay
  their content out inside a gutter, so the rail's tag counts and the row
  highlights stop where the bar begins.
- **The playhead and the selection have been separated properly.** A press that
  never travels is a click, wherever it lands, and a click always moves the
  playhead. Travel is what makes it a drag: sweeping selects, the ends adjust
  the range, and the grip carries it out. Pressing the grip and releasing
  without moving now seeks like anywhere else instead of starting a drag.

### Reviewing what was tagged

Folders in the Tagging tab open out. Each file shows its name, the tags it now
carries, and a dot for whether that is saved, changed, or untouched — so a run
over two hundred files can be looked over before anything is written. Clicking
one plays it.

This was the half of tagging that was missing: the model would run and there
was no way to see what it decided without saving first and going to look
somewhere else.

### A marker on the hit

Effects now measure where the sound actually lands — the start of the loudest
run, not simply the loudest frame, which for anything with a flat top falls
arbitrarily inside it. For a transition effect that is the sync point.

It is written into the range XML as a marker, so the clip arrives in Premiere
with the point already flagged.

### The range import still needs testing

It did not work when dropped. The document now carries a sequence-level format
block and a timecode block, which is closer to what Premiere writes itself and
is the most likely thing to have been missing.

If dropping still does nothing, **File → Import** on the same `.xml` is worth
trying — that path is Premiere's documented one, and the file is written to
`cache/ranges/` either way. Knowing which of the two fails would say whether
the problem is the document or the drop.

### Still to do

1. **Zoom that slides between list and grid.**
2. **A native folder picker.**
3. **Moving tracks into mood folders on save.**

---

## Seventh pass — 2026-09-04, evening

### Interface fixes

- **The right panel has a toggle**, mirroring the sidebar's, because closing it
  now stops it reappearing and there was no way back except a keyboard
  shortcut nobody was told about.
- **The playhead has its own strip.** Seeking and selecting were competing for
  the same clicks — once a selection existed, its middle was the drag-out grip,
  so clicking there to move the playhead started a drag. The top fifteen
  pixels are now a ruler with a time scale that scrubs, and nothing else uses
  it. This is what every audio editor does and for the same reason.
- **List columns no longer overlap.** The tag column had a minimum width, so on
  a narrow list its left edge sat behind the name's right edge: the name was
  handed a negative amount of room and drew over the header. Columns are now
  worked out left to right and are dropped when they will not fit. Checked at
  every width from 120 to 2400 pixels by `--selftest`.

### Browsing

`ui/browse.odin`. There is a current folder, a breadcrumb above the list, and
folders appear as rows and tiles you step into. A library arrives already
sorted by someone — Impacts, Risers, UI — and flattening it means every search
starts from ten thousand files instead of the forty in the folder you meant.

Searching still ignores the folder, because a query is a question about the
library rather than about where you happen to be standing. The breadcrumb says
so when a search is running.

### Sorting by feel

`ui/features.odin`. Seven orders: name, length, brightest, punchiest, loudest,
building, and **most like the selected one**. All but the first are measured
properties, which is what turns ten thousand effects into something browsable —
all the risers together, all the short bright ones together.

### Effects: measured, not guessed

The AudioSet tagger was answering the wrong question. It describes an *object*
— a door, a dog, breaking glass — which is right for film foley and wrong for
editing, where the question is what a sound does to a timeline. A riser rises.
That is a property of the waveform.

So seven numbers come out of the same decode that builds the waveform:
duration, loudness, peak, brightness, onset, slope and sustain. From those:
Riser, Impact, Downlifter, Drone, Whoosh, Stab, plus Bright/Dark/Punchy/
Sustained. No model, no download, and the whole library is described by the
import that was already happening.

**The thresholds were calibrated against the real SFX folder, and two of them
were badly wrong first time round.** `--shapes <folder>` prints the numbers and
the verdicts, which is how they were caught:

- `attack` was the time to the *loudest moment*, so a drone that swells late
  read as a nineteen-second attack. It is the onset now — the first crossing of
  a quarter of the peak — which is what separates a hit from a swell.
- Whoosh wanted *high* sustain. Every real whoosh has low sustain: it arrives,
  passes and is gone. Nothing matched until that was inverted.
- Dark fired on 27 of 40 files because the brightness scale is compressed
  toward the bottom.

After recalibration on the same 40 files: Whoosh 0 → 14, Impact 6, Stab 6,
Riser 2, Drone 3, and Dark down from 27 to 10.

The AudioSet job is still there and still useful for what it is good at —
naming the object — but it is no longer the thing the effects workflow rests
on.

### Dragging a range instead of a clip

`ui/fcpxml.odin`. A selection drag now carries a Final Cut Pro 7 XML rather
than a rendered wav. Premiere reads that format, and it describes a sequence
that *references* media with in and out points — so the whole original file is
imported and only the chosen range is placed. Nothing is rendered, nothing is
padded, and the handles either side are still there to trim into.

The toggle in the dock switches back to a rendered clip.

`--selftest` checks the document is well formed, that the in and out land where
the selection was, that it points at the original rather than the clip cache,
and that a path with Japanese or full-width punctuation is percent-escaped.
**Whether a given Premiere build accepts an XML by drop is the one thing that
cannot be checked from here.**

### A cache bug worth remembering

The peaks file gained the measured features, which changed its format. The
warm-up skipped every stale file because it checked the cache *existed* rather
than that it was readable — so nothing was ever rebuilt and the library had no
waveforms at all until the folder was deleted by hand. It reads the magic
number now.

### Still to do

1. **Zoom that slides between list and grid**, the way File Pilot does.
2. **A native folder picker.**
3. **Moving tracks into mood folders on save.**

---

## Sixth pass — 2026-09-04, afternoon

### Splitters and scrollbars could not be grabbed

Draw order. The list drew before the splitters, so its rows took every click
aimed at a panel edge. Chrome now claims its input at the top of the frame,
before any panel draws, and only the line is drawn afterwards — `splitter_input`
and `splitter_line` are two halves of what used to be one call.

The scrollbar had a second problem: a six-pixel target sitting next to the
splitter's own grab zone. The bar still draws thin, but the area that catches
it is three times that, it sits clear of the panel edge so the two do not
compete, clicking the track jumps there, and dragging the thumb no longer makes
it jump to centre on the pointer.

### Smaller things asked for

- **The inspector stays shut.** Closing it turns off auto-open, so selecting a
  track no longer brings it back. Tab reopens it and turns auto-open back on.
- **Right-click a track**: play, copy files, copy path, show in Explorer, set
  game, analyze or guess from filename, clear tags, save. It acts on the
  selection when the click lands inside one.
- **Tag categories can be added**, and each declares whether it belongs to
  music, effects, or both. The rail only offers the ones matching the tab, so
  All shows everything and the other two stay focused.

### The waveform is an editor now

`ui/waveform.odin`. The wheel zooms about the pointer, shift-wheel and
middle-drag pan, and a bar underneath shows where the zoomed window sits in the
whole track. A selection's ends are draggable, alt-drag slides the whole range,
and only the visible window is drawn — so zooming in shows more detail rather
than the same shape stretched.

In the middle of the selection is a **grip**. That is what gets dragged into an
editor. It is in the middle so the ends stay free for adjusting, and it is in
the same place whatever size the selection is.

### Sound effects

`mtag/sfxtax.py`, `sfx_job.py`. An AudioSet tagger's 527 classes are folded
into 53 tags in five categories, scoped to effects:

    Type      what it is        Impact, Whoosh, Interface, Creature…
    Material  what it is made of  Metal, Wood, Glass, Water…
    Space     where it sounds     Close, Room, Hall, Outdoor…
    Length    how it behaves      One-Shot, Loop, Tail
    Intent    what it is for      Confirm, Cancel, Error, Level-Up…

**Three sources, and the split between them is the point.**

*Length is measured, not guessed.* A loop's start and end match in level; a
one-shot decays to silence. Verified on the real SFX folder: every file there
reads as One-Shot, the long ones also as Tail.

*The AudioSet model does acoustics.* It is a sound-effect ontology to begin
with, so Door, Footsteps, Glass and Explosion come out of it directly.

*Intent comes from the filename, and cannot come from a model.* Confirm and
Cancel are the same sound. They differ only in what the designer meant, so no
classifier can separate them — but a game effect's filename nearly always says
so outright. `SFX_INTENT_PHRASES` covers all sixteen intents and each is
covered by a test. An intent also implies Interface, which filenames leave
unsaid.

If the model cannot be loaded the job says so and carries on with filenames and
length rather than failing.

**The model is not downloaded yet.** `MIT/ast-finetuned-audioset-10-10-0.4593`
is about 350 MB. Everything else in the pipeline runs without it.

### Still to do

1. **Zoom that slides between list and grid**, the way File Pilot does, rather
   than the two being separate views with a size slider.
2. **Premiere importing the whole file and placing only the selection.**
   Dropping a trimmed file works today. The whole-file-with-in-and-out version
   needs Premiere to accept an FCP7 XML by drop, which is worth an experiment.
3. **A native folder picker.**
4. **Moving tracks into mood folders on save.**

---

## Fifth pass — 2026-09-04, morning

### Two bugs, one cause each

**A third of the library would not play.** 586 of 1823 files are `.m4a`, which
raylib cannot decode, so they are transcoded to a cached wav first — and the
original `.m4a` extension was still being handed to raylib alongside the wav
bytes. It picked a decoder by extension, got the wrong one, and failed. The
transcode now reports the extension of the file it actually produced.

The same function was why those tracks sat on "reading waveform" forever: the
failure returned early, before `request_waveform`. The waveform is read from a
cache file and has nothing to do with playback, so it is asked for first now.
A track that will not play still shows its shape.

`--playcheck` opens one track of every format in the library and checks it
decodes.

**Japanese filenames drew as "????" in a chunky pixel font.** That font was
raylib's own built-in fallback. Every Japanese face Windows ships — Yu Gothic,
MS Gothic, Meiryo — is a `.ttc`, a collection holding several fonts in one
file, and raylib hands the file to stb_truetype at offset zero, which for a
collection is the container header. The load fails, raylib silently returns its
default font, and a default font is a perfectly valid Font, so nothing
complained.

`ui/fontfile.odin` unpacks the collection: a `.ttc` is a header, a count, and
an offset per font, and copying one font's tables out with corrected offsets
gives a standalone font stb reads happily. Two guards were added with it —
a load that comes back as the fallback is treated as a failure, and a face that
loads but cannot draw the library's own characters is rejected in favour of the
next candidate.

`--fontcheck` reports what every atlas can actually draw. Note it samples from
the library's own characters: an earlier version of that test hardcoded フ,
which this library never uses, and blamed the font for not baking it.

### The sidebar

Libraries are a deliberate list now, not a recent-folders list that grew an
entry whenever anything was imported.

- **+** beside LIBRARIES adds one; right-click any of them for Open, Rename,
  Change folder, Remove.
- The name is separate from the path, so a library can be called whatever makes
  sense.
- The app **reopens the last library at startup** rather than starting empty.
- Removing one takes it out of the sidebar and touches nothing on disk.

`libraries.json` still writes `folders` as a flat array of paths, which is all
`app.py` reads, and adds `libraries` and `last` alongside it.

**Dropping a track back on the window used to add a second copy of the
library.** Any dropped file was treated as "import the folder it lives in". Now
a folder imports, a file already in the open library selects and plays it —
which is what dragging one out and letting go again means — and a file from
elsewhere opens the add-library box with its folder filled in rather than
importing on the strength of one track.

### The grid

`ui/grid.odin`, a fourth view beside List, Map and Tag, with a zoom slider.
Each tile draws the track's waveform from the cache the import already built. A
percussive one-shot, a slow pad and a track with a long quiet intro are three
different pictures, and picking one out of a wall of pictures beats reading
forty file names. Peaks are read on demand for what is on screen and kept in a
512-entry cache; a tile whose waveform is not built yet simply draws without
one rather than stalling the frame to decode it.

### Panels

The edges between the rail, the list and the inspector are draggable, the
sidebar collapses from the button at the top left, and both widths are
remembered. The list is never squeezed below 320 points however far the handles
are pushed.

### Resizing, properly this time

The earlier measurements were right and the conclusion was incomplete: drawing
was never the problem. Windows runs a resize as a **modal loop** inside
`DefWindowProc`, which does not return until the mouse is released — so the
main loop stops running for the whole drag and the window shows a stretched
rectangle until it ends.

`ui/liveresize.odin` replaces the window procedure, starts a timer when the
modal loop begins, and paints on each tick. The paint is deliberately not
`EndDrawing`: that polls input, which pumps messages, which would re-enter the
same handler from inside itself. Flushing the render batch and swapping buffers
does the drawing half with none of that.

Best-effort throughout — if the hook cannot be installed the window behaves
exactly as it did before. `--benchmark` drives 60 size changes through it.

### The drag card

A card now follows the cursor showing the track name and how many files are
being carried, instead of a bare copy arrow.

The shell will draw one if it is handed a bitmap — but it stores that bitmap by
calling `SetData` **on the source's own data object**, so `IDataObject::SetData`
had to stop returning "not implemented" and actually keep what it is given.
The card itself is drawn with raylib into a render texture and read back, so it
uses the same panel colour, corner radius and font as the rest of the app.

### Still to do

1. **The sound-effect pipeline**, and a cluster view for effects rather than
   for music. See the third pass on using an AudioSet tagger.
2. **A native folder picker.**
3. **Moving tracks into mood folders on save.**

---

## Fourth pass — 2026-09-04, overnight

### Dragging files out

`ui/dragdrop.odin`. Windows has one way to be a drag source and it is not a
message you send: the application implements `IDataObject` and `IDropSource`
as COM objects and hands them to `DoDragDrop`. Both are built by hand here —
a struct whose first field points at a table of function pointers, in the
order the interface declares. The order *is* the interface; one entry out of
place and the target calls the wrong method.

- The payload is CF_HDROP, the same list of paths Explorer hands over, so any
  host that accepts dropped files accepts these.
- `GetData` returns a fresh copy of the block every time. The target takes
  ownership of what it is given and frees it, so handing out the original
  would free it underneath us.
- `EnumFormatEtc` is answered with the shell's standard enumerator rather than
  a hand-written one. Some hosts ask what is on offer instead of guessing.
- Press and move at least six pixels on a row to start a drag; a press that
  does not move is still a click. A waveform selection that has been rendered
  is dragged instead of the whole track.
- `DoDragDrop` runs its own message loop, so the window stops drawing until
  the drop lands. Every drag source behaves that way — Windows is drawing the
  drag, not us.

ole32 and shell32 are loaded at run time, for the same reason user32 is in
`clipboard.odin`: raylib defines its own `CloseWindow` and so does user32, and
linking both makes the linker discard raylib's.

### Waveforms built on import

`ui/warmup.odin`. After a scan, a pool of two workers builds and caches the
peaks for every track, so opening one later is a file read rather than a
decode. The status line shows the progress. The whole library — 1823 files —
takes **under two minutes**, about ten files a second.

The pool never touches `lib`. It is handed copies of the paths it needs, so a
rescan freeing the library's arena mid-decode is not something to lock
against — it cannot happen. Its only output is cache files on disk.

`mtag-test.exe --warm-waveforms <folder>` runs the same pool from a terminal
and waits for it, for the first pass over a large library.

#### The 150x bug, and the wrong explanation that nearly stuck

The first version of this managed **four files a minute**. Four workers were
measured against one and came out three times *slower*, and the explanation
was obvious and wrong: four decoders thrashing a mechanical drive.

Timing one file settled it. ffmpeg decodes one of these tracks in **0.12 s**;
the app was taking about **15 s**. The bottleneck was never the disk, the
thread count, or ffmpeg.

`run_capture` polled the child's pipe with `PeekNamedPipe` and called
`Sleep(1)` when it found nothing. Windows rounds a 1 ms sleep up to the timer
resolution — roughly 15 ms — and a decode pushes megabytes through a 64 KB
pipe, so the job spent essentially all of its time asleep. `stream_read_wait`
does a blocking `ReadFile` instead and lets the OS wake the thread.

Result: **4 files a minute to 633**. Every other subprocess got faster with
it, since clip export, format conversion and the model bridge all read through
the same helper.

The lesson worth keeping: both of the thread-count measurements were real
numbers, and the conclusion drawn from them was still wrong, because the thing
being compared was not the thing that mattered. Timing the single operation
against the tool that does it was what found the bug.

### Frame cost

Resizing was reported as laggy. Measured rather than guessed, with
`--benchmark`:

| | before | after |
|---|---|---|
| 1440 px wide | 1.08 ms | 0.78 ms |
| 1180 px wide | 1.77 ms | 0.68 ms |
| 900 px wide | 1.83 ms | 0.63 ms |

The cause was `elide_left`/`elide_right` measuring the string once per
character removed — O(n^2) per row, and worse the narrower the window, which
is exactly when it was noticed. They binary search now: about seven
measurements instead of a hundred. Note the old numbers *rise* as the window
narrows and the new ones do not.

`count_dirty` was also walking all 1823 tracks every frame for a number that
is usually zero; it is cached and invalidated on tag changes.

What is left is not ours: a frame that also resizes the window costs about
5.5 ms, and turning MSAA off changes that to 5.6 ms — so it is framebuffer
reallocation in the driver, not drawing. If dragging the window edge still
feels rough, the remaining cause is GLFW's modal resize loop, which does not
pump frames while the border is held; hooking it needs a patched raylib.

Every waveform in the library is cached as of this pass, so the player has
nothing to wait for.

`--selftest` also covers the drag payload now: the CF_HDROP block is built,
read back the way a drop target would read it, and checked for its offset, its
wide flag, its double null terminator, its length, and a path containing
characters outside the code page. `DoDragDrop` itself needs a hand on a mouse.

### Still to do

1. **The sound-effect pipeline**, and a cluster view built for effects rather
   than for music — the map currently places by mood and sound, which say
   nothing about a door slam. See the note in the third pass about using an
   AudioSet tagger rather than the music model.
2. **A native folder picker.**
3. **Moving tracks into mood folders on save.**

---

## Third pass — 2026-09-04

### Bugs reported, and their causes

- **Special characters broke the list and stopped playback.** Two separate
  faults with one appearance. Rendering: the wide-face test sniffed raw bytes
  for anything above 0xE0, which catches an en dash and a curly apostrophe, so
  most of the list was drawn in Yu Gothic at widths measured against Segoe UI
  and names ran over the tag column. It decodes properly now, the name column
  is clipped as well as elided, and the look-alike characters a YouTube rip
  uses (`⧸` for a slash, `？` for a question mark) are folded to ASCII **for
  display only** — the path on disk is never touched. Playback: raylib opens
  files through the C runtime, which on Windows uses the active code page, so
  those paths simply failed to open. The bytes are read by Odin and handed to
  `LoadMusicStreamFromMemory` instead.
- **No way to add a game tag.** The inspector now has a Game section: the
  current tag, a picker that searches the Game group, and a one-click
  suggestion read from the folder and the files beside it.
- **Tag colours were not imported.** Dropping a TagSpaces tag-library export on
  the window reads it, colours and all — `tagGroups`/`children`/`title` as well
  as this program's own shape. `tag_color_of` prefers a tag's own colour, then
  its group's, then the vocabulary default.
- **Dragging a track out did nothing.** Still true, and it needs an OLE drop
  source — see below. `Ctrl+C` now puts the selected files (or the rendered
  clip) on the clipboard as `CF_HDROP`, the same payload a drag would carry.

  `clipboard.odin` loads user32 at run time rather than linking it, and that is
  deliberate: raylib defines its own `CloseWindow` and so does user32. Linking
  both makes the linker discard raylib's, which would send raylib's shutdown
  call into the Windows function with the wrong argument. `/FORCE:MULTIPLE`
  links and even passes the tests, and is wrong.

### The Tagging tab

A third view, next to List and Map, organised by folder because that is the
unit files arrive in. Each row is a folder: how many tracks, how many are
tagged, and which game it looks like. Tick folders, then act on all of them.

Detect games, apply them, analyze the checked music, guess the checked effects
from their filenames, save. On this library one pass applies a game to **925
tracks across 20 folders** — the whole `Untagged/` batch.

### Working out the game from a batch

`ui/gamedetect.odin`. The old detector matched a filename against a table of
known phrases, so a game not in the table was invisible. This looks for the
longest run of words every filename in a folder shares, which is the game,
because the track titles are the part that differs.

Four rules decide the answer, and each came from a wrong result on the real
library:

1. **A known game anywhere in the folder chain, outermost first.** So
   `Bayonetta/DISC 3` is Bayonetta and not DISC 3.
2. **A known game in what the filenames share.**
3. **The outermost folder that names something.** Staging folders and mood
   folders are skipped — half this library's folders are named after a mood
   because tagged tracks get filed into one, and "Chill" was being proposed as
   a game.
4. **Whatever the filenames share, cleaned up.**

Plus: a word already written with inner capitals keeps its spelling, so
`JimmyHere` and `TF2` survive instead of becoming `Jimmyhere` and `Tf2`; and a
lone trailing number is part of the title while a run of them is a version, so
`Mario 64` keeps its 64 while `Terraria Soundtrack 1 4 4` loses its.

It proposes `JimmyHere`, `VA-11-Hall-A`, `Terraria`, `Bayonetta`,
`Hello-Baby`, `Blasphemous`, `Wario-World`, `Orange-Lounge` and
`Legend-Of-Zelda-Breath-Of-The-Wild` — the list of new games from the open
items below, without any of them being typed in.

Applying never overwrites a game tag already on a file, and never tags an
effect. Both are checked by `--selftest`.

### The waveform

Rebuilt against the Soundly reference: two lanes, one per channel, each
mirrored about its own centre line, near-white on near-black with the played
part tinted. Peaks are generated in stereo now — a mono average hides a
hard-panned effect completely. The cache format changed with it, so the first
open of a track regenerates its peaks.

### Still to do

1. **Dragging a file out of the window.** Needs `IDataObject` and `IDropSource`
   implemented as COM objects and driven by `DoDragDrop` — a few hundred lines,
   and the only way Windows will let an application be a drag source.
   `Ctrl+C` covers it in the meantime.
2. **A model for sound effects.** Not the music model, and probably not a
   trained one to start with: AudioSet is a sound-effect ontology and an
   AudioSet tagger (PANNs, AST or BEATs) already emits classes like Door,
   Footsteps, Explosion and Wind. Mapping those 527 classes onto the sixteen
   categories here needs no training at all. A trained probe per category, the
   way the music side works, is worth doing only once there are enough tagged
   effects to train on — with 40 files there are not.
3. **A native folder picker.**
4. **Moving tracks into mood folders on save.**

---

## Second pass — 2026-09-04

Fixes and features on top of the native rewrite below.

### Bugs that were reported, and what caused them

- **Clicks went to the wrong thing.** Rows were clipped when drawn but not when
  hit-tested, so list rows scrolled under the player still consumed clicks
  aimed at the transport. `begin_clip`/`end_clip` in `widgets.odin` now clip
  both, and `ui.modal_open` makes an open popover swallow the frame's input —
  panels draw before it and would otherwise take its clicks.
- **Text was illegible.** One 32-pixel atlas was being scaled down to 11, 13
  and 15. Every size is now baked at exactly the pixel height it is drawn at,
  with point sampling and whole-pixel placement.
- **The interface did not scale.** Windows reports a DPI scale of 1.0 on a
  1440p panel at 100%, so `auto_scale()` gives the display's own height a vote
  and takes the larger. Adjustable in Settings, or Ctrl +/-/0, saved to
  `prefs.json`.
- **Favourite stars drew as "?".** Segoe UI has no star. Favourites are drawn
  as a shape, like the rest of the icons.
- **The settings button did nothing.** It was never written. It is now a
  popover with the scale, the scan options and a rescan.

### The map

`ui/nodes.odin`. Every track is a dot placed by the tags it carries. The tags
are the only things simulated — a force layout over about forty nodes where two
tags attract in proportion to how many tracks carry both — and each track is
then placed at the weighted average of its own tags' anchors.

Two decisions that decide whether it groups at all, both measured:

- **Game tags are not anchors.** Every track in one soundtrack carries the same
  game tag, so they co-occur with everything and drag unrelated music together.
  With them in, tracks sharing a tag sat only 27% closer than unrelated ones.
- **Tags are weighted by rarity** (1/sqrt of its count) rather than averaged
  flat, or four tags average out to the middle of the map.

`--selftest` measures the result: tracks sharing a mood or sound tag sit at
**0.64** of the distance of tracks sharing none. Layout takes 4 ms for 1823
dots. Untagged tracks get their own island below the map — that island is the
pile of work.

### Sound effects

Effects are no longer skipped. They are imported, marked `is_sfx`, and shown
through the **All / Music / Effects** switch in the top bar. The music model is
never pointed at them: `start_analysis_for_current` filters them out, because
a mood/sound vocabulary produces confident nonsense about a door slam.

The workflow follows from what effects actually are:

- **The filename is the first guess.** `SFX_PHRASES` in `mtag/taxonomy.py` maps
  words to categories; `door_slam_metal.wav` suggests Impact and Mechanical.
  `G` sweeps every untagged effect in view. It is a lookup, not a model, and it
  is meant to be edited as the library grows.
- **The number keys tag and advance.** 1–9 and 0 toggle the first ten
  categories and step to the next file, so auditioning is the only slow part.
- **Selections tag in bulk.** Shift-click a range or Ctrl-click individuals; a
  number key or a palette click applies to all of them. A folder of forty
  footsteps is one keypress. If every selected file already has the tag, the
  same key clears it.

### The tag library

`ui/tag_library.odin`. The vocabulary is now editable data rather than compiled
in: the Python taxonomy is the starting point, and additions are merged from
`tag_library.json` — the same file the old browser app read.

- **+** beside TAGS in the rail creates a tag; hovering a tag reveals rename
  and remove.
- **Deleting** removes a tag from the vocabulary and touches no file. Files
  that carry it keep it, as in TagSpaces.
- **Renaming** does change files: it rewrites the tag on every loaded track and
  marks them to save. The dialog says how many before it runs.

### On replacing TagSpaces

Reading and writing its sidecars is done and covered by tests, including
preserving descriptions, geo data, stars and tags from other tools. That is the
whole format, and it did not need their source.

Before copying any code from the TagSpaces repository, **check its licence
first** — the desktop app is copyleft, and vendoring it would put this project
under the same terms. Nothing has been copied.

### Still to do

1. **Dragging a clip into Premiere** — needs a Windows OLE drop source.
2. **A native folder picker** — import is drop, type, or recent.
3. **The waveform look.** A Soundly screenshot was mentioned but did not arrive
   in the session, so the dock is drawn to its own design: peaks either side of
   a centre line, played portion lit, drag to select, click to seek.
4. **Reading the TagSpaces tag library** for colours and groups it defines,
   rather than only the tags found on files.
5. **Moving tracks into mood folders on save** — not carried over.

---

## Native rewrite — 2026-09-04

The interface is now a native Odin program. The Flask app, the pywebview host
and `templates/index.html` are no longer how the tool is used.

### Run it

```
build.bat          builds MusicTagger.exe (needs Odin at C:\Odin\dist)
MusicTagger.exe    the app
```

`mtag-test.exe --selftest "H:\Media Browser\Mega Music Pack"` runs 55 checks
over sidecars, the vocabulary, game detection, search and a real scan, without
opening a window. `--selftest-model` adds one real tagging job through the
model. `--selftest-pipe` exercises the subprocess reader alone.

### Shape

```
MusicTagger.exe          Odin + raylib, one process, ~85 MB resident
        |
        |  browsing, search, playback, waveforms, sidecar read/write
        |  all happen here, with no Python running at all
        |
        +-- ffmpeg / ffprobe    waveform peaks, clip export, format conversion
        |
        +-- venv\python.exe tag_job.py --paths-from <file>
                launched only when Analyze is pressed, exits when done.
                Emits newline-delimited JSON, one line per track, read a chunk
                at a time inside the frame loop.
```

Nothing Python is resident between jobs, so the encoder cannot hold VRAM or
stall the window. This replaces the lazy-load/unload dance the Flask app
needed.

### Files

```
ui/app.odin          window, layout, the four regions, input
ui/widgets.odin      immediate-mode buttons, chips, text fields, scrolling
ui/icons.odin        icons drawn as shapes, not font glyphs
ui/theme.odin        every colour and size in the interface
ui/library.odin      Track/Library model, TagSpaces sidecar read and write
ui/scan.odin         threaded folder walk, tag counts, recent folders
ui/search.odin       the two-tier filter and the completion menu
ui/audio.odin        playback, waveform peaks and their disk cache, clip export
ui/subprocess.odin   CreateProcessW with CREATE_NO_WINDOW, pipe reading
ui/tagger.odin       launches tag_job.py, parses its NDJSON, saves sidecars
ui/selftest.odin     the checks behind --selftest
ui/taxonomy.odin     GENERATED from mtag/taxonomy.py by ui/gen_taxonomy.py
tag_job.py           one tagging job as a child process
build.bat            regenerates taxonomy.odin, then builds both binaries
```

`mtag/` is unchanged and still owns the model, the encoders, training and the
vocabulary. **`mtag/taxonomy.py` is still the single source of truth for tags**
— after editing it, `build.bat` regenerates `ui/taxonomy.odin` automatically.

### Layout

One screen. The old Library / Tagging / Tag Map split is gone: those hid each
other, so tagging a track meant losing your place in the list.

```
top bar     search with operator chips, counts, Analyze, Save
rail        imported folders, then every tag with how many tracks carry it
list        virtualised — only the ~40 visible rows are drawn, never 1783
inspector   the selected track: tags, the vocabulary to click, model scores
dock        transport and waveform, always mounted, playback never stops
```

The inspector is a panel, not a page, so the list never moves under you.
Tab hides it. The rail's tag counts are new: you can see the shape of the
library before searching it, and clicking a tag toggles it as a filter.

### Measured

Against the real library, 1783 files:

| | |
|---|---|
| Scan, including reading 878 sidecars | **132 ms** |
| One keystroke re-filtering 1783 files | **0.35 ms** |
| Resident memory | **~85 MB** |
| Executable | 1.6 MB |
| Analyze one track (embedding cached) | 1.9 s end to end |

`"mario"` returns 276 files, which is exactly what the filesystem reports.

### Search

`+tag` requires, `|tag` accepts any, `-tag` excludes, bare words are text.
`tag:`, `name:` and `game:` still work. Completed filters become coloured chips
in the search bar; typing `+`, `|` or `-` opens a completion menu ordered so
tags present in this library come first.

Matching is two-tier, and this is deliberate: a bare word is a plain substring
against the path and the tags. Only when that finds **nothing at all** does it
retry allowing the letters to be spread through the file name. Applied by
default that forgiving pass turned `"mario"` into 443 hits out of 1783 when
only 276 files say Mario — a search that quietly mixes wrong answers into right
ones is worse than one that finds nothing.

### Things that bit, so they do not bite again

- **`core:os` process spawning flashes a console.** It does not pass
  `CREATE_NO_WINDOW` to `CreateProcessW`. `ui/subprocess.odin` calls
  `CreateProcessW` directly. Do not switch back to `os.process_start`.
- **`STARTF_USESTDHANDLES` needs a real stdin.** A NULL handle is not "no
  input", it is an invalid one, and the child can hang on it. It is pointed at
  `NUL`.
- **An `Allocator` holds a pointer to its arena.** The scan built the library in
  a local and stored `virtual.arena_allocator(&out.arena)` in it; once the
  worker returned, that pointer was into a dead stack frame. Reads still
  worked, so every scan test passed — the crash only came when a tag result
  tried to *allocate*. `lib_allocator()` now derives it from the live global.
  Never store an allocator in a struct that gets moved.
- **Freeing a string literal crashes.** `job.detail` was assigned a literal on
  start and freed on the next update. Every owned string on `Job` goes through
  `set_owned`.
- **The waveform worker reads `lib.tracks` by index.** A rescan frees that arena,
  so `poll_scan` calls `wave_quiesce()` and `reset_player()` before the swap.
- **Segoe UI has none of the media-control glyphs.** 54 of the icons came back
  as blanks. They are drawn as shapes in `ui/icons.odin` instead, which also
  keeps them sharp at any window scale.
- **The font atlas is rebuilt after a scan** from the characters the library
  actually uses, so Japanese titles render. CJK goes to a second atlas from Yu
  Gothic; `font_for()` picks per string.

### Still to do

1. **Drag a clip into Premiere.** Selecting a range on the waveform and
   exporting it to a wav works. Dragging that wav out of the window to another
   application does not — it needs a Windows OLE drop source, which raylib does
   not provide. The exported path is shown so it can be dragged from Explorer
   in the meantime.
2. **A folder picker.** Import is by dropping a folder on the window, typing a
   path, or clicking a recent one. There is no native browse dialog yet.
3. **Editing the tag library.** The rail lists tags and their counts but does
   not add, rename or delete vocabulary entries. `tag_library.json` is not read
   by the native app.
4. **Retrain from the app.** Still `venv\Scripts\python.exe train.py <library>`.
5. **Moving tracks into mood folders on save.** Not carried over.
6. The old browser stack is still in the repo — `app.py`, `desktop.py`,
   `launcher.py`, `templates/index.html`, `run-webview.bat`,
   `build-webview.bat`. Nothing in the native app touches them. They were
   renamed rather than deleted so the old workflow is still reachable.

---


## Codex implementation log — 2026-09-03 to 2026-09-04

This section records the desktop/application work completed after the original
handover was written. It is the current operational reference; some older
sections below still describe the pre-desktop browser workflow.

### Safety and backups

- Before implementation, a complete verified project backup was created at:
  `C:\Users\simsi\music-tagger-v2.backup-2026-09-03-complete`
- The backup contained 43,831 files and was made before the implementation
  changes. The predecessor project at `C:\Users\simsi\music-tagger` was not
  modified.
- All feature work remains uncommitted in the v2 repository so it can be
  reviewed or reverted deliberately.

### Current launch model

The application is now a Windows desktop window backed by the existing local
Flask application:

```
MusicTagger.exe / run.bat
        |
  venv/Scripts/pythonw.exe desktop.py
        |
  pywebview + embedded Edge/WebView2
        |
  Flask routes on a loopback-only ephemeral port
```

- `desktop.py` starts the local server and opens a pywebview desktop window.
- `launcher.py` is the small executable entry point. It locates the project
  beside `dist` and starts the managed virtual-environment runtime.
- `dist\\MusicTagger.exe` was built with PyInstaller as a windowed launcher. It
  intentionally depends on the project folder and its `venv`; it is not a
  self-contained model distribution.
- `run.bat` starts `pythonw.exe` and exits, so no Python terminal should remain
  visible.
- `build.bat` rebuilds the launcher executable when the launcher itself changes.
  UI/backend source changes are read directly by the managed runtime.
- A startup exception is written to `music-tagger-startup-error.log` and shown
  in a Windows dialog rather than silently disappearing behind `pythonw`.

### Desktop startup bug fixed

The native API object originally exposed its public `window` attribute to
pywebview. WebView2 recursively inspected that entire native object graph,
causing recursion errors and making every click show “Not Responding”. The
reference is now private (`DesktopApi._window`), so only callable API methods
are exposed to JavaScript.

### Library and playback UI

`templates/index.html` was substantially reorganized around a Soundly-inspired
library workflow:

- The Library view is for finding, selecting, and playing tracks/SFX.
- Tagging is a separate view and is never triggered by selecting a track.
- Tag Map/Node view remains separate.
- A shared bottom player remains mounted outside those views, so playback
  continues while switching between Library, Tagging, and Tag Map.
- The HTML audio controls are hidden; playback uses custom transport controls,
  waveform display, seek, zoom, rate, volume, previous, and next controls.
- Selecting a row only changes the current track and starts playback. It does
  not call `/api/analyze`.
- Music analysis is explicit through “Analyze for tags” or batch Analyze in the
  Tagging view. SFX tagging is manual and explicit.
- A row has a file drag handle for dragging an audio source to compatible
  external applications.

### Waveforms and clip selection

`mtag/audio.py` and `app.py` now provide waveform and editor-preview support:

- Scanning/importing a folder returns the file list immediately, then starts a
  background waveform warm-up for the imported files.
- Waveforms are cached in `cache/waveforms/` using absolute path, size, mtime,
  and point count, so unchanged files do not need decoding again.
- `/api/waveform` serves cached or newly generated peaks.
- All ffmpeg/ffprobe subprocesses use `CREATE_NO_WINDOW` on Windows, fixing the
  flashing terminal previously visible on track selection.
- Dragging over the bottom waveform selects a time range. A click without a
  drag still seeks.
- The selected range is rendered by ffmpeg as a PCM WAV in `cache/clips/` via
  `/api/clip`.
- Once rendering completes, “Drag selection to Premiere” becomes available. Its
  drag payload points to the generated short WAV, not the full source track.
- The external drag uses Chromium `DownloadURL`, URI, and plain-text payloads.
  Target software must accept one of those standard drag formats; the app does
  not currently implement a custom Windows OLE `CF_HDROP` provider.

### Persistent imported folders

- `app.py` remembers scanned folders in `libraries.json` (up to 12 recent
  valid folders).
- The sidebar displays those folders under Imported Libraries and clicking one
  reopens/scans it.
- `libraries.json` is user-local and ignored by Git.

### TagSpaces-compatible search

`mtag/search.py` and the Library UI now use a local indexed search model:

- Search operates against the in-memory result set after import, so typing does
  not rescan the filesystem.
- Bare terms use tolerant fuzzy matching against filename, relative path, full
  path, and tags.
- `+tag` means the tag is required (AND).
- `|tag` means at least one OR tag must match.
- `-tag` excludes a tag.
- Existing `tag:`, `game:`, and `name:` forms remain supported by the backend.
- The search bar contains completed tag chips, visually separating tag filters
  from free text. Chips are operator-colored and removable.
- Typing `+`, `|`, or `-` opens a completion menu. Choosing a result turns it
  into a chip.
- Clicking a tag in the tag library or on a track adds it as a search chip.

This behavior follows TagSpaces’ documented search composition: `+` required,
`|` optional/OR, `-` excluded, fuzzy free text, and tag suggestions during
query composition. References:

- https://docs.tagspaces.org/search/
- https://docs.tagspaces.org/ui/taglibrary/
- https://docs.tagspaces.org/tagging/

### Tag library and manual tagging

The Library now has a summonable right-side Tag library panel:

- Open it with the **Tag library** button in the top bar.
- It shows the complete default groups even when a tag has not been used on any
  imported track: Mood, Sound, SFX, Game, and Favorites.
- It also incorporates custom/unknown tags found in imported TagSpaces
  sidecars.
- Favorite symbols include `⭐`, `★`, `🌟`, and `☆`; they are displayed as
  favorite tags and preserved as user-owned metadata.
- Click a tag to search it.
- Drag a tag onto a track to add and save it immediately.
- Add creates a tag in a selected group.
- Edit renames a library entry.
- Delete removes the entry from the library definition but deliberately does
  not rewrite or erase that tag from existing audio files.
- The editable library is persisted in `tag_library.json`, which is ignored by
  Git. If it does not exist, the built-in taxonomy is used as the initial
  library.
- Backend endpoints are `GET/POST /api/tag-library` and `GET /api/libraries`.

### TagSpaces sidecars and metadata preservation

`mtag/sidecar.py` was extended/verified to:

- Read all TagSpaces sidecar tag titles, not only the model’s Mood/Sound tags.
- Keep unknown/custom tags visible and searchable.
- Preserve star/favorite emoji tags, ratings, Game tags, and unrelated metadata.
- Read SFX tags separately from music taxonomy tags.
- Deduplicate a tag when a manual drag/save would otherwise re-add a tag that
  already exists in the preserved sidecar content.
- Continue mapping known historical aliases to canonical project tags.

### Lazy model and VRAM behavior

The model is no longer loaded by desktop startup or normal browsing:

- Application state begins as `idle` with the message “Models load only when
  you start tagging.”
- Scanning, search, playback, waveform generation, and manual SFX tagging do
  not load the encoder.
- `/api/analyze` and `/api/analyze-batch` call the on-demand loader only after
  an explicit Tagging action.
- Leaving Tagging calls `/api/unload-model`, clears encoder/tagger/cache
  references, runs garbage collection, and calls `torch.cuda.empty_cache()`.
- A direct idle-state check reported CUDA allocated = 0 and reserved = 0.
- Importing the `torch` package to report device availability is not the same
  as loading the encoder weights; no model weights are moved into VRAM in idle
  mode.

### Files changed or added by the implementation

```
.gitignore             ignores local libraries/tag-library/cache/build data
README.md              desktop/runtime and workflow notes
app.py                 desktop routes, lazy model, waveform cache, clip export,
                       persistent folders, editable tag-library API
desktop.py             pywebview host, private native bridge, startup logging
launcher.py            windowed managed-runtime launcher
build.bat              executable build command
run.bat                no-console desktop startup
requirements.txt       desktop/runtime dependencies
templates/index.html   Library/Tagging/Tag Map UI, search chips, tag panel,
                       shared player, waveform selection and drag workflows
mtag/audio.py          hidden ffmpeg, waveform generation, clip export
mtag/search.py         TagSpaces-style operators and fuzzy matching
mtag/sidecar.py        all-tag preservation and duplicate-safe writes
mtag/taxonomy.py       Mood/Sound/SFX/Game library vocabulary and aliases
tests.py               search, waveform clip, sidecar and existing ML checks
```

### Verification completed

- `python -m compileall` passes for the modified Python modules.
- Browser JavaScript extracted from `templates/index.html` passes `node --check`.
- Tag library endpoint returns 5 default groups and 98 default tags.
- Idle model check reports zero CUDA allocation/reservation.
- Waveform and clip regression checks pass, including a short exported range.
- Full `tests.py` suite passes, including sidecar round-trips, tag aliases,
  SFX separation, search operators/fuzzy matching, waveform generation, clip
  export, game detection, organization, fusion, and model probes.

### Recommended next work

1. Test the native executable manually with the user’s actual Premiere version,
   because external applications differ in which Chromium drag payload they
   accept. If Premiere rejects the generated clip drop, implement a native
   Windows OLE drag source in `desktop.py`.
2. Add an explicit Tag Library import/export format if tags need to be shared
   with TagSpaces installations rather than only read from sidecars.
3. Consider replacing the Python/pywebview shell with a true native frontend
   only after the current workflow is feature-complete; the current host keeps
   the heavy ML/runtime work out of the UI process while retaining a small
   executable entry point.
4. Keep the full verified backup untouched until the new search/tag-library and
   Premiere workflows have been exercised against the real media library.
Auto-tags a game-soundtrack library with Mood and Sound tags, writes them back as
TagSpaces sidecars, reads the game name off the filename or folder, and files
tracks into folders named after their primary mood.

- **Code:** `C:\Users\simsi\music-tagger-v2` (git, 6 commits)
- **Library:** `H:\Media Browser\Mega Music Pack`
- **Predecessor:** `C:\Users\simsi\music-tagger` — untouched, kept as reference
- **User:** Zengane. Video editor; the tags are editing cues, not musicology.

---

## Run it

```bat
cd "C:\Users\simsi\music-tagger-v2"
run.bat
```

Creates the venv on first run, then serves the review UI at `http://127.0.0.1:5000`.

| Command | What it does |
|---|---|
| `run.bat` | Review UI |
| `venv\Scripts\python.exe train.py "H:\Media Browser\Mega Music Pack"` | Retrain from sidecars |
| `venv\Scripts\python.exe bakeoff.py "H:\Media Browser\Mega Music Pack"` | Re-score all encoders |
| `venv\Scripts\python.exe fix_tags.py "<library>" [--apply]` | Rewrite tags missing from the tag library |
| `venv\Scripts\python.exe tests.py` | 96 checks |

**UI flow:** set *Folder* (music to tag) and *Library root* (`Mega Music Pack`) →
tick *untagged only* → Scan → Analyze all → review → tick *move into mood folders
on save* → Save all analyzed → Retrain.

Keys: `↑`/`↓` move, `Enter` save and advance, click a tag to toggle.

---

## Current state

Model: **fusion**, 4096-dim, trained on **878** tracks.

```
macro AP 0.597 · macro AUC 0.916 · precision 0.50 · recall 0.74 · 33 probes
zero-shot fallback: Loss, Romantic, Trappy, Wintery
```

Read that as: it suggests about three quarters of the tags the user would have
applied, and about half its suggestions survive review. It is a review tool, not
an unattended one.

### Which tags to trust

| Trust | Tags |
|---|---|
| Good (AP > 0.65) | Victory, Orchestral, Rock-Metal, Fantasy, Goofy, Oriental, Hype, Chill, Childish, Serene, Jazzy, Ambient |
| Middling (0.5–0.65) | Epic, Bombastic-Heavy, Awkward, Medieval, Funky, Weird, Adventure, Folk, Dreamy, Ominous, Electronic, Choir, Tribal, Tension |
| Check by ear (< 0.5) | Chiptuney 0.45, Melancholic 0.43, Hopeful 0.41, Beachy 0.37, **Build-Up 0.34**, **Mysterious 0.31** |

**Vocals is special:** precision 0.92, recall 0.37. It exists to filter tracks
*out* of an edit, so its threshold leans to precision (F-0.6 in
`probes.TAG_BETA`, against F-1.5 everywhere else). When it fires it is almost
always right; it misses about two thirds of vocal tracks. Only 30 examples — the
honest fix is a dedicated vocal detector (source separation on the vocal stem),
not more threshold tuning.

### The new batch

`Mega Music Pack/Untagged/` holds **925 tracks** the user dropped in and has not
tagged yet. That is the immediate job. Game detection covers 100% of it.

---

## How it works

```
audio ── ffmpeg ──> 12 windows spread across the whole track
                          |
              muq-mulan + muq + clap-music (frozen)
                          |
              mean + std pooled, concatenated, L2 normalised   (4096-dim)
                          |
        ┌─────────────────┴──────────────────┐
   probe per tag                      zero-shot text
   (>= 12 examples)                   (rarer tags)
```

One independent logistic regression per tag, trained on the user's own sidecar
labels. `C` picked by cross-validation, `class_weight="balanced"`, per-tag
thresholds tuned on out-of-fold predictions.

### File map

```
mtag/taxonomy.py   tag vocabulary, game phrases, skip rules — most edits land here
mtag/sidecar.py    TagSpaces sidecar read/write, tag aliasing
mtag/audio.py      ffmpeg decode, whole-track windowing, file discovery + skipping
mtag/encoders.py   the four encoders and the fusion wrapper
mtag/dataset.py    label collection, embedding cache, cache re-keying on move
mtag/probes.py     per-tag training, CV, threshold selection, TAG_BETA
mtag/model.py      the saved tagger, zero-shot fallback heads
mtag/gametag.py    game name from filename or folder
mtag/organize.py   mood-folder filing
bakeoff.py  train.py  fix_tags.py  app.py  tests.py
```

---

## Why it is built this way

### v1 was broken five ways

v1 asked zero-shot CLAP "does this sound like *goofy silly playful cartoon
comedic funny music*?" and thresholded the answer.

1. **It only heard 10 seconds.** `laion/clap-htsat-unfused` is configured
   `max_length_s=10, truncation="rand_trunc"`. v1 decoded 60s; the processor
   discarded fifty of them at random.
2. **It ran on the CPU.** The venv had `torch==2.10.0+cpu`. `run.bat` probed
   `cuda.is_available()` *before* installing torch, so the CUDA branch misfired.
3. **Min-max per category** forced one mood to 1.0 and one to 0.0 in every file.
4. **Thresholds fit on positives only** — 20th percentile of positive logits,
   with negatives never consulted.
5. **The vocabulary is personal.** Build-Up, Awkward, Bombastic-Heavy are editing
   cues. No zero-shot model knows what they mean here.

Meanwhile the library already held ~857 hand-tagged tracks. v2 treats that as
training data. That is the whole idea; don't regress to zero-shot.

### The encoder was chosen by measurement, not by paper

Scored on the library's own labels (`results/bakeoff.json`):

| encoder | dim | macro AP | AUC | prec | rec |
|---|---|---|---|---|---|
| **fusion** | 4096 | **0.591** | 0.917 | 0.51 | 0.74 |
| muq-mulan | 1024 | 0.559 | 0.909 | 0.48 | 0.73 |
| clap-music | 1024 | 0.526 | 0.893 | 0.44 | 0.73 |
| muq | 2048 | 0.521 | 0.889 | 0.44 | 0.71 |
| mert | 2048 | 0.445 | 0.871 | 0.40 | 0.69 |

No single encoder won everywhere. MuQ-MuLan takes most tags; MuQ is better at
Fantasy, Ambient and Medieval; CLAP-music is much better at Chiptuney. Fusing
moved Fantasy +0.16, Medieval +0.13, Chiptuney +0.13.

**MERT is excluded on purpose:** +0.003 AP for another 2048 dimensions and
another pass over every file. Don't add it back without re-measuring.

### Other settled decisions

- **Thresholds lean to recall** (F-1.5). A missing tag is invisible in TagSpaces;
  a wrong one is one click. `Vocals` inverts this — see above.
- **Folder names are not labels.** They agree with the sidecars 822/858 of the
  time; the 36 disagreements are deliberate retags.
- **Game tags are never predicted from audio.** Two Mario Galaxy tracks sound
  nothing alike. Read from the filename or folder, or not at all.
- **Folders outrank filenames** for game detection — a drop is named after its
  game. But a *known* game in a filename beats a *guessed* folder name, so
  `JimmyHere music/` doesn't swallow the Mario Galaxy tracks inside it.
- **Outermost folder wins**, not innermost: `Bayonetta/DISC 3/` → Bayonetta.
- **Moves are planned then confirmed.** Sidecars travel with the track,
  collisions are refused, and folders the user made are never deleted.

---

## Library facts worth knowing

- ~1783 audio files: ~858 tagged and filed by mood, 925 in `Untagged/`, 40 in `SFX/`.
- Mood folders: Adventure, Awkward, **Build up** (not "Build-Up"), Chill, Epic,
  Goofy, Hype, `Hype - Ominous`, Melancholic, Mysterious, Ominous, Serene,
  Tension, Victory. Bombastic-Heavy, Hopeful and Loss have no folder yet.
- **SFX is skipped everywhere** until it gets its own model — one-shot hits and
  drones don't fit a music taxonomy. Opt out with `skip_dirs=()`.
- **"Audio Extracted" files are skipped.** The user renders stems out for
  Audition and they land next to the original.
- **Tag aliases** (`taxonomy.TAG_ALIASES`, `GAME_ALIASES`): four names were typed
  into sidecars that the tag library doesn't contain. `fix_tags.py --apply` has
  been run, 16 sidecars corrected, nothing unknown remains. Reading still maps
  them so this can't silently recur.
- **`Penny-Big-Breakaway` is canonical**, *not* the tag library's
  `Penny's-Big-Breakaway`. TagSpaces wouldn't match the apostrophe form, so the
  user renamed it: 44 files use the short form, 0 use the library's. Generated
  tags drop apostrophes for the same reason.
- **N64-Zelda means Ocarina + Majora** deliberately — similar OSTs, one tag. Do
  not retag those 72 files. `legend of zelda` is *not* a match phrase; it used to
  be, and it would have put 123 Breath of the Wild tracks on that tag.

---

## Traps

- **Never let pip resolve torch freely.** `muq` → `x_clip` → `torchvision` will
  pull a CPU wheel over the CUDA build, silently, and everything still "works" at
  roughly 40x slower. `requirements.txt` pins `+cu130` local versions so pip
  refuses the substitution. This is exactly how v1 lost the GPU. `tests.py`
  asserts CUDA is visible.
- **Python 3.12 only.** 3.13+ has no matching CUDA torch wheels.
- **The Windows console is cp1252.** Filenames contain `⧸`, `｜`, `＂` and
  Japanese. CLI entry points must call `console.init()` or one filename kills the
  whole run.
- **The Windows filesystem is case-insensitive** — it bit one test that created
  two files differing only in case.
- **transformers 5.x renamed CLAP's `audios=` to `audio=`** and moved the
  projected embedding onto `.pooler_output`.
- **Zero-shot uses `meta["text_slice"]`, not "the first half".** With three
  encoders stacked, the text-comparable block is columns 0:512 (MuQ-MuLan's mean
  half). Encoders declare this via `text_slice()`.
- **Restart Flask after editing `app.py`.** There is no reloader; a stale process
  cost time once already.
- **MuQ weights are CC-BY-NC 4.0.** Fine for a personal library, not a product.

---

## Caches

`cache/<encoder>/*.npy`, keyed by path + size + mtime. Moving a file re-keys its
entries (`dataset.rekey_caches`) so it isn't re-embedded.

`cache/fusion/` is a second copy of the concatenated vectors, written only by the
app (`app.py:_embed`); `train.py` and `bakeoff.py` skip it via
`caches_internally` and read the three part caches instead. Harmless, ~8 MB, and
it makes review one file read instead of three. Delete it freely.

Re-embedding the whole library costs roughly 40 minutes on the RTX 3070 Ti.

---

## Open items

1. **Tag the 925 tracks in `Untagged/`.** The actual job.
2. **Get the new game tags into TagSpaces.** 14 new games (Bayonetta, Terraria,
   TF2, VA-11-Hall-A, Wii-Sport-Resort, Legend-Of-Zelda-Breath-Of-The-Wild,
   Mario-Kart, Wario-World, JimmyHere, Orange-Lounge, Yosumin, Blasphemous,
   Hello-Baby, Mario-64), plus dropping the stale `Penny's-Big-Breakaway` entry.
   - `tsTagLibrary` lives in TagSpaces' Chromium localStorage
     (`AppData\Roaming\TagSpaces\Local Storage\leveldb`) alongside locations,
     settings and history. **Do not write to it** — corruption risk, and the app
     holds a lock while running.
   - `.ts/tsl.json` in the location auto-loads per-location tag groups, refreshed
     by Tag Library → *Reload Location Tags*. The installed build (6.9.2)
     references `tsl.json`, but the feature is **Pro-gated** and it is unconfirmed
     whether the user holds a Pro licence. **Ask before building this.**
   - Fallback that works on any edition: regenerate the export JSON and import it
     by hand. Nothing is written yet; the decision sits with the user.
3. **Vocals recall is 0.37.** Needs a real vocal detector, not more tuning.
4. **SFX tagging** — deliberately out of scope; needs its own taxonomy and model.
5. Untrainable tags: Loss (8), Romantic (7), Trappy (6), Wintery (5). The
   zero-shot fallback fires them at about 3x prevalence for manual review. They
   improve on their own as the user tags more.
