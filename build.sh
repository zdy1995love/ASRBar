#!/usr/bin/env bash
# Build ASRBar.app from ASRBar.swift (single-file SwiftUI macOS app).
# Produces ASRBar.app in the same directory; ad-hoc signed.

set -euo pipefail
cd "$(dirname "$0")"

APP="ASRBar"
BUNDLE="$APP.app"
ARCH="$(uname -m)"             # arm64 / x86_64
DEPLOY_TARGET="13.0"
ICON_SRC="Qwen.png"
ICON_NAME="AppIcon"

# 1. clean
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# 1b. build .icns from Qwen.png (all standard Retina sizes)
if [[ -f "$ICON_SRC" ]]; then
    echo "▶ icon → $ICON_NAME.icns"
    ICONSET="$(mktemp -d)/$ICON_NAME.iconset"
    mkdir -p "$ICONSET"
    for SPEC in \
        "16:icon_16x16.png" \
        "32:icon_16x16@2x.png" \
        "32:icon_32x32.png" \
        "64:icon_32x32@2x.png" \
        "128:icon_128x128.png" \
        "256:icon_128x128@2x.png" \
        "256:icon_256x256.png" \
        "512:icon_256x256@2x.png" \
        "512:icon_512x512.png" \
        "1024:icon_512x512@2x.png"; do
        SIZE="${SPEC%%:*}"
        NAME="${SPEC##*:}"
        sips -z "$SIZE" "$SIZE" "$ICON_SRC" --out "$ICONSET/$NAME" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/$ICON_NAME.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

# 2. Info.plist (mic permission + plain-HTTP allow for the LAN vLLM)
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP</string>
    <key>CFBundleDisplayName</key><string>ASRBar</string>
    <key>CFBundleIdentifier</key><string>com.qwen3asr.$APP</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP</string>
    <key>LSMinimumSystemVersion</key><string>$DEPLOY_TARGET</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>$ICON_NAME</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Used to transcribe your voice into text.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

# 3. compile
echo "▶ swiftc → $BUNDLE/Contents/MacOS/$APP"
swiftc -O \
    -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
    -parse-as-library \
    -o "$BUNDLE/Contents/MacOS/$APP" \
    ASRBar.swift

# 4. ad-hoc sign (required for AVFoundation mic access on modern macOS)
echo "▶ codesign (ad-hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE"

echo
echo "✓ built: $(pwd)/$BUNDLE"
echo "  launch: open '$(pwd)/$BUNDLE'"
echo "  install: cp -R '$(pwd)/$BUNDLE' /Applications/"
