#!/bin/bash
# Build Alt-Drag.app (a real bundle, so the Accessibility grant sticks).
set -euo pipefail
cd "$(dirname "$0")"

# The active Command Line Tools have a broken SwiftBridging modulemap; use the
# full Xcode toolchain instead (no sudo/xcode-select).
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP="build/Alt-Drag.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

# Compile the C core (CGS space switching, Dock-swipe classification, MTActuator
# haptics) and link it into the Swift build via the bridging header.
xcrun clang -O2 -c Sources/spacecore.c -o build/spacecore.o

xcrun swiftc -O Sources/*.swift build/spacecore.o \
    -import-objc-header Sources/AltDrag-Bridging.h \
    -o "$MACOS/AltDrag" \
    -framework Cocoa -framework ApplicationServices -framework ServiceManagement \
    -framework CoreGraphics
rm -f build/spacecore.o

# Prefer a stable self-signed identity so the Accessibility (TCC) grant sticks
# across rebuilds; ad-hoc signatures change every build and drop the grant.
# Run scripts/setup-signing.sh once to create "AltDrag Local Signing".
SIGN_IDENTITY="${ALTDRAG_SIGN_IDENTITY:-AltDrag Local Signing}"
SIGN_KEYCHAIN="$HOME/Library/Keychains/altdrag-signing.keychain-db"
if security find-certificate -c "$SIGN_IDENTITY" "$SIGN_KEYCHAIN" >/dev/null 2>&1; then
    echo "==> Code signing with stable identity: $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" "$APP"
else
    echo "==> Code signing (ad-hoc — run scripts/setup-signing.sh for a sticky grant)"
    codesign --force --sign - "$APP"
fi

echo "built $APP"
