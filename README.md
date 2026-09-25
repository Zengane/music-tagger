# Music Tagger

A desktop app for browsing, tagging and finding things in a large library of
music, sound effects, images, video, 3D models and documents — built for
finding the right file quickly while editing, rather than for organising files
as an end in itself.

It tags tracks with a model trained on a real hand-tagged library, lays the
whole collection out as a map you can navigate by ear, and sends a chosen span
straight to the Premiere timeline.

Windows, macOS and Linux. Written in [Odin](https://odin-lang.org) with
raylib; the analysis is Python. Everything runs on your own machine.

**New here?** [docs/overview.md](docs/overview.md) describes what the app does
and why, without the build instructions.

## What it does

- **Tags music by listening to it.** A small trained model scores each track
  against 33 mood and sound tags. Only tags whose accuracy was measured to be
  good enough apply themselves; the rest are offered as suggestions, ranked.
- **Tags are files, not a database.** Everything is written as TagSpaces
  sidecars — one JSON file per track in a `.ts` folder beside the audio — so
  your tags travel with your files and other tools can read them.
- **Two maps.** One places tracks by the tags they carry; the other by how the
  audio actually sounds, so it works on a folder nobody has tagged yet.
- **Files music into folders by mood**, always showing you the plan first and
  never overwriting anything.
- **Sends a selection to Premiere** — the original media, with handles, placed
  at the playhead.
- **Sound effects** get filename and folder based suggestions, silence-based
  splitting, and their own map.
- **Images, video, 3D models and documents** are tagged too. What can be
  measured is measured — green and blue screens, alpha channels, black
  backgrounds for Screen blends, flashes, loops, cuts, colours, vertical
  video, frame rate. What cannot is asked of an image model: muzzle flash or
  explosion, drone shot or close-up, meme or stock photo. Each picture gets a
  one-line description, and any text in it is read (OCR), so a meme is found
  by what it says.
- **Search by description.** Type "explosion on black", "drone shot of a
  harbour" or "tense string build-up" and it finds files by what they look
  like, sound like or say, whatever they are called.

Nothing is written to your library until you press Save.

## Installing

Download the release for your system, unzip it anywhere, and run
`MusicTagger.exe` (Windows) or `./MusicTagger` (macOS, Linux). Nothing is
installed and nothing is written outside the folder — delete it to remove it.

For the AI features, run `setup.bat` (Windows) or `./setup.sh` (macOS, Linux)
once. It needs Python 3.12 or 3.13, builds the Python environment, and finds or
explains how to get ffmpeg. On macOS the AI features need Apple Silicon and
macOS 14 or newer: PyTorch no longer supports Intel Macs.

**Two things worth knowing before you do:**

- The Python environment is about **3.5 GB**, and the models add several GB
  more in your home folder (`.cache/huggingface`) — on Windows that is your
  **C: drive**, wherever you installed the app. Check you have room.
- A CUDA GPU makes tagging roughly forty times faster. It works on the CPU;
  it is just slow. Apple Silicon Macs use their own GPU for the image models.
- **Speed or accuracy:** Settings → Analysis models → Fast, Balanced, Best, or
  Auto (the default, picked from your GPU and memory). It decides the image,
  caption, text and sound-search models; see `docs/audio-models.md`.

If something does not work, run `diagnose.bat` / `./diagnose.sh` and read
`diagnose.txt`. The app also writes `logs/musictagger.log` on every run.

## Building

Needs [Odin](https://odin-lang.org). On Windows, with the app closed:

```bat
build.bat
```

On macOS and Linux:

```sh
./build.sh
```

Linux also needs the X11 and OpenGL development headers raylib links against
(on Ubuntu: `libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev
libgl-dev`).

Or directly:

```bat
odin build ui -out:MusicTagger.exe -o:speed -subsystem:windows -resource:app.rc
odin build ui -out:mtag-test.exe -o:speed
```

## Checking it works

Most of what this app claims is measurable, and there is a mode for each.
None of them need the window.

```bat
mtag-test.exe --selftest "<your library folder>"    everything
mtag-test.exe --audiocheck "<library>"    which files can be played as-is
mtag-test.exe --rescancheck "<library>"   the library being replaced underneath
mtag-test.exe --filingcheck "<library>"   plan, move, rescan, rebuild
mtag-test.exe --windowcheck               the layout at every window width
mtag-test.exe --games / --soundmap / --drops / --benchmark

venv\Scripts\python.exe tests_filing.py   moving files, on a throwaway copy
venv\Scripts\python.exe sfx_map_bench.py  how coherent the effects map is
venv\Scripts\python.exe tests.py          the Python side
venv\Scripts\python.exe tests_media.py    measured tags on generated media
venv\Scripts\python.exe tests_media_models.py  the model plumbing, offline
venv\Scripts\python.exe tests_semantic.py search-by-description ranking
```

(On macOS and Linux: `./mtag-test` and `venv/bin/python`.)

## How good is the tagging, honestly

Thresholds are set per tag at a measured precision of 0.60. On the library it
was trained on it applies 2.9 tags per track where a person applied 3.1 — of
those, about 1.8 are right and 1.2 want removing. Three tags never apply
themselves because their probes never reached that precision.

The effects map is weaker, and the number is worth stating plainly. Asking
whether a sound's nearest neighbour on the map comes from the same family, over
6568 effects in 93 filename-derived families:

| | |
|---|---|
| chance | 0.16% |
| what the encoder knows | 32.7% |
| the map, as 2D t-SNE | 9.4% |
| the map now, as 2D UMAP | 16.2% |

So the layout improved by about 70%, and the remaining gap is the encoder's,
not the projection's. `sfx_map_bench.py` reproduces all of that.

## Training your own model

The shipped model was trained on one person's library and their vocabulary.
Yours will differ. With a few hundred hand-tagged tracks:

```bat
venv\Scripts\python.exe train.py "<your library folder>" --encoder fusion
```

`docs/why-v2.md` explains why the first version of this did not work, which is
most of what is worth knowing about the approach.

## What is bundled

`premiere/ZenDrop` is a small Adobe CEP panel that receives clips from the app.
Its installer copies it into your Adobe extensions folder and sets a per-user
registry flag so Premiere will load an unsigned panel. Both are reversible by
deleting the folder and the flag.

## Licence

MIT — see [LICENSE](LICENSE). The models it downloads and ffmpeg are not
distributed with it and carry their own licences.
