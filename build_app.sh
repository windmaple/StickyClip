#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔨 Building StickyClip..."
swift build -c release

APP_DIR="$SCRIPT_DIR/StickyClip.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/StickyClip" "$MACOS_DIR/StickyClip"
cp "Info.plist" "$CONTENTS_DIR/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
chmod +x "$MACOS_DIR/StickyClip"

# Sign with a stable local certificate so the Accessibility (TCC) grant survives rebuilds.
# (Ad-hoc signatures are tied to the binary hash, which changes every build.)
KEYCHAIN="$HOME/Library/Keychains/stickyclip-signing.keychain-db"
CERT_SHA1=""
if ./setup_signing.sh && security unlock-keychain -p stickyclip "$KEYCHAIN" 2>/dev/null; then
    CERT_SHA1="$(security find-certificate -c "StickyClip Local Signing" -Z "$KEYCHAIN" | awk '/SHA-1/ {print $NF}')"
fi
if [ -n "$CERT_SHA1" ]; then
    # Sign by hash: the self-signed cert isn't "trusted", so lookup by name fails.
    codesign --force --deep --sign "$CERT_SHA1" --identifier "com.stickyclip.mac" "$APP_DIR"
else
    echo "⚠️  Falling back to ad-hoc signing (Accessibility will need re-granting after each build)"
    codesign --force --deep --sign - --identifier "com.stickyclip.mac" "$APP_DIR"
fi

echo "✅ Packaged $APP_DIR"
echo "   Run with: open \"$APP_DIR\""
