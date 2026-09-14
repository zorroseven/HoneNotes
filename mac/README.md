# Hone Notes — Mac version

The Hone Notes app page is the same on Mac and Windows. This folder only adds the small
menu-bar helper that powers the one-press **Copy report** on a Mac (the Windows `.exe` does
the same job on Windows).

## Build it (on a Mac, once)

1. Install Apple's command-line tools if you don't have them:
   ```
   xcode-select --install
   ```
2. Copy the whole `HoneNotes` folder to the Mac (you need `index.html` and this `mac` folder).
3. In Terminal:
   ```
   cd HoneNotes/mac
   bash build.sh
   ```
4. You get:
   - `mac/dist/Hone Notes.app` — the app
   - `mac/Hone-Notes-mac.zip` — send this to Mac coworkers

## First run (each Mac)

1. Double-click **Hone Notes.app**. macOS may say it's from an unidentified developer:
   right-click the app → **Open** → **Open**.
2. It asks for **Accessibility** permission. Open
   **System Settings > Privacy & Security > Accessibility**, turn **Hone Notes** on.
   This lets Copy report watch your Cmd+V and paste the screenshots for you.
3. Open Hone Notes again. It lives in the menu bar (top-right, "HN"). The app window opens in
   Chrome or Edge if you have one, otherwise your default browser.

## Using it

Same as Windows, but with **Cmd** instead of Ctrl:
- Paste a screenshot: **Cmd+V**
- Copy report, then one **Cmd+V** on the website pastes the notes + each screenshot in turn.

## Updating

Quit from the menu bar (**HN > Quit**) before replacing the app with a new build, then open it again.

## Notes / limits

- Needs Google Chrome or Microsoft Edge for the app to open in its own window. Without either it
  opens in the default browser (Safari), which still works but not as its own window.
- Your notes are stored by the browser on that Mac (same idea as Windows).
- If Copy report pastes the notes but no screenshots, check Accessibility is on, then look at the
  log at `/tmp` … actually `$TMPDIR/HoneNotes/helper.log` (paste that path into Finder's
  **Go > Go to Folder**). Send me the last lines.

## Status

This helper was written on a Windows PC and **has not been compiled or tested on a Mac yet**.
Run `build.sh` and send me any compiler errors or runtime issues; expect one or two rounds of
fixes before it's solid, like the Windows version needed.
