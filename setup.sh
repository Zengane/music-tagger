#!/usr/bin/env bash
# Music Tagger setup for macOS and Linux. The Windows equivalent is setup.bat.
#
# Builds the Python environment the AI features run in: tagging, the maps,
# filing, imports, and the analysis of images, video, 3D and documents.
# Browsing, playing and tagging by hand work without it.
#
# Nothing is installed outside this folder except what pip and Hugging Face
# cache in your home folder (the models: several GB, in ~/.cache/huggingface).
set -uo pipefail
cd "$(dirname "$0")"

echo "Music Tagger needs a Python environment for the AI features."
echo "Browsing, playing and tagging by hand work without it."
echo

ok_python() {
    "$1" -c 'import sys; sys.exit(0 if (3,12) <= sys.version_info < (3,14) else 1)' >/dev/null 2>&1
}

# The version is checked, not assumed: an older Python fails deep inside pip
# with a message about numpy that says nothing about Python at all.
PY=""
for candidate in python3.12 python3.13 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && ok_python "$candidate"; then
        PY="$(command -v "$candidate")"
        break
    fi
done

if [ -z "$PY" ]; then
    echo "  Music Tagger needs Python 3.12 or 3.13."
    command -v python3 >/dev/null 2>&1 && echo "  You have: $(python3 -V 2>&1)"
    echo
    if [ "$(uname)" = "Darwin" ]; then
        echo "  Install it with Homebrew:  brew install python@3.12"
        echo "  or from https://www.python.org/downloads/"
    else
        echo "  Install it with your package manager, for example:"
        echo "    Ubuntu/Debian:  sudo apt install python3.12 python3.12-venv"
        echo "    Fedora:         sudo dnf install python3.12"
        echo "    Arch:           sudo pacman -S python"
    fi
    echo "  Then run this again."
    exit 1
fi
echo "Using $("$PY" -V 2>&1) at $PY"

if [ "$(uname)" = "Darwin" ] && [ "$(uname -m)" != "arm64" ]; then
    echo
    echo "  Warning: PyTorch no longer ships for Intel Macs. The AI features"
    echo "  need Apple Silicon (M1 or later) on macOS 14 or newer."
    echo
fi

# A venv built by the wrong Python cannot be repaired by installing into it.
if [ -x venv/bin/python ] && ! ok_python venv/bin/python; then
    echo
    echo "  The existing venv folder was built with an unsupported Python."
    read -r -p "  Delete venv and rebuild it? [y/N] " answer
    case "$answer" in
        [yY]*) rm -rf venv ;;
        *) echo "Left alone. Nothing was changed."; exit 1 ;;
    esac
fi

# ffmpeg is not optional: every audio and video file is decoded through it.
# It is looked for in bin/ beside the app first, then on PATH.
if [ -x bin/ffmpeg ] || command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg: found"
else
    echo
    echo "  ffmpeg is needed to read audio and video, and it is not installed."
    if [ "$(uname)" = "Darwin" ]; then
        if command -v brew >/dev/null 2>&1; then
            read -r -p "  Install it now with Homebrew (brew install ffmpeg)? [Y/n] " answer
            case "$answer" in
                [nN]*) echo "  Skipped. Install it later with: brew install ffmpeg" ;;
                *) brew install ffmpeg ;;
            esac
        else
            echo "  Install Homebrew (https://brew.sh), then: brew install ffmpeg"
            echo "  Or put the ffmpeg and ffprobe programs in a folder called bin"
            echo "  next to the app."
        fi
    else
        echo "  Install it with your package manager, for example:"
        echo "    Ubuntu/Debian:  sudo apt install ffmpeg"
        echo "    Fedora:         sudo dnf install ffmpeg   (from RPM Fusion)"
        echo "    Arch:           sudo pacman -S ffmpeg"
        echo "  Or put the ffmpeg and ffprobe programs in a folder called bin"
        echo "  next to the app."
    fi
    echo
fi

if [ ! -d venv ]; then
    echo "Creating the environment. This takes a minute."
    if ! "$PY" -m venv venv; then
        echo "Could not create venv. On Debian/Ubuntu install python3.12-venv first."
        exit 1
    fi
fi

echo "Installing packages. This downloads a few GB and takes a while."
venv/bin/python -m pip install --upgrade pip
if ! venv/bin/python -m pip install -r requirements.txt; then
    echo
    echo "Install failed. Run ./diagnose.sh and read diagnose.txt."
    exit 1
fi

echo
echo "Done. Start the app: ./MusicTagger"
