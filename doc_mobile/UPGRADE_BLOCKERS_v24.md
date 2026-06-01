# v24 upgrade blockers and proposed fixes

This document tracks known issues encountered while bringing the
`mobile/v24` patch stack to life. It is meant to be **kept current**: when a
blocker is resolved, move it to the bottom under "Resolved" with a link to
the patch that fixed it.

The starting point for `mobile/v24` is the upstream release tag `v24.15.0`.
Layer-A (legacy nodejs-mobile patches from `nodejs-mobile/nodejs-mobile main`)
and layer-B (the v24 migration patches from
[`heylogin/nodejs-mobile@icu`](https://github.com/heylogin/nodejs-mobile/tree/icu))
land in subsequent PRs. Three upstream upgrade attempts preceded this
work:

- [PR #134](https://github.com/nodejs-mobile/nodejs-mobile/pull/134) — staltz, v22.9.0, last activity Oct 2024.
- [PR #150](https://github.com/nodejs-mobile/nodejs-mobile/pull/150) — alzhuravlev, v22.9.0.
- [PR #151](https://github.com/nodejs-mobile/nodejs-mobile/pull/151) — jsamol, v24.5.0.

The blockers below are extracted from those PRs' comments and the heylogin
patch stack.

---

## Active

### B-1. Native modules fail with missing NAPI symbols on Android

**Reported by:** PR #151 (jsamol). User reports `dlopen` of a native module
fails with errors like `undefined symbol: napi_get_cb_info`.

**Why this matters:** without working native modules, this fork is unusable
for the React Native and Cordova plugins that depend on it.

**What to verify first:**

```sh
nm -gU --defined-only out_android/arm64/libnode.so | grep '^.* T napi_'
```

If `napi_get_cb_info`, `napi_create_string_utf8`, `napi_throw_error`, etc. are
not listed, the symbols are not being exported from the shared library.

**Likely cause.** NAPI declarations are decorated with
`__attribute__((visibility("default")))` (see `src/js_native_api.h:36`,
`src/node_api.h:24`), which should override `-fvisibility=hidden` if it's
applied. Two ways the override fails:

1. The implementation file is compiled with `-fvisibility=hidden` *and* the
   NAPI implementation lives in a translation unit that does not see the
   header's visibility attribute (e.g. it uses a local `extern "C"`
   declaration instead). Check `src/node_api.cc` and `src/js_native_api_v8.cc`.
2. The libnode link uses `-Wl,--exclude-libs,ALL` or otherwise strips
   archive symbols that arrive via static deps.

**Proposed fix path:**

1. Build with `node.gyp` `node_shared_lib` target and add explicit
   `-Wl,--export-dynamic` to its `ldflags` for `OS=="android"` (mirroring the
   FreeBSD branch that already exists at `common.gypi:785`).
2. If symbols are present but native modules still fail, inspect with
   `readelf -s` to confirm they are in `.dynsym`, not just `.symtab`.
3. As a last resort, add a `version-script` linker file enumerating the NAPI
   symbols. This is what Electron's libnode build does.

**Owner:** unassigned. Smoke-testable on any device with a NAPI module
(`@nodejs-mobile/sqlite3` is a small reproducer).

---

### B-2. iOS x86_64 simulator build requires Intel runner

**Reported by:** PR #151 (jsamol). The current workaround in
`.github/workflows/build-mobile.yml` is to pin `x64-simulator` builds to
`macos-13` (Intel). This will stop being supported by GitHub Actions soon.

**Likely cause.** Cross-compiling arm64 host → x86_64 iOS-simulator target
requires a host Xcode toolchain that supports both architectures. heylogin's
patch `63187ca7` already split host vs target xcode settings, but iOS sim
still needs the host clang/sysroot to invoke `node_js2c` natively while
emitting x86_64 object code.

**Proposed fix path:**

1. Pass `-target x86_64-apple-ios-simulator` to the iOS-target compiler
   invocations in `tools/v8_gypfiles/toolchain.gypi` rather than relying on
   `SDKROOT=iphonesimulator` to do it implicitly.
2. Verify `node_js2c` and `mksnapshot` are built for the host (Apple
   Silicon arm64) and only the V8 snapshot artifacts are emitted for the
   target.
3. Test on `macos-15` runners (Apple Silicon) with Xcode 16+. If green,
   remove the `macos-13` pin in `build-mobile.yml`.

**Owner:** unassigned.

---

### B-3. simdutf gnu++20 requirement on Android

**Reported by:** PR #134 (staltz). Newer V8/simdutf code requires
`-std=gnu++20`; older NDK toolchains and Ubuntu 20.04 GHA runners default to
`gnu++17`.

**Status:** *partially* addressed by heylogin's `133aa987 Use ubuntu-22.04`
and `7805519d Run builds on Ubuntu 24.04` commits. We currently build on
`ubuntu-24.04` with NDK r27d, both of which support gnu++20.

**Action item:** confirm the C++ standard flag is being threaded through to
*all* deps (deps/simdutf, deps/ada, deps/uvwasi). A `grep -rn 'gnu++17'
deps/*/Makefile* deps/*/build-config.* 2>/dev/null` after a clean configure
should find no hits if this is fully resolved.

---

### B-4. Trap handler must be disabled on both platforms

**Status:** addressed by heylogin's `dd424be4 Disable trap handler on all
platforms`. The `android-patches/trap-handler.h.patch` file is the v18-era
mechanism; with the v24 stack the change is applied directly via the patch
stack.

**Action item on next rebase:** verify `v8_enable_trap_handler` is set to
`false` (or the relevant V8 build flag) and remove the legacy
`android-patches/` directory once we confirm nothing applies it.

---

### B-5. iOS minimum deployment target

**Status:** addressed by heylogin's `be5082b0 Increase iOS min deploy target
to 14.0`. APIs like `preadv` / `pwritev` used by libuv require iOS 14+.

**Action item:** update `doc_mobile/CHANGELOG.md` and any consumer docs that
still claim iOS 13.0 support.

---

### B-6. Android NDK pinning

**Status:** the build-mobile.yml workflow pins `ANDROID_NDK_VERSION: r27d`.
NDK r24 and r26 each had blocker bugs (CRC32 LLVM crash on r24, simdutf
miscompile on r26 in some configurations).

**Action item:** when bumping NDK, do it as a single commit on the patch
stack so the change is bisectable. Add a one-line note in the commit body
explaining what made the new NDK necessary or what bug the previous NDK had.

---

### B-7. 16 KB page size on Android

**Status:** addressed via `LDFLAGS: -Wl,-z,max-page-size=16384` in
`build-mobile.yml` and patch `ffe4361a Compile using 16 KB alignment`.
Required because Android 15+ phones with 16 KB pages reject 4 KB-aligned
shared libraries.

---

## Resolved

### R-1. iOS host-toolchain split (`DYLD_ROOT_PATH not set for simulator`)

**Was:** PR #134's primary blocker. When building for iOS simulator, the
codegen tool `node_js2c` was being built with iOS-target settings and could
not run on the macOS host.

**Resolved by:** heylogin's `63187ca7 Use clang and ninja for iOS, include
iOS in make and ninja builds, fix host compilation`. This commit splits
`common.gypi` Apple settings into a `_toolset=="host"` branch (uses
`MACOSX_DEPLOYMENT_TARGET=13.5`) and a target branch (uses
`IPHONEOS_DEPLOYMENT_TARGET=14.0` with `SDKROOT=iphoneos` /
`iphonesimulator`). `node.gyp:1367` declares `node_js2c` with
`'toolsets': ['host']`, which now correctly picks the macOS settings.

### R-2. Android NDK r24 LLVM CRC32 crash on arm64

**Was:** zlib intrinsics crashed at link time with NDK r24.

**Resolved by:** heylogin's `4bc9e5dc Use Android NDK r26d to fix LLVM CRC32
crash`, then later upgraded to r27d.
