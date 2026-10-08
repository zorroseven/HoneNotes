# Installs (or updates) Hone Notes on Windows without an exe, so Smart App Control has nothing to block.
# On a new PC, paste this into PowerShell:
#
#     irm https://raw.githubusercontent.com/zorroseven/HoneNotes/main/install.ps1 | iex
#
# Run from a checkout instead (build.ps1 does this), it installs the files from that checkout.
# Either way it copies HoneNotes.ps1, launcher.cs, index.html and icon.ico to
# %LOCALAPPDATA%\Programs\HoneNotes, adds Desktop + Start menu shortcuts and starts it. Notes are kept.

$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\HoneNotes'
$files = 'HoneNotes.ps1', 'launcher.cs', 'index.html', 'icon.ico'
$raw = 'https://raw.githubusercontent.com/zorroseven/HoneNotes/main/'

New-Item -ItemType Directory -Force $installDir | Out-Null

# Ask a running copy to quit (no Origin header, like a newer exe would) so the new code is used
try { Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'http://localhost:47831/quit' -TimeoutSec 2 | Out-Null; Start-Sleep -Milliseconds 500 } catch { }

if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'launcher.cs'))) {
    foreach ($f in $files) { Copy-Item (Join-Path $PSScriptRoot $f) $installDir -Force }
}
else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($f in $files) {
        $out = Join-Path $installDir $f
        Invoke-WebRequest -UseBasicParsing -Uri ($raw + $f) -OutFile $out
        Unblock-File $out
    }
    # A dev-source.txt from a checkout on this PC would make the app ignore the page just downloaded
    Remove-Item (Join-Path $installDir 'dev-source.txt') -Force -ErrorAction SilentlyContinue
}

# An exe from an older install would only bring the Smart App Control popup back
Remove-Item (Join-Path $installDir 'HoneNotes.exe') -Force -ErrorAction SilentlyContinue

$script = Join-Path $installDir 'HoneNotes.ps1'
$shell = New-Object -ComObject WScript.Shell
foreach ($dir in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('DesktopDirectory')) {
    $lnk = $shell.CreateShortcut((Join-Path $dir 'Hone Notes.lnk'))
    $lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
    $lnk.WorkingDirectory = $installDir
    $lnk.IconLocation = (Join-Path $installDir 'icon.ico') + ',0'
    $lnk.Description = 'Hone Notes'
    $lnk.WindowStyle = 7 # minimized, so the console doesn't flash up before -WindowStyle Hidden applies
    $lnk.Save()
}

Start-Process (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Hone Notes.lnk')
Write-Host "Hone Notes is installed to $installDir"
Write-Host "Open it any time from the Hone Notes icon on your desktop or in the Start menu."
