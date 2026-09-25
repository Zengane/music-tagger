"""Speed against accuracy: which model does each job.

Three profiles, and "auto", which picks one from the hardware. Every model
named here allows commercial use (see docs/model-licences.md), and every one
of them is in transformers itself, with no remote code.

    fast      runs on any machine, CPU included. The models the effects side
              has always used, and the small image models.
    balanced  a GPU with 4 GB or more, or an Apple Silicon Mac with 16 GB.
              Swaps the sound search model for PE-AV small, which is much
              better at "find the sound I am describing".
    best      a GPU with 8 GB or more. The large image, caption and text
              models, and PE-AV large for sound.

The music tagger is not switched by a profile. Its probes were trained on one
particular set of encoders, and a different encoder needs a retrain on your
own tags (train.py) before it can say anything; docs/audio-models.md explains
how to measure whether that is worth it.

The installer's "speed or accuracy" screen is meant to be a front for this
module: `python -m mtag.profiles` prints the hardware it found and the profile
it recommends, as JSON. The app passes the choice to every job in the
environment variable MUSICTAGGER_PROFILE.

Caches are named after the model that made each vector, so switching profile
never mixes vectors from two models. It only means the files are analysed
again the first time they are needed with the new models.
"""

from __future__ import annotations

import json
import os
import platform
import sys
from dataclasses import asdict, dataclass

AST = "MIT/ast-finetuned-audioset-10-10-0.4593"
CLAP_GENERAL = "laion/clap-htsat-unfused"


@dataclass(frozen=True)
class Profile:
    name: str
    label: str
    needs: str
    siglip: str          # images, video, 3D: tags and visual search
    florence: str        # captions and OCR
    text: str            # text search and document kinds
    audio_text: str      # sound search, zero-shot effect tags, the effects map
    sfx_tagger: str      # AudioSet classifier for effect categories


PROFILES: dict[str, Profile] = {
    "fast": Profile(
        "fast", "Fast", "any computer; the CPU is enough",
        siglip="google/siglip2-base-patch16-256",
        florence="florence-community/Florence-2-base",
        text="intfloat/multilingual-e5-small",
        audio_text=CLAP_GENERAL,
        sfx_tagger=AST,
    ),
    "balanced": Profile(
        "balanced", "Balanced", "a GPU with 4 GB, or an Apple Silicon Mac with 16 GB",
        siglip="google/siglip2-base-patch16-256",
        florence="florence-community/Florence-2-base",
        text="intfloat/multilingual-e5-small",
        audio_text="facebook/pe-av-small",
        sfx_tagger=AST,
    ),
    "best": Profile(
        "best", "Best", "a GPU with 8 GB or more",
        siglip="google/siglip2-so400m-patch16-384",
        florence="florence-community/Florence-2-large",
        text="intfloat/multilingual-e5-base",
        audio_text="facebook/pe-av-large",
        sfx_tagger=AST,
    ),
}

# The cache folder each sound-and-text model writes to. Kept here, not only on
# the encoder classes, so a job that finds everything cached can name the
# folder without importing torch (see tests_sfx_map.py).
AUDIO_TEXT_SPACE = {
    CLAP_GENERAL: "clap-sfx-v1",
    "facebook/pe-av-small": "pe-av-small",
    "facebook/pe-av-base": "pe-av-base",
    "facebook/pe-av-large": "pe-av-large",
}


def audio_text_space(profile: "Profile | None" = None) -> str:
    return AUDIO_TEXT_SPACE[(profile or current()).audio_text]


# Names used before profiles existed.
_ALIASES = {"small": "balanced", "large": "best"}


@dataclass
class Hardware:
    device: str = "cpu"        # cuda, mps or cpu
    gpu: str = ""
    vram_gb: float = 0.0
    ram_gb: float = 0.0
    cpus: int = 0
    system: str = ""


def _ram_gb() -> float:
    try:
        if os.name == "nt":
            import ctypes

            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]

            m = MEMORYSTATUSEX()
            m.dwLength = ctypes.sizeof(m)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m))
            return m.ullTotalPhys / 2**30
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30
    except Exception:
        return 0.0


_DETECTED: Hardware | None = None


def detect() -> Hardware:
    """What this machine has. Asked once per process: importing torch to find
    out takes a second or two."""
    global _DETECTED
    if _DETECTED is not None:
        return _DETECTED
    _DETECTED = _detect()
    return _DETECTED


def _detect() -> Hardware:
    """Without importing torch where it can be helped: that takes seconds,
    and a job that finds everything cached should not pay it."""
    hw = Hardware(ram_gb=round(_ram_gb(), 1), cpus=os.cpu_count() or 0,
                  system=f"{platform.system()} {platform.machine()}")

    if sys.platform == "darwin":
        if platform.machine() == "arm64":
            # Apple Silicon shares memory between CPU and GPU.
            hw.device, hw.gpu, hw.vram_gb = "mps", "Apple GPU", hw.ram_gb
        return hw

    import shutil
    import subprocess

    smi = shutil.which("nvidia-smi")
    if smi:
        try:
            kw = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
            out = subprocess.run([smi, "--query-gpu=name,memory.total", "--format=csv,noheader,nounits"],
                                 capture_output=True, text=True, timeout=10, **kw)
            first = out.stdout.strip().splitlines()[0] if out.returncode == 0 and out.stdout.strip() else ""
            if first:
                name, mem = [x.strip() for x in first.rsplit(",", 1)]
                hw.device, hw.gpu, hw.vram_gb = "cuda", name, round(float(mem) / 1024, 1)
                return hw
        except Exception:
            pass

    # No nvidia-smi means no NVIDIA driver, so no CUDA. AMD cards (ROCm)
    # answer to torch's CUDA API too; only then is torch worth asking.
    if not shutil.which("rocm-smi"):
        return hw
    try:
        import torch

        if torch.cuda.is_available():
            props = torch.cuda.get_device_properties(0)
            hw.device, hw.gpu = "cuda", props.name
            hw.vram_gb = round(props.total_memory / 2**30, 1)
    except Exception:
        pass
    return hw


def recommend(hw: Hardware) -> str:
    if hw.device == "cuda":
        if hw.vram_gb >= 7.5:
            return "best"
        if hw.vram_gb >= 3.5:
            return "balanced"
        return "fast"
    if hw.device == "mps":
        return "balanced" if hw.ram_gb >= 15.5 else "fast"
    return "fast"


def profile_name() -> str:
    """The profile in force: MUSICTAGGER_PROFILE, else the older
    MUSICTAGGER_MODEL_SIZE, else what this machine can run."""
    raw = (os.environ.get("MUSICTAGGER_PROFILE") or os.environ.get("MUSICTAGGER_MODEL_SIZE") or "auto")
    name = _ALIASES.get(raw.strip().lower(), raw.strip().lower())
    if name in PROFILES:
        return name
    return recommend(detect())


def current() -> Profile:
    return PROFILES[profile_name()]


def main() -> int:
    hw = detect()
    rec = recommend(hw)
    print(json.dumps({
        "hardware": asdict(hw),
        "recommended": rec,
        "in_force": profile_name(),
        "profiles": {n: {"label": p.label, "needs": p.needs} for n, p in PROFILES.items()},
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
