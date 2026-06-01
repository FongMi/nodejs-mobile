# nodejs-mobile v24.15.0 — Audit & Release-Readiness Report

Branch: `claude/review-mobile-v24-upgrade` · HEAD: `2b4fe8b40a` · Patch-stack base: `v24.15.0`

This report consolidates a multi-agent analysis of the v24.15.0 mobile upgrade: a
per-commit build/configure triage of the layer-B patch stack, adversarial
diagnosis of the two known blockers (B-1 NAPI symbols, B-2 iOS x86_64 simulator),
and the patch-management + CI tooling authored during the workflow. It maps
directly onto the phases in [`RELEASE_PLAN_v24.md`](./RELEASE_PLAN_v24.md).

---

## 1. Executive summary

**The tree is NOT release-ready.** `./configure --help` exits 0 at HEAD and the
default Android/iOS configure paths parse, but two distinct *build/link*
regressions were introduced by the v18→v24 conflict resolution ("took theirs"
on the major build files), and the two documented blockers are not yet closed.
None of these would be caught by configure-time CI alone; they surface at link
time or at addon-load time on-device.

### Root cause

The PR #2 / PR #3 conflict resolution silently reverted **`node.gyp`,
`v8.gyp`, `configure.py`, `make.py` and `node.gypi`** to v18-era versions
(while `ninja.py` was inconsistently kept at v24.15.0). Four large layer-B
commits then hand-re-typed the v24 content — but authored against **v24.5.0**,
not v24.15.0. The result: source lists and dependency wiring that drifted from
upstream and dropped real files.

The per-file pass (section 2b) shows the "take theirs" revert was **broader than
the major build files**: a scatter of individual `src/*` and `deps/*` source
files (and the test harness) were reverted to v18 while their v24 headers/siblings
stayed in place — producing hard compile/link breaks and several dropped
security/correctness fixes that the file-level build triage did not see. Net of
the per-file pass, **35 of 66 audited files are CLEAN** (upstream retained, mobile
patch correctly re-applied), and 31 are flagged.

### Must-fix before tagging v24.15.0

1. **`node.gyp` stale source lists (REWORK `dbea9dee52`).** Drops 3 `node_sources`
   and 5 `node_crypto_sources` entries that exist in `src/` but won't compile/link
   (ML-DSA/KEM/KMAC crypto, diagnostics_channel binding, SEA, builtin_info).
   This is a real undefined-symbol link break, not just parse drift.
2. **`node.gypi` dropped v24 dependency wiring (Blocker B-1 collateral).** The
   "take theirs" merge removed `deps/uvwasi`, `deps/ada`, `deps/simdjson`,
   `deps/sqlite`, `deps/zstd` link stanzas. Surfaces as `ada::*`, `sqlite3_*`,
   `ZSTD_*`, `uvwasi_*` undefined symbols — easy to misattribute to B-1.
3. **Blocker B-1 (NAPI on Android) — empirical gate required.** The stated cause
   (hidden visibility / `--exclude-libs`) was **refuted**; `napi_*` should already
   be exported. Must verify with `nm -gDU` on a real arm64 build before patching,
   then apply the version-script hardening regardless.
4. **Blocker B-2 (iOS x86_64 sim) — Intel-runner clock.** The current build only
   works because `arch -x86_64` makes it a same-arch build, not a cross-compile.
   The `macos-13` Intel runner is deprecated; a true arm64-host cross-compile is
   blocked by an unconditional ARCHS clobber in `common.gypi` / `toolchain.gypi`.
5. **`configure.py` / `make.py` drift (REWORK `99d245010f`).** Drops upstream
   `--shared-*` options and carries 30 hunks of v18→v24 make-generator drift.
   Lower risk (default configure works) but a regression hazard.
6. **ICU enablement (REWORK `a938b63be7`).** Verify small-icu actually links on
   iOS/Android; drop the stray `icu` CI branch-filter hunk (heylogin leftover).
7. **Lone v18 files inside the v24 tree (NEW, from the per-file pass, F12–F20).**
   The merge left several source files reverted to v18 while their headers/siblings
   are v24, each a hard compile/link break: `deps/uv/src/unix/fs.c` (F12,
   `uv__req_register` arity), `deps/v8/.../trap-handler/trap-handler.h` (F13,
   undeclared `AssertThreadNotInWasm`/`SetLandingPad` called under WASM-enabled
   builds), `src/node_env_var.cc` (F14, pure-virtual `KVStore` mismatch +
   `CreateEnvProxyTemplate` arity), `src/node_metadata.h` (F15/F20, missing
   `pairs()`/keys vs the v24 `.cc`), and `deps/uv/src/unix/darwin.c` (F16, missing
   `uv_get_available_memory`). Plus dropped **security/correctness** fixes:
   `deps/uvwasi/src/uvwasi.c` (F17, WASI symlink-sandbox confinement + readlink
   overread). Re-base each on v24.15.0 and re-apply only the minimal mobile delta.
8. **Test infrastructure reverted to v18 (NEW, F18/F19).** `test/common/index.{js,mjs}`
   and `tools/test.py` were taken from v18, so the v24 suite cannot run
   (`GetCommand` vs `GetRunConfiguration`; missing `escapePOSIXShell`/`isMacOS`/
   `hasSQLite` helpers). This masks v24 regressions and blocks the SQLite tests for
   the feature the fork just added.

Once the source-list, dependency-wiring, and lone-v18-file gaps are closed and a
real Android arm64 + iOS arm64 build links, the tree moves from "configure-clean"
(Phase 1) to "build-clean" (Phase 2). B-1/B-2 (Phase 3) and device tests (Phase 5)
remain.

---

## 2. Critical & High findings

The findings below come from two sources: the build/configure triage and two
blocker diagnoses (F1–F11), and a **per-file conflict-resolution audit** of 66
files touched by the v18→v24 merge (section 2b). The per-file pass did not run
in the first iteration; it has now completed and is integrated here. It
**confirmed and sharpened** the build/link thesis of F1–F11 and **surfaced
several new critical/high build-breaks** in `src/*` and `deps/*` that the
file-level triage missed (libuv `fs.c`/`darwin.c`, the V8 trap-handler header,
`node_env_var.cc`, `node_metadata.h`, uvwasi sandbox hardening). All are
classified below using the same severity scale. The "Adversarial note" column
records where the verifier refuted or downgraded a stated cause.

| # | File / area | Classification | Severity | Lost / broken change | Recommendation | Adversarial note |
|---|---|---|---|---|---|---|
| F1 | `node.gyp` (`dbea9dee52`) | Stale source list on v18 base | **CRITICAL** | `node_sources` 121 vs 124, `node_crypto_sources` 40 vs 45. Missing `src/builtin_info.cc`, `src/node_diagnostics_channel.cc`, `src/node_sea_bin.cc`, `crypto_argon2.cc`, `crypto_chacha20_poly1305.cc`, `crypto_ml_dsa.cc`, `crypto_kem.cc`, `crypto_kmac.cc` (+ matching `.h`). Files exist in `src/` but are not compiled → undefined symbols / missing registration. | REWORK: regenerate `node.gyp` as a minimal mobile delta on the **v24.15.0** `node.gyp`. | Confirmed real link break (files present in `src/`); configure still parses, so configure-only CI would miss it. |
| F2 | `node.gypi` (B-1 collateral) | Dropped v24 dep wiring | **CRITICAL** | "Take theirs" removed `node_shared_uvwasi/ada/simdjson/sqlite/zstd==false → deps/*` link stanzas (present in both v24.15.0 upstream and `heylogin/icu`). → `ada::*`, `sqlite3_*`, `ZSTD_*`, `uvwasi_*` undefined symbols. `simdutf` survives via the v8.gyp target. | REWORK: re-add the stanzas (B-1 Part C) after confirming each `deps/<x>/<x>.gyp` exists. | Found while refuting B-1; a *separate* real regression, distinct from the NAPI symptom. |
| F3 | Blocker B-1 — NAPI symbols on Android | Export contract | **HIGH** | Reported symptom: `undefined symbol: napi_get_cb_info` when dlopen-ing an addon. | Verify empirically (`nm -gDU … \| grep ' T napi_'`), then add Android version-script hardening (B-1 Part B). | **Refuted/downgraded.** Stated cause (`-fvisibility=hidden`, `--exclude-libs`, whole-archive) does NOT hold: NAPI decls carry `visibility("default")`, core is not built hidden, `-rdynamic` is on for Android, no strip flags, LTO off. Most plausibly an embedder RTLD_GLOBAL/load-order issue, not a libnode export bug. Confidence: medium. |
| F4 | `configure.py` + `tools/gyp/.../make.py` (`99d245010f`) | Hand-merged v24.5.0 full files | **HIGH** | Drops upstream argparse options `--shared-gtest*`, `--shared-hdr-histogram*`, `--shared-nbytes*`. `make.py` still 30 hunks off v24.15.0 on a v18-derived base; `ninja.py` was kept at v24 (inconsistent generator base). | REWORK: re-derive the mobile delta on the v24.15.0 `configure.py`/`make.py`. | Downgraded from "configure-broken": `./configure --help` exits 0, the `packaging.version` import matches upstream and resolves in-tree, default Android/iOS configure works. Risk is dropped flags + make-generator drift, not parse failure. |
| F5 | Blocker B-2 — iOS x86_64 simulator | Build-host portability | **HIGH** | x64-sim only builds on Intel `macos-13` (deprecated). `arch -x86_64 make` makes `host_arch==target_arch==x64`, so it never cross-compiles; true arm64-host cross-compile is blocked. | Real cross-compile: drop `arch -x86_64`, add `--ios-simulator`, gate the unconditional x64 `ARCHS` to `_toolset=="target"`, add a symmetric arm64-host override, optional explicit `-target` triple, repin runner to `macos-15`. | Confidence: medium. mksnapshot is a non-issue (`--without-node-snapshot/code-cache`); only `node_js2c` must run on host. Concrete missing piece: no symmetric `host_arch=="arm64"` override to mirror the existing inverse fix at `toolchain.gypi:601-614`. |
| F6 | `v8.gyp` (`aff2710125`) | Hand-merged v24.5.0 full file | **MEDIUM** | Residual ~115-line diff vs v24.15.0; drops AIX-only `torque/implementation-visitor.cc` `-O0` case (mobile-irrelevant); reshapes host stack_trace/platform source selection. | REWORK: rebase the mobile delta onto v24.15.0 `v8.gyp` so structure matches upstream. | Mostly intentional mobile platform conditionals. Generated/torque/builtins source lists **verified to match upstream**. Low link risk for iOS/Android. |
| F7 | ICU enablement (`a938b63be7`) | Build-graph change + CI leftover | **MEDIUM** | Flips `--with-intl=none → small-icu`; adds `libicudata.a` to iOS outputs. Includes a stray `icu` branch-filter hunk from heylogin's source branch. | REWORK: drop the CI branch-filter hunk; confirm icu sources / `icu_versions.json` / `libicudata.a` link on iOS+Android. | — |
| F8 | GYP_DEFINE rename split (`2f0b34d422` #5 / `147768a676` #8) | Producer/consumer split | **MEDIUM** | Consumers switch `ANDROID_NDK_ROOT→android_ndk_path` at #5 while `android_configure.py` emits the old names until #8 → Android graph broken for commits #5–#7 in isolation. | REORDER/MERGE the two so the rename is atomic. | Per-commit (patch-stack) hazard, not a HEAD hazard (both land by HEAD). |
| F9 | `host_os` value mismatch (`62700f825f` #18) | Producer/consumer split | **MEDIUM** | gyp conditions keyed on `host_os=="mac"` land at #6/#7, but `android_configure.py` emits `host_os=darwin` until #18 → no host platform sources for the macOS-host Android cross-build, commits #6–#17. | REORDER `host_os=mac` up next to `aff2710125`/`548f268e72`. | Per-commit hazard; correct at HEAD. |
| F10 | `node.gyp` histogram dep (`dbea9dee52` residual) | Dependency mismatch | **MEDIUM** | HEAD adds `deps/histogram/histogram.gyp:histogram` while `configure.py` dropped `--shared-hdr-histogram`. | Verify the `histogram`/`nbytes` static-lib targets exist and are wired in v24.15.0, or the link fails. | Folded into the F1 rework. |
| F11 | iOS framework link lists (`40f5bde367`/`1f8169254c`/`a938b63be7`) | Output-list drift | **MEDIUM** | `ios_framework_prepare.sh` `outputs_common` + `project.pbxproj` Frameworks must list exactly the gyp lib targets. SQLite disabled then re-enabled (`libsqlite.a`); ICU adds `libicudata.a`. If a lib renamed v24.5→v24.15, lipo/link fails. | Verify pbxproj fileRefs + gyp target names match the produced `.a` set. | — |
| F12 | `deps/uv/src/unix/fs.c` (per-file) | Lone v18 file inside v24 libuv tree | **CRITICAL** *(security)* | Whole file reverted to libuv 1.44.2 + the 2 mobile patches (990-line delta vs v24.15.0). Hard **compile break**: v24 `uv-common.h` defines `uv__req_register(loop)` as a 1-arg macro, but this v18 `fs.c` calls it 2-arg (lines 153, 1778). Also drops the EINTR-retrying `uv__fstat/lstat/stat` wrappers, `utime`/`futime` inf/nan guards, the ceph-fuse `EACCES` `ftruncate` workaround, the `_Atomic` migration, io_uring fast path. | REWORK: re-vendor `fs.c` from `v24.15.0` (matches the rest of OURS libuv 1.51.0) and re-apply ONLY the 2 mobile patches (the Android `copy_file_range` guard; the Darwin `!TARGET_OS_IPHONE` sendfile branch). | Lone reverted file — `linux.c`/`core.c`/`process.c`/`uv.h`/`version.h` are all v24 byte-for-byte. Recommend auditing deps for other lone v18 outliers. |
| F13 | `deps/v8/src/trap-handler/trap-handler.h` (per-file) | v18 header under v24 .cc tree | **CRITICAL** *(security)* | Entire v18 header + mobile patch on the wrong base. Drops `AssertThreadNotInWasm()`, `SetLandingPad()`, `RegisterV8Sandbox`/`UnregisterV8Sandbox`, `TH_EXPORT_PRIVATE` on globals, the Android `#error` defense. **Hard build break**: `AssertThreadNotInWasm()` is called under `#if V8_ENABLE_WEBASSEMBLY` (default ON) from `isolate.cc:2097/2222`, `heap-allocator-inl.h:85`, `runtime-wasm.cc:125`; `SetLandingPad` from `isolate.cc:4254`, `wasm-interpreter.cc:657` → undeclared-identifier compile failures. | REWORK: take `git show heylogin/icu:.../trap-handler.h` (v24 base + the minimal `#define V8_TRAP_HANDLER_SUPPORTED false` mobile patch); restore trailing newline. | The dropped functions ARE still defined in the v24 `handler-outside.cc` shipped in OURS → header/impl mismatch. The whole `trap-handler/` dir is a tightly-coupled ABI set. |
| F14 | `src/node_env_var.cc` (per-file) | Verbatim v18.20.4 file | **CRITICAL** | Entire v18 file shipped. **Will not compile/link** against the v24 tree: (1) pure-virtual mismatch vs v24 `util.h` `KVStore` (`Get`/`Enumerate`/`AssignFromObject` signatures) → `RealEnvStore`/`MapKVStore` stay abstract; (2) `CreateEnvProxyTemplate` defined 2-arg but declared/called 1-arg (`node_process.h:19`, `env.cc:536`) → undefined symbol; (3) V8 24 interceptor ABI mismatch (Intercepted-returning getters); (4) `--trace-env` family parses but is silently inert (no `TraceEnvVar` calls); (5) reverted `ToLocalChecked`→`ToLocal` correctness hardening. | REWORK: re-port from `v24.15.0` `node_env_var.cc`, then re-apply ONLY the mobile `Clone` guard (change the missing-key early-return to `continue` to keep the Android LD_PRELOAD intent). | Defensive `ToLocalChecked`→`ToLocal` conversions lost; no specific CVE. |
| F15 | `src/node_metadata.h` (+ `.cc`) (per-file) | v18 header under v24 .cc | **HIGH** *(security-adjacent)* | `.cc` is correct v24 but `.h` is v18 + mobile macro. **Build break**: `.h` declares neither `pairs()` nor `NODE_VERSIONS_KEY_COUNT` and omits `<array>`/`<utility>`; `.cc` assigns members `merve`/`zstd`/`simdjson`/`nbytes`/`ncrypto`/`amaro`/`sqlite` that the `.h` macro never declares; still expands dead `cjs_module_lexer`/`base64`; uses removed `OPENSSL_INFO_QUIC` not `NODE_OPENSSL_HAS_QUIC`. Three consumers also fail: `node_process_object.cc:86`, `node_report.cc:797`, `tracing/traced_value.cc:243`. | REWORK: replace `.h` with the `v24.15.0` version + re-apply ONLY the `NODE_VERSIONS_KEY_MOBILE(V)→V(mobile)` macro inside `NODE_VERSIONS_KEYS`. `.cc` needs no change. | The `GetOpenSSLVersion` BoringSSL `0.0.0` OOB-substr hardening lives in the `.cc` and IS retained. Corroborated by F20. |
| F16 | `deps/uv/src/unix/darwin.c` (per-file) | Wholesale v18 + mobile patch | **HIGH** | Every v24 change lost. **Link break**: public API `uv_get_available_memory()` is absent here but declared in `uv.h:1827` and called from `env.cc:2108`, `node_process_methods.cc:257`, `node_report.cc:656` → undefined symbol on the darwin/iOS static-vendored build. Also: `uv_get_free/total_memory()` revert to casting a negative `UV__ERR` into `uint64_t` (bogus huge value) instead of the v24 `return 0`. | REWORK: rebase onto `v24.15.0` `darwin.c` (keeps `uv_get_available_memory`, `return 0` paths, sysctl cpu-speed); re-apply ONLY the iOS cpu-speed guard; drop the obsolete `uv__get_cpu_speed` layer-A guard. | Same lone-v18-file pattern as F12; deps/uv is otherwise v24. |
| F17 | `deps/uvwasi/src/uvwasi.c` (per-file) | Verbatim uvwasi 0.0.19 + Android guard | **HIGH** *(security)* | Whole file reverted to v18; security/correctness fixes dropped: (1) **WASI sandbox** — `path_symlink` no longer NUL-truncates `old_path` nor rejects absolute targets (`/`→`EPERM`); passes raw, unterminated buffer to `uv_fs_symlink` → weakened path confinement + unterminated-buffer read; (2) `path_readlink` over-reports length by 1 (`*bufused = len + 1`) — info over-read to the WASM guest; (3) `fd_pread/pwrite` lose the `offset > INT64_MAX` guard; (4) `iovs_len==0` no-op handling; (5) weaker `VALIDATE_FSTFLAGS`; (6) `fd_advise` dir→`EBADF`; (7) `uvwasi_init`/`sock_accept` NULL-malloc→`ENOMEM` checks (NULL-deref risk). | REWORK: `git checkout v24.15.0 -- deps/uvwasi/src/uvwasi.c`; **DROP** the Android `seekdir/telldir` guard entirely — v24 `fd_readdir` uses a portable `cur_cookie` loop, so the patch is obsolete. | The reverted `fd_readdir` reintroduces `seekdir/telldir` (OURS lines 1400/1417), making the mobile patch redundant atop obsolete code. |
| F18 | `test/common/index.js` + `index.mjs` (per-file) | v18 harness + `isAndroid/isIOS` bolted on | **HIGH** *(test infra)* | Entire v24 harness rewrite reverted (`took theirs` = took v18). `escapePOSIXShell` (48 tests), `isMacOS` (49), `hasSQLite`/`skipIfSQLiteMissing` (30 — the very SQLite feature the fork just added cannot be tested), `expectRequiredModule` (12), `parseTestMetadata` (3) are now undefined → `TypeError` / silent wrong skips. `.mjs` named-export-not-found fails at module eval. Broadly masks v24 regressions. | REWORK: re-base both on the v24 `index.js`/`index.mjs`, re-add `isAndroid/isIOS` to the destructure + export block. Note `.js` 100755→100644 mode flip from the revert. | Not shipped in the binary, but it breaks/masks the entire v24 suite. Several other test files (F-table 2b) depend on the missing helpers. |
| F19 | `tools/test.py` (per-file) | v18 runner vs v24 testcfgs | **HIGH** *(test infra)* | Entire v24 rewrite reverted; only the `android/ios→system` mapping kept. **Breaking mismatch**: line 601 calls `self.GetCommand()`, but the v24 test configs (`test/testpy/__init__.py`, `message/testcfg.py`, `pseudo-tty/testcfg.py`) define `GetRunConfiguration()` and NO `GetCommand()` → `AttributeError`; the node test suite as assembled likely cannot run. Also lost: argparse migration, TAP skip_regex, `max_virtual_memory` rlimit, `NODE_SKIP_FLAG_CHECK`. | REWORK: discard v18 `tools/test.py`, start from v24, re-apply only the ~6-line arch→`env['system']` mapping in `Main()`. | The single most impactful test-infra finding — pairs a v18 runner with v24 testcfgs. |
| F20 | `test/parallel/test-process-versions.js` (per-file) | v18 test + node_metadata.h collateral | **CRITICAL** *(security)* | Reverted to v18: `expected_keys` lists `cjs_module_lexer`/`base64`, missing `zstd`/`simdjson`/`nbytes`/`merve`/`ncrypto`/`sqlite`/`amaro`; `assert.match` for merve/nbytes/zstd/ncrypto gone; calls `common.hasOpenSSL3` (UNDEFINED on v24 — moved to `../common/crypto`) so it silently picks the OpenSSL-1.x regex branch. **Critical collateral**: the same layer-A commit reverted `src/node_metadata.h` to v18 while `.cc` stayed v24 → C++ compile error (same break as F15). | REWORK: (1) reconcile `node_metadata.h`↔`.cc` (= F15 fix); (2) rebuild this test from v24, replace `common.hasOpenSSL3` with `require('../common/crypto').hasOpenSSL3`, fix `expected_keys`. | Severity is critical because of the build-blocking `.h`/`.cc` collateral, not the test text alone. Corroborates F15. |

No findings were *fabricated*; the only refutation/downgrades are the B-1 root
cause (F3), the configure-breakage claim (F4), and the per-file
`handler-inside-posix.cc` finding (downgraded high→low after verification — see
section 2b). All are reflected above and in 2b.

---

## 2b. Per-file conflict-resolution audit

A second pass adversarially reviewed **66 files** touched by the v18→v24 merge,
diffing each against `v24.15.0`, `heylogin/icu`, and `nm-org/main` to detect
"take theirs" reverts where an upstream change (especially a security/correctness
fix) was silently dropped. **35 of the 66 files were CLEAN** — the expected,
reassuring outcome: the upstream content was correctly retained and the mobile
patch re-applied on top (model examples: `src/node.cc`, `src/node_credentials.cc`
with its CVE-2024-22017 io_uring guard intact, `src/crypto/crypto_context.cc`,
`lib/internal/modules/cjs/loader.js`, `deps/v8/.../platform-posix.cc`,
`test/parallel/test-fs-realpath.js`, `test/parallel/test-watch-mode-files_watcher.mjs`).
**31 files were flagged**; the non-trivial ones are tabulated below
(critical/high first). The trivial flags are summarized after the table.

### Non-clean findings

| File | Class | Sev | Lost change | Recommendation | Adversarial note |
|---|---|---|---|---|---|
| `node.gyp` | LOST_UPSTREAM | **CRIT** | Source lists track v24.5.0, not v24.15.0. 13 missing + 2 phantom paths: `node_crypto_sources` drops `crypto_chacha20_poly1305.cc` (referenced **unconditionally** → guaranteed link fail), `crypto_argon2`/`kem`/`kmac`/`ml_dsa` (+.h); `node_sources` drops `builtin_info.cc/.h`, `node_cjs_lexer.cc`, `node_diagnostics_channel.cc/.h`, `node_sea_bin.cc`; phantom `src/json_parser.{h,cc}` no longer exist → dangling GYP refs. | Re-derive from v24.15.0; add the 13, remove the 2 phantoms; add a CI assert that every `src/**/*.cc` is referenced. | **Extends F1** with the exact identity: lists are v24.5.0, the link break is the unconditional ChaCha20-Poly1305 symbol, plus loss of PQC ML-DSA/KEM/KMAC/Argon2 bindings. |
| `src/node_env_var.cc` | LOST_UPSTREAM | **CRIT** | See F14. | See F14. | NEW (F14). |
| `deps/uv/src/unix/fs.c` | NEEDS_REWORK | **CRIT** | See F12. | See F12. | NEW (F12). |
| `deps/v8/src/trap-handler/trap-handler.h` | NEEDS_REWORK | **CRIT** | See F13. | See F13. | NEW (F13). |
| `test/parallel/test-process-versions.js` | NEEDS_REWORK | **CRIT** | See F20. | See F20. | NEW (F20); corroborates F15. |
| `configure.py` | NEEDS_REWORK | **HIGH** | Is the v24.5.0 file, inconsistent with the rest of the v24.15.0 tree → 2 build breaks + 2 correctness bugs: (1) reverted `config.gypi` writer to `pprint.pformat` but OURS `js2c.cc` expects JSON → embedded-builtins build fail; (2) `shareable_builtins` still lists `cjs_module_lexer/*` files deleted in v24 (now `deps/merve`) → missing-input build fail; (3) `try_check_compiler` reverted to a 4-tuple but callers unpack 5 → `ValueError` on compiler-not-found; (4) `v8_enable_v8_checks` release/debug flip. | Re-derive from v24.15.0; restore `json.dumps`, the v24.15 `shareable_builtins` set, the 5-tuple, and the `--shared-*` flags. | **Extends F4** with the precise build-break mechanism (js2c.cc JSON contract, deleted cjs-module-lexer, tuple arity). |
| `src/node_metadata.h` / `.cc` | NEEDS_REWORK | **HIGH** | See F15. | See F15. | NEW (F15). |
| `deps/uv/src/unix/darwin.c` | NEEDS_REWORK | **HIGH** | See F16. | See F16. | NEW (F16). |
| `deps/uvwasi/src/uvwasi.c` | NEEDS_REWORK | **HIGH** *(sec)* | See F17. | See F17. | NEW (F17). |
| `test/common/index.js` / `index.mjs` | BROKEN_MOBILE | **HIGH** | See F18. | See F18. | NEW (F18). |
| `tools/test.py` | NEEDS_REWORK | **HIGH** | See F19. | See F19. | NEW (F19). |
| `node.gypi` | LOST_UPSTREAM | MED | v18 file + iOS-framework block; entire v24 rewrite dropped: `uvwasi`/`ada`/`merve`/`simdjson`/`sqlite`/`zstd` link wiring, `HAVE_SQLITE`/`HAVE_AMARO` defines (→ TypeScript/Amaro + node:sqlite silently compiled out), `-framework Security`; stale `v8_enable_shared_ro_heap`/`NOMINMAX` retained. | `git checkout heylogin/icu -- node.gypi` (already = v24 base + all 4 mobile patches), then confirm mobile blocks survive. | **Extends F2** and fixes it in one move; adds the `HAVE_SQLITE`/`HAVE_AMARO`-disabled subsystem impact. |
| `deps/ngtcp2/ngtcp2.gyp` | LOST_UPSTREAM | MED | `ngtcp2_sources` is the stale v18 list vs the v24 vendored tree in HEAD: references missing `ngtcp2_conversion.c`; omits `ngtcp2_dcidtr.c`, `ngtcp2_settings.c`, `ngtcp2_transport_params.c` → broken build + never-compiled QUIC modules. | Replace with the v24.15.0 source list (drop `conversion.c`; add the 3). | NEW. Downgraded high→medium: build-config only, the C sources themselves were upgraded correctly. |
| `test/parallel/test-fs-promises.js` | LOST_UPSTREAM | MED | Whole file reverted to v18 + 2 guards; heaviest test-coverage loss in the batch: drops the `throwIfNoEntry:false` test, the buffer-`TypeError` test, ~9 `mustCall` callback guards, and multiple `await assert.rejects`/`.then(mustCall())` rejection guards (reintroduces silently-passing assertions). | Rebase the 2 mobile guards onto v24; restore the 2 new tests + the rejection guards. | NEW. Test-only. |
| `test/parallel/test-assert-deep.js` | LOST_UPSTREAM | MED | v18 structure + iOS patch; loses ALL coverage of `assert.partialDeepStrictEqual` (a shipping v24 API) + the #61386 mixed-key regression tests. | Rebase onto v24, re-apply the iOS `stderr.columns` patch. | NEW. Test-only; missing tests, not dropped runtime fix. |
| `test/parallel/test-fs-mkdir.js` | LOST_UPSTREAM | MED | Whole file reverted; drops `path.toNamespacedPath` oracle updates (fails on Windows), the `mustCall` ENOENT wrapper, the `isMainThread` import. | Rebase only the platform-guard widening onto v24; restore the oracle + wrapper. | NEW. Test-only. |
| `common.gypi` | NEEDS_REWORK | LOW | One lost rename: v24 deleted `V8_COMPRESS_POINTERS_IN_ISOLATE_CAGE` (now only in OURS) and added the `..._IN_MULTIPLE_CAGES` define — addons (via common.gypi) vs V8/node (via features.gypi) would define different pointer-compression ABIs in an unsupported pc=1/shared_cage=0 config. | Replace the obsolete branch with the v24 `MULTIPLE_CAGES` form. | NEW. Low: mobile defaults PC off; `configure.py:1736` forces shared_cage=1. Build-config, no runtime logic. |
| `deps/v8/.../trap-handler/handler-inside-posix.cc` | LOST_UPSTREAM | LOW | Drops `IsAccessedMemoryCovered` pre-check + the `IsFaultAddressCovered`/`gLandingPad` API migration, and **build-breaks** (calls removed `TryFindLandingPad`/`v8_probe_memory_continuation`). | Replace with the v24.15.0 file verbatim (the mobile guard was upstreamed). | NEW. **Downgraded high→low** (`refuted`): the security pre-check is real but the headline is a build break against its v24 sibling headers; fixed together with F13. |
| `deps/v8/.../push_registers_asm.cc` | LOST_UPSTREAM | LOW | v18 blob; drops the typo fix, the `_WIN64`→`#error` cleanup, and the ELF `.size` directive (no symbol-size metadata for unwinder/symbolizer on Android/ELF — tooling only, not execution). | Use the `heylogin/icu` v24-rebased blob; apply only the `#ifndef V8_TARGET_ARCH_ARM` guard. | NEW. Hygiene/build-metadata only; no runtime/security impact. |
| `tools/gyp/.../make.py` | LOST_UPSTREAM | LOW | Pinned at v24.5.0 gyp-next: sha1 (not sha256) temp-filename hash; missing `openharmony` flavor. Neither affects iOS/Android shipped artifacts. | Optional: cherry-pick the sha256 + openharmony lines; reflow formatter churn. | **Corroborates F4** (make.py drift) but downgrades the runtime impact to nil. |
| `tools/gyp/.../ninja.py` | LOST_UPSTREAM | LOW | Reverted md5→sha256 hashlib switch; the un-encoded `outputs[0]` site would `TypeError` under Py3 but is gated on `flavor=="win"` (never reached on mobile). compile_commands feature is present. | Optional: re-apply the 2 sha256 lines to converge + fix the latent Win bug. | NEW. Build-time only; iOS-flavor patches intact. |
| `tools/v8_gypfiles/v8.gyp` | CLEAN | LOW | No conflict drop; only the v24.5.0→v24.15.0 base lag (V8_PLATFORM_SHARED export plumbing, cross-platform `-fvisibility=hidden`, AIX torque `-O1`). None is a security fix or alters the iOS/Android static-lib runtime. | Accept; the drift is the tree-wide base lag, not a v8.gyp resolution artifact. | **Refines F6**: the residual is the base-version lag (same as the whole tree), not a mobile-vs-upstream conflict. The 6 mobile hunks are correct. |
| `test/parallel/test-aborted-util.js`, `test-fs-lchmod.js`, `test-fs-open-flags.js`, `test-fs-watch.js` (parallel), `test-fs-watchfile.js`, `test/sequential/test-fs-watch.js`, `test-http-response-setheaders.js` | LOST_UPSTREAM / BROKEN_MOBILE | LOW | Assorted v18 reverts: lost `{ skip: !lazySpawn() }` idiom, `.then(mustCall())` rejection guards, the macOS libuv#4503 setTimeout flake workaround, `isMacOS` renames, and deliberately-neutered `globalThis.Headers` coverage. No iOS/Android runtime or security impact; several are also `.status`-SKIP'd on-device. | Low priority; rebase the small mobile delta onto v24 when convenient to restore desktop-CI coverage and reduce macOS flake. | Test-only; some in-file guards are dead because a `.status` SKIP wins on device. |

### Trivial / no-action flags

The remaining low-noise items need no code change and are recorded for parity:
`test/message/testcfg.py` (CLEAN; optional drop of the inert `--expose_wasm`
IgnoreLine), `test/parallel/parallel.status` & `test/sequential/sequential.status`
(CLEAN merges; only dead/stale mobile SKIP entries that are harmless no-ops),
and the carry-forward-onto-untouched-region clean cases
(`test-dgram-socket-buffer-size.js`, `test-fs-copyfile.js`, etc.).

### How 2b relates to F1–F11

- **`node.gyp` ↔ F1** — confirms the link break and pins it to v24.5.0 lists
  (unconditional ChaCha20-Poly1305 symbol + lost PQC crypto + 2 phantom paths).
- **`node.gypi` ↔ F2** — confirms the dropped dep wiring and adds the
  `HAVE_SQLITE`/`HAVE_AMARO`-disabled impact; gives a one-command fix
  (`git checkout heylogin/icu -- node.gypi`).
- **`configure.py` + `make.py` ↔ F4** — confirms the v24.5.0 base and adds the
  precise build-break (js2c.cc JSON contract, deleted cjs-module-lexer, 5-tuple).
- **`v8.gyp` ↔ F6** — refines: the residual is the tree-wide base lag, not a
  conflict-resolution loss; no security fix hidden in the gyp.
- **`toolchain.gypi` (CLEAN) ↔ F5** — confirms the feared stale-host-`xcode_settings`
  revert did NOT happen; the host SDKROOT now lives in `common.gypi` (`4e16296636`).
- **NEW, not in F1–F11** — F12 `fs.c`, F13 `trap-handler.h`, F14 `node_env_var.cc`
  (critical); F15 `node_metadata.h`, F16 `darwin.c`, F17 `uvwasi.c`, F18
  test-harness, F19 `tools/test.py` (high); F20 `test-process-versions.js`
  (critical, surfacing the F15 build blocker from the test side).

---

## 3. Remediation backlog (prioritized checklist)

Ordered by severity. Each item is actionable as a single commit on top of
`mobile/v24` (per the patch-stack model — never amend a merged commit).

### Critical — block the tag

- [ ] **F1 — Rework `node.gyp` source lists.** Re-derive `node.gyp` as a minimal
  mobile delta on the **v24.15.0** upstream `node.gyp`. Confirm `node_sources`
  has all 124 entries and `node_crypto_sources` all 45 (re-add `builtin_info.cc`,
  `node_diagnostics_channel.cc`, `node_sea_bin.cc`, `crypto_argon2.cc`,
  `crypto_chacha20_poly1305.cc`, `crypto_ml_dsa.cc`, `crypto_kem.cc`,
  `crypto_kmac.cc` + headers). *Done when:* Android arm64 links with no undefined
  `crypto_*`/`diagnostics_channel`/`sea`/`builtin_info` symbols.
- [ ] **F2 — Restore dropped `node.gypi` dependency wiring.** Re-add the
  `node_shared_uvwasi/ada/simdjson/sqlite/zstd==false → deps/*` stanzas (see B-1
  Part C, after the `node_shared_libuv` block). Confirm each `deps/<x>/<x>.gyp`
  exists. Keep the mobile `OS=="android" or OS=="ios" → NODE_MOBILE` define and
  the iOS CoreFoundation/Security stanza. *Done when:* `nm -D libnode.so` shows no
  `U ada::`, `U sqlite3_`, `U ZSTD_`, `U uvwasi_`. **Per-file 2b note:** simplest
  fix is `git checkout heylogin/icu -- node.gypi` (= v24 base + all 4 mobile
  patches), which also restores the `HAVE_SQLITE`/`HAVE_AMARO` feature defines
  (without them, node:sqlite + TypeScript/Amaro are silently compiled out).
- [ ] **F12 — Re-vendor `deps/uv/src/unix/fs.c` from v24.15.0.** The current file
  is libuv 1.44.2 sitting inside the v24 libuv tree — a hard compile break
  (`uv__req_register` called 2-arg against the v24 1-arg macro) plus ~975 lost
  upstream lines (EINTR-resilient `uv__fstat/lstat/stat` wrappers, `utime` inf/nan
  guards, ceph-fuse `EACCES` workaround). Re-base on `git show v24.15.0:…/fs.c`,
  re-apply ONLY the 2 mobile patches (Android `copy_file_range` guard; Darwin
  `!TARGET_OS_IPHONE` sendfile branch). *Done when:* `fs.c` compiles against the
  v24 `uv-common.h` and OURS-vs-v24 diff is just the 2 patches. Also sweep deps
  for other lone v18-reverted files.
- [ ] **F13 — Replace `deps/v8/.../trap-handler/trap-handler.h` with the v24
  header.** The v18 header drops `AssertThreadNotInWasm`/`SetLandingPad`/
  `RegisterV8Sandbox` that v24 `.cc` files call under `#if V8_ENABLE_WEBASSEMBLY`
  (default ON) → undeclared-identifier compile failures in `isolate.cc`,
  `heap-allocator-inl.h`, `runtime-wasm.cc`, `wasm-interpreter.cc`. Take
  `git show heylogin/icu:…/trap-handler.h` (v24 + the `#define
  V8_TRAP_HANDLER_SUPPORTED false` mobile patch); fix the trailing newline. Fix
  **F-2b `handler-inside-posix.cc`** in the same change (it calls the removed
  `TryFindLandingPad`/`v8_probe_memory_continuation` — restore the v24.15.0 file
  verbatim). *Done when:* the whole `trap-handler/` dir is consistently v24 and a
  WASM-enabled build compiles.
- [ ] **F14 — Re-port `src/node_env_var.cc` from v24.15.0.** The v18 file will not
  compile/link against the v24 tree (pure-virtual `KVStore` mismatch,
  `CreateEnvProxyTemplate` arity, V8 24 interceptor ABI) and silently disables the
  `--trace-env` family. Start from v24's file, re-apply ONLY the mobile `Clone`
  guard (change the missing-key early-return to `continue` for the Android
  LD_PRELOAD intent). *Done when:* `node_env_var.o` compiles, `CreateEnvProxyTemplate`
  links, and `grep TraceEnvVar node_env_var.cc` is non-empty.
- [ ] **F20 — Reconcile `src/node_metadata.h` and rebuild `test-process-versions.js`.**
  The layer-A revert left `node_metadata.h` at v18 while `.cc` is v24 → C++
  compile error (missing `pairs()`/`NODE_VERSIONS_KEY_COUNT`/members). This is the
  same blocker as **F15**; fix once (see F15). Then rebuild
  `test/parallel/test-process-versions.js` from v24: fix `expected_keys`, and
  replace the now-undefined `common.hasOpenSSL3` with
  `require('../common/crypto').hasOpenSSL3`. *Done when:* the four
  `node_metadata`-consuming TUs compile and the test passes against a v24 binary.

### High — close before ship

- [ ] **F3 — B-1 empirical gate + hardening.** (Part A) Build arm64, run
  `nm -gDU --defined-only out_android/arm64*/libnode.so | grep ' T napi_'` (expect
  >100) and `readelf --dyn-syms … | grep napi_get_cb_info`. If present, fix the
  embedder JNI load site (RTLD_GLOBAL / load order) — a *doc* bug, not a build bug.
  (Part B) Regardless, add the Android version-script (`tools/libnode.android.ver`
  exporting `napi_*`, `node_api_*`, `node_module_register`) + `-Wl,--version-script`
  in the shared-lib target. *Done when:* the `mobile-napi-smoke.yml` job is green.
- [ ] **F4 — Rework `configure.py` / `make.py`.** Re-derive both as mobile deltas
  on v24.15.0; restore the dropped `--shared-gtest*`, `--shared-hdr-histogram*`,
  `--shared-nbytes*` options; reconcile the 30 `make.py` hunks against v24.15.0
  so the generator base matches `ninja.py`.
- [ ] **F5 — B-2 real cross-compile.** In `ios_framework_prepare.sh` drop
  `arch -x86_64`, add `--ios-simulator`. In `common.gypi` gate the unconditional
  x64 `ARCHS` map to `_toolset=="target"` and add a `host_arch=="arm64" → ARCHS arm64`
  host override; mirror in `toolchain.gypi`. Optional explicit
  `-target x86_64-apple-ios-14.0-simulator`. Repin `build-mobile.yml` x64-sim row
  to `macos-15`/Xcode 16.4. *Done when:* `file out/Release/node_js2c` reports arm64
  and the x64-sim `.a` reports x86_64 on an Apple-Silicon runner.
- [ ] **F15 — Reconcile `src/node_metadata.h` with the v24 `.cc`.** Replace the
  v18 header with the v24.15.0 one and re-apply ONLY the mobile
  `NODE_VERSIONS_KEY_MOBILE(V)→V(mobile)` macro inside `NODE_VERSIONS_KEYS`. This
  restores `pairs()`, `NODE_VERSIONS_KEY_COUNT`, `<array>`/`<utility>`, the
  `amaro/merve/zstd/simdjson/sqlite/nbytes/ncrypto` keys, and the
  `NODE_OPENSSL_HAS_QUIC` guard. `.cc` needs no change. *Done when:*
  `node_metadata.cc` and its three consumers (`node_process_object.cc`,
  `node_report.cc`, `tracing/traced_value.cc`) compile and the key count matches
  the member count. (Same blocker reached from the test side in F20.)
- [ ] **F16 — Rebase `deps/uv/src/unix/darwin.c` onto v24.15.0.** Restore
  `uv_get_available_memory()` (a link error otherwise — referenced by `env.cc`,
  `node_process_methods.cc`, `node_report.cc`) and the `return 0` failure paths
  (the v18 file casts a negative `UV__ERR` into `uint64_t`). Re-apply ONLY the iOS
  cpu-speed guard; drop the obsolete `uv__get_cpu_speed` layer-A guard. *Done when:*
  the darwin/iOS build links with no undefined `uv_get_*_memory`.
- [ ] **F17 — Re-vendor `deps/uvwasi/src/uvwasi.c` from v24.15.0 and drop the
  Android patch.** Restores the WASI **sandbox** hardening (symlink target
  confinement + `EPERM` on absolute targets + NUL-truncation), the `readlink`
  length fix, the `pread/pwrite` `INT64_MAX` guard, `iovs_len==0` handling,
  `fstflags` mutual-exclusion, `fd_advise` `EBADF`-on-dir, and `ENOMEM` NULL
  checks. The Android `seekdir/telldir` guard is obsolete (v24 `fd_readdir` uses a
  portable `cur_cookie` loop) — remove it. *Done when:* `grep -n 'seekdir\|telldir'`
  returns nothing and OURS == v24.15.0 for this file.
- [ ] **F18 — Re-base `test/common/index.{js,mjs}` on the v24 harness.** Re-add
  `isAndroid`/`isIOS` to both the destructure and the export block; do NOT keep the
  v18 files. Restores `escapePOSIXShell` (48 tests), `isMacOS` (49),
  `hasSQLite`/`skipIfSQLiteMissing` (30 — required for the fork's new SQLite
  tests), `expectRequiredModule`, `parseTestMetadata`. *Done when:* the v24 suite
  loads without `TypeError`/named-export-not-found; note the `.js` 100755→100644
  mode flip.
- [ ] **F19 — Re-base `tools/test.py` on the v24 runner.** Discard the v18 file,
  start from v24, re-apply only the ~6-line `android/ios→env['system']` mapping in
  `Main()`. The v18 runner calls `self.GetCommand()` but the v24 testcfgs define
  `GetRunConfiguration()` → `AttributeError`, so the suite cannot run as assembled.
  *Done when:* `tools/test.py` drives a sample `test/parallel` slice against the v24
  testcfgs without `AttributeError`.

### Medium — should-fix; can trail the tag if time-boxed

- [ ] **F6 — Rework `v8.gyp`** onto the v24.15.0 base (structure-only; lists verified).
- [ ] **F7 — ICU:** drop the stray `icu` CI branch-filter hunk; verify small-icu
  links on iOS+Android against `icu_versions.json` and `libicudata.a`.
- [ ] **F8 — Merge `2f0b34d422`+`147768a676`** so the NDK env-var rename is atomic.
- [ ] **F9 — Reorder `62700f825f`** (`host_os=mac`) up beside `aff2710125`/`548f268e72`.
- [ ] **F10/F11 — Verify** the `histogram`/`nbytes` targets and the iOS
  `outputs_common`/pbxproj lists match the produced gyp lib set.
- [ ] **2b — `deps/ngtcp2/ngtcp2.gyp` source list.** Replace the stale v18
  `ngtcp2_sources` with the v24.15.0 list: drop the missing `ngtcp2_conversion.c`;
  add `ngtcp2_dcidtr.c`, `ngtcp2_settings.c`, `ngtcp2_transport_params.c` (present
  in the v24 vendored tree but never compiled). Fixes a missing-file build ref +
  never-built QUIC transport-params/settings modules.
- [ ] **2b — Restore v24 test coverage** in `test-fs-promises.js` (heaviest loss:
  `throwIfNoEntry:false`, buffer-`TypeError`, ~9 `mustCall` + rejection guards),
  `test-assert-deep.js` (`assert.partialDeepStrictEqual` + #61386), and
  `test-fs-mkdir.js` (`toNamespacedPath` oracle + ENOENT `mustCall`). Rebase the
  small mobile delta onto v24 instead of keeping the v18 files. Test-only.

### Low / cleanup — converge with upstream (no iOS/Android runtime or security impact)

- [ ] **2b — `common.gypi` pointer-compression macro.** Replace the obsolete
  `V8_COMPRESS_POINTERS_IN_ISOLATE_CAGE` branch with the v24
  `..._IN_MULTIPLE_CAGES` form (matches `features.gypi`/`v8/BUILD.gn`). Only
  reachable in an unsupported pc=1/shared_cage=0 config; fix for parity.
- [ ] **2b — `push_registers_asm.cc`** → adopt the `heylogin/icu` v24-rebased blob
  (typo fix, `_WIN64` `#error`, ELF `.size` directive, single mobile guard, trailing
  newline). Build-metadata only.
- [ ] **2b — `make.py` / `ninja.py` gyp-next lag.** Optional: cherry-pick the
  `sha1→sha256`/`md5→sha256` hashlib lines + `openharmony` flavor; reflow formatter
  churn. (Corroborates F4; zero shipped-artifact impact.)
- [ ] **2b — Low-priority test files** (`test-aborted-util.js`, `test-fs-lchmod.js`,
  `test-fs-open-flags.js`, `test-fs-watch.js` ×2, `test-fs-watchfile.js`,
  `test-http-response-setheaders.js`): rebase the small mobile delta onto v24 when
  convenient to restore desktop-CI coverage / reduce macOS flake. Several are
  already `.status`-SKIP'd on-device.

### Housekeeping — patch-stack hygiene (Phase 1, no functional risk)

- [ ] **Merge** SQLite disable (`40f5bde367`) ↔ enable (`1f8169254c`).
- [ ] **Merge** NDK `r26d` (`e3ff0efc74`) ↔ `r27d` (`690804819f`) — net r27d.
- [ ] **Merge** x64-sim runner churn: `851f731354` (macos-15) → `c0c0c00d05`
  (macos-15-large) → `2a56134eb2` (macos-13) into one final choice (see F5).
- [ ] **Squash** CI-only housekeeping (`8a058d9742` Ubuntu 24.04, `8342d51947`
  16 KB alignment).

---

## 4. Build/configure triage summary (26 layer-B commits)

The RELEASE_PLAN doc commit `2b4fe8b40a` is ignored (doc-only).

**KEEP** (clean, self-contained, parse/configure in isolation):
`dcd5d5fd11` (iOS min 14.0), `fe40c67328` (macOS dep target), `4fc62cfd04`
(clang+ninja iOS host/target split — `ninja.py` already at v24, sits on the right
base), `3b35767795` (x86_64 sim ARCHS), `4aa4456b87` (iOS cert trust fallback),
`44a2d49a55` (ninja iOS postbuild guard), `616778e727` (iOS framework links),
`96a8c80480` (disable trap handler), `548f268e72` (os checks — coupled to F6),
`4e16296636` (host SDKROOT), `8342d51947` / `8a058d9742` (CI-only).

**REWORK** (carry stale hand-typed full files drifting from v24.15.0):
- `dbea9dee52` — **`node.gyp`** (F1, the most critical: real link break).
- `aff2710125` — **`v8.gyp`** (F6, mostly fine; re-derive on v24.15.0).
- `99d245010f` — **`configure.py` / `make.py`** (F4, dropped shared-lib options).
- `a938b63be7` — **icu-small** (F7, drop stray CI branch filter).

**REORDER** (producer/consumer split across commits):
- `2f0b34d422` (#5) ↔ `147768a676` (#8) — NDK env-var rename split (F8).
- `62700f825f` (#18) `host_os=mac` → move up beside #6/#7 (F9).

**MERGE** (flip-flop / churn to squash):
- SQLite `40f5bde367` → `1f8169254c`.
- NDK `e3ff0efc74` (r26d) → `690804819f` (r27d).
- x64-sim runner `851f731354` → `c0c0c00d05` → `2a56134eb2`.

**DROP:** none recommended (no commit superseded by an upstream fix).

Bottom line: `./configure --help` exits 0 at HEAD and default configure runs.
The dominant residual risk is the **`node.gyp` / `node.gypi` source-and-dependency
gap (build/link)**, not configure parsing.

---

## 5. Blocker fixes (concise)

### B-1 — NAPI symbols on Android (confidence: medium)

The stated cause is **refuted** — `napi_*` should already be in `.dynsym`
(default visibility on the decls, core not built hidden, `-rdynamic` on for
Android, no strip flags, LTO off, NAPI TUs are first-class members of
`libnode.so`). Three-part fix:

- **Part A (gate first):** build arm64 and run
  `nm -gDU --defined-only out_android/arm64*/libnode.so | grep ' T napi_'`.
  If present, the bug is at the embedder JNI load site — `dlopen` `libnode.so`
  with `RTLD_GLOBAL` (or load it before any addon). That is an embedder doc fix.
- **Part B (harden regardless):** add `tools/libnode.android.ver` exporting
  `napi_*`/`node_api_*`/`node_module_register` and wire
  `-Wl,--export-dynamic -Wl,--version-script=…` into the shared-lib target for
  `OS=="android" and node_shared=="true"`. Makes the export contract explicit and
  hides V8/internal symbols (size + correctness).
- **Part C (collateral, F2):** restore the dropped `node.gypi` dep-wiring stanzas.

### B-2 — iOS x86_64 simulator on Apple Silicon (confidence: medium)

Today's build "works" only because `arch -x86_64 make` collapses
`host==target==x64` (no real cross-compile), forcing the deprecated Intel
`macos-13` runner. The blocker for a true arm64-host build is an unconditional
`target_arch==x64 → ARCHS x86_64` map in `common.gypi:760-775` (and
`toolchain.gypi:495-501/543-548`) that clobbers the host toolset's ARCHS, so
`node_js2c` would build as x86_64 on an arm64 host. Fix:

- `ios_framework_prepare.sh`: drop `arch -x86_64`, add `--ios-simulator`, keep
  `--dest-cpu=x64 --cross-compiling` (now genuinely cross-compiling).
- `common.gypi`: gate the x64 ARCHS map to `_toolset=="target"`; add a
  `host_arch=="arm64" → ARCHS!['x86_64']/ARCHS['arm64']` host override.
- `toolchain.gypi`: mirror the host override (symmetric to the existing inverse
  fix at lines 601-614).
- Optional: explicit `-target x86_64-apple-ios-14.0-simulator` on the target toolset.
- `build-mobile.yml`: repin the x64-sim row from `macos-13` to `macos-15`/Xcode 16.4.
- *Validate:* `file out/Release/node_js2c` → arm64; x64-sim `.a` → x86_64.

---

## 6. New tooling & CI added

8 new files, 0 existing tracked files modified. Mapped to RELEASE_PLAN phases:

### Patch-management scripts (Phase 1 / Phase 7.4 — patches-only repo)

All read the base from `doc_mobile/upstream-base.txt` (first non-comment line =
`v24.15.0`), same parse as `validate-patch-stack.yml`. Documented in
[`PATCH_TOOLING.md`](./PATCH_TOOLING.md).

- `scripts/mobile/export-patches.sh [out_dir]` — `git format-patch base..HEAD
  --zero-commit --no-signature` into a numbered series + `series` manifest;
  clears stale patches first. (Verified: "Exported 32 patch(es) from v24.15.0..HEAD".)
- `scripts/mobile/apply-patches.sh <upstream_dir> [patches_dir]` — applies the
  series in order with `git am --3way --keep-cr --whitespace=nowarn`, stopping on
  first failure with recovery commands.
- `scripts/mobile/verify-patches.sh [patches_dir]` — the integrity proof: exports
  HEAD's series, applies it to a detached `v24.15.0` worktree, asserts the
  reconstructed tree `== HEAD^{tree}`. (Verified: exit 0, trees match.)

> Key bug found & fixed during verification: the user's `apply.whitespace=fix`
> git config silently stripped trailing whitespace and mutated the tree (9 files
> diverged). Forcing `--whitespace=nowarn` in `apply-patches.sh` makes the apply
> byte-exact regardless of caller config — `apply(export(HEAD)) == HEAD`.

### CI workflows (Phase 2 / Phase 4)

All reuse `build-mobile.yml` conventions (checkout fetch-depth 0, sccache, the
NDK r27d / SDK 24 / 16 KB-page env block, `permissions: contents: read`, the
python3.12 venv + setuptools distutils workaround where relevant). All YAML
validated with `yaml.safe_load`.

| File | RELEASE_PLAN phase | What it does |
|---|---|---|
| `.github/workflows/host-smoke.yml` | **P4.1** | Native ubuntu-24.04 build of the `node` target, then `node -e "console.log(process.versions)"` exit-0 smoke. Triggers on push to `mobile/**`,`claude/**` + PRs. ~5 min. |
| `.github/workflows/mobile-napi-smoke.yml` | **P4.2 / P3.1 (B-1)** | Builds Android arm64 `libnode.so` via `android_build.sh`, asserts `nm -gU` shows `T napi_get_cb_info`/`napi_create_string_utf8`/`napi_throw_error`, fails with `::error::` if missing. Cheaper proxy for a full dlopen addon test. PR paths `mobile/**` + dispatch. |
| `.github/workflows/ios-simulator-tests.yml` | **P4.3** | macos-15 / arm64-simulator. Builds the framework, boots an iPhone sim (dynamic devicetype+runtime), runs a bounded `test/parallel` slice (`-r 1,8`) via `node-ios-proxy.sh`, skips child_process/spawn/signal/fork/cluster (iOS sandbox). Nightly cron + `mobile-test` label + dispatch. |
| `.github/workflows/android-emulator-tests.yml` | **P4.4** | macos-13 + `reactivecircus/android-emulator-runner@v2`, API 24 x86_64. Builds x86_64 `libnode.so`, installs the testnode app via `prepare-android-test.sh`, runs a ~10-glob `parallel/*` subset via `--arch android` proxy. Nightly cron + `mobile-test` label + dispatch. |

**Known follow-ups in the CI files** (documented in-file): the iOS proxy/prepare
scripts and testnode pbxproj are hardcoded to `iphoneos`/`Release-iphoneos` and
drive installs via `ios-deploy` (a real-device tool) — a pure simulator runner
likely needs an `xcrun simctl install/launch` path to actually pass. The Android
testnode `app/build.gradle` is old (compileSdkVersion 26) and `assembleDebug` is
the most likely follow-up point. These are pre-existing config, wired as-is.

---

## 7. What this workflow did NOT verify

This was a static + reasoning audit. It did **not**:

- **Run any real cross-compile.** No Android NDK build and no Xcode/iOS build was
  executed. The `node.gyp`/`node.gypi`/`v8.gyp` link breakage (F1, F2, F6) and the
  per-file compile/link breaks (F12 `fs.c`, F13 `trap-handler.h`, F14
  `node_env_var.cc`, F15/F20 `node_metadata.h`, F16 `darwin.c`) are inferred from
  source/diff analysis against the v24 headers/siblings they sit beside, not
  observed at compile/link time. The Phase-2 build + `nm -gDU` / `nm -D` checks
  remain to be run on real artifacts.
- **Compile the v24 test suite.** The harness/runner breaks (F18
  `test/common/index.{js,mjs}`, F19 `tools/test.py`, F20 `test-process-versions.js`)
  are inferred from the v18-vs-v24 API surface (missing helpers; `GetCommand` vs
  `GetRunConfiguration`), not from a failed test run.
- **Empirically gate B-1.** No `nm -gDU` / `readelf --dyn-syms` was run on a
  produced `libnode.so`; the refutation of the NAPI cause is from reading
  headers/gyp, not from inspecting `.dynsym`. B-1 Part A must run before patching.
  Confidence: medium.
- **Empirically validate B-2.** No arm64-host x86_64-simulator build was attempted;
  the ARCHS-clobber diagnosis is from reading `common.gypi`/`toolchain.gypi`.
  Confidence: medium.
- **Run the new CI workflows on GitHub.** They are YAML-valid and convention-aligned
  but unexecuted; the iOS/Android emulator harnesses have the documented
  simulator-path / gradle follow-ups that will only surface on a real run.
- **Run device tests.** Phase 5 (real arm64 Android + iOS device, and a
  consumer-plugin end-to-end round-trip) is still required and is the highest-fidelity
  gate before tagging.
- **Confirm a clean per-commit patch stack.** The REORDER/MERGE items (F8, F9 +
  housekeeping) were identified by triage, not by running `validate-patch-stack.yml`
  per commit (Phase 1 P1.3).

---

*Generated for the v24.15.0 release-readiness review. Critical: 6 · High: 9
(after adversarial adjustment — B-1 cause refuted, configure-breakage downgraded,
`handler-inside-posix.cc` downgraded high→low). Of these, the per-file
conflict-resolution audit added 4 new critical (F12 `fs.c`, F13 `trap-handler.h`,
F14 `node_env_var.cc`, F20 `test-process-versions.js`/`node_metadata.h`) and 6 new
high (F15 `node_metadata.h`, F16 `darwin.c`, F17 `uvwasi.c`, F18 test-harness, F19
`tools/test.py`) beyond the original F1–F11 build/configure triage. 35 of 66
audited files were CLEAN.*
