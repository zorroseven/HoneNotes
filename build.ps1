# Builds dist\HoneNotes.exe from launcher.cs, with index.html and icon.ico built in,
# then installs it so the Desktop / Start menu / pinned shortcuts run what was just built.
# Uses the C# compiler that ships with Windows (.NET Framework 4), so nothing extra to install.
#
#     powershell -ExecutionPolicy Bypass -File build.ps1              # build + install
#     powershell -ExecutionPolicy Bypass -File build.ps1 -NoInstall   # build only, for a Release

param([switch]$NoInstall)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "Can't find the C# compiler at $csc" }

New-Item -ItemType Directory -Force dist | Out-Null

& $csc /nologo /target:winexe /optimize+ `
    /out:dist\HoneNotes.exe `
    /win32icon:icon.ico `
    /resource:index.html,HoneNotes.index.html `
    /reference:System.Web.Extensions.dll `
    /reference:System.Windows.Forms.dll `
    /reference:System.Drawing.dll `
    launcher.cs
if ($LASTEXITCODE -ne 0) { throw "Build failed" }

Write-Host "Built dist\HoneNotes.exe"
if ($NoInstall) { return }

# Installing is just running the fresh exe: it closes the copy in the tray, replaces
# %LOCALAPPDATA%\Programs\HoneNotes, refreshes the shortcuts and starts again. Notes are kept.
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\HoneNotes'
$installed = Join-Path $installDir 'HoneNotes.exe'
$want = (Get-FileHash dist\HoneNotes.exe -Algorithm SHA256).Hash

# Point the installed app at this checkout, so editing index.html is live the next time the app
# is opened, with no rebuild. Written before the install so the copy it starts already sees it.
New-Item -ItemType Directory -Force $installDir | Out-Null
[IO.File]::WriteAllText((Join-Path $installDir 'dev-source.txt'), $PSScriptRoot)

Start-Process -FilePath (Join-Path $PSScriptRoot 'dist\HoneNotes.exe')

# The install hands off to a new process, so wait for the copy on disk to match this build
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $have = try { (Get-FileHash $installed -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $null }
    if ($have -eq $want) {
        Write-Host "Installed to $installDir"
        Write-Host "Live page:   $PSScriptRoot\index.html (edit it, then just reopen Hone Notes)"
        return
    }
}
Write-Warning "Built, but the install didn't finish in time. See %TEMP%\HoneNotes\helper.log"
