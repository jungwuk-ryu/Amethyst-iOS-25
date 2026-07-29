#!/usr/bin/env bash
# Builds a tiny iOS Simulator app that exercises the Desktop GL/Metal
# texture-buffer path used by Minecraft 26.2 Pre-Release 6.
#
# To build only:
#   scripts/test_angle_simulator.sh
#
# To install, launch, and assert the saved PASS result on a booted Simulator:
#   ANGLE_SIMULATOR_UDID=<udid> scripts/test_angle_simulator.sh

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ANGLE_SOURCE_DIR="${ANGLE_SOURCE_DIR:-$SOURCE_DIR/.angle-src}"
FRAMEWORK_DIR="${ANGLE_FRAMEWORK_DIR:-$SOURCE_DIR/Natives/resources/FrameworksSimulator}"
BUILD_DIR="$SOURCE_DIR/artifacts/angle-simulator-smoke"
APP_DIR="$BUILD_DIR/AngleSimulatorSmoke.app"
BUNDLE_ID="org.catsruledogs.amethyst.angle-simulator-smoke"

if [ ! -f "$ANGLE_SOURCE_DIR/include/EGL/egl.h" ]; then
    echo "[angle-simulator-smoke] ERROR: ANGLE headers not found at $ANGLE_SOURCE_DIR/include." >&2
    echo "[angle-simulator-smoke] Set ANGLE_SOURCE_DIR to the pinned, patched ANGLE checkout." >&2
    exit 1
fi

for framework in libEGL libGLESv2; do
    if [ ! -f "$FRAMEWORK_DIR/$framework.framework/$framework" ]; then
        echo "[angle-simulator-smoke] ERROR: missing $framework Simulator framework." >&2
        echo "[angle-simulator-smoke] Run ANGLE_INSTALL=simulator scripts/build_angle.sh first." >&2
        exit 1
    fi
done

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Frameworks"

xcrun --sdk iphonesimulator clang++ \
    -std=c++17 \
    -fobjc-arc \
    -arch arm64 \
    -mios-simulator-version-min=16.0 \
    -I"$ANGLE_SOURCE_DIR/include" \
    -F"$FRAMEWORK_DIR" \
    -framework libEGL \
    -framework libGLESv2 \
    -framework UIKit \
    -framework Foundation \
    -Wl,-rpath,@executable_path/Frameworks \
    "$SOURCE_DIR/tests/angle_simulator/AngleSimulatorSmoke.mm" \
    -o "$APP_DIR/AngleSimulatorSmoke"

install -m 0644 "$SOURCE_DIR/tests/angle_simulator/Info.plist" "$APP_DIR/Info.plist"
cp -R "$FRAMEWORK_DIR/libEGL.framework" "$APP_DIR/Frameworks/"
cp -R "$FRAMEWORK_DIR/libGLESv2.framework" "$APP_DIR/Frameworks/"

codesign --force --sign - --timestamp=none "$APP_DIR/Frameworks/libEGL.framework"
codesign --force --sign - --timestamp=none "$APP_DIR/Frameworks/libGLESv2.framework"
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "[angle-simulator-smoke] built $APP_DIR"

if [ -z "${ANGLE_SIMULATOR_UDID:-}" ]; then
    echo "[angle-simulator-smoke] build-only mode; set ANGLE_SIMULATOR_UDID to run."
    exit 0
fi

xcrun simctl uninstall "$ANGLE_SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$ANGLE_SIMULATOR_UDID" "$APP_DIR"

data_container="$(xcrun simctl get_app_container "$ANGLE_SIMULATOR_UDID" "$BUNDLE_ID" data)"
result_path="$data_container/Documents/angle-simulator-smoke.txt"
rm -f "$result_path"
xcrun simctl launch "$ANGLE_SIMULATOR_UDID" "$BUNDLE_ID"
for _ in {1..60}; do
    if [ -f "$result_path" ]; then
        break
    fi
    sleep 0.25
done

if [ ! -f "$result_path" ]; then
    echo "[angle-simulator-smoke] ERROR: timed out waiting for $result_path" >&2
    exit 1
fi

cat "$result_path"
if [ "$(sed -n '1p' "$result_path")" != "PASS" ]; then
    echo "[angle-simulator-smoke] ERROR: texture-buffer test failed." >&2
    exit 1
fi

echo "[angle-simulator-smoke] PASS"
