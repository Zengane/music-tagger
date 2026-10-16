; Windows installer for Music Tagger. Built by make_release.py --installer,
; which passes the folder it assembled:
;
;   ISCC /DSourceDir=dist\MusicTagger /DOutDir=dist /DAppVersion=<commit> installer\MusicTagger.iss
;
; The app reads and writes everything relative to its own .exe (venv, cache,
; prefs), so it installs per user into %LOCALAPPDATA%\Programs, where it can
; write without admin rights. Program Files would make every save fail.

#ifndef SourceDir
  #define SourceDir "..\dist\MusicTagger"
#endif
#ifndef OutDir
  #define OutDir "..\dist"
#endif
#ifndef AppVersion
  #define AppVersion "dev"
#endif
#ifndef IconFile
  #define IconFile "..\MusicTagger.ico"
#endif

[Setup]
AppId={{6C1F3E2A-8B4D-4F7E-9A51-2D7C0B9E4A13}
AppName=Music Tagger
AppVersion={#AppVersion}
AppPublisher=Zengane
AppPublisherURL=https://github.com/Zengane/music-tagger
DefaultDirName={localappdata}\Programs\MusicTagger
DefaultGroupName=Music Tagger
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutDir}
OutputBaseFilename=MusicTagger-Setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\MusicTagger.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Music Tagger"; Filename: "{app}\MusicTagger.exe"
Name: "{group}\Set up AI features"; Filename: "{app}\setup.bat"; WorkingDir: "{app}"
Name: "{group}\Install Premiere panel"; Filename: "{app}\premiere\install-premiere-extension.bat"; WorkingDir: "{app}\premiere"
Name: "{group}\Uninstall Music Tagger"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Music Tagger"; Filename: "{app}\MusicTagger.exe"; Tasks: desktopicon

[Run]
; setup.bat asks its own questions and downloads a few GB, so it runs in its
; own window and the user can untick it and run it later from the Start menu.
Filename: "{app}\setup.bat"; WorkingDir: "{app}"; Description: "Set up the AI features now (downloads a few GB)"; Flags: postinstall shellexec skipifsilent
Filename: "{app}\MusicTagger.exe"; Description: "Start Music Tagger"; Flags: postinstall nowait skipifsilent unchecked

[UninstallDelete]
; Made after install by setup.bat and the app. Tags are not here: they live in
; sidecars beside the user's own files and are left alone.
Type: filesandordirs; Name: "{app}\venv"
Type: filesandordirs; Name: "{app}\bin"
Type: filesandordirs; Name: "{app}\cache"
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\__pycache__"
Type: filesandordirs; Name: "{app}\mtag\__pycache__"
