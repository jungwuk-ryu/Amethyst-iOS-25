# ANGLE release evidence

Validation date: 2026-07-30

Source:

- Google ANGLE base: `6024e9c05548480c3b2ea42836a112509a549a95`
- Patched commit: `5d7e055b5f40f79bb06b15d7fbdf4a328c5cee3c`
- Patched tree: `81da38451656b2aed7686682f42fcdaa95ce55a4`
- Patch application: all six `patches/angle/*.patch` files applied cleanly
  to the base in a new worktree and produced the patched tree above.

Automated checks:

```text
angle_unittests
  6,557 tests from 240 suites
  6,556 passed
  1 pre-existing expectations-parser test skipped

MSLOutputDesktopGLTest.*
  12 passed

DesktopMetalTextureBufferTest.* --use-config=GL3_2_Core_Metal
  3 passed on Apple M5 Pro

ANGLE Simulator standalone smoke, iPhone 17 Pro / iOS 26.5 (23F77)
  Validation context: PASS
  No-error context: PASS
  GL_VERSION=3.3.0
  GL_RENDERER=ANGLE Metal / Apple iOS simulator GPU

Fresh reproducibility run
  Started from an empty ANGLE_WORK_DIR
  Cloned the pinned source/tool revisions and applied all six patches
  Rebuilt host tests and the Simulator frameworks
  Release SHA-256 manifest: PASS
  Simulator validation/no-error smoke: PASS
```

Application smoke:

```text
PR #45 launcher plus the final patched Simulator ANGLE frameworks
  Minecraft 26.2 Pre-Release 5: same single-player world entered; process
  remained active through the timed smoke run; no new hs_err, SIGSEGV, or
  Metal validation failure.
  Minecraft 26.2 Pre-Release 6: same single-player world entered; process
  remained active in-world for 3 minutes 10 seconds; no new hs_err, SIGSEGV,
  or Metal validation failure.
  Final rebuilt launcher/tinygl diagnostics-off path: Pre-Release 6 re-entered
  the same world and remained active for more than 1 minute 50 seconds.
  Persisted renderer set to libmobileglues.dylib: Simulator launcher logged
  the unsupported selection, normalized it to ANGLE, and entered the same
  Pre-Release 6 world.
```

The user separately validated the MobileGlues PR IPA on physical devices
running iOS 26 and iOS 27 beta. That does not count as direct-ANGLE device
validation. Direct ANGLE on a physical device remains required before the
device `auto` renderer can prefer ANGLE over the retained MobileGlues
fallback.
