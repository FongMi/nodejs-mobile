# CLAUDE.md — agent guide for nodejs-mobile

This repo is **upstream Node.js plus a stack of mobile patches**. This file
orients an agent (or new maintainer) and links the canonical docs in
[`doc_mobile/`](./doc_mobile/README.md) for detail — read the linked doc before
doing the task, and **don't duplicate their content back into here**.

## Repo model (read first)
- A **patch stack** rebased on a clean `nodejs/node` release tag — not a merge of
  upstream. Current line: **`mobile/v24`** (Node 24). `main` is the legacy Node
  18 line. New majors get a fresh sibling branch (`mobile/v26`), not a descendant.
- History is **linear**: land changes by rebase, never a merge-commit. Force-push
  only a rebase/PR branch, never `mobile/v24` or `main`.
- Mobile changes are small, subsystem-prefixed commits (`android:` / `ios:` in
  the subject for platform-specific ones).
- → [`doc_mobile/MAINTENANCE_MODEL.md`](./doc_mobile/MAINTENANCE_MODEL.md)

## Build
- **Android:** `./tools/android_build.sh <ndk-path> <sdk> [arch]`. **Build on
  Linux** — a macOS host cannot complete the Android cross-build (node's gyp
  links the *host* build-tools with GNU `ar`/`ld` options Apple's toolchain
  rejects; this is upstream behavior, not a mobile patch).
- **iOS:** `./tools/ios_framework_prepare.sh [arm64|arm64-simulator]`. Builds on
  macOS (Xcode); produces `NodeMobile.xcframework`.
- **Python 3.12 is required** for both. Newer Python (3.13/3.14) breaks V8's gyp
  code generation; CI pins 3.12 in a venv with `setuptools`.
- **Flavors:** default `full`; `NODEJS_MOBILE_FLAVOR=lite` builds the
  comapeo-tuned smaller binary.
- → [`doc_mobile/BUILDING.md`](./doc_mobile/BUILDING.md), and the
  [lite variant](./doc_mobile/README.md#the-lite-variant)

## Test — the release gate
- The gate is a curated `test/parallel` subset
  (`tools/mobile-test/tier2-parallel-tests.txt`) run through the proxy harness on
  an Android emulator + an iOS simulator, plus a Tier-1 boot smoke and a NAPI
  symbol smoke. A test passes when the app writes `PASS` to its per-launch
  sandbox verdict file (not scraped from logs).
- Caveats baked into the curated list: tests that **spawn a child node process**
  (`process.execPath`) can't pass on Android and are excluded; a test that calls
  **`process.exit()`** is mis-scored by the current per-process harness (it exits
  via libc `exit()` before the verdict is written) — none are in the curated list.
- → [`doc_mobile/TEST_PLAN.md`](./doc_mobile/TEST_PLAN.md) (strategy + gate),
  [`doc_mobile/TESTING.md`](./doc_mobile/TESTING.md) (manual how-to)

## Playbook — fix a bug / make a change
1. Branch from `mobile/v24`.
2. One focused, subsystem-prefixed commit (touch upstream files only when
   necessary; prefer additive mobile files).
3. Build (Android on Linux) and run the relevant curated tests.
4. Open a PR to `mobile/v24`; keep history linear (rebase, no merge-commit).

## Playbook — upgrade to a newer upstream Node
Rebase the stack onto the new release tag, resolve conflicts patch-by-patch, then
re-validate the full gate. A new major is a fresh sibling branch + cherry-pick.
→ [`doc_mobile/UPGRADING.md`](./doc_mobile/UPGRADING.md)

## Release
**Never tag or publish a release by hand.** Dispatch the `prepare-release`
workflow; the guarded automation opens a version-bump PR, requires the test gate
green, and tags + publishes behind a human approval.
→ [`doc_mobile/RELEASING.md`](./doc_mobile/RELEASING.md)

## Gotchas / do-not
- **WASI symlink fixtures:** the mobile test-asset prepare/copy scripts
  (`prepare-android-test.sh`, the iOS testnode asset copy) delete
  `test/fixtures/wasi/subdir/{input_link,outside}.txt` (symlinks) from the
  working tree. Restore them (`git checkout -- test/fixtures/wasi/subdir/`)
  before committing — otherwise they leak into a commit as spurious deletions.
- **Stage explicitly:** use `git add <paths>`, never `git add -A` — build outputs
  (`out_*`) and local planning docs must not be swept into commits.
- **Don't push to the upstream repo or create a tag/release without maintainer
  authorization.** Work on a branch / fork and open a PR.
