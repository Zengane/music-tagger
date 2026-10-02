# Downloads (yt-dlp)

Download playlists and videos, tag them, and file them into the library.
Laid out like Stacher. Open it with the download button in the top bar,
left of the folder path. Esc goes back to the library.

## How to use it

1. Paste links into the box and press Enter. Several at once is fine: one per
   line, or Ctrl V anywhere on the screen.
2. Each link becomes a card. The app reads the link (titles, how many tracks,
   the thumbnail) and guesses:
   - the **name**: the game or album, from the playlist title, with "OST",
     "Soundtrack", "Original Game Soundtrack", "[Full Album]", "(HQ)" and the
     like taken out. `Lethal League Blaze OST` becomes `Lethal League Blaze`.
   - the **category**: Game OST when the titles say OST, Soundtrack, BGM and
     so on; Music otherwise; Video in video mode.
   - each track's **title, artist and number**:
     `Bignic - Ruiner [Lethal League Blaze OST]` becomes track 3, artist
     `Bignic`, title `Ruiner`.
3. Change anything before it starts: the name (click it), the category, Audio
   or Video, the format. The arrow opens the track list: untick tracks, click a
   title or artist to change it, choose how titles are read ("Artist - Title",
   "Title - Artist", keep whole), set the album artist.
4. Press **Download** on a card, or **Download all**. The first time, the app
   asks for the download folder.

Every playlist gets its own folder: `<download folder>/Game OSTs/<name>/`, and
each track is named `01 - Title.opus`. Both patterns are in **Options**.

A long video with chapters (a "full OST" upload) is cut into one file per
chapter, each tagged as its own track. Untick "One file per chapter" to keep
it whole; the chapters then stay in the file as markers.

## Formats

Audio, default **M4A for Premiere**: YouTube's own AAC stream (about 128
kbps), put into an M4A as it is, nothing converted. Premiere and everything
else open it. When a video has no AAC stream, the original is converted to AAC
at 256 kbps. Also: **Original (Opus)**, the stream as YouTube has it, usually
Opus, which Premiere does not open; MP3 320; FLAC; Opus; WAV.

Until 2026-10-02 the default was the original stream, so downloads came out
as Opus. A queue saved before then switches to M4A when it loads.

**Replace N as M4A**: a finished card whose files are in another format than
the card's offers this. Each track is downloaded again in the card's format.
The sidecar (saved tags, markers) moves to the new file, and the old file goes
to the Recycle Bin, never deleted outright: on a drive with no Recycle Bin the
old file stays. In the open library the old entry hands its tags, saved or
not, to the new one and leaves the list. Change the card's format first to
replace with something else (MP3, FLAC).

Video, default **Best quality** (often AV1 or VP9 in MKV). Also 4K, 1440p,
1080p, 720p, 480p, and **MP4 for Premiere** (H.264 and AAC, which every editor
opens).

## Tags

Written with ffmpeg, the sound copied untouched: title, artist, album, album
artist, track (`3/20`), disc, genre (`Game Soundtrack` for game music), year,
and the source link as the comment. The thumbnail becomes the cover, cropped
square. MP3 tags are ID3v2.3, which Windows Explorer and Premiere read.

## After the download

When the download folder is inside the open library, the new folder is scanned
in. Game soundtracks get their game tag (`Lethal-League-Blaze`) like a tag
added by hand: **nothing is written to the sidecars until you press Save.**

Nothing is ever overwritten. A file with the same name gets ` (2)`.

Run a playlist again and only new tracks download: a track already in its
folder (same name in any format, or the same video by its id) is skipped. A
finished card where you tick more tracks offers **Get N more**.

**Stop** stops yt-dlp and ffmpeg at once. Half-done files stay in the cache and
resume next time. Closing the app stops downloads; they wait as **Resume**.

A video that appears twice in a playlist is marked "repeat of 12" and starts
unticked. (A 331-track playlist had 29 repeats; before this fix the second
copies showed "already there" or never moved.)

YouTube sometimes refuses a download for a while (HTTP 403, 429), more often
on long playlists. Such a track is tried again after 5, 20 and 60 seconds.
If it still fails, its row says why; **Get N more** tries the failed ones
again later. A private or deleted video is not retried.

**"Sign in to confirm you're not a bot"** (or HTTP 429): YouTube has flagged
the connection, after about 630 videos in one day on 2026-10-02. Every video
then fails, and asking again keeps the block going. So the first such answer
stops the whole run, and the cards say what happened. The block lifts by
itself, usually within hours; signing in with a browser's cookies (Options)
also gets past it. **Pause between videos** (Options, on by default) waits 2
to 5 seconds before each video so a big playlist is less likely to trigger it.

Downloads run at normal priority, unlike analysis, which runs below normal.
Below normal, they starved while other programs were busy: 6 tracks took
27.6 s at normal priority and were not done after 9 minutes below normal.

## Options

- Where files go: the download folder, and a folder pattern per category.
  `{album}` is the card's name; also `{artist}`, `{uploader}`, `{year}`,
  `{playlist}`.
- File names: `{track:02}`, `{title}`, `{artist}`, `{album}`, `{disc}`, `{year}`.
- Tags: write tags, cover art, square cover, subtitles in videos, the genre for
  game music, more words to take out of names.
- After downloading: add to the library, tag game soundtracks.
- Downloading: how many at once (3), browser cookies for age-restricted or
  members-only videos (Firefox works best), a speed limit, more yt-dlp options.

Stored in `downloads.json` beside the app, with the list of cards.

## yt-dlp

On every start the app runs `yt-dlp -U` in the background, then reads the
version; the status line at the bottom says what happened. A yt-dlp installed
with pip cannot update itself this way; the app then uses it as it is.

When yt-dlp is not found (not in `bin\`, not on PATH), the app downloads it
from the yt-dlp releases on GitHub into `bin\` with curl, which Windows 10 and
later include. `setup.sh` does the same on macOS and Linux. yt-dlp is
Unlicense (public domain); nothing is bundled.

## How it works

- `ui/downloads.odin`: the screen, the queue, yt-dlp updates and install.
- `download_job.py probe`: reads links with `yt-dlp -J --flat-playlist`, saves
  a PNG thumbnail, guesses names (`mtag/downloads.py`).
- `download_job.py run --plan`: one yt-dlp per track (3 at a time), then
  ffmpeg for the tags and cover, then the move into place. Progress is one
  JSON line per event. A line `stop` on stdin stops everything.
- Both use only the Python standard library, so they run before the AI
  environment is installed.

## Checks

```bat
venv\Scripts\python.exe tests_download.py
mtag-test.exe --downloadcheck "<empty folder>" "<link>" [--run 3] [--library]
```

`tests_download.py`: name guessing on the test playlist's titles and common
upload patterns, and a full run against a stand-in yt-dlp (no network): tags,
cover, folder, skipping on a second run, never overwriting.

`--downloadcheck`: the real screen in a hidden window, with real links:
update check, reading, screenshots in `work\downloads-*.png`; `--run 3`
downloads the first 3 tracks of each card; `--library` also checks the scan
and the game tag.

Measured on 2026-10-01 (RTX PC, home connection):

| | |
|---|---|
| Read the 20-track test playlist | 1.8 to 2.0 s |
| Download, tag and file 3 tracks (Opus) | 4.1 s |
| Second run, same tracks | 0.2 s (all skipped) |
| Celeste full OST, one video, 2 of 21 chapters | 17 to 73 s (the whole video downloads) |
| Stop during a download | job gone in 0.7 s, no yt-dlp or ffmpeg left |
| Install yt-dlp when missing | 17.8 MB into `bin\`, then works |

## Not done yet

- Only YouTube was tried. Other sites yt-dlp supports should work; names are
  guessed the same way.
- A full-OST video downloads whole even when only some chapters are wanted.
- No Windows `setup.bat` exists (the README names one); the app installs
  yt-dlp itself.
