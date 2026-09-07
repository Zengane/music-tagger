@echo off
REM Builds ZenDropSend.exe with the C# compiler that ships with .NET Framework.
REM No SDK install needed.
setlocal
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
    echo Could not find csc.exe. Is .NET Framework 4 installed?
    exit /b 1
)
"%CSC%" /nologo /target:winexe /optimize+ /out:"%~dp0ZenDropSend.exe" /r:System.dll /r:System.Windows.Forms.dll "%~dp0ZenDropSend.cs"
if errorlevel 1 exit /b 1
echo Built "%~dp0ZenDropSend.exe"
