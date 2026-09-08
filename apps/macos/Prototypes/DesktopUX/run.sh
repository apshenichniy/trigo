#!/bin/bash
set -euo pipefail

PROTOTYPE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROTOTYPE_APP="$PROTOTYPE_DIR/.build/Trigo UX Prototype.app"
mkdir -p "$PROTOTYPE_APP/Contents/MacOS"

xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx15.0 \
  "$PROTOTYPE_DIR/PrototypeModel.swift" \
  "$PROTOTYPE_DIR/Library.swift" \
  "$PROTOTYPE_DIR/RecordingAndSettings.swift" \
  "$PROTOTYPE_DIR/CompactRecordingPanel.swift" \
  "$PROTOTYPE_DIR/PrototypeRenders.swift" \
  "$PROTOTYPE_DIR/PrototypeApp.swift" \
  -o "$PROTOTYPE_APP/Contents/MacOS/TrigoUXPrototype"

cat > "$PROTOTYPE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.apshenichniy.trigo.prototype.desktopux</string>
  <key>CFBundleName</key><string>Trigo UX Prototype</string>
  <key>CFBundleDisplayName</key><string>Trigo UX Prototype</string>
  <key>CFBundleExecutable</key><string>TrigoUXPrototype</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

if [[ "${1:-}" == "--build-only" ]]; then
  printf '%s\n' "$PROTOTYPE_APP"
elif [[ "${1:-}" == "--render-fixtures" ]]; then
  "$PROTOTYPE_APP/Contents/MacOS/TrigoUXPrototype" --render-fixtures "${2:-$PROTOTYPE_DIR/evidence/rendered}"
else
  open "$PROTOTYPE_APP" --args "$@"
fi
