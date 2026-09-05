@echo off
cd /d "%~dp0"
title Build Music Tagger

:: Builds the native front end. The Python side is not compiled ??? tag_job.py is
:: launched from the venv when you press Analyze and is read from source, so a
:: change there needs no rebuild.

if "%ODIN%"=="" set "ODIN=C:\Odin\dist\odin.exe"

if not exist "%ODIN%" (
    echo ERROR: Odin not found at %ODIN%
    echo Download it from https://odin-lang.org and unzip it, or set ODIN to odin.exe.
    pause & exit /b 1
)

:: The tag vocabulary lives in mtag\taxonomy.py. Regenerate the front end's copy
:: first so the two can never drift apart.
if exist "venv\Scripts\python.exe" (
    echo Regenerating the tag vocabulary...
    venv\Scripts\python.exe ui\gen_taxonomy.py
    if errorlevel 1 (
        echo ERROR: Could not regenerate ui\taxonomy.odin
        pause & exit /b 1
    )
) else (
    echo No venv yet, using the checked-in ui\taxonomy.odin.
)

:: A running copy holds the exe open, and the linker's failure is one line in
:: the middle of a lot of output. Two rounds of "that bug is still there" came
:: from a build that never actually replaced the program.
tasklist /fi "imagename eq MusicTagger.exe" 2>nul | find /i "MusicTagger.exe" >nul
if not errorlevel 1 (
    echo.
    echo   Music Tagger is running, so its .exe cannot be replaced.
    echo   Close it and run this again.
    echo.
    pause & exit /b 1
)

echo Building MusicTagger.exe...
:: -subsystem:windows keeps a console from opening behind the window.
"%ODIN%" build ui -out:MusicTagger.exe -o:speed -subsystem:windows -resource:app.rc
if errorlevel 1 (
    echo ERROR: Build failed.
    pause & exit /b 1
)

:: A second console build of the same code, for the self test. It is the same
:: program: --selftest needs a console to print to.
echo Building mtag-test.exe...
"%ODIN%" build ui -out:mtag-test.exe -o:speed
if errorlevel 1 (
    echo ERROR: Test build failed.
    pause & exit /b 1
)

echo.
echo Ready: %~dp0MusicTagger.exe
echo Check it with: mtag-test.exe --selftest "H:\Media Browser\Mega Music Pack"
pause

