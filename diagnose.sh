#!/usr/bin/env bash
# Answers "why is tagging doing nothing" without needing the app to start.
# Writes diagnose.txt next to this file; send that when reporting a problem.
# The Windows equivalent is diagnose.bat.
cd "$(dirname "$0")"
OUT="$(pwd)/diagnose.txt"

{
    echo "Music Tagger diagnosis"
    echo "Folder: $(pwd)"
    echo "System: $(uname -a)"
    echo

    echo "== Python =="
    if [ -x venv/bin/python ]; then
        echo "venv found"
        venv/bin/python -c "import sys;v=sys.version_info;print('SUPPORTED' if (3,12)<=v<(3,14) else 'UNSUPPORTED - needs 3.12 or 3.13, rerun setup.sh')" 2>&1
        venv/bin/python -c "import sys;print('version', sys.version)" 2>&1
        venv/bin/python -c "import torch;print('torch', torch.__version__, 'cuda', torch.cuda.is_available(), 'mps', getattr(torch.backends,'mps',None) is not None and torch.backends.mps.is_available())" 2>&1
        venv/bin/python -c "import transformers, numpy, sklearn;print('transformers', transformers.__version__);print('numpy', numpy.__version__)" 2>&1
        venv/bin/python -c "import muq;print('muq', getattr(muq,'__version__','unknown'))" 2>&1
        venv/bin/python -c "import PIL, pypdfium2, docx, trimesh;print('media readers ok: pillow', PIL.__version__, 'trimesh', trimesh.__version__)" 2>&1
    else
        echo "venv MISSING - run ./setup.sh"
    fi
    echo
    echo "== Python on PATH =="
    for p in python3.12 python3.13 python3; do command -v "$p" && "$p" -V; done 2>&1
    echo

    echo "== ffmpeg =="
    if [ -x bin/ffmpeg ]; then echo "found in bin"; bin/ffmpeg -version 2>&1 | head -1
    elif command -v ffmpeg >/dev/null 2>&1; then command -v ffmpeg; ffmpeg -version 2>&1 | head -1
    else echo "NOT FOUND - nothing can be decoded, so tagging will produce nothing"; fi
    echo

    echo "== Model =="
    if [ -f model/tagger.pkl ]; then echo "model/tagger.pkl found"; else echo "model/tagger.pkl MISSING"; fi
    echo

    echo "== The tagging job, asked to describe itself =="
    [ -x venv/bin/python ] && venv/bin/python tag_job.py --probe 2>&1
    echo
    echo "== The media job, asked to describe itself =="
    [ -x venv/bin/python ] && venv/bin/python media_job.py --probe 2>&1 | tail -8
    echo

    echo "== Last run of the app =="
    if [ -f logs/musictagger.log ]; then cat logs/musictagger.log
    else echo "no log yet - start the app and press Analyze once"; fi
} > "$OUT" 2>&1

echo "Written to diagnose.txt"
echo "Send that file when reporting a problem."
