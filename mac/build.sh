#!/bin/bash
# Builds "Hone Notes.app" for macOS from HoneNotesHelper.swift + the shared index.html.
#
# Run this on a Mac that has Xcode's command-line tools:
#     xcode-select --install     # once, if you don't have them
#     cd mac && bash build.sh
#
# Result: mac/dist/Hone Notes.app  (and Hone-Notes-mac.zip to send to people).

set -e
cd "$(dirname "$0")"

APP="dist/Hone Notes.app"
PAGE="../index.html"

if [ ! -f "$PAGE" ]; then
  echo "Can't find $PAGE — run this from the mac/ folder inside HoneNotes." >&2
  exit 1
fi

echo "Cleaning…"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling helper…"
swiftc -O HoneNotesHelper.swift -o "$APP/Contents/MacOS/HoneNotes"

echo "Bundling app page…"
cp "$PAGE" "$APP/Contents/Resources/index.html"

echo "Writing Info.plist…"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hone Notes</string>
  <key>CFBundleDisplayName</key><string>Hone Notes</string>
  <key>CFBundleIdentifier</key><string>com.honenotes.helper</string>
  <key>CFBundleExecutable</key><string>HoneNotes</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc code signature. Helps macOS remember the Accessibility permission across rebuilds.
echo "Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" || echo "  (codesign skipped — not fatal)"

echo "Zipping for sharing…"
( cd dist && zip -qry ../Hone-Notes-mac.zip "Hone Notes.app" )

echo
echo "Done:"
echo "  App:  mac/$APP"
echo "  Zip:  mac/Hone-Notes-mac.zip  (send this to Mac users)"
echo
echo "First run: double-click Hone Notes.app, then allow it under"
echo "System Settings > Privacy & Security > Accessibility, and open it again."
