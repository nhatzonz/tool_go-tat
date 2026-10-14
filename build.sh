#!/bin/zsh
# Build "Dán Nhanh.app" từ main.swift
set -e
cd "$(dirname "$0")"

APP="DanNhanh.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/DanNhanh"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Dán Nhanh</string>
    <key>CFBundleDisplayName</key><string>Dán Nhanh</string>
    <key>CFBundleIdentifier</key><string>com.nhatnguyen.dannhanh</string>
    <key>CFBundleExecutable</key><string>DanNhanh</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "Đã build: $(pwd)/$APP"
