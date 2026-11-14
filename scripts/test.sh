#!/bin/sh
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -target arm64-apple-macos12.0 -emit-library -parse-as-library \
  "$PROJECT_ROOT/src/WidgetContext.swift" -o "$TEST_DIR/WidgetifyContext.dylib" \
  -Xlinker -install_name -Xlinker @loader_path/WidgetifyContext.dylib
xcrun clang -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -fblocks \
  -DENHANCEMENTS_TEST -framework AppKit -framework UserNotifications -framework CoreGraphics \
  "$PROJECT_ROOT/src/Enhancements.m" "$PROJECT_ROOT/src/OriginalFolderBridge.m" "$PROJECT_ROOT/src/ComponentIntegration.m" \
  "$PROJECT_ROOT/src/ComponentSettings.m" "$PROJECT_ROOT/src/ReminderSchedule.m" "$PROJECT_ROOT/src/DirectoryReferences.m" "$TEST_DIR/WidgetifyContext.dylib" -o "$TEST_DIR/check-enhancements"
"$TEST_DIR/check-enhancements"
python3 -m py_compile "$PROJECT_ROOT/scripts/build.py" "$PROJECT_ROOT/scripts/patch_binary.py" "$PROJECT_ROOT/scripts/release.py"
