#!/bin/zsh
# Build "Gõ Tắt.app" từ main.swift
set -e
cd "$(dirname "$0")"

APP="GoTat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Build cho cả Mac chip Apple (arm64) và Mac chip Intel (x86_64), rồi gộp thành 1 file
TMP="$(mktemp -d)"
swiftc -O -swift-version 5 -target arm64-apple-macos14 main.swift -o "$TMP/GoTat-arm64"
swiftc -O -swift-version 5 -target x86_64-apple-macos14 main.swift -o "$TMP/GoTat-x86_64"
lipo -create "$TMP/GoTat-arm64" "$TMP/GoTat-x86_64" -output "$APP/Contents/MacOS/GoTat"

# Icon app: tạo AppIcon.icns từ icon/icon_1024.png (vẽ lại bằng: swift icon/make_icon.swift icon/icon_1024.png)
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s icon/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) icon/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Gõ Tắt</string>
    <key>CFBundleDisplayName</key><string>Gõ Tắt</string>
    <key>CFBundleIdentifier</key><string>com.nhatnguyen.dannhanh</string>
    <key>CFBundleExecutable</key><string>GoTat</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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
