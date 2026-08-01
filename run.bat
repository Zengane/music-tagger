@echo off
cd /d "%~dp0"
title Music Tagger v2

if not exist "venv\Scripts\activate.bat" (
    echo [1/3] Creating virtual environment...
    py -3.12 -m venv venv
    if errorlevel 1 (
        echo ERROR: Python 3.12 not found. Install it from python.org.
        echo Python 3.13+ is not supported: the CUDA torch wheels lag behind.
        pause & exit /b 1
    )
    echo [2/3] Installing dependencies ^(~4 GB, one time^)...
    venv\Scripts\python.exe -m pip install -q --upgrade pip
    venv\Scripts\python.exe -m pip install -r requirements.txt
    if errorlevel 1 (
        echo ERROR: Failed to install dependencies.
        pause & exit /b 1
    )
) else (
    echo [1/3] Virtual environment found.
    echo [2/3] Skipping install. Delete the venv folder to reinstall.
)

:: v1 shipped a CPU torch for months without anyone noticing. Fail loudly instead.
venv\Scripts\python.exe -c "import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)"
if errorlevel 1 (
    echo.
    echo WARNING: torch cannot see the GPU. Tagging will run on the CPU, ~40x slower.
    echo   venv\Scripts\python.exe -m pip install --force-reinstall -r requirements.txt
    echo.
    pause
)

if not exist "model\tagger.pkl" (
    echo.
    echo No trained model yet. Train one first, e.g.:
    echo   venv\Scripts\python.exe train.py "H:\Media Browser\Mega Music Pack"
    echo.
    pause & exit /b 1
)

echo [3/3] Starting Music Tagger...
echo.
echo  Browser opens automatically. Close this window to stop.
echo.
venv\Scripts\python.exe app.py
pause
