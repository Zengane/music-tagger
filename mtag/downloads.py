"""Names for downloaded playlists and their tracks.

A playlist arrives with a title someone typed for YouTube, not for a library:

    Lethal League Blaze OST
    Super Mario Galaxy - Original Soundtrack [Full Album]
    Album - Hades (Original Soundtrack)

and its videos are named the same way:

    Bignic - Ruiner [Lethal League Blaze OST]
    Super Mario Galaxy OST - Gusty Garden Galaxy
    01. Main Theme (HQ)

What a library wants is the game ("Lethal League Blaze") as the folder and the
album, and for each track a title ("Ruiner"), an artist when one is written
("Bignic") and a track number. This module works that out. It is a guess, and
the app shows it, editable, before anything is downloaded.

Standard library only: download_job.py runs before the AI environment exists.
"""

from __future__ import annotations

import re
import unicodedata

# Words that describe the upload, never the game. Trimmed from the ends of a
# name and dropped from bracketed groups; a word in the middle of a name stays,
# so "Music Man" and "Original Sin" survive.
NOISE_WORDS = [
    "original game soundtrack", "original video game soundtrack",
    "official game soundtrack", "original soundtrack", "official soundtrack",
    "complete soundtrack", "video game soundtrack", "game soundtrack",
    "full soundtrack", "soundtrack", "soundtracks", "original score", "ost", "osts",
    "o.s.t.", "o.s.t", "bgm", "gamerip", "game rip", "rip", "full album", "complete",
    "album", "music", "musics", "full", "official", "hq", "hd", "high quality",
    "extended ost", "playlist", "all tracks", "every track", "complete ost",
    "official audio", "audio", "official video", "lyrics", "lyric video",
    "visualizer", "visualiser", "1080p", "720p", "4k", "60fps", "320kbps",
    "flac", "mp3", "lossless", "with download", "download", "free download",
]
# The same words, in the order they are tried: longest first, so
# "original soundtrack" goes before "soundtrack" leaves "original" behind.
_NOISE = sorted({w.lower() for w in NOISE_WORDS}, key=len, reverse=True)



def add_noise_words(words: list[str]) -> None:
    """More words to strip, from the app's options ('remaster, ver.')."""
    global _NOISE
    extra = {w.strip().lower() for w in words if w.strip()}
    _NOISE = sorted(set(_NOISE) | extra, key=len, reverse=True)


# What a playlist is about, from its title and its videos' titles.
GAME_HINTS = re.compile(
    r"\b(ost|o\.s\.t|soundtrack|bgm|gamerip|video ?game|game music|"
    r"nintendo|playstation|xbox|snes|n64|gamecube|ps[1-5]|famicom|steam)\b",
    re.IGNORECASE)

# Things that wrap a title and say nothing about it.
_BRACKETS = re.compile(r"\s*[\[(【「{][^\])】」}]*[\])】」}]")
_DASH = re.compile(r"\s+[-–—|~]\s+|\s*[|｜]\s*")
_TRACK_NO = re.compile(
    r"^\s*(?:track\s*|#|no\.?\s*)?(\d{1,3})(?:\s*[.):\-–—]\s*|\s+(?=\D))", re.IGNORECASE)
_DISC_TRACK = re.compile(r"^\s*(\d)[-.](\d{1,2})\s*[.):\-–—]?\s+")
_SPACES = re.compile(r"\s+")
_DISC = re.compile(r"[\s\-–—,]*[\[(]?\b(?:disc|disk|cd)\s*(\d{1,2})\b[\])]?", re.IGNORECASE)
# "Album - Hades (Original Soundtrack)": YouTube Music's auto-made albums.
_ALBUM_PREFIX = re.compile(r"^\s*(album|playlist|mix)\s*[-–—:]\s*", re.IGNORECASE)


def fold(text: str) -> str:
    """Lowercase, accents off, punctuation as spaces: for comparing only."""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = re.sub(r"[^\w]+", " ", text.lower())
    return _SPACES.sub(" ", text).strip()


def _is_noise(fragment: str, years: bool = True) -> bool:
    """Whether a bracketed group or dash-separated part is only noise words.

    years: whether a bare year counts as noise. In a track title "(2018)" is
    an upload detail; in a game's name it tells DOOM (2016) from DOOM.
    """
    rest = " " + fold(fragment) + " "
    for word in _NOISE:
        rest = rest.replace(" " + fold(word) + " ", " ")
    if years:
        rest = re.sub(r"\b(19|20)\d\d\b", " ", rest)
    return rest.strip() == ""


def _strip_noise_ends(name: str) -> str:
    """Drop noise words from both ends, repeatedly: 'X OST Full Album' -> 'X'."""
    changed = True
    while changed and name:
        changed = False
        for word in _NOISE:
            pattern = re.escape(word)
            new = re.sub(rf"^\s*{pattern}(?=\W|$)[\s:\-–—|]*", "", name, flags=re.IGNORECASE)
            new = re.sub(rf"[\s:\-–—|,]*(?<!\w){pattern}\s*$", "", new, flags=re.IGNORECASE)
            # "Hollow Knight Soundtrack 2017": a year after a noise word is
            # the upload's, so it goes with the word. "FIFA 2002" keeps its.
            new = re.sub(rf"(?<!\w)({pattern})\s+(19|20)\d\d\s*$", r"\1", new, flags=re.IGNORECASE)
            if new != name:
                name, changed = new, True
    return name.strip(" -–—|:,~.")


def split_disc(title: str) -> tuple[str, int]:
    """'Pokémon X & Y OST (Disc 2)' -> ('Pokémon X & Y OST', 2)."""
    m = _DISC.search(title or "")
    if not m:
        return title, 0
    return (title[:m.start()] + title[m.end():]).strip(), int(m.group(1))


def clean_name(title: str) -> str:
    """The game or album a playlist title names, with the upload noise gone.

        'Lethal League Blaze OST'                         -> 'Lethal League Blaze'
        'Super Mario Galaxy - Original Soundtrack [Full]' -> 'Super Mario Galaxy'
        'Album - Hades (Original Soundtrack)'             -> 'Hades'
    """
    name = unicodedata.normalize("NFKC", title or "").strip()
    name = _ALBUM_PREFIX.sub("", name)
    name, _ = split_disc(name)  # the disc is a tag, not part of the folder name
    # Bracketed groups go when they are only noise: "(Original Soundtrack)",
    # "[HQ]". A group with a real word or a year in it stays: "(2016)".
    name = _BRACKETS.sub(lambda m: "" if _is_noise(m.group(0).strip()[1:-1], years=False) else m.group(0), name)
    # Dash-separated parts likewise: "Hades - Original Soundtrack".
    parts = [p for p in _DASH.split(name) if p.strip()]
    kept = [p for p in parts if not _is_noise(p, years=False)]
    name = " - ".join(kept) if kept else name
    name = _strip_noise_ends(name)
    return _SPACES.sub(" ", name).strip() or (title or "").strip()


def is_game_music(playlist_title: str, entry_titles: list[str]) -> bool:
    """Whether this looks like a game soundtrack rather than other music."""
    if GAME_HINTS.search(playlist_title or ""):
        return True
    hits = sum(1 for t in entry_titles if GAME_HINTS.search(t or ""))
    return bool(entry_titles) and hits >= max(1, len(entry_titles) // 3)


def common_phrase(titles: list[str]) -> str:
    """The longest run of words every title shares, as written in the first.

    A playlist titled 'My favourites' whose videos are all
    'Super Mario Galaxy OST - ...' still names its game; this finds it.
    """
    titles = [t for t in titles if t]
    if len(titles) < 2:
        return ""
    words = re.findall(r"[\w'’&.]+", titles[0])
    folded = [" " + fold(t) + " " for t in titles[1:]]
    best = ""
    for i in range(len(words)):
        for j in range(len(words), i, -1):
            if j - i <= len(best.split()):
                break
            phrase = " ".join(words[i:j])
            key = " " + fold(phrase) + " "
            if key.strip() and all(key in f for f in folded):
                best = phrase
                break
    return best


def game_in_title(title: str) -> str:
    """The game a single video names in passing: 'Bignic - Ruiner [Lethal
    League Blaze OST]' -> 'Lethal League Blaze'. Empty when none is named."""
    fragments = [m.group(0).strip()[1:-1] for m in _BRACKETS.finditer(title or "")]
    fragments += _DASH.split(_BRACKETS.sub(" ", title or ""))
    for frag in fragments:
        if GAME_HINTS.search(frag):
            name = clean_name(frag)
            if name and not _is_noise(name) and not GAME_HINTS.search(name):
                return name
    return ""


def guess_collection(playlist_title: str, entry_titles: list[str], uploader: str = "") -> dict:
    """The name and category for a whole playlist, before any track."""
    name = clean_name(playlist_title)
    if len(entry_titles) <= 1:
        name = game_in_title(playlist_title) or name
    game = is_game_music(playlist_title, entry_titles)
    # The videos may name the game better than the playlist does: a playlist
    # called 'favourites' or 'OST' says nothing; its tracks all say 'Celeste'.
    shared = clean_name(common_phrase(entry_titles))
    if shared and (not name or _is_noise(playlist_title) or fold(name) in ("", "favorites", "favourites")):
        name = shared
    if uploader and uploader.endswith(" - Topic"):
        artist = uploader[: -len(" - Topic")]
    else:
        artist = ""
    _, disc = split_disc(playlist_title or "")
    return {
        "name": name or shared or (playlist_title or "Download").strip(),
        "category": "game" if game else "music",
        "album_artist": artist,
        "disc": disc,
    }


def _remove_phrase(text: str, phrase: str) -> str:
    """Remove a phrase wherever it appears, matched loosely (case, accents)."""
    if not phrase:
        return text
    words = [re.escape(w) for w in re.findall(r"\w+", phrase)]
    if not words:
        return text
    pattern = r"(?<!\w)" + r"\W{0,3}".join(words) + r"(?!\w)"
    return re.sub(pattern, " ", text, flags=re.IGNORECASE)


def parse_track(title: str, collection: str = "", index: int = 0,
                pattern: str = "auto", uploader: str = "") -> dict:
    """Track number, artist and title from one video's title.

    pattern: 'auto', 'artist-title', 'title-artist' or 'title' (keep it whole,
    noise removed). 'auto' reads 'A - B' as artist and title, the usual
    YouTube convention, unless A is a number.
    """
    raw = unicodedata.normalize("NFKC", title or "").strip()
    text = raw
    track = 0
    disc = 0

    # Brackets: drop those naming the collection or holding only noise.
    def bracket(m: re.Match) -> str:
        inner = m.group(0).strip()[1:-1]
        if _is_noise(inner) or (collection and _is_noise(_remove_phrase(inner, collection))):
            return " "
        return m.group(0)

    text = _BRACKETS.sub(bracket, text)
    if collection:
        # "Super Mario Galaxy OST - Gusty Garden" and "... - Celeste OST":
        # the part that is the collection plus noise goes entirely.
        parts = [p for p in _DASH.split(text) if p.strip()]
        kept = [p for p in parts if not _is_noise(_remove_phrase(p, collection))]
        if kept and len(kept) < len(parts):
            text = " - ".join(kept)
    parts = [p.strip() for p in _DASH.split(text) if p.strip()]
    parts = [p for p in parts if not _is_noise(p)] or parts
    text = " - ".join(parts)

    m = _DISC_TRACK.match(text)
    if m:
        disc, track = int(m.group(1)), int(m.group(2))
        text = text[m.end():]
    else:
        m = _TRACK_NO.match(text)
        if m and int(m.group(1)) < 500 and text[m.end():].strip():
            track = int(m.group(1))
            text = text[m.end():]

    artist = ""
    parts = [p.strip() for p in _DASH.split(text) if p.strip()]
    if pattern == "title":
        body = " - ".join(parts)
    elif len(parts) >= 2 and pattern in ("auto", "artist-title", "title-artist"):
        if pattern == "title-artist":
            body, artist = " - ".join(parts[:-1]), parts[-1]
        else:
            first = parts[0]
            if re.fullmatch(r"\d{1,3}", first):
                track = track or int(first)
                body = " - ".join(parts[1:])
            else:
                artist, body = first, " - ".join(parts[1:])
    else:
        body = " - ".join(parts)

    if not artist and uploader.endswith(" - Topic"):
        artist = uploader[: -len(" - Topic")]
    body = _strip_noise_ends(_SPACES.sub(" ", body)).strip()
    if not body:
        body = _SPACES.sub(" ", raw).strip()
    return {
        "track": track or index,
        "disc": disc,
        "artist": _SPACES.sub(" ", artist).strip(),
        "title": body,
    }


def guess_tracks(entries: list[dict], collection: str, pattern: str = "auto") -> list[dict]:
    """parse_track over a playlist, with one look at the whole.

    Two checks need every title at once:
      - When 'auto' found an artist on fewer than half the tracks, the dashes
        were part of titles ("Main Theme - Reprise"), not artist separators.
      - Track numbers written in the titles are kept only when they are all
        different; otherwise the playlist order is the numbering.
    """
    parsed = [parse_track(e.get("title", ""), collection, i + 1, pattern, e.get("uploader") or "")
              for i, e in enumerate(entries)]
    if pattern == "auto" and parsed:
        with_artist = sum(1 for p in parsed if p["artist"])
        if with_artist and with_artist < len(parsed) / 2:
            parsed = [parse_track(e.get("title", ""), collection, i + 1, "title", e.get("uploader") or "")
                      for i, e in enumerate(entries)]
    numbers = [p["track"] for p in parsed]
    if len(set(numbers)) != len(numbers):
        for i, p in enumerate(parsed):
            p["track"] = i + 1
    return parsed


_FORBIDDEN = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def safe_filename(name: str, limit: int = 150) -> str:
    """A name Windows, macOS and Linux all accept. Forbidden characters become
    their full-width look-alikes, the way yt-dlp does, so 'AC/DC' stays legible."""
    table = {'<': '＜', '>': '＞', ':': '：', '"': '＂', '/': '⧸', '\\': '⧹',
             '|': '｜', '?': '？', '*': '＊'}
    name = "".join(table.get(c, c) for c in name)
    name = _FORBIDDEN.sub("", name)
    name = name.strip().rstrip(".")
    if name.upper() in {"CON", "PRN", "AUX", "NUL"} | {f"COM{i}" for i in range(1, 10)} | {f"LPT{i}" for i in range(1, 10)}:
        name = "_" + name
    if len(name) > limit:
        name = name[:limit].rstrip(" .")
    return name or "_"


def render_template(template: str, fields: dict) -> str:
    """'{track:02} - {title}' with the fields of one track.

    Missing or empty fields render empty, and the separators left dangling
    around them are tidied: '{artist} - {title}' with no artist is 'Title'.
    """
    def sub(m: re.Match) -> str:
        key, spec = m.group(1), m.group(2) or ""
        value = fields.get(key, "")
        if value in (None, "", 0) and key in ("track", "disc", "year"):
            return ""
        try:
            return format(value, spec[1:]) if spec else str(value)
        except (ValueError, TypeError):
            return str(value)

    out = re.sub(r"\{(\w+)(:[^}]*)?\}", sub, template)
    out = re.sub(r"^(\s*[-–—_.]\s*)+|(\s*[-–—_]\s*)+$", "", out)
    out = re.sub(r"(\s[-–—]\s*){2,}", " - ", out)
    return _SPACES.sub(" ", out).strip()
