#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${JNA_WORK_DIR:-$ROOT_DIR/.jna-src}"
INSTALL_DIR="${JNA_INSTALL_DIR:-$ROOT_DIR/Natives/resources/FrameworksSimulator/jna}"
SIMULATOR_SDK_VERSION="26.5"
FOUNDATION_MACOS="/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"
FOUNDATION_IOS="/System/Library/Frameworks/Foundation.framework/Foundation"

mkdir -p "$WORK_DIR" "$INSTALL_DIR"

build_jna() {
    local version="$1"
    local abi_version="$2"
    local jar_sha256="$3"
    local output_sha256="$4"
    local jar_path="$WORK_DIR/jna-$version.jar"
    local extract_dir="$WORK_DIR/$version"
    local source_path="$extract_dir/com/sun/jna/darwin-aarch64/libjnidispatch.jnilib"
    local output_dir="$INSTALL_DIR/$abi_version"
    local output_path="$output_dir/libjnidispatch.dylib"
    local temporary_dir
    local temporary_path

    curl --fail --location --retry 3 --silent --show-error \
        --output "$jar_path" \
        "https://repo1.maven.org/maven2/net/java/dev/jna/jna/$version/jna-$version.jar"
    printf '%s  %s\n' "$jar_sha256" "$jar_path" | shasum -a 256 --check

    mkdir -p "$extract_dir" "$output_dir"
    temporary_dir="$(mktemp -d "$INSTALL_DIR/.jna-$abi_version.XXXXXX")"
    temporary_path="$temporary_dir/libjnidispatch.dylib"
    trap 'rm -rf -- "$temporary_dir"' EXIT
    unzip -oq "$jar_path" \
        com/sun/jna/darwin-aarch64/libjnidispatch.jnilib \
        -d "$extract_dir"
    cp "$source_path" "$temporary_path"
    chmod 755 "$temporary_path"

    xcrun vtool -arch arm64 \
        -set-build-version 7 16.0 "$SIMULATOR_SDK_VERSION" \
        -replace -output "$temporary_path" "$temporary_path"
    xcrun install_name_tool \
        -change "$FOUNDATION_MACOS" "$FOUNDATION_IOS" \
        "$temporary_path"
    codesign --force --sign - --timestamp=none "$temporary_path"
    codesign --verify --strict --verbose=2 "$temporary_path"

    printf '%s  %s\n' "$output_sha256" "$temporary_path" |
        shasum -a 256 --check
    file "$temporary_path" | grep -q \
        'Mach-O 64-bit dynamically linked shared library arm64'
    otool -l "$temporary_path" |
        awk '/cmd LC_BUILD_VERSION/{getline; getline; print}' |
        grep -q 'platform 7'
    otool -L "$temporary_path" | grep -q "$FOUNDATION_IOS"

    mv -f "$temporary_path" "$output_path"
    rmdir "$temporary_dir"
    trap - EXIT
}

build_jna \
    "5.13.0" \
    "5.13" \
    "66d4f819a062a51a1d5627bffc23fac55d1677f0e0a1feba144aabdd670a64bb" \
    "c426a704f4a02f8d1bf9428d0d20c8fefbbf77b54cb39ded0dca044cd945619f"
build_jna \
    "5.17.0" \
    "5.17" \
    "b3a9408e7c51e08ef0e3bfcc08f443f6ec0f6191ba8cd7c18d53d2b22e5bdbc0" \
    "2badcbd3212b0b6cbf902d7dc963136226b18746c0a0d51d535a770893f89a8c"

echo "Simulator JNA natives installed in $INSTALL_DIR"
