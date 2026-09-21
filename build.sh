#!/bin/bash
# Build Ancla.app — native full-screen anchor overlay
# Usage: ./build.sh
set -e
cd "$(dirname "$0")"

swiftc -O src/Ancla.swift -o build/ancla

APP=build/Ancla.app
mkdir -p "$APP/Contents/MacOS"
cp build/ancla "$APP/Contents/MacOS/Ancla"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.pepe.ancla</string>
    <key>CFBundleName</key>
    <string>Ancla</string>
    <key>CFBundleExecutable</key>
    <string>Ancla</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
echo "built: $APP"
