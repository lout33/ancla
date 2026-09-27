#!/bin/bash
# Build build/Ancla.app from src/*.swift.
# Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Ancla.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O src/*.swift -o "$APP/Contents/MacOS/Ancla"
cp resources/Info.plist "$APP/Contents/Info.plist"
echo "built: $APP"
