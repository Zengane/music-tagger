@echo off
:: Double-clicked, a batch file's window closes the moment anything goes wrong,
:: taking the error with it. So it runs itself again inside a window that
:: stays open.
if not defined MT_BUILD_INNER (
    set "MT_BUILD_INNER=1"
    cmd /k "%~f0"
    exit /b
)
cd /d "%~dp0"
title Build Music Tagger

:: Builds the native front end. The Python side is not compiled: tag_job.py is
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

:: Which commit this is, shown in the title bar and in Settings, About.
:: Read by a small Python script, because GitHub Desktop keeps git off PATH.
set "BUILD_ID=unknown"
if exist "venv\Scripts\python.exe" for /f "delims=" %%i in ('venv\Scripts\python.exe ui\build_id.py') do set "BUILD_ID=%%i"

echo Building MusicTagger.exe (build %BUILD_ID%)...
:: -subsystem:windows keeps a console from opening behind the window.
"%ODIN%" build ui -out:MusicTagger.exe -o:speed -subsystem:windows -resource:app.rc -define:BUILD_ID=%BUILD_ID%
if errorlevel 1 (
    echo.
    echo   ==========================================================
    echo     BUILD FAILED. MusicTagger.exe was NOT updated.
    echo     The old version is still there. Copy the error above
    echo     and send it over.
    echo   ==========================================================
    echo.
    pause & exit /b 1
)

:: A second console build of the same code, for the self test. It is the same
:: program: --selftest needs a console to print to.
echo Building mtag-test.exe...
"%ODIN%" build ui -out:mtag-test.exe -o:speed -define:BUILD_ID=%BUILD_ID%
if errorlevel 1 (
    echo ERROR: Test build failed.
    pause & exit /b 1
)

echo.
echo Ready: %~dp0MusicTagger.exe
echo The title bar should read "build %BUILD_ID%". If it shows something else,
echo an old copy is running.
echo Check it with: mtag-test.exe --selftest "<your library folder>"
pause

