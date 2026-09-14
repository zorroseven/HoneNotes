# Builds dist\HoneNotes.exe from launcher.cs, with index.html and icon.ico built in.
# Uses the C# compiler that ships with Windows (.NET Framework 4), so nothing extra to install.
#
#     powershell -ExecutionPolicy Bypass -File build.ps1

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
