"""The effects map: layout, nearest neighbours, groups and their names.

Shared by `sfx_map_job.py`, which the app runs, and `sfx_map_bench.py`, which
scores it, so the bench measures exactly what the app draws.

Everything here works on the audio alone. Filenames only ever help *name* a
group, and only when a group's files agree on a word; they never decide where a
sound goes. A folder of `sfx_0001.wav` … gets the same map and the same groups
as the same sounds with their real names.
"""

from __future__ import annotations

import re
from collections import Counter
from pathlib import Path

import numpy as np


def unit(X: np.ndarray) -> np.ndarray:
    X = np.asarray(X, dtype=np.float32)
    return X / (np.linalg.norm(X, axis=1, keepdims=True) + 1e-9)


def text_half(X: np.ndarray) -> np.ndarray:
    """The mean-pooled block, which shares a space with the text tower."""
    X = np.asarray(X, dtype=np.float32)
    half = X.shape[1] // 2
    return unit(X[:, :half] if half > 0 else X)


# ── layout ──────────────────────────────────────────────────────────────────

def reduce_to_plane(X: np.ndarray, seed: int = 0) -> np.ndarray:
    """Flatten effect embeddings to a plane in -1..1, the way the music map is.

    PCA to 50, then t-SNE at perplexity 30: the same recipe as `map_job.py`.
    Measured on the bench (93 families, 1057 labelled among 6567 effects,
    nearest neighbour on the plane by *distance*), general CLAP vectors:

        the encoder's own space (no plane)    32.6%
        UMAP n_neighbors=5 (the old map)      ~25-26%  (moves with the seed)
        t-SNE perplexity 30                    31.3%

    The old bench scored the plane by cosine, which for a flat map measures
    the angle from the centre rather than the distance between two dots, and
    so read 13-16% for the old map. That number was wrong, not the map.
    """
    from sklearn.decomposition import PCA
    from sklearn.manifold import TSNE

    X = unit(X)
    n = X.shape[0]
    if n < 4:
        return np.zeros((n, 2), dtype=np.float32)
    comps = int(min(50, n - 1, X.shape[1]))
    reduced = PCA(n_components=comps, random_state=seed).fit_transform(X)
    perplexity = float(min(30, max(1, (n - 1) / 3)))
    plane = TSNE(n_components=2, perplexity=perplexity, init="pca",
                 learning_rate="auto", random_state=seed, max_iter=1000).fit_transform(reduced)
    plane = plane - plane.mean(axis=0)
    extent = float(np.abs(plane).max())
    if extent > 0:
        plane = plane / extent
    return plane.astype(np.float32)


# ── neighbours ──────────────────────────────────────────────────────────────

def nearest(X: np.ndarray, k: int = 20, block: int = 1024) -> np.ndarray:
    """Each effect's `k` nearest others by cosine, closest first.

    This is what hopping uses, and it is read from the full embedding rather
    than the plane, so it is as good as the encoder is.
    """
    U = unit(X)
    n = U.shape[0]
    k = max(0, min(k, n - 1))
    out = np.zeros((n, k), dtype=np.int32)
    if k == 0:
        return out
    for s in range(0, n, block):
        S = U[s:s + block] @ U.T
        rows = np.arange(S.shape[0])
        S[rows, rows + s] = -np.inf
        part = np.argpartition(-S, k - 1, axis=1)[:, :k]
        order = np.argsort(-np.take_along_axis(S, part, axis=1), axis=1)
        out[s:s + block] = np.take_along_axis(part, order, axis=1)
    return out


# ── groups ──────────────────────────────────────────────────────────────────

def group(X: np.ndarray, size: int = 40) -> np.ndarray:
    """Groups of effects that sound alike: one label per effect, biggest
    group first.

    Ward clustering on unit vectors (where distance follows cosine), cut to
    about one group per `size` effects. Every effect gets a group; there is no
    "noise" bucket, because on a map an unlabelled dot is a dot nobody can
    find. Measured on the bench with general CLAP vectors, ~164 groups:

                          pure   whole   biggest group
        ward              83.2%  78.3%   154
        average linkage   73.8%  79.7%   458, and one-sound groups
        HDBSCAN           97%    71%     but 2 of 3 sounds in no group
    """
    from sklearn.cluster import AgglomerativeClustering
    from sklearn.decomposition import PCA

    U = unit(X)
    n = U.shape[0]
    if n < 2:
        return np.zeros(n, dtype=np.int32)
    k = int(np.clip(round(n / size), 2, 400))
    k = min(k, n)
    comps = int(min(50, n - 1, U.shape[1]))
    R = unit(PCA(n_components=comps, random_state=0).fit_transform(U))
    labels = AgglomerativeClustering(n_clusters=k, linkage="ward").fit_predict(R)
    counts = Counter(labels.tolist())
    order = {g: i for i, (g, _) in enumerate(sorted(counts.items(), key=lambda c: (-c[1], c[0])))}
    return np.array([order[g] for g in labels], dtype=np.int32)


# ── names ───────────────────────────────────────────────────────────────────

# Plain descriptions the audio is asked about. A group is named after the one
# its sounds match best, unless its files agree on a word (see `name_groups`).
CONCEPTS = [
 "an explosion", "a gunshot", "a heavy impact", "a punch", "breaking glass",
 "a door", "footsteps", "a whoosh", "a riser", "a downward sweep",
 "a metallic clang", "a wooden knock", "a bell", "a chime",
 "an electronic beep", "a user interface click", "a notification",
 "typing on a keyboard", "a coin", "a cash register",
 "a car engine", "a motorcycle", "a jet plane", "a helicopter", "a train",
 "tyres screeching", "a car horn",
 "rain", "thunder", "wind", "ocean waves", "a stream of water",
 "a water splash", "a water drop", "bubbles underwater",
 "fire crackling", "a flame burst",
 "birds singing", "a dog barking", "a cat", "a horse", "insects at night",
 "a baby crying", "a baby laughing", "a crowd cheering", "applause",
 "screaming", "laughter", "a cough", "breathing", "whispering",
 "singing", "a choir", "a man speaking", "a woman speaking",
 "a drum beat", "a cymbal crash", "a bass drop", "an orchestral hit",
 "a synthesiser pad", "an ambient drone", "a low rumble", "deep sub bass",
 "machinery", "a motor whirring", "a clock ticking", "a camera shutter",
 "a zipper", "paper rustling", "cloth movement", "a switch",
 "a laser", "a science fiction weapon", "a magic spell", "a power up",
 "a sword", "a bow and arrow", "an alarm siren", "a telephone ringing",
 "a monster growl", "a creature", "a robot", "a glitch",
 "a retro video game sound", "a cartoon sound", "a slide whistle",
 "a small room", "a large hall", "near silence",
 "a squeak", "a scrape", "a rattle", "a pop", "a click", "a thud", "a hiss",
]


def signpost(phrase: str) -> str:
    """The phrase as a label: "a baby crying" scores better as a prompt, but
    on a map plate the article is dead width."""
    for lead in ("a ", "an ", "the "):
        if phrase.startswith(lead):
            return phrase[len(lead):]
    return phrase


# Words that say nothing about the sound: counters, formats, game-engine
# prefixes and the like.
_STOP = {
    "sfx", "sound", "sounds", "snd", "audio", "wav", "mp3", "ogg", "flac",
    "aif", "aiff", "play", "stop", "loop", "loops", "oneshot", "shot",
    "var", "variation", "version", "ver", "take", "alt", "mix", "edit", "final",
    "new", "old", "copy", "the", "and", "with", "for", "mono", "stereo",
    "bank", "file", "clip", "track", "part", "short", "long", "small", "big",
    "large", "med", "medium", "high", "low", "soft", "hard", "single",
    "multi", "various", "misc", "other", "generic", "amb", "npc",
}
_SPLIT = re.compile(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])")


def name_tokens(stem: str) -> set[str]:
    """The words in a filename. CamelCase, `_`, `-` and spaces split; digits,
    short pieces and stop words dropped. "Play_Amb_Lp_02" gives nothing;
    "WhooshFast 03" gives {"whoosh", "fast"}."""
    words = set()
    for part in re.split(r"[\s_\-\.\(\)\[\]]+", stem):
        for w in _SPLIT.findall(part):
            w = w.lower()
            if len(w) >= 3 and w not in _STOP:
                words.add(w)
    return words


def word_prompt(word: str) -> str:
    """How a filename word is put to the text tower."""
    return f"the sound of {word}"


def agreed_words(paths, groups: np.ndarray, agree: float = 0.6) -> list[str]:
    """Per group, the filename word that at least `agree` of its files share,
    or "". Groups of fewer than three files never agree."""
    n_groups = int(groups.max()) + 1 if len(groups) else 0
    tokens = [name_tokens(Path(p).stem) for p in paths]
    out = []
    for g in range(n_groups):
        rows = np.where(groups == g)[0]
        votes = Counter(w for r in rows for w in tokens[r])
        word = ""
        if votes and len(rows) >= 3:
            w, c = max(votes.items(), key=lambda kv: (kv[1], kv[0]))
            if c >= agree * len(rows):
                word = w
        out.append(word)
    return out


def name_groups(paths, groups: np.ndarray, audio_text: np.ndarray | None,
                text: np.ndarray | None, phrases=CONCEPTS,
                word_text: dict | None = None, agree: float = 0.6,
                heard_rank: int = 10) -> list[str]:
    """A name for every group.

    The audio decides: each group is named after the phrase its sounds match
    best (the group's mean text-aligned vector against each phrase).

    A filename word the group's files agree on (see `agreed_words`) is the name
    instead, but only when the sound model hears it too: put to the text tower
    as "the sound of <word>", it has to score at least as well as the
    `heard_rank`-th best phrase. That keeps "Siren" and "Sweeper", and drops
    pack and product words like "Dsb", "Bpm" or "Moments", which a whole
    folder shares but which say nothing about the sound. Without the model's
    vectors for the words (`word_text`), no word is trusted.

    Names are unique: a smaller group that would repeat a name takes its
    second-best phrase as well, then a number.
    """
    n_groups = int(groups.max()) + 1 if len(groups) else 0
    words = agreed_words(paths, groups, agree)
    names: list[str] = []
    used: Counter = Counter()
    T = unit(text) if text is not None and len(phrases) else None
    for g in range(n_groups):
        phr: list[str] = []
        word = ""
        if audio_text is not None and T is not None:
            m = unit(audio_text[groups == g].mean(axis=0, keepdims=True))[0]
            s = T @ m
            order = np.argsort(-s)
            phr = [signpost(phrases[i]) for i in order[:3]]
            w = words[g]
            if w and word_text and w in word_text:
                bar = s[order[min(heard_rank, len(order)) - 1]]
                if float(unit(np.asarray(word_text[w])[None])[0] @ m) >= bar:
                    word = w.capitalize()
        name = word or (phr[0] if phr else f"group {g + 1}")
        if used[name] and not word and len(phr) > 1:
            name = f"{phr[0]}, {phr[1]}"
        base = name
        if used[base]:
            name = f"{base} {used[base] + 1}"
        used[base] += 1
        names.append(name)
    return names


def regions(plane: np.ndarray, groups: np.ndarray, names: list[str]) -> list[dict]:
    """Where each group sits on the plane: the median of its dots and how far
    they spread, as signposts for the map. Biggest first."""
    out = []
    for g, name in enumerate(names):
        rows = plane[groups == g]
        if len(rows) == 0:
            continue
        centre = np.median(rows, axis=0)
        spread = float(np.median(np.linalg.norm(rows - centre, axis=1))) if len(rows) > 1 else 0.0
        out.append({"label": name, "group": g, "pos": [float(centre[0]), float(centre[1])],
                    "count": int(len(rows)), "spread": spread})
    out.sort(key=lambda r: -r["count"])
    return out
