# Hone Notes

A small desktop app for keeping notes and screenshots per person. **Copy report** puts the notes and
every screenshot on the clipboard, so a single paste drops the whole report into another app.

The app itself is one web page ([index.html](index.html)). A small helper runs alongside it —
a tray app on Windows, a menu-bar app on Mac — so the page can put real image files on the clipboard.

## Windows

### Install / update

Run `HoneNotes.exe` from anywhere (e.g. Downloads). It installs itself to
`%LOCALAPPDATA%\Programs\HoneNotes`, adds Desktop and Start menu shortcuts, and starts.

To update, run a newer `HoneNotes.exe` the same way — it closes the running copy and replaces it.
Notes are kept.

### Build

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

Produces `dist\HoneNotes.exe` with `index.html` and `icon.ico` built in. Uses the C# compiler that
ships with Windows, so nothing extra needs installing.

### Troubleshooting

The helper logs to `%TEMP%\HoneNotes\helper.log`.

## Mac

See [mac/README.md](mac/README.md). The Mac helper has not been tested on a Mac yet.

## Project layout

| File | What it is |
| --- | --- |
| `index.html` | The app page (shared by Windows and Mac) |
| `launcher.cs` | Windows installer + tray helper |
| `build.ps1` | Builds the Windows exe |
| `icon.ico` | App icon |
| `mac/` | macOS menu-bar helper and its build script |

Built files (`dist/`, `*.exe`, `mac/dist/`, zips) aren't committed. Attach them to a
[GitHub Release](../../releases) instead.
