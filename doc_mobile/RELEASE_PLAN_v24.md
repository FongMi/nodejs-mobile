# Release plan: nodejs-mobile 24.15.0

Last updated 2026-05-29, after local build validation. This revision
replaces the original "merge first, fix later" sequencing with the
**validate-then-merge** order that the work actually followed, and folds in
what local Android/iOS/host builds taught us. See
[`V24_AUDIT_REPORT.md`](./V24_AUDIT_REPORT.md) for the per-finding detail
this plan references (F1–F20).

---

## Status at a glance

| Stage | State |
|---|---|
| Audit of the v18→v24 import | ✅ done — 6 critical + 9 high took-theirs reverts found |
| Remediation of the 15 broken files | ✅ committed (`d05f4fcbf3`) |
| **Host build** (`make node`) | ✅ **PASSED** — node 24.15.0 compiles, links, runs |
| **Android arm64** | ✅ target objects compile (NDK r27c); host-tool link is macOS-only-incompatible → validated on **CI/Linux** |
| **iOS arm64 (device)** | ✅ builds locally after the bitcode + c-ares fixes |
| 3 build-surfaced fixes (bitcode, c-ares, exec-bit) | ✅ done (committed with this revision) |
| Full CI matrix | ⏳ next |
| B-1 / B-2 blockers | B-1 downgraded (see Phase 3); B-2 pending |
| Device smoke + release eng | pending (release gated on maintainer sign-off) |

The single most important fact: **a passing host build proves the
remediation is real** (the dropped crypto sources, dep-link wiring, libuv
arity, trap-handler, node_env_var, node_metadata fixes all compile and
link). That de-risked the bulk of the audit's critical findings in one shot.

---

## Why the order changed: validate-then-merge

The original plan merged the three PRs into `mobile/v24` *first*, then fixed
problems. That would have merged a tree that does not build. The audit
showed the import was far more broken than "configure tidying" — entire
`src/*`/`deps/*` files had been reverted to v18 while their v24 headers and
callers stayed, producing compile/link breaks (F1, F2, F12–F20).

The corrected order — used here — is:

1. Audit the stacked PRs (don't merge yet).
2. Remediate on the PR branches.
3. Prove it builds (host + iOS locally; Android on CI).
4. **Then** merge a known-green stack into `mobile/v24`.

Everything below reflects that order.

---

## Phase 1 — Remediate the import (DONE)

The audit ([`V24_AUDIT_REPORT.md`](./V24_AUDIT_REPORT.md)) found the
conflict resolution in the layer-A/B import had systematically taken the
v18 side of 15 shared files. Each was re-derived as `v24.15.0` + the
minimal mobile delta and committed (`d05f4fcbf3`). Spot-verified examples:
libuv `fs.c` `uv__req_register` arity (F12), `node_env_var.cc` KVStore
`MaybeLocal` override (F14), restored `node.gyp` crypto sources +
`node.gypi` dep wiring (F1/F2), verbatim-v24 uvwasi sandbox hardening (F17).

*Acceptance (met):* the host build below.

---

## Phase 2 — Build-clean (host + iOS local; Android on CI)

Build-clean is split by environment. **Android cannot be built faithfully
on a macOS host** — the Linux/Android build path emits GNU `ar`
(`crsT @file-list`) and `ld --start-group` for the *host* toolset, which
Apple `ar`/`ld` reject. The project's CI cross-compiles Android on Linux,
where this is native. So:

- **P2.1 — Host build (DONE).** `./configure && make -j node` with a
  distutils-capable Python (3.11). Produced a working `node 24.15.0`
  (V8 13.6, OpenSSL 3.5.5). This is the fast, authoritative check that the
  C++ remediation compiles and links.

- **P2.2 — iOS arm64 device (DONE locally).** `--dest-os=ios` uses the
  Apple toolchain (libtool, via the `make.py` `flavor in (mac, ios)` mobile
  patch), so no GNU-tooling issue. Required two fixes (see Phase 3, found
  by building): bitcode removal and the c-ares iOS header guard.

- **P2.3 — Android arm/arm64/x86_64 → CI.** Target objects compile locally;
  the full shared `libnode.so` link is validated by `build-mobile.yml` on
  ubuntu-24.04. Do **not** spend time forcing this on macOS.

- **P2.4 — iOS arm64-sim + x86_64-sim + `.xcframework` → CI** (plus B-2).

*Acceptance:* `build-mobile.yml` green for all Android arches and all iOS
slices, and the combined `.xcframework` assembles.

---

## Phase 3 — Blockers and build-surfaced fixes

### Resolved by building locally (committed with this revision)

These were **not** in the audit's took-theirs set; only an actual compile
surfaced them, and each would also fail CI (not just local Xcode 26):

- **Exec-bit regression** — 8 mobile scripts (`android_build.sh`,
  `ios_framework_prepare.sh`, the `mobile-test` proxies, `gradlew`, …) lost
  their `+x` during the layer-A import (`git show > file` drops mode).
  Restored to `100755`. Would have broken every `./tools/*.sh` CI step.
- **Bitcode** (`common.gypi`) — the iOS-device branch forced
  `ENABLE_BITCODE: YES` + `-fembed-bitcode`. Bitcode was removed in
  Xcode 14; this errors on CI's Xcode 16.4 and on local Xcode 26. Removed.
- **c-ares `sys/random.h`** (`deps/cares/config/darwin/ares_config.h`) —
  c-ares uses the darwin config for iOS too, which set `HAVE_SYS_RANDOM_H`,
  but the iOS SDK has never shipped that header. Guarded the define to
  macOS via `TARGET_OS_IPHONE` (c-ares falls back to `arc4random_buf` on
  Apple). This likely explains earlier unresolved iOS build trouble.

### B-1 — NAPI symbols on Android (DOWNGRADED)

The audit **refuted** the original "hidden visibility / `--exclude-libs`"
cause: NAPI decls carry `visibility("default")`, core is not built hidden,
`-rdynamic` is on for Android, no strip, LTO off. The most plausible
explanation is an embedder `RTLD_GLOBAL`/load-order issue, not a libnode
export bug.

- **Gate empirically:** the committed `mobile-napi-smoke.yml` runs
  `nm -gDU libnode.so | grep ' T napi_'` on CI. If present (expected),
  B-1 is an embedder-documentation note, not a build fix.
- **Harden regardless (cheap):** add an Android `--version-script`
  exporting `napi_*`/`node_api_*`/`node_module_register`.

This is no longer the dominant schedule risk it was in the original plan.

### B-2 — iOS x86_64 simulator on Apple Silicon (PENDING)

Still real. The current x64-sim build only works via `arch -x86_64` on a
deprecated Intel `macos-13` runner. Land the true arm64-host →
x86_64-simulator cross-compile (gate the x64 `ARCHS` clobber to
`_toolset=="target"`, add a host override; drop `arch -x86_64`, add
`--ios-simulator`), then repin the runner to `macos-15`.

---

## Phase 4 — Test infrastructure (AUTHORED; needs first green run)

The CI harness was authored during the audit workflow and is committed in
PR #3 — this phase is now *validation*, not authoring:

- `host-smoke.yml` (P4.1) — native build + `node -e` smoke.
- `mobile-napi-smoke.yml` (P4.2) — the B-1 `nm -gDU` gate above.
- `ios-simulator-tests.yml` (P4.3) — bounded `test/parallel` slice on a
  booted simulator. **Known follow-up:** the iOS proxy/testnode project is
  hardcoded to `iphoneos`/`ios-deploy`; a pure-simulator path needs
  `xcrun simctl install/launch`.
- `android-emulator-tests.yml` (P4.4) — bounded subset via
  `reactivecircus/android-emulator-runner`. **Known follow-up:** the
  testnode `build.gradle` is old (compileSdk 26).
- `validate-patch-stack.yml` — per-commit `./android-configure`.

Trigger policy stays: smoke on push/PR; emulator/simulator suites on
nightly cron + `mobile-test` label (full suite per push is too costly).
Update [`TESTING.md`](./TESTING.md) once the harness has a green run.

---

## Phase 5 — Real-device smoke tests (needs maintainer / devices)

The highest-fidelity gate; **cannot be done in this environment** — needs
physical hardware (or a cloud device farm: Firebase Test Lab / BrowserStack).

- **P5.1** — `mobile-test` on a real arm64 Android device (Android 14+).
- **P5.2** — `mobile-test` on a real arm64 iOS device (iOS 17+).
- **P5.3** — End-to-end in `nodejs-mobile-react-native`: build the
  artifact, `require()` it, run a basic IPC round-trip + load one NAPI
  addon (the real B-1 check).

---

## Phase 0′ — Merge the validated stack

Now that the stack builds, merge it (this is the original "Phase 0", moved
after validation):

- PR #1 (strategy/CI/docs) → `mobile/v24`.
- PR #2 (layer A) → `mobile/v24`.
- PR #3 (layer B + remediation + build fixes + audit/tooling) → `mobile/v24`.

`mobile/v24` HEAD is then `v24.15.0` + the mobile patch stack, green on CI.

---

## Phase 6 — Release engineering (GATED on maintainer sign-off)

Tagging/publishing is irreversible and outward-facing — do not run without
explicit approval; stays on `gmaclennan/nodejs-mobile` per repo policy.

- **P6.1** — `src/node_mobile_version.h` → `24.15.0`; CHANGELOG entry
  (per [`RELEASING.md`](./RELEASING.md)).
- **P6.2** — `git tag nodejs-mobile-24.15.0`; CI builds the release
  artifacts (Android arm/arm64/x86_64 zip + iOS `.xcframework` zip +
  headers); publish GitHub Release.
- **P6.3** — Bump consumer plugins (`nodejs-mobile-react-native`,
  `nodejs-mobile-cordova`); announce.

---

## Phase 7 — Post-release hygiene (ongoing)

- **P7.1** — Address remaining **medium** audit findings F6–F11 (v8.gyp
  structure, ICU CI-filter leftover, histogram/nbytes wiring verify, iOS
  framework output-list verify).
- **P7.2** — Patch-stack hygiene: the commit reorder/merge items (F8 NDK
  env-var rename split; F9 `host_os=mac` ordering; SQLite/NDK/runner
  flip-flops). Run `validate-patch-stack.yml` per commit (P1.3 in the old
  plan) to confirm each commit is individually clean.
- **P7.3** — Split the layer-A squash into themed atomic commits (reduces
  next-rebase conflict surface).
- **P7.4** — Reconcile any v24.5→v24.15 upstream changes dropped in the
  conflict resolution beyond the 15 already fixed.
- **P7.5** — First real rebase exercise (`mobile/v24` → next v24 minor);
  record conflict count / time in [`UPGRADING.md`](./UPGRADING.md).
- **P7.6** — Optional: prototype the patches-only repo
  ([`PATCHES_ONLY_PROPOSAL.md`](./PATCHES_ONLY_PROPOSAL.md)) if P7.5 shows
  it would cut maintenance cost.

---

## Revised effort estimate

Phase 1 is done and the host + iOS builds pass, so the remaining path is
much shorter than the original 3–6 week estimate:

| Remaining work | Estimate |
|---|---|
| CI matrix green (Android + iOS slices) | 1–3 days (fix-and-rerun cycles) |
| B-1 empirical gate + (maybe) version-script | hours–1 day |
| B-2 iOS x64-sim cross-compile | 1–2 days |
| Device smoke (P5) — needs maintainer/hardware | 1–3 days |
| Release engineering (P6) — gated | ~1 day |
| **To v24.15.0 ship** | **~1–2 weeks**, dominated by CI cycles + device access |

The original plan's dominant uncertainty (B-1) has largely dissolved; the
new critical path is **CI matrix green → device smoke → release**.

---

## Immediate next step

Push the branch and run the full CI matrix (free for public repos, ~2h).
It is the authoritative check for Android (all arches) and the iOS
simulator slices that can't be built faithfully on this host. Triage red,
fix, re-push sparingly.
