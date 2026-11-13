#!/bin/sh
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -fblocks \
  -DENHANCEMENTS_TEST -framework AppKit -framework UserNotifications -framework CoreGraphics \
  "$PROJECT_ROOT/src/Enhancements.m" -o "$TEST_DIR/check-enhancements"
"$TEST_DIR/check-enhancements"
python3 -m py_compile "$PROJECT_ROOT/scripts/build.py" "$PROJECT_ROOT/scripts/patch_binary.py"
