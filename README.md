# Hone Notes

A small desktop app for keeping notes and screenshots per person. **Copy report** puts the notes and
every screenshot on the clipboard, so a single paste drops the whole report into another app.

The app itself is one web page ([index.html](index.html)). A small helper runs alongside it —
a tray app on Windows, a menu-bar app on Mac — so the page can put real image files on the clipboard.

## Windows

### Install / update

Open PowerShell (Start → type "PowerShell"), paste this and press Enter:

```powershell
irm https://raw.githubusercontent.com/zorroseven/HoneNotes/main/install.ps1 | iex
```

It installs to `%LOCALAPPDATA%\Programs\HoneNotes`, adds Desktop and Start menu shortcuts, and
starts. To update, run the same line again — it closes the running copy and replaces it. Notes are kept.

This installs Hone Notes as a PowerShell script ([HoneNotes.ps1](HoneNotes.ps1), which compiles
[launcher.cs](launcher.cs) in memory) rather than an exe, because Windows 11's Smart App Control
blocks the unsigned `HoneNotes.exe` outright, with no "Run anyway". On a PC without Smart App
Control the exe from a [Release](../../releases) still works: run it from anywhere and click
**More info** → **Run anyway** at the "Windows protected your PC" prompt.

### Build

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

Produces `dist\HoneNotes.exe` with `index.html` and `icon.ico` built in, then installs it, so the
Desktop / Start menu / pinned shortcuts run what you just built. Uses the C# compiler that ships
with Windows, so nothing extra needs installing. When Smart App Control is on, it installs the
script version with `install.ps1` instead, since the exe can't run.

Add `-NoInstall` to only produce `dist\HoneNotes.exe` without touching the installed copy, which is
what you want when building a file to attach to a Release.

### Editing the page

Installing also writes `dev-source.txt` into the install folder, holding the path of this checkout.
While that file is there the app reads `index.html` from the checkout every time it opens, so
editing the page is live on the next open — no rebuild, no reinstall. Rebuild only when you change
`launcher.cs`, or to produce an exe for someone else.

Delete `dev-source.txt` to go back to the installed page. Anywhere the file is absent — every
machine that installs from GitHub — the installed page is used, so this stays a local
convenience and never ships.

### Troubleshooting

The helper logs to `%TEMP%\HoneNotes\helper.log`.

## Mac

See [mac/README.md](mac/README.md). The Mac helper has not been tested on a Mac yet.

## Project layout

| File | What it is |
| --- | --- |
| `index.html` | The app page (shared by Windows and Mac) |
| `launcher.cs` | Windows installer + tray helper |
| `HoneNotes.ps1` | Runs `launcher.cs` without an exe (for Smart App Control) |
| `install.ps1` | Installs / updates the script version, from GitHub or a checkout |
| `build.ps1` | Builds the Windows exe |
| `icon.ico` | App icon |
| `mac/` | macOS menu-bar helper and its build script |

Built files (`dist/`, `*.exe`, `mac/dist/`, zips) aren't committed. Attach them to a
[GitHub Release](../../releases) instead.
