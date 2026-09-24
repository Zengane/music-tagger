"""The three models that look at and read files.

    SigLIP 2       image and text in one space. Zero-shot tags, and the visual
                   half of natural-language search. Apache-2.0.
    Florence-2     a caption for every picture, and the text in it (OCR) — what
                   makes a meme findable by what it says. MIT.
    multilingual   E5, a sentence embedder. Documents, captions and OCR text go
      E5           into one space, so a search finds a file by what it says or
                   what is described in it, in any of ~100 languages. MIT.

Every licence was checked before wiring the model in; see
docs/model-licences.md. Nothing non-commercial is used here.

Two builds, as the roadmap promised: `small` is CPU-usable, `large` wants a
GPU and is more accurate. Choose with MUSICTAGGER_MODEL_SIZE=small|large, or
with prefs. Embeddings from the two are not comparable, so every cache is
namespaced by the model that made it — a user who switches builds gets fresh
vectors, never a silently mixed map.

All three stay resident for a job. At fp16 the small set is about 1.5 GB of
VRAM and the large about 4.5 GB, well inside an 8 GB card, so there is no need
for the model-major juggling the music fusion has to do.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class Build:
    name: str
    siglip: str
    florence: str
    text: str


BUILDS = {
    "small": Build("small",
                   siglip="google/siglip2-base-patch16-256",
                   florence="florence-community/Florence-2-base",
                   text="intfloat/multilingual-e5-small"),
    "large": Build("large",
                   siglip="google/siglip2-so400m-patch16-384",
                   florence="florence-community/Florence-2-large",
                   text="intfloat/multilingual-e5-base"),
}


def build_name() -> str:
    name = os.environ.get("MUSICTAGGER_MODEL_SIZE", "").strip().lower()
    return name if name in BUILDS else "small"


def current_build() -> Build:
    return BUILDS[build_name()]


def space_name(model_id: str) -> str:
    """A cache folder name for a model: which model made a vector matters."""
    return model_id.split("/")[-1].lower()


def device() -> str:
    import torch

    if torch.cuda.is_available():
        return "cuda"
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        # Some ops are still missing on MPS; let them fall back to the CPU
        # instead of failing the whole job.
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
        return "mps"
    return "cpu"


def _dtype(dev: str):
    import torch

    return torch.float16 if dev == "cuda" else torch.float32


def to_rgb(frame: np.ndarray, background: int = 128):
    """RGBA uint8 -> PIL RGB, transparent areas on neutral grey.

    Grey rather than white or black, because either of those would make a
    transparent overlay look like it sat on a white or black background, and
    that is a tag with a meaning of its own.
    """
    from PIL import Image

    if frame.shape[-1] == 4:
        a = frame[..., 3:4].astype(np.float32) / 255.0
        rgb = frame[..., :3].astype(np.float32) * a + background * (1 - a)
        frame = rgb.astype(np.uint8)
    return Image.fromarray(frame, "RGB")


def _pooled(out):
    """transformers 5 returns a model output with `pooler_output` set to the
    projected embedding; older versions returned the tensor itself."""
    return out.pooler_output if hasattr(out, "pooler_output") else out


def _normalise(x: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(x, axis=-1, keepdims=True)
    return x / np.maximum(n, 1e-8)


class Siglip:
    def __init__(self, model_id: str):
        self.model_id = model_id
        self.space = space_name(model_id)
        self.model = None

    def load(self):
        import torch
        from transformers import AutoModel, AutoProcessor

        self.dev = device()
        self.processor = AutoProcessor.from_pretrained(self.model_id)
        self.model = AutoModel.from_pretrained(self.model_id, dtype=_dtype(self.dev)).to(self.dev).eval()
        self.scale = float(self.model.logit_scale.detach().float().exp().cpu())
        self.bias = float(self.model.logit_bias.detach().float().cpu())
        self._torch = torch
        return self

    def embed_images(self, frames: list[np.ndarray], batch: int = 16) -> np.ndarray:
        torch = self._torch
        out = []
        for i in range(0, len(frames), batch):
            imgs = [to_rgb(f) for f in frames[i:i + batch]]
            inp = self.processor(images=imgs, return_tensors="pt")
            inp = {k: (v.to(self.dev, dtype=self.model.dtype) if v.is_floating_point() else v.to(self.dev))
                   for k, v in inp.items()}
            with torch.no_grad():
                feats = _pooled(self.model.get_image_features(**inp))
            out.append(feats.float().cpu().numpy())
        return _normalise(np.concatenate(out, axis=0)) if out else np.zeros((0, 0), np.float32)

    def embed_texts(self, texts: list[str], batch: int = 64) -> np.ndarray:
        torch = self._torch
        out = []
        for i in range(0, len(texts), batch):
            # SigLIP was trained with every text padded to 64 tokens; anything
            # else quietly changes the scores.
            inp = self.processor(text=texts[i:i + batch], padding="max_length", max_length=64,
                                 truncation=True, return_tensors="pt")
            inp = {k: v.to(self.dev) for k, v in inp.items()}
            with torch.no_grad():
                feats = _pooled(self.model.get_text_features(**inp))
            out.append(feats.float().cpu().numpy())
        return _normalise(np.concatenate(out, axis=0)) if out else np.zeros((0, 0), np.float32)

    def probabilities(self, image_vecs: np.ndarray, text_vecs: np.ndarray) -> np.ndarray:
        """SigLIP's own sigmoid score for each (image, text) pair."""
        logits = image_vecs @ text_vecs.T * self.scale + self.bias
        return 1.0 / (1.0 + np.exp(-logits))


class Florence:
    CAPTION = "<DETAILED_CAPTION>"
    OCR = "<OCR>"

    def __init__(self, model_id: str):
        self.model_id = model_id
        self.model = None

    def load(self):
        import torch
        from transformers import AutoProcessor, Florence2ForConditionalGeneration

        self.dev = device()
        self.processor = AutoProcessor.from_pretrained(self.model_id)
        self.model = Florence2ForConditionalGeneration.from_pretrained(
            self.model_id, dtype=_dtype(self.dev)).to(self.dev).eval()
        self._torch = torch
        return self

    def run(self, frames: list[np.ndarray], task: str, max_new_tokens: int = 160,
            batch: int = 8) -> list[str]:
        torch = self._torch
        answers: list[str] = []
        for i in range(0, len(frames), batch):
            imgs = [to_rgb(f, background=255 if task == self.OCR else 128) for f in frames[i:i + batch]]
            inp = self.processor(text=[task] * len(imgs), images=imgs, return_tensors="pt")
            inp = {k: (v.to(self.dev, dtype=self.model.dtype) if v.is_floating_point() else v.to(self.dev))
                   for k, v in inp.items()}
            with torch.no_grad():
                ids = self.model.generate(**inp, max_new_tokens=max_new_tokens, num_beams=3,
                                          do_sample=False)
            # Both tasks used here answer in plain text, so the answer is the
            # decoded sequence. post_process_generation is only needed for the
            # region tasks, and depends on config a checkpoint may not carry.
            answers.extend(self.processor.batch_decode(ids, skip_special_tokens=True))
        return [a.strip() for a in answers]

    def captions(self, frames):
        return self.run(frames, self.CAPTION)

    def ocr(self, frames):
        return self.run(frames, self.OCR, max_new_tokens=256)


class TextEmbedder:
    """E5: prefix "query: " for searches and "passage: " for what is searched."""

    def __init__(self, model_id: str):
        self.model_id = model_id
        self.space = space_name(model_id)
        self.model = None

    def load(self):
        import torch
        from transformers import AutoModel, AutoTokenizer

        self.dev = device()
        self.tokenizer = AutoTokenizer.from_pretrained(self.model_id)
        self.model = AutoModel.from_pretrained(self.model_id, dtype=_dtype(self.dev)).to(self.dev).eval()
        self._torch = torch
        return self

    def embed(self, texts: list[str], kind: str = "passage", batch: int = 32) -> np.ndarray:
        torch = self._torch
        out = []
        for i in range(0, len(texts), batch):
            chunk = [f"{kind}: {t}" for t in texts[i:i + batch]]
            inp = self.tokenizer(chunk, padding=True, truncation=True, max_length=512, return_tensors="pt")
            inp = {k: v.to(self.dev) for k, v in inp.items()}
            with torch.no_grad():
                hidden = self.model(**inp).last_hidden_state
            mask = inp["attention_mask"].unsqueeze(-1).to(hidden.dtype)
            pooled = (hidden * mask).sum(1) / mask.sum(1).clamp(min=1)
            out.append(pooled.float().cpu().numpy())
        return _normalise(np.concatenate(out, axis=0)) if out else np.zeros((0, 0), np.float32)


def free(*models) -> None:
    import gc

    for m in models:
        if m is not None and getattr(m, "model", None) is not None:
            m.model = None
    gc.collect()
    try:
        import torch

        if torch.cuda.is_available():
            torch.cuda.empty_cache()
    except Exception:
        pass
