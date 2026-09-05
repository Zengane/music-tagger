@echo off
cd /d "%~dp0"
title Build Music Tagger executable

if not exist "venv\Scripts\python.exe" (
    echo Run run.bat once first so the Python environment exists.
    pause & exit /b 1
)

echo Installing the small launcher build tools...
venv\Scripts\python.exe -m pip install -q pyinstaller pywebview
if errorlevel 1 (
    echo ERROR: Could not install the build tools.
    pause & exit /b 1
)

echo Building dist\MusicTagger.exe...
venv\Scripts\python.exe -m PyInstaller --noconfirm --clean --onefile --windowed --name MusicTagger launcher.py
if errorlevel 1 (
    echo ERROR: Build failed.
    pause & exit /b 1
)

echo.
echo Ready: %~dp0dist\MusicTagger.exe
pause
