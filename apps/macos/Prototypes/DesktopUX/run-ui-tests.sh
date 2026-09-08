#!/bin/bash
set -euo pipefail

PROTOTYPE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROTOTYPE_DIR"
PROTOTYPE_RUN="$PROTOTYPE_DIR/.build/ui-tests/run-$(date +%Y%m%d-%H%M%S)-$RANDOM"
PROTOTYPE_RESULTS="$PROTOTYPE_RUN/results.xcresult"
PROTOTYPE_ACTION=test
if [[ "${1:-}" == "--build-only" ]]; then
  PROTOTYPE_ACTION=build-for-testing
  shift
fi
mkdir -p "$PROTOTYPE_DIR/.build/ui-tests"
mkdir -p "$PROTOTYPE_RUN"

mise exec -- xcodegen generate --spec "$PROTOTYPE_DIR/project.yml" --project "$PROTOTYPE_DIR"
PROTOTYPE_STATUS=0
xcodebuild "$PROTOTYPE_ACTION" -quiet \
  -project "$PROTOTYPE_DIR/TrigoDesktopUX.xcodeproj" \
  -scheme DesktopUX \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PROTOTYPE_DIR/.build/ui-tests/DerivedData" \
  -resultBundlePath "$PROTOTYPE_RESULTS" \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 120 \
  "$@" || PROTOTYPE_STATUS=$?

if [[ "$PROTOTYPE_ACTION" == test && -d "$PROTOTYPE_RESULTS" ]]; then
  python3 "$PROTOTYPE_DIR/collect-ui-evidence.py" "$PROTOTYPE_RESULTS" "$PROTOTYPE_RUN" || {
    if [[ "$PROTOTYPE_STATUS" == 0 ]]; then PROTOTYPE_STATUS=1; fi
  }
fi
printf '%s\n' "$PROTOTYPE_RUN" > "$PROTOTYPE_DIR/.build/ui-tests/latest-run.txt"
printf 'UI test results: %s\n' "$PROTOTYPE_RESULTS"
exit "$PROTOTYPE_STATUS"
