#!/bin/bash
set -euo pipefail
binary=${1:?Usage: package-app.sh executable app-directory}
app=${2:?Usage: package-app.sh executable app-directory}
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/M3Desk"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>M3Desk</string>
<key>CFBundleIdentifier</key><string>local.m3desk.mvp</string>
<key>CFBundleName</key><string>M3 Desk</string>
<key>CFBundleDisplayName</key><string>M3 Desk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.3</string>
<key>CFBundleVersion</key><string>2026100203</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# File-provider FinderInfo is not app content and prevents ad-hoc signing.
xattr -r -d com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -r -d com.apple.ResourceFork "$app" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
