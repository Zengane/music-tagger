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

    def load(self) -> None:
        raise NotImplementedError

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


ENCODERS = {
    e.name: e
    for e in (MuQMuLanEncoder, MuQEncoder, MertEncoder, ClapMusicEncoder)
}


def get_encoder(name: str) -> Encoder:
    if name not in ENCODERS:
        raise KeyError(f"unknown encoder {name!r}; have {sorted(ENCODERS)}")
    enc = ENCODERS[name]()
    enc.load()
    return enc
