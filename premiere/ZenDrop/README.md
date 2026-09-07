# Zen Drop

Send a file from Listary (or anything else) straight onto the Premiere timeline,
into a fixed bin, on the first track that has room at the playhead. Nothing gets
overwritten and nothing gets rippled.

## Parts

| Part | What it does |
| --- | --- |
| `client/` | The panel. Runs a loopback HTTP listener on 127.0.0.1. |
| `host/host.jsx` | Import, free-track search, placement. |
| `bridge/ZenDropSend.exe` | Tiny stub Listary runs. Forwards the path to the panel. |

Installed copy Premiere loads: `%APPDATA%\Adobe\CEP\extensions\ZenDrop`
Both must be kept in sync.

## Why it does not use the native Insert/Overwrite buttons

The Source Monitor only offers Insert (`,`) and Overwrite (`.`). Insert ripples
every clip to the right of the playhead. Overwrite destroys whatever is under
the clip. Neither looks for a free track. Zen Drop finds a span that is already
empty and only then calls `overwriteClip`, so overwrite has nothing to destroy.

## Free-track rule

1. Start = playhead, frame-aligned. Length = the item's in/out points.
2. Walk video tracks from V1 upward. A track is free if no clip and no
   transition overlaps that span, and (optionally) it is not locked.
3. For a file with audio, the audio track of the same number must be free too,
   because that is where Premiere puts the audio.
4. Audio-only files walk the audio tracks instead.
5. Nothing free: add a new V+A pair through the QE DOM, or refuse. Your choice
   in settings.

## Listary setup

Listary 6: **Options > Actions > add an action**.

* Command / program: `%APPDATA%\Adobe\CEP\extensions\ZenDrop\bridge\ZenDropSend.exe`
* Arguments: `"{path}"`

The settings dialog prints this exact line under "Listary command" so it can be
copied.

If Listary rejects `{path}`, use `"%1"` instead, or check the hint next to
Listary's arguments box for the token it expects for the full file path.

Add a second action with an extra `--source` argument if you want a hotkey that
always loads the Source Monitor regardless of the panel's mode.

The exe accepts:

```
ZenDropSend.exe "C:\clip.mp4"             panel's current mode
ZenDropSend.exe "C:\clip.mp4" --source    force Source Monitor
ZenDropSend.exe "C:\clip.mp4" --timeline  force straight to timeline
ZenDropSend.exe --place                   place what the Source Monitor holds
ZenDropSend.exe ... --port 47821          override the port
ZenDropSend.exe ... --quiet               no error popup
```

## Source Monitor mode

Mode "Source Monitor" imports the file and loads it in the Source Monitor
instead of placing it. Set in/out there, then press **Place from Source Monitor**
in the panel (or run `ZenDropSend.exe --place`). The clip lands with the trimmed
length, using the same free-track rule.

## Rebuilding the bridge

```
bridge\build.cmd
```

Uses the C# compiler shipped with .NET Framework 4. No SDK needed.

## Settings

Stored at `%APPDATA%\Zengane\Zen Drop\settings.json`. The panel and the bridge
exe both read it, so the port lives in one place.
