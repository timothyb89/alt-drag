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
