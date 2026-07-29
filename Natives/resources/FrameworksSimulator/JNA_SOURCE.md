# Bundled Simulator JNA natives

The iOS Simulator package includes pre-converted, ad-hoc-signed
`libjnidispatch.dylib` binaries for JNA 5.13 and 5.17. They are extracted
unchanged from the official JNA Maven artifacts, except for two platform
compatibility changes:

- `LC_BUILD_VERSION` is changed from macOS to iOS Simulator, with a minimum
  deployment target of iOS 16.0.
- Foundation's macOS-style `/Versions/C/` load path is changed to the iOS
  framework path.

The resulting files are ad-hoc signed after both changes. This is required
because Amethyst's runtime platform patch intentionally invalidates the
original macOS signature. That path works on devices through Amethyst's
library-validation bypass, but a normal Simulator launch otherwise terminates
with `CODESIGNING / Invalid Page`. A debugger-attached launch masks the
failure, so Simulator validation must include a launch without LLDB.

Rebuild and verify both binaries with:

```sh
scripts/build_simulator_jna.sh
```

The script pins and verifies the Maven artifacts and final outputs:

| Version | Maven artifact SHA-256 | Simulator dylib SHA-256 |
| --- | --- | --- |
| 5.13.0 | `66d4f819a062a51a1d5627bffc23fac55d1677f0e0a1feba144aabdd670a64bb` | `c426a704f4a02f8d1bf9428d0d20c8fefbbf77b54cb39ded0dca044cd945619f` |
| 5.17.0 | `b3a9408e7c51e08ef0e3bfcc08f443f6ec0f6191ba8cd7c18d53d2b22e5bdbc0` | `2badcbd3212b0b6cbf902d7dc963136226b18746c0a0d51d535a770893f89a8c` |

JNA is dual-licensed under LGPL 2.1 or later and Apache License 2.0. This
distribution uses the Apache License 2.0 option; the upstream license notice
and text are stored beside this document.
