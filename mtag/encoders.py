"""Pluggable audio encoders.

Each encoder turns a track into one fixed-length vector. The bakeoff scores
them against the user's own labels, so no encoder is privileged here.

Every encoder embeds several windows spread across the track (see audio.py) and
pools them. Pooling is mean + std concatenated: the mean captures what the track
sounds like overall, the std captures how much it changes, which is the whole
signal for tags like Build-Up.
"""

from __future__ import annotations

import numpy as np
import torch

from . import audio as A

_DEVICE = "cuda" if torch.cuda.is_available() else "cpu"


def _pool(frames: np.ndarray) -> np.ndarray:
    """(n_windows, d) -> (2d,) mean+std, L2 normalised."""
    if frames.shape[0] == 1:
        pooled = np.concatenate([frames[0], np.zeros_like(frames[0])])
    else:
        pooled = np.concatenate([frames.mean(0), frames.std(0)])
    norm = np.linalg.norm(pooled)
    return pooled / norm if norm > 0 else pooled


class Encoder:
    name: str
    sr: int
    window_s: float
    max_windows: int
    batch: int = 8
    has_text: bool = False          # whether embed_text() returns anything
    caches_internally: bool = False  # set when the encoder manages its own cache

    def load(self) -> None:
        raise NotImplementedError

    def text_slice(self, total_dim: int) -> tuple[int, int] | None:
        """Which columns of a track embedding share a space with `embed_text`.

        Zero-shot fallback compares a track against a tag's text embedding, so it
        needs the mean-pooled block specifically — the std block, and any other
        encoder's columns in a fusion, are not in that space.
        """
        return (0, total_dim // 2) if self.has_text else None

    def embed_windows(self, wavs: torch.Tensor) -> np.ndarray:
        """(n, samples) float32 on device -> (n, d) numpy."""
        raise NotImplementedError

    def embed_file(self, filepath) -> np.ndarray:
        w = A.windows(filepath, self.sr, self.window_s, self.max_windows)
        outs = []
        for i in range(0, w.shape[0], self.batch):
            chunk = torch.from_numpy(w[i : i + self.batch]).to(_DEVICE)
            with torch.no_grad():
                outs.append(self.embed_windows(chunk))
        return _pool(np.concatenate(outs, axis=0))

    def embed_text(self, texts: list[str]) -> np.ndarray | None:
        """Only text-aligned encoders implement this; used for zero-shot fallback."""
        return None


class MuQMuLanEncoder(Encoder):
    """Contrastive music-text model. Also gives us a zero-shot path for rare tags."""

    name = "muq-mulan"
    has_text = True
    sr = 24000
    window_s = 20.0
    max_windows = 12
    batch = 4

    def load(self):
        from muq import MuQMuLan

        self.model = MuQMuLan.from_pretrained("OpenMuQ/MuQ-MuLan-large").to(_DEVICE).eval()

    def embed_windows(self, wavs):
        return self.model(wavs=wavs).float().cpu().numpy()

    def embed_text(self, texts):
        with torch.no_grad():
            return self.model(texts=texts).float().cpu().numpy()


class MuQEncoder(Encoder):
    """Self-supervised music representation, no text tower. Probe-only."""

    name = "muq"
    sr = 24000
    window_s = 20.0
    max_windows = 12
    batch = 4

    def load(self):
        from muq import MuQ

        self.model = MuQ.from_pretrained("OpenMuQ/MuQ-large-msd-iter").to(_DEVICE).eval()

    def embed_windows(self, wavs):
        out = self.model(wavs, output_hidden_states=True)
        # Average the middle third of the stack: for music SSL models the top
        # layers drift toward the pretraining objective and lose tag-relevant detail.
        hs = out.hidden_states
        lo, hi = len(hs) // 3, (2 * len(hs)) // 3
        stacked = torch.stack(hs[lo:hi]).mean(0)  # (b, t, d)
        return stacked.mean(1).float().cpu().numpy()


class MertEncoder(Encoder):
    name = "mert"
    sr = 24000
    window_s = 20.0
    max_windows = 12
    batch = 4

    def load(self):
        from transformers import AutoModel

        self.model = (
            AutoModel.from_pretrained("m-a-p/MERT-v1-330M", trust_remote_code=True)
            .to(_DEVICE)
            .eval()
        )

    def embed_windows(self, wavs):
        out = self.model(wavs, output_hidden_states=True)
        hs = out.hidden_states
        lo, hi = len(hs) // 3, (2 * len(hs)) // 3
        stacked = torch.stack(hs[lo:hi]).mean(0)
        return stacked.mean(1).float().cpu().numpy()


class ClapMusicEncoder(Encoder):
    """LAION CLAP fine-tuned on music. The old tagger used the generic variant and
    let its feature extractor silently truncate to 10s; here the 10s limit is
    respected explicitly and windows tile the whole track."""

    name = "clap-music"
    has_text = True
    sr = 48000
    window_s = 10.0
    max_windows = 12
    batch = 8

    MODEL_ID = "laion/larger_clap_music_and_speech"

    def load(self):
        from transformers import ClapModel, ClapProcessor

        self.processor = ClapProcessor.from_pretrained(self.MODEL_ID)
        self.model = ClapModel.from_pretrained(self.MODEL_ID).to(_DEVICE).eval()

    def embed_windows(self, wavs):
        inp = self.processor(
            audio=[w.cpu().numpy() for w in wavs],
            return_tensors="pt",
            sampling_rate=self.sr,
        )
        inp = {k: v.to(_DEVICE) for k, v in inp.items()}
        # get_audio_features returns the tower output with `pooler_output` swapped
        # for the projected, L2-normalised embedding in the shared audio/text space.
        return self.model.get_audio_features(**inp).pooler_output.float().cpu().numpy()

    def embed_text(self, texts):
        inp = self.processor(text=texts, return_tensors="pt", padding=True)
        inp = {k: v.to(_DEVICE) for k, v in inp.items()}
        with torch.no_grad():
            return self.model.get_text_features(**inp).pooler_output.float().cpu().numpy()


class FusionEncoder(Encoder):
    """Several encoders concatenated.

    The bakeoff showed no single encoder wins everywhere: MuQ-MuLan takes most
    tags, MuQ is better at Fantasy, Ambient and Medieval, and CLAP-music is much
    better at Chiptuney. Concatenating lets each probe draw on whichever
    representation actually separates its tag — worth +0.03 macro AP over
    MuQ-MuLan alone, and +0.03 precision at the same recall.

    MERT is deliberately absent: it added 0.003 AP for another 2048 dimensions
    and another pass over every file.

    Each part keeps its own embedding cache, so switching between a single
    encoder and a fusion never re-embeds anything, and a part whose vectors are
    all cached is never even loaded onto the GPU.
    """

    name = "fusion"
    PARTS = ("muq-mulan", "muq", "clap-music")
    caches_internally = True   # parts are cached individually; skip the outer cache

    def __init__(self, parts: tuple[str, ...] = PARTS):
        self.part_names = tuple(parts)
        self.parts: dict[str, Encoder] = {n: ENCODERS[n]() for n in self.part_names}
        self.part_dims: dict[str, int] = {}
        self._caches: dict[str, object] = {}
        self._loaded: set[str] = set()

    @property
    def has_text(self) -> bool:
        return any(p.has_text for p in self.parts.values())

    def load(self) -> None:
        """No-op: parts load on first use, so a fully cached run stays off the GPU."""

    def _part(self, name: str) -> Encoder:
        if name not in self._loaded:
            self.parts[name].load()
            self._loaded.add(name)
        return self.parts[name]

    def embed_part(self, name: str, filepath) -> np.ndarray:
        from .dataset import EmbeddingCache

        cache = self._caches.setdefault(name, EmbeddingCache(name))
        vec = cache.get(filepath)
        if vec is None:
            vec = self._part(name).embed_file(filepath)
            cache.put(filepath, vec)
        self.part_dims[name] = vec.shape[0]
        return vec

    def embed_file(self, filepath) -> np.ndarray:
        vec = np.concatenate([self.embed_part(n, filepath) for n in self.part_names])
        norm = np.linalg.norm(vec)
        return vec / norm if norm > 0 else vec

    def text_slice(self, total_dim: int) -> tuple[int, int] | None:
        """The mean block of the first text-capable part, located in the concat."""
        if not self.part_dims:
            raise RuntimeError("embed a file before asking for the text slice")
        offset = 0
        for n in self.part_names:
            d = self.part_dims[n]
            if self.parts[n].has_text:
                return (offset, offset + d // 2)
            offset += d
        return None

    def embed_text(self, texts):
        for n in self.part_names:
            if self.parts[n].has_text:
                return self._part(n).embed_text(texts)
        return None


ENCODERS = {
    e.name: e
    for e in (MuQMuLanEncoder, MuQEncoder, MertEncoder, ClapMusicEncoder)
}


def get_encoder(name: str) -> Encoder:
    if name == FusionEncoder.name:
        enc = FusionEncoder()
        enc.load()
        return enc
    if name not in ENCODERS:
        raise KeyError(f"unknown encoder {name!r}; have {sorted(ENCODERS) + ['fusion']}")
    enc = ENCODERS[name]()
    enc.load()
    return enc
