# Music Tagger — what it is

A desktop app for finding the right sound in a library too big to remember.

It listens to every file, tags it, and lays the whole collection out as a map
you can navigate. Then it hands the file to whatever you are editing in.

Everything runs on your own machine. Nothing is uploaded, and there is no
account.

---

## The problem it solves

A few thousand music tracks and sound effects, with names like `Boom69.wav`,
`03 - On Your Way.mp3` and `711804__leonseptavaux__drone_1.wav`.

You know the sound you want. You cannot remember which file it is, and the
filename will not tell you. So you audition folders one clip at a time, and the
good file you found six months ago stays lost.

Tagging by hand fixes that, and nobody does it, because tagging four thousand
files by hand is not work anyone finishes.

---

## What it does

### Tags files by listening to them

A model scores each track against 33 mood and sound tags — Epic, Melancholic,
Orchestral, Chiptuney, Build-Up, and so on.

It only applies a tag when that tag's accuracy was **measured** to be good
enough. The rest are offered as suggestions, ranked by how close they came, so
accepting one is a click. Three tags never apply themselves at all, because
their accuracy never reached the bar.

The vocabulary is yours. The shipped model was trained on one person's library
and their words; the point is that "Build-Up" means what *you* mean by it, and
you can retrain it on your own tags.

### Puts the whole library on a map

Two maps, and they answer different questions.

**By tags** — tracks cluster by how they are described. The corner where the
goofy chiptune lives, the ridge between Ominous and Tension.

**By sound** — tracks cluster by what they actually sound like, whether or not
anyone has tagged them. This is the one that works on a folder you imported
five minutes ago.

The sound map names its own regions. It asks the audio what it is against a
vocabulary of plain descriptions, then puts a signpost where those files sit —
*heavy impact*, *riser*, *whoosh*, *baby crying*. Nobody types those labels.

Searching does not rebuild the map. It lights up what matches and dims the
rest, so the shape you have learned stays put.

### Files things where they belong

The library is arranged by mood on disk. When a track is tagged, it can be
moved into the folder it was tagged with.

It always shows you the plan first — how many files, and where they are going —
and it never overwrites anything. A name clash is refused and reported, not
resolved by guessing. Sidecars and cached analysis follow the file, so nothing
is re-analysed and nothing is lost.

### Sends a clip straight to Premiere

Select a span in the waveform and send it. The original media lands on the
timeline at the playhead, with handles still there to trim back out to. No
rendered copy, no round trip through Explorer.

You can also drag any file out of the app into anything else.

### Sound effects, which are a different job

Effects get their own treatment: suggestions from filenames and folder names,
a map of their own, and silence-based splitting that turns one long recording
into a folder of individual clips.

### Four ways to look at the same library

**List** for detail, **Grid** for thumbnails, **Map** for shape, **Tag** for
working through a folder of new files in bulk.

---

## How it works, briefly

1. Every file is turned into a **vector** — a long list of numbers describing
   how it sounds — by an audio model.
2. Those vectors are **cached** on disk, keyed by the file's path, size and
   date, so nothing is ever analysed twice.
3. Small **trained probes** turn a vector into tag scores. Each has its own
   threshold, set where its measured accuracy justified it.
4. The map **flattens** those scores to two dimensions for drawing.
5. Tags are written as **TagSpaces sidecars** — one small JSON file per track,
   in a `.ts` folder beside the audio.

That last point matters more than it sounds. Your tags are files. They travel
with your audio when you move it, other tools can read them, and there is no
database to corrupt or migrate. If you delete the app tomorrow, your tags are
still there.

The heavy lifting is Python, launched as a short-lived job and then gone —
nothing is resident while you browse. The app itself is native code and draws
in about a millisecond a frame.

---

## What it will not do

- **Nothing is written until you press Save.** Tagging a hundred files changes
  nothing on disk until you say so.
- **It never overwrites a file.** Filing refuses a name clash rather than
  resolving it.
- **It does not phone home.** No account, no telemetry, no upload. The only
  network use is downloading the models once, and one loopback connection to
  Premiere on your own machine.
- **It will not pretend to be certain.** Where accuracy was measured, the
  number is stated, including where it is poor.

---

## Honest limits

- **Windows only**, today.
- **The install is large.** The Python environment is about 3.5 GB, and the
  models add several GB more.
- **A GPU makes tagging roughly forty times faster.** It works without one. It
  is slow without one.
- **The effects map is useful, not magic.** Asked how often a sound's nearest
  neighbour on the map is genuinely from the same family, it scores 16.2%,
  against 0.16% for chance and 32.7% for what the model itself knows. That is a
  large improvement on where it started and still leaves room.
- **The shipped model reflects one person's taste.** Retraining on your own
  library is expected, not exotic.

---

## Where to go next

- `README.md` — installing it, building it, and the checks you can run
- `docs/why-v2.md` — why the first version did not work, which is most of what
  is worth knowing about the approach
- `docs/roadmap.md` — where this is going: images, video, 3D, and other
  platforms
- `docs/model-licences.md` — every model, its licence, and whether it can be
  used commercially
- `HANDOVER.md` — the full technical history, for anyone working on the code
