#!/bin/bash
# Build the CLI and the Finder-launchable menu bar app.
set -e
cd "$(dirname "$0")"
swiftc -O -o Tugboat Tugboat.swift \
    -framework Cocoa -framework SwiftUI -framework Combine
mkdir -p Tugboat.app/Contents/MacOS
cp Tugboat Tugboat.app/Contents/MacOS/Tugboat
cat > Tugboat.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Tugboat</string>
<key>CFBundleIdentifier</key><string>com.brb.tugboat</string>
<key>CFBundleName</key><string>Tugboat</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - Tugboat.app
echo "built: $(pwd)/Tugboat.app"
