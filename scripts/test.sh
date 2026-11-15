#!/bin/sh
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -target arm64-apple-macos12.0 -emit-library -parse-as-library \
  "$PROJECT_ROOT/src/WidgetContext.swift" "$PROJECT_ROOT/src/WaterPresentation.swift" "$PROJECT_ROOT/src/ShortcutCategories.swift" "$PROJECT_ROOT/src/InspirationPresentation.swift" "$PROJECT_ROOT/src/InspirationHistory.swift" "$PROJECT_ROOT/src/InspirationIntegration.swift" -o "$TEST_DIR/WidgetifyContext.dylib" \
  -Xlinker -install_name -Xlinker @loader_path/WidgetifyContext.dylib
xcrun clang -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -fblocks \
  -DENHANCEMENTS_TEST -framework AppKit -framework UserNotifications -framework CoreGraphics -framework QuartzCore \
  "$PROJECT_ROOT/src/Enhancements.m" "$PROJECT_ROOT/src/OriginalFolderBridge.m" "$PROJECT_ROOT/src/ComponentIntegration.m" \
  "$PROJECT_ROOT/src/ComponentSettings.m" "$PROJECT_ROOT/src/ReminderSchedule.m" "$PROJECT_ROOT/src/DirectoryReferences.m" "$TEST_DIR/WidgetifyContext.dylib" -o "$TEST_DIR/check-enhancements"
"$TEST_DIR/check-enhancements"
python3 -m py_compile "$PROJECT_ROOT/scripts/build.py" "$PROJECT_ROOT/scripts/patch_binary.py" "$PROJECT_ROOT/scripts/release.py" "$PROJECT_ROOT/scripts/build_inspiration_preview.py" "$PROJECT_ROOT/scripts/build_preview.py"

xcrun swiftc -target arm64-apple-macos12.0 -parse-as-library \
  "$PROJECT_ROOT/src/WidgetContext.swift" "$PROJECT_ROOT/src/InspirationPresentation.swift" "$PROJECT_ROOT/src/InspirationHistory.swift" "$PROJECT_ROOT/src/InspirationIntegration.swift" \
  "$PROJECT_ROOT/tests/InspirationStoreTests.swift" -o "$TEST_DIR/check-inspiration"
"$TEST_DIR/check-inspiration"
xcrun swiftc -target arm64-apple-macos12.0 -parse-as-library \
  "$PROJECT_ROOT/src/WaterPresentation.swift" "$PROJECT_ROOT/tests/WaterSurfaceTests.swift" -o "$TEST_DIR/check-water-surface"
"$TEST_DIR/check-water-surface"
xcrun swiftc -target arm64-apple-macos12.0 -parse-as-library \
  "$PROJECT_ROOT/src/InspirationIntegration.swift" "$PROJECT_ROOT/tests/InspirationIntegrationTests.swift" -o "$TEST_DIR/check-inspiration-integration"
"$TEST_DIR/check-inspiration-integration"
python3 "$PROJECT_ROOT/tests/test_inspiration_migration.py"
