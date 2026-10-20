#!/bin/zsh
# Build Overflow Monitor.app into /Applications and (re)launch it. Needs Xcode command line tools.
set -e
cd "$(dirname "$0")"
APP="/Applications/Overflow Monitor.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -target arm64-apple-macosx13.0 -framework Cocoa -framework ServiceManagement -o "$APP/Contents/MacOS/OverflowMonitor" main.swift
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null
pkill -x OverflowMonitor 2>/dev/null && sleep 1 || true
open "$APP"
echo "  built and launched $APP"
