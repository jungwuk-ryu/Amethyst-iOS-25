# ANGLE framework third-party notices

This inventory accompanies the patched ANGLE `libEGL` and `libGLESv2`
frameworks. The exact dependency revisions are resolved by ANGLE commit
`6024e9c05548480c3b2ea42836a112509a549a95` and its `DEPS` file. The source
paths below are relative to the fully synchronized ANGLE checkout produced by
`scripts/build_angle.sh`.

| Component | Revision recorded by the pinned checkout | License | Included notice |
| --- | --- | --- | --- |
| ANGLE | `6024e9c05548480c3b2ea42836a112509a549a95` | BSD-3-Clause-style | `LICENSE`; reproduced as `ANGLE_LICENSE.txt` |
| Abseil C++ | `ba5fd0979b4e74bd4d1b8da1d84347173bd9f17f` | Apache-2.0 | `ANGLE_THIRD_PARTY_LICENSES/Abseil-LICENSE` |
| xxHash | `0f2dd4a1cb103e3fc8c55c855b821eb24c6d82c3` | BSD | `ANGLE_THIRD_PARTY_LICENSES/xxHash-LICENSE` |
| Arm ASTC Encoder | `573c475389bf51d16a5c3fc8348092e094e50e8f` | Apache-2.0 | `ANGLE_THIRD_PARTY_LICENSES/astc-encoder-LICENSE.txt` |
| zlib | `ac8f12c97d1afd9bafa9c710f827d40a407d3266` | zlib | `ANGLE_THIRD_PARTY_LICENSES/zlib-LICENSE` |
| volk | `1ee0b6642ecb947a10f4f988930c02f54cb4b577` | MIT | `ANGLE_THIRD_PARTY_LICENSES/volk-LICENSE.md` |
| libc++ | `e2d898ca22f1d5863d8f6a7a0df849109483e05f` | Apache-2.0 WITH LLVM-exception | `ANGLE_THIRD_PARTY_LICENSES/libcxx-LICENSE.TXT` |
| libc++abi | dependency selected by the pinned `DEPS` graph | Apache-2.0 WITH LLVM-exception | `ANGLE_THIRD_PARTY_LICENSES/libcxxabi-LICENSE.TXT` |
| Clang compiler runtime | `llvmorg-20-init-3847-g69c43468-28` toolchain build | Apache-2.0 WITH LLVM-exception | `ANGLE_THIRD_PARTY_LICENSES/compiler-rt-LICENSE.TXT` |

The listed license texts are copied verbatim from the pinned synchronized
checkout. The inventory was checked against the GN dependency and final
dynamic-link graphs for all four shipped binaries: device and Simulator
variants of both `libEGL` and `libGLESv2`. Those four targets resolve the same
99 third-party GN dependencies, while their final dynamic imports contain
only Apple system libraries. Build-only dependencies used only by the host
tests are not included. Redistributors must keep `ANGLE_LICENSE.txt`, this
inventory, and the `ANGLE_THIRD_PARTY_LICENSES` directory with the
frameworks.
