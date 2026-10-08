# Runs Hone Notes without an exe, for machines where Smart App Control blocks the unsigned
# HoneNotes.exe. Compiles launcher.cs in memory and runs it in place (--hosted).
# build.ps1 installs this next to launcher.cs and icon.ico, with shortcuts that start it hidden.

$ErrorActionPreference = 'Stop'
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'launcher.cs') `
        -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Web.Extensions
    [HoneNotes]::Main(@('--hosted'))
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("Hone Notes couldn't start:`n`n" + $_, 'Hone Notes') | Out-Null
}
