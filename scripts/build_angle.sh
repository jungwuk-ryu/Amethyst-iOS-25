#!/usr/bin/env bash
# Rebuilds and tests the pinned ANGLE frameworks used by Amethyst.
#
# Defaults:
#   - run the host translator and Metal end-to-end regression tests
#   - build both the arm64 iOS device and arm64 iOS Simulator frameworks
#   - build the standalone iOS Simulator smoke-test app
#   - leave all build products in the temporary work directory
#
# Set ANGLE_SIMULATOR_UDID to install and run the smoke test as part of the
# build. Without it, the smoke-test app is compile/link validated only.
#
# Installation is explicit:
#   ANGLE_INSTALL=device    scripts/build_angle.sh
#   ANGLE_INSTALL=simulator scripts/build_angle.sh
#   ANGLE_INSTALL=all       scripts/build_angle.sh
#
# ANGLE_BUILD may be "all" (the default), "device", or "simulator".

set -euo pipefail

ANGLE_COMMIT="6024e9c05548480c3b2ea42836a112509a549a95"
DEPOT_TOOLS_COMMIT="621cd2a212921328b0a552582c0bc18ba786588c"
ANGLE_URL="https://github.com/google/angle.git"
DEPOT_TOOLS_URL="https://chromium.googlesource.com/chromium/tools/depot_tools.git"
IOS_DEPLOYMENT_TARGET="16.0"
EXPECTED_GLES_SYMBOL_COUNT="2439"

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="$SOURCE_DIR/patches/angle"
HASH_MANIFEST="$SOURCE_DIR/Natives/resources/Frameworks/ANGLE_SHA256SUMS"
ANGLE_BUILD="${ANGLE_BUILD:-all}"
ANGLE_INSTALL="${ANGLE_INSTALL:-none}"

# Keep the historical ANGLE_INSTALL=1 spelling compatible with the old script.
if [ "$ANGLE_INSTALL" = "1" ]; then
    ANGLE_INSTALL="device"
elif [ "$ANGLE_INSTALL" = "0" ]; then
    ANGLE_INSTALL="none"
fi

case "$ANGLE_BUILD" in
    all | device | simulator) ;;
    *)
        echo "[angle] ERROR: ANGLE_BUILD must be all, device, or simulator." >&2
        exit 2
        ;;
esac

case "$ANGLE_INSTALL" in
    none | device | simulator | all) ;;
    *)
        echo "[angle] ERROR: ANGLE_INSTALL must be none, device, simulator, or all." >&2
        exit 2
        ;;
esac

if [ "$ANGLE_INSTALL" = "device" ] && [ "$ANGLE_BUILD" = "simulator" ]; then
    echo "[angle] ERROR: cannot install the device frameworks when ANGLE_BUILD=simulator." >&2
    exit 2
fi
if [ "$ANGLE_INSTALL" = "simulator" ] && [ "$ANGLE_BUILD" = "device" ]; then
    echo "[angle] ERROR: cannot install the Simulator frameworks when ANGLE_BUILD=device." >&2
    exit 2
fi
if [ "$ANGLE_INSTALL" = "all" ] && [ "$ANGLE_BUILD" != "all" ]; then
    echo "[angle] ERROR: ANGLE_INSTALL=all requires ANGLE_BUILD=all." >&2
    exit 2
fi

if [ -n "${ANGLE_WORK_DIR:-}" ]; then
    WORK_DIR="$ANGLE_WORK_DIR"
    mkdir -p "$WORK_DIR"
else
    WORK_DIR="$(mktemp -d -t amethyst-angle.XXXXXX)"
fi

ANGLE_DIR="$WORK_DIR/angle"
DEPOT_TOOLS_DIR="$WORK_DIR/depot_tools"

if [ -e "$ANGLE_DIR" ] || [ -e "$DEPOT_TOOLS_DIR" ] || [ -e "$WORK_DIR/.gclient" ]; then
    echo "[angle] ERROR: work directory is not empty: $WORK_DIR" >&2
    echo "[angle] Choose a fresh ANGLE_WORK_DIR or omit it." >&2
    exit 1
fi

clone_pinned() {
    local url="$1"
    local revision="$2"
    local destination="$3"
    local actual_revision

    git clone --filter=blob:none --no-checkout "$url" "$destination"
    git -C "$destination" fetch --depth=1 origin "$revision"
    git -C "$destination" checkout --detach "$revision"

    actual_revision="$(git -C "$destination" rev-parse HEAD)"
    if [ "$actual_revision" != "$revision" ]; then
        echo "[angle] ERROR: expected $revision, got $actual_revision" >&2
        exit 1
    fi
}

echo "[angle] work directory: $WORK_DIR"
echo "[angle] cloning pinned ANGLE and depot_tools revisions..."
clone_pinned "$ANGLE_URL" "$ANGLE_COMMIT" "$ANGLE_DIR"
clone_pinned "$DEPOT_TOOLS_URL" "$DEPOT_TOOLS_COMMIT" "$DEPOT_TOOLS_DIR"

export DEPOT_TOOLS_UPDATE=0
export PATH="$DEPOT_TOOLS_DIR:$PATH"

# A detached/pinned depot_tools checkout is intentionally not self-updated.
# Initialize its pinned CIPD tools explicitly so wrappers such as gn can find
# python3_bin_reldir.txt without advancing the depot_tools Git revision.
DEPOT_TOOLS_DIR="$DEPOT_TOOLS_DIR" "$DEPOT_TOOLS_DIR/ensure_bootstrap"

(
    cd "$WORK_DIR"
    gclient config --name=angle --unmanaged "$ANGLE_URL"
    gclient sync --no-history --shallow
)

actual_angle_revision="$(git -C "$ANGLE_DIR" rev-parse HEAD)"
if [ "$actual_angle_revision" != "$ANGLE_COMMIT" ]; then
    echo "[angle] ERROR: gclient changed ANGLE to $actual_angle_revision" >&2
    exit 1
fi

patch_count=0
for patch_path in "$PATCH_DIR"/*.patch; do
    if [ ! -e "$patch_path" ]; then
        echo "[angle] ERROR: no ANGLE patches found in $PATCH_DIR" >&2
        exit 1
    fi
    patch_count=$((patch_count + 1))
    echo "[angle] applying $(basename "$patch_path")"
    git -C "$ANGLE_DIR" apply --check "$patch_path"
    git -C "$ANGLE_DIR" apply "$patch_path"
done
echo "[angle] applied $patch_count patches"
git -C "$ANGLE_DIR" diff --check

if ! metal_tool="$(xcrun -f metal 2>/dev/null)" ||
        ! "$metal_tool" --version >/dev/null 2>&1; then
    echo "[angle] ERROR: the Xcode Metal toolchain is unavailable." >&2
    echo "[angle] Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi
metal_bin="$(dirname "$metal_tool")/"

echo "[angle] building host regression tests..."
host_args="is_debug=false is_component_build=false"
host_args="$host_args angle_enable_gl_desktop_frontend=true angle_enable_metal=true"
host_args="$host_args angle_enable_vulkan=false angle_enable_wgpu=false"
host_args="$host_args angle_enable_swiftshader=false angle_enable_null=false"
host_args="$host_args angle_metal_toolchain_bin_path=\"$metal_bin\""
(
    cd "$ANGLE_DIR"
    gn gen out/host-test --args="$host_args"
    third_party/ninja/ninja -C out/host-test angle_unittests angle_end2end_tests

    out/host-test/angle_unittests

    # --use-config is required. Without it, this parameterized Desktop GL test
    # is not instantiated and a successful "0 tests" result is misleading.
    out/host-test/angle_end2end_tests \
        --gtest_filter='DesktopMetalTextureBufferTest.*' \
        --use-config=GL3_2_Core_Metal
)

verify_frameworks() {
    local output_dir="$1"
    local expected_platform="$2"
    local manifest_prefix="$3"
    local framework_binary
    local symbol_count
    local manifest_key
    local expected_hash
    local actual_hash

    for framework_binary in \
            "$output_dir/libEGL.framework/libEGL" \
            "$output_dir/libGLESv2.framework/libGLESv2"; do
        if ! file "$framework_binary" |
                grep -q "Mach-O 64-bit dynamically linked shared library arm64"; then
            echo "[angle] ERROR: expected an arm64 Mach-O framework: $framework_binary" >&2
            exit 1
        fi
        if ! vtool -show-build "$framework_binary" |
                grep -Eq "platform[[:space:]]+$expected_platform$"; then
            echo "[angle] ERROR: expected platform $expected_platform: $framework_binary" >&2
            exit 1
        fi
    done

    symbol_count="$(nm -gU "$output_dir/libGLESv2.framework/libGLESv2" |
        wc -l | tr -d ' ')"
    if [ "$symbol_count" != "$EXPECTED_GLES_SYMBOL_COUNT" ]; then
        echo "[angle] ERROR: unexpected libGLESv2 public symbol count: $symbol_count" >&2
        exit 1
    fi

    if [ ! -f "$HASH_MANIFEST" ]; then
        echo "[angle] ERROR: missing release hash manifest: $HASH_MANIFEST" >&2
        exit 1
    fi

    for framework_binary in \
            "$output_dir/libEGL.framework/libEGL" \
            "$output_dir/libGLESv2.framework/libGLESv2"; do
        case "$framework_binary" in
            */libEGL.framework/libEGL)
                manifest_key="$manifest_prefix/libEGL.framework/libEGL"
                ;;
            */libGLESv2.framework/libGLESv2)
                manifest_key="$manifest_prefix/libGLESv2.framework/libGLESv2"
                ;;
        esac
        expected_hash="$(awk -v key="$manifest_key" \
            '$2 == key { print $1 }' "$HASH_MANIFEST")"
        if [ -z "$expected_hash" ]; then
            echo "[angle] ERROR: no hash for $manifest_key in $HASH_MANIFEST" >&2
            exit 1
        fi
        actual_hash="$(shasum -a 256 "$framework_binary" | awk '{ print $1 }')"
        if [ "$actual_hash" != "$expected_hash" ]; then
            echo "[angle] ERROR: release hash mismatch for $manifest_key" >&2
            echo "[angle] expected: $expected_hash" >&2
            echo "[angle] actual:   $actual_hash" >&2
            exit 1
        fi
    done

    echo "[angle] framework SHA-256 ($expected_platform):"
    shasum -a 256 \
        "$output_dir/libEGL.framework/libEGL" \
        "$output_dir/libGLESv2.framework/libGLESv2"
}

build_ios_frameworks() {
    local target_environment="$1"
    local output_dir="$ANGLE_DIR/out/ios-$target_environment"
    local ios_args

    echo "[angle] building iOS arm64 frameworks ($target_environment)..."
    ios_args="target_os=\"ios\" target_environment=\"$target_environment\" target_cpu=\"arm64\""
    ios_args="$ios_args is_component_build=false is_debug=false symbol_level=0"
    ios_args="$ios_args ios_enable_code_signing=false"
    ios_args="$ios_args ios_deployment_target=\"$IOS_DEPLOYMENT_TARGET\""
    ios_args="$ios_args angle_enable_gl_desktop_frontend=true angle_enable_metal=true"
    ios_args="$ios_args angle_enable_gl=false angle_enable_vulkan=false"
    ios_args="$ios_args angle_enable_wgpu=false angle_enable_swiftshader=false"
    ios_args="$ios_args angle_enable_null=false angle_build_tests=false"
    ios_args="$ios_args angle_metal_toolchain_bin_path=\"$metal_bin\""

    (
        cd "$ANGLE_DIR"
        gn gen "out/ios-$target_environment" --args="$ios_args"
        third_party/ninja/ninja -C "out/ios-$target_environment" libEGL libGLESv2
    )

    if [ "$target_environment" = "device" ]; then
        verify_frameworks "$output_dir" "IOS" "device"
    else
        verify_frameworks "$output_dir" "IOSSIMULATOR" "simulator"
    fi
}

install_frameworks() {
    local output_dir="$1"
    local destination="$2"

    mkdir -p \
        "$destination/libEGL.framework" \
        "$destination/libGLESv2.framework"
    install -m 0755 "$output_dir/libEGL.framework/libEGL" \
        "$destination/libEGL.framework/libEGL"
    install -m 0644 "$output_dir/libEGL.framework/Info.plist" \
        "$destination/libEGL.framework/Info.plist"
    install -m 0755 "$output_dir/libGLESv2.framework/libGLESv2" \
        "$destination/libGLESv2.framework/libGLESv2"
    install -m 0644 "$output_dir/libGLESv2.framework/Info.plist" \
        "$destination/libGLESv2.framework/Info.plist"
    echo "[angle] installed frameworks into $destination"
}

if [ "$ANGLE_BUILD" = "all" ] || [ "$ANGLE_BUILD" = "device" ]; then
    build_ios_frameworks device
fi
if [ "$ANGLE_BUILD" = "all" ] || [ "$ANGLE_BUILD" = "simulator" ]; then
    build_ios_frameworks simulator
    ANGLE_SOURCE_DIR="$ANGLE_DIR" \
        ANGLE_FRAMEWORK_DIR="$ANGLE_DIR/out/ios-simulator" \
        ANGLE_SIMULATOR_UDID="${ANGLE_SIMULATOR_UDID:-}" \
        "$SOURCE_DIR/scripts/test_angle_simulator.sh"
fi

if [ "$ANGLE_INSTALL" = "device" ] || [ "$ANGLE_INSTALL" = "all" ]; then
    install_frameworks \
        "$ANGLE_DIR/out/ios-device" \
        "$SOURCE_DIR/Natives/resources/Frameworks"
fi
if [ "$ANGLE_INSTALL" = "simulator" ] || [ "$ANGLE_INSTALL" = "all" ]; then
    install_frameworks \
        "$ANGLE_DIR/out/ios-simulator" \
        "$SOURCE_DIR/Natives/resources/FrameworksSimulator"
fi

if [ "$ANGLE_INSTALL" = "none" ]; then
    echo "[angle] build complete; frameworks remain in:"
    if [ "$ANGLE_BUILD" = "all" ] || [ "$ANGLE_BUILD" = "device" ]; then
        echo "[angle]   $ANGLE_DIR/out/ios-device"
    fi
    if [ "$ANGLE_BUILD" = "all" ] || [ "$ANGLE_BUILD" = "simulator" ]; then
        echo "[angle]   $ANGLE_DIR/out/ios-simulator"
    fi
    echo "[angle] set ANGLE_INSTALL=device, simulator, or all to install them"
fi

echo "[angle] patched source checkout: $ANGLE_DIR"
