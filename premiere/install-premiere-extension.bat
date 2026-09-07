@echo off
setlocal
cd /d "%~dp0"
title Install the Premiere extension

echo Zen Drop - the Premiere panel Music Tagger sends clips to
echo.
echo This will:
echo   1. copy the panel to your Adobe CEP extensions folder
echo   2. allow Premiere to load unsigned panels (a per-user registry setting)
echo   3. write the panel's default settings if it has none yet
echo.
echo Nothing needs administrator rights, and nothing outside your own user
echo account is changed. Close Premiere before continuing.
echo.
pause

set "DEST=%APPDATA%\Adobe\CEP\extensions\ZenDrop"

if not exist "ZenDrop\CSXS\manifest.xml" (
    echo ERROR: ZenDrop\CSXS\manifest.xml is missing. Unzip the whole folder
    echo and run this again from inside it.
    pause & exit /b 1
)

echo Copying to "%DEST%"
if not exist "%APPDATA%\Adobe\CEP\extensions" mkdir "%APPDATA%\Adobe\CEP\extensions"
robocopy "ZenDrop" "%DEST%" /E /NFL /NDL /NJH /NJS /R:1 /W:1 >nul
if errorlevel 8 (
    echo ERROR: could not copy the panel. Is Premiere still open?
    pause & exit /b 1
)

rem Premiere refuses to load an unsigned panel unless this is set. The number
rem is the CSXS runtime version and differs between Premiere releases, so all
rem the plausible ones are set - a key for a version you do not have is inert.
echo Allowing unsigned panels
for %%V in (9 10 11 12 13) do (
    reg add "HKCU\Software\Adobe\CSXS.%%V" /v PlayerDebugMode /t REG_SZ /d 1 /f >nul 2>nul
)

set "CFG=%APPDATA%\Zengane\Zen Drop"
if not exist "%CFG%\settings.json" (
    echo Writing default settings
    if not exist "%CFG%" mkdir "%CFG%"
    > "%CFG%\settings.json" echo {"version":1,"port":47821,"bin":"Music Tagger","mode":"timeline","fallback":"newtrack","checkAudio":true,"skipLocked":true,"focusPremiere":true,"logLines":60}
) else (
    echo Keeping the settings you already have
)

echo.
echo Done.
echo.
echo   1. Start Premiere Pro.
echo   2. Window - Extensions - Zen Drop. Leave the panel open; it is the
echo      listener, so nothing arrives while it is closed.
echo   3. In Music Tagger, right click a track and choose "Send to Premiere".
echo.
echo To remove it later, delete:
echo   %DEST%
echo.
pause
