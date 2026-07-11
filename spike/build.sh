#!/bin/bash
# Build the spike into a standalone binary.
set -euo pipefail
cd "$(dirname "$0")"
# The active Command Line Tools have a duplicate SwiftBridging modulemap that
# breaks swiftc; use the full Xcode toolchain instead (no sudo/xcode-select).
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -O main.swift -o alt-drag-spike
echo "built ./spike/alt-drag-spike"
xcrun swiftc -O resize.swift -o alt-resize-spike
echo "built ./spike/alt-resize-spike"
xcrun swiftc -O clickthrough.swift -o clickthrough \
    -framework Cocoa -framework ApplicationServices
echo "built ./spike/clickthrough"
xcrun clang -O2 -c spacecore.c -o spacecore.o
xcrun clang -O2 spaces.c spacecore.o -o spaces \
    -framework CoreGraphics -framework CoreFoundation -framework ApplicationServices
echo "built ./spike/spaces"
xcrun swiftc -O overlay.swift spacecore.o \
    -import-objc-header overlay-bridge.h -o overlay \
    -framework Cocoa -framework CoreGraphics -framework ApplicationServices
echo "built ./spike/overlay"
xcrun clang -O2 haptictest.c spacecore.o -o haptictest \
    -framework CoreGraphics -framework CoreFoundation -framework ApplicationServices
echo "built ./spike/haptictest"
rm -f spacecore.o
