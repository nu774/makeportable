@echo off
rem Extract CoreAudioToolbox.dll / CoreFoundation.dll and their dependencies
rem from the iTunes installer into QTfiles (32bit) or QTfiles64 (64bit).
rem
rem usage: extract_qtfiles.bat [path\to\iTunesSetup.exe or iTunes64Setup.exe]
rem requires: powershell, expand.exe and msiexec (all bundled with Windows 10/11)
setlocal

rem --- locate installer ---
set "INSTALLER=%~f1"
if not defined INSTALLER if exist "iTunes64Setup.exe" set "INSTALLER=%CD%\iTunes64Setup.exe"
if not defined INSTALLER if exist "iTunesSetup.exe" set "INSTALLER=%CD%\iTunesSetup.exe"
if not defined INSTALLER goto usage
if not exist "%INSTALLER%" (
    echo ERROR: installer not found: "%INSTALLER%"
    exit /b 1
)

set "WORK=%TEMP%\itunes_extract_%RANDOM%%RANDOM%"
set "CABDIR=%WORK%\cab"
set "MSIDIR=%WORK%\msi"
set "CABFILE=%WORK%\payload.cab"
mkdir "%CABDIR%" || exit /b 1

rem --- step 1: carve the cabinet out of the installer exe ---
rem Cut the embedded cabinet out into a plain .cab file with the PowerShell
rem code at the bottom of this file, so that expand.exe can read it.
echo Extracting cabinet from "%INSTALLER%" ...
set "SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((Get-Content -LiteralPath $env:SELF -Raw) -replace '(?s)^.*?\r?\n#PS1\r?\n')"
if errorlevel 1 (
    echo ERROR: failed to extract the cabinet from the installer.
    goto fail
)

rem --- step 2: pull iTunes.msi / iTunes64.msi out of the cabinet ---
rem expand.exe rather than tar.exe: libarchive 3.8 fails to decompress the
rem LZX stream of the 32bit installer.
expand.exe "%CABFILE%" -F:iTunes*.msi "%CABDIR%" >nul
if errorlevel 1 (
    echo ERROR: failed to extract the msi from the cabinet.
    goto fail
)
del "%CABFILE%"

:msi_found
if exist "%CABDIR%\iTunes64.msi" (
    set "MSI=%CABDIR%\iTunes64.msi"
    set "OUTDIR=%CD%\QTfiles64"
) else if exist "%CABDIR%\iTunes.msi" (
    set "MSI=%CABDIR%\iTunes.msi"
    set "OUTDIR=%CD%\QTfiles"
) else (
    echo ERROR: neither iTunes64.msi nor iTunes.msi was found in the installer.
    goto fail
)

rem --- step 3: administrative install = plain extraction of the msi ---
echo Extracting "%MSI%" ...
start "" /wait msiexec.exe /a "%MSI%" /qn TARGETDIR="%MSIDIR%"
if errorlevel 1 (
    echo ERROR: msiexec failed with exit code %ERRORLEVEL%.
    goto fail
)

rem --- step 4: move the wanted DLLs ---
if not exist "%OUTDIR%" mkdir "%OUTDIR%"
if not exist "%OUTDIR%" (
    echo ERROR: cannot create "%OUTDIR%".
    goto fail
)
rem note: for /r does not check existence for names without wildcards,
rem hence the explicit "if exist".
for /r "%MSIDIR%" %%F in (
    CoreAudioToolbox.dll CoreFoundation.dll
    libdispatch.dll objc.dll ASL.dll
    libicuin.dll libicuuc.dll icudt*.dll
    msvcp*.dll msvcr*.dll vcruntime*.dll
) do if exist "%%F" (
    echo   %%~nxF
    move /y "%%F" "%OUTDIR%" >nul
)

rem --- step 5: clean up ---
rd /s /q "%WORK%"

if not exist "%OUTDIR%\CoreAudioToolbox.dll" goto incomplete
if not exist "%OUTDIR%\CoreFoundation.dll" goto incomplete
echo Done: "%OUTDIR%"
exit /b 0

:incomplete
echo ERROR: CoreAudioToolbox.dll / CoreFoundation.dll were not found in the msi.
exit /b 1

:fail
rd /s /q "%WORK%" 2>nul
exit /b 1

:usage
echo usage: %~nx0 [iTunesSetup.exe ^| iTunes64Setup.exe]
echo   Without an argument, iTunes64Setup.exe or iTunesSetup.exe in the
echo   current directory is used.
exit /b 1

rem ---- PowerShell part: everything below the marker line is run by step 1 ----
#PS1
$ErrorActionPreference = 'Stop'
$in = [IO.File]::OpenRead($env:INSTALLER)
try {
    # the cabinet starts right after the small setup stub; 16MB is plenty
    $buf = New-Object byte[] (16MB)
    $n = 0
    while ($n -lt $buf.Length -and ($r = $in.Read($buf, $n, $buf.Length - $n)) -gt 0) { $n += $r }
    # Latin-1 maps bytes to chars 1:1, so String.IndexOf works as a byte search
    $s = [Text.Encoding]::GetEncoding(28591).GetString($buf, 0, $n)
    $i = -1
    $len = 0
    while (($i = $s.IndexOf("MSCF`0`0`0`0", $i + 1, [StringComparison]::Ordinal)) -ge 0) {
        if ($i + 36 -gt $n) { $i = -1; break }
        # CFHEADER: cbCabinet at +8, versionMinor/Major (3, 1) at +24/+25
        $len = [BitConverter]::ToUInt32($buf, $i + 8)
        if ($buf[$i + 24] -eq 3 -and $buf[$i + 25] -eq 1 -and $i + $len -le $in.Length) { break }
    }
    if ($i -lt 0) { throw 'cabinet not found in the installer' }
    $out = [IO.File]::Create($env:CABFILE)
    try {
        $in.Position = $i
        $chunk = New-Object byte[] (1MB)
        while ($len -gt 0) {
            $r = $in.Read($chunk, 0, [Math]::Min($len, $chunk.Length))
            if ($r -le 0) { throw 'unexpected end of file' }
            $out.Write($chunk, 0, $r)
            $len -= $r
        }
    } finally { $out.Close() }
} finally { $in.Close() }
