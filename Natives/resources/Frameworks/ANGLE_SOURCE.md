# Bundled ANGLE provenance

Amethyst bundles `libEGL.framework` and `libGLESv2.framework` built from
Google ANGLE commit
[`6024e9c05548480c3b2ea42836a112509a549a95`](https://github.com/google/angle/commit/6024e9c05548480c3b2ea42836a112509a549a95).
This is intentionally the revision introduced by Amethyst commit `fb752888`.
Later ANGLE revisions removed the Desktop OpenGL frontend that
`tinygl4angle` uses, so replacing these frameworks with a current upstream
binary is not equivalent.

The reproducible checkout also pins depot_tools commit
[`621cd2a212921328b0a552582c0bc18ba786588c`](https://chromium.googlesource.com/chromium/tools/depot_tools/+/621cd2a212921328b0a552582c0bc18ba786588c).
ANGLE's own `DEPS` file at the pinned commit remains the authority for all
other dependency revisions.

The same patched source is published on the public
[`codex/amethyst-ios-desktop-gl`](https://github.com/jungwuk-ryu/angle/tree/codex/amethyst-ios-desktop-gl)
branch at commit
[`5d7e055b5f40f79bb06b15d7fbdf4a328c5cee3c`](https://github.com/jungwuk-ryu/angle/commit/5d7e055b5f40f79bb06b15d7fbdf4a328c5cee3c).
Applying the patch series below to the pinned Google revision produces the
same Git tree, `81da38451656b2aed7686682f42fcdaa95ce55a4`.

## Patch series

The complete changes relative to the Google commit are stored as an ordered
mail patch series in `patches/angle`:

1. `0001-Metal-enable-the-Desktop-GL-frontend.patch`
   advertises the preserved Desktop OpenGL 3.3 frontend on Metal and fills
   caps required to create that context.
2. `0002-Metal-translate-Desktop-GL-sampler-buffers.patch`
   exposes internal Metal translator built-ins to the Desktop frontend and
   emits the missing `texture_buffer` `texelFetch` helper.
3. `0003-Translator-materialize-Desktop-GL-implicit-conversio.patch`
   implements Desktop GLSL integer-to-float conversions in the typed AST,
   including GLSL 4.10 overload ranking, rather than emitting invalid mixed
   integer/float MSL.
4. `0004-Metal-support-the-separately-installed-Xcode-toolcha.patch`
   lets GN use the separately installed Xcode Metal compiler.
5. `0005-Metal-implement-Desktop-GL-texture-buffers.patch`
   enables core Desktop GL texture-buffer state and validation, creates
   buffer-backed Metal texture views with correct alignment and lifetime,
   preserves padded backing allocations across buffer orphaning, and adds a
   draw/reallocation end-to-end regression test.
6. `0006-Metal-harden-Desktop-GL-texture-buffers-on-iOS.patch`
   adds the iOS Simulator private texture mirror required by `MTLSimBuffer`,
   converts the valid `RGB32F/I/UI` source layouts to RGBA32 Metal storage,
   emits scalar `textureSize` support, makes range validation version- and
   overflow-correct, reuses converted textures across dirty updates, and
   extends update, conversion, and Simulator regressions.

The patches are general ANGLE compatibility fixes. They do not recognize or
rewrite a Minecraft shader string.

## Failure addressed

Minecraft 26.2 Pre-Release 6 added a cloud-rendering path that uses core
Desktop GL texture buffers. The old Desktop frontend did not create the zero
`TextureType::Buffer` object, and the Metal backend did not implement
`TextureMtl::setBuffer`. In a no-error context that mismatch could reach
`gl::Texture::setBufferRange` through a null texture.

After those frontend gaps were fixed, the first Simulator failure was
captured at `glDrawElementsInstancedBaseVertex`:

```text
TextureMtl::ensureBufferTextureCreated
MTLSimBuffer newTextureWithDescriptor:offset:bytesPerRow:
Linear texture can only be created on buffers with MTLStorageModePrivate
```

That is an iOS Simulator Metal restriction, not a shader-string-specific
failure. The final backend allocates a standalone private texture buffer on
Simulator and uploads the GL buffer through a blit. Device builds retain the
zero-copy buffer-backed texture view. The series also fixes the Desktop
GLSL-to-MSL translation failures found while compiling the same rendering
path.

## Rebuild and tests

Install the separately distributed Metal toolchain once:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Then run:

```sh
scripts/build_angle.sh
```

The default command performs all of the following:

- clones the exact ANGLE and depot_tools commits into a fresh work directory;
- synchronizes the dependency revisions from ANGLE's pinned `DEPS`;
- applies every patch with `git apply --check` and runs `git diff --check`;
- builds `angle_unittests` and `angle_end2end_tests` on macOS;
- runs the complete host `angle_unittests` suite, including all 12 new
  `MSLOutputDesktopGLTest.*` translator tests;
- runs all three `DesktopMetalTextureBufferTest.*` cases with
  `--use-config=GL3_2_Core_Metal`;
- builds and validates arm64 frameworks for both iOS device and iOS
  Simulator;
- compile/link validates the standalone Simulator smoke-test app; and
- checks each Mach-O platform, the 2,439-symbol `libGLESv2` export set, and
  every output against the release hashes in `ANGLE_SHA256SUMS`.

Set a booted Simulator UDID to run the smoke test as part of the same clean
build:

```sh
ANGLE_WORK_DIR=/path/to/new-empty-directory \
ANGLE_SIMULATOR_UDID=<udid> \
scripts/build_angle.sh
```

The script prints its patched source checkout. To rerun only the Simulator
test against that build:

```sh
ANGLE_SOURCE_DIR=/path/to/new-empty-directory/angle \
ANGLE_FRAMEWORK_DIR=/path/to/new-empty-directory/angle/out/ios-simulator \
ANGLE_SIMULATOR_UDID=<udid> \
scripts/test_angle_simulator.sh
```

Installation is deliberately separate from building:

```sh
ANGLE_INSTALL=device scripts/build_angle.sh
ANGLE_INSTALL=simulator scripts/build_angle.sh
ANGLE_INSTALL=all scripts/build_angle.sh
```

Device frameworks are installed in `Natives/resources/Frameworks`.
Simulator frameworks are installed in
`Natives/resources/FrameworksSimulator`. `ANGLE_BUILD=device` or
`ANGLE_BUILD=simulator` can limit the framework build when only one platform
is needed. `ANGLE_WORK_DIR` can select a fresh persistent work directory.

The final host regression run used for the checked-in binaries ran 6,557
unit tests: 6,556 passed and one pre-existing expectations-parser test was
skipped. This includes 12/12 `MSLOutputDesktopGLTest` cases. All 3/3 Metal
texture-buffer end-to-end tests passed on an Apple M5 Pro. A concise,
committed record of the release checks is in `ANGLE_RELEASE_EVIDENCE.md`.

The standalone test passed in both validation and no-error OpenGL 3.3
contexts on an arm64 iOS 26.5 Simulator. Minecraft 26.2 Pre-Release 5 and
Pre-Release 6 each entered the same single-player world with the final
patched framework. Pre-5 remained active through the timed smoke run, and
Pre-6 remained active in-world for more than three minutes, with no new JVM
fatal log, SIGSEGV, or Metal validation failure. A direct-ANGLE
physical-device run remains required before changing the device `auto`
renderer away from its MobileGlues fallback.

## GN configuration

The common release configuration is:

```text
is_component_build=false
is_debug=false
symbol_level=0
angle_enable_gl_desktop_frontend=true
angle_enable_metal=true
angle_enable_gl=false
angle_enable_vulkan=false
angle_enable_wgpu=false
angle_enable_swiftshader=false
angle_enable_null=false
angle_build_tests=false
ios_enable_code_signing=false
ios_deployment_target="16.0"
angle_metal_toolchain_bin_path="<xcrun metal directory>/"
```

The device build adds:

```text
target_os="ios"
target_environment="device"
target_cpu="arm64"
```

The Simulator build changes only the environment:

```text
target_os="ios"
target_environment="simulator"
target_cpu="arm64"
```

## Audited binary hashes

The checked-in frameworks were built with Xcode 26.6 (`17F113`), iPhoneOS
and iPhoneSimulator SDK 26.5 (`23F81a`), and a minimum OS version of 16.0.
Device frameworks are unsigned until Amethyst's packaging/signing step.
Simulator frameworks may carry ad-hoc linker signatures and are re-signed
with the containing app during Simulator packaging.

Device:

```text
a2909383fd5e0b4b15afe831a66f0024d2d35daf5444b46185b4f0ac81596d8d  libEGL.framework/libEGL
fff82931348fbab835acb60859da46d071a55d3c72b71135c73456a8068902e0  libGLESv2.framework/libGLESv2
```

arm64 Simulator:

```text
1685dc5ffa8be9d633ccb482112e2d0648fa16285da8d73a54ee340c973c29c0  libEGL.framework/libEGL
505e315aaf8c18932c28db24e76f51065900f8535074d33d6b7b5cbf36db20ea  libGLESv2.framework/libGLESv2
```

Both `libGLESv2` binaries export 2,439 public symbols.
`ANGLE_SHA256SUMS` is the canonical machine-checked copy of these hashes.
Its platform-prefixed logical paths are consumed by `scripts/build_angle.sh`;
it is not a directly runnable `shasum -c` manifest.

## Conformance boundary

The framework advertises a Desktop OpenGL 3.3 core context because that is
the frontend consumed by `tinygl4angle`. This is a targeted compatibility
configuration, not a claim that the Metal backend passes the full Desktop
OpenGL 3.3 conformance suite.

In particular:

- core `glTexBuffer` is enabled, but `GL_EXT_texture_buffer` and
  `GL_OES_texture_buffer` are not advertised;
- directly representable formats use a Metal buffer view; the valid
  three-component `RGB32F/I/UI` layouts are converted from their 12-byte GL
  stride to RGBA32 Metal storage with the defined alpha component;
- `glTexBufferRange` is rejected in the advertised Desktop GL 3.3 context
  because that entry point did not enter Desktop core until 4.3;
- `getImageANGLE` remains unadvertised because the Metal backend does not
  implement its complete uncompressed/compressed image-readback contract;
- regressions cover an `R8I` buffer texture, one-byte allocation padding,
  sub-data and mapped updates, backing-buffer reallocation, `RGB32F/I/UI`,
  scalar `textureSize`, and validation/no-error Simulator contexts; and
- device gameplay validation is separate from this reproducible source/build
  verification.

## Licenses and third-party notices

ANGLE is redistributed under its BSD-style license, reproduced in
`ANGLE_LICENSE.txt`. The framework also statically contains third-party code
selected by the pinned GN graph. Its provenance is recorded in
`ANGLE_THIRD_PARTY_NOTICES.md`, and the applicable license texts are included
verbatim in `ANGLE_THIRD_PARTY_LICENSES`.
