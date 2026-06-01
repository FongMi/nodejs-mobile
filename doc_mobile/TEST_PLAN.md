# Test plan: validating nodejs-mobile v24 on real mobile runtimes

> **Ephemeral planning doc — delete before tagging a release.** This captures the
> pre-release test *strategy*; the permanent dev-facing guide is
> [`TESTING.md`](./TESTING.md). Remove this file once the test tiers have had a
> green CI run and the v24 work is merge-ready.

Last updated 2026-05-29. This is the **strategy** for proving the
`mobile/v24` patch stack actually runs on Android and iOS before we tag a
release. It complements two existing docs:

- [`TESTING.md`](./TESTING.md) — the **manual how-to** for running the
  upstream suite on a physical device (the janeasystems proxy harness).
- [`RELEASE_PLAN_v24.md`](./RELEASE_PLAN_v24.md) — Phase 4 (CI test infra)
  and Phase 5 (real-device smoke) are the schedule entries this plan fills in.

This document is the *what and why*; once a tier has had a green run, fold
its concrete invocation into `TESTING.md` and tick it off in the release plan.

---

## The problem this plan solves

A passing **host build** (`make node` on Linux/macOS) proves the C++
remediation compiles, links, and runs — but only against the *host* x86_64
binary. It says nothing about whether the cross-compiled **mobile ABI**
(`libnode.so` for Android arm64/arm/x86_64, `NodeMobile.xcframework` for iOS
arm64) actually **boots and executes JavaScript on the device runtime**.
That gap is exactly where the historically painful failures live:

- **B-1** (missing NAPI symbols on Android) is suspected to be a
  device-side load-order/`dlopen` issue — invisible to a host build and only
  approximated by the symbol-table grep in
  [`mobile-napi-smoke.yml`](../.github/workflows/mobile-napi-smoke.yml).
- **B-2** (iOS x86_64 simulator) is a toolchain/ABI problem that only a real
  simulator build surfaces.

So the test ladder below climbs from "compiles" toward "runs real code on a
real arm64 device", trading cost for fidelity at each rung.

---

## Current state (what PR #3 already ships)

| Workflow | Environment | What it proves | Trigger | Status |
|---|---|---|---|---|
| [`host-smoke.yml`](../.github/workflows/host-smoke.yml) | Linux, native | C++ patches compile/link/run; `node -e` works | every push/PR | ✅ should be green |
| [`mobile-napi-smoke.yml`](../.github/workflows/mobile-napi-smoke.yml) | Linux, cross | NAPI symbols exported from Android `libnode.so` (B-1 proxy) | PR | ✅ should be green |
| `smoke-android` / `smoke-ios` (jobs in [`build-mobile.yml`](../.github/workflows/build-mobile.yml)) | emulator x86_64 / simulator arm64 | the shipped artifact boots and runs JS on-device, then exits (Tier 1) | every push/PR (after build) | ✅ validated locally; pending first CI run |
| [`android-emulator-tests.yml`](../.github/workflows/android-emulator-tests.yml) | emulator x86_64 (ubuntu+KVM) | curated `test/parallel` subset via proxy (Tier 2) | nightly + `mobile-test` label | ✅ validated locally; pending first CI run |
| [`ios-simulator-tests.yml`](../.github/workflows/ios-simulator-tests.yml) | simulator arm64 (simctl) | curated `test/parallel` subset via proxy (Tier 2) | nightly + `mobile-test` label | ✅ validated locally; pending first CI run |
| [`validate-patch-stack.yml`](../.github/workflows/validate-patch-stack.yml) | Linux | every commit passes `./android-configure` | PR | ✅ |

### Gaps that block "ascertain it works on mobile before release"

1. ~~**No true on-device smoke test.**~~ **Closed** — Tier 1 below
   (`smoke-android` / `smoke-ios` in `build-mobile.yml`) now boots the
   emulator/simulator and runs JS against the shipped artifact. Validated
   locally on an arm64 Android emulator (API 29) and an iPhone 16 simulator
   (iOS 26.2): both printed `NODEJS_MOBILE_SMOKE_OK v24.15.0 …` and exited 0.

2. ~~**The iOS simulator Tier 2 workflow can't run as written.**~~ **Closed** —
   the simulator now has its own `simctl` path
   ([`prepare-ios-sim-tests.sh`](../tools/mobile-test/ios/prepare-ios-sim-tests.sh)
   + [`node-ios-sim-proxy.sh`](../tools/mobile-test/ios/node-ios-sim-proxy.sh)),
   separate from the physical-device `ios-deploy` path
   ([`prepare-ios-tests.sh`](../tools/mobile-test/ios/prepare-ios-tests.sh)).
   See Tier 2 below.

---

## How the on-device harness works (and why it constrains the device-farm tier)

The testnode harness runs the **real upstream `tools/test.py`** on the host,
but points its `node` executable at a **proxy shell script**
([android](../tools/mobile-test/android/node-android-proxy.sh) /
[ios](../tools/mobile-test/ios/node-ios-proxy.sh)). For *each test case* the
proxy:

1. Relaunches the testnode app on device — `adb am start -e nodeargs …`
   (Android) or `simctl launch` / `ios-deploy --args …` (iOS) — passing the
   test file path and a unique **per-launch token**.
2. The app runs that file in-process via `node_start()` /
   `startNodeWithArguments()`. When the embedded node returns, the native code
   writes the **real exit code** as a `PASS` / `FAIL` verdict to a per-launch
   file in the app's private sandbox (`<filesDir>/result-<token>.txt` on
   Android, `<Documents>/result-<token>.txt` on iOS). An `atexit` fallback
   writes `FAIL` if the process terminates abnormally before that.
3. The proxy reads that verdict file back — `adb run-as … cat` (Android) or
   `simctl get_app_container` (iOS) — and reports `PASS` / `FAIL` / no-verdict
   (timeout/crash) to `test.py`. The app's stdout/stderr is echoed separately
   for `test.py`'s `.out` comparison, but the **verdict never rides that
   stream**.

**Why a sandbox file, not a log marker.** The earlier design emitted a
`RESULT:<token>:PASS` marker on stdout and scraped it from `logcat` /
`simctl --console`. Those are shared, lossy streams: logcat rate-limits,
ring-buffer-evicts, and truncates at ~4 KB; `simctl --console` drops the whole
stream intermittently on loaded CI runners. A single dropped marker line became
an unrecoverable, silent **false FAIL** — unacceptable once Tier 2 is a release
gate. The private result file is durable and immune to all of that; the token
makes a stale file or a spawned grandchild impossible to mis-attribute.

**Verdict fidelity caveat (Option A).** `node_start` returns the true exit code
only when the event loop drains normally — which every curated test does. An
explicit `process.exit(n)` routes through `node::Exit` → libc `exit()`, never
unwinds to `node_start`, so the post-run write is skipped and only the `atexit`
`FAIL` fallback fires. For the gate this is the *conservative* verdict (no
curated test calls `process.exit()`), but it means a hypothetical
`process.exit(0)` test would be mis-scored as FAIL. Option D (below) removes
this caveat by reading the code from `SpinEventLoop`.

**Strengths:** runs the genuine upstream test files against the genuine
device runtime — high fidelity. **Cost:** one app relaunch per test case, so
it is slow (~3–4 min per platform for the curated subset on a warm device,
dominated by per-test app relaunch; much longer from cold including build).

**Why it does not port to BrowserStack:** App Automate takes an uploaded app
+ a test bundle; it does **not** hand you an interactive `adb` / `ios-deploy`
session to drive hundreds of host-orchestrated relaunches.
(`BrowserStackLocal` tunnels *network* traffic, not device control.) So
"run the existing proxy suite on BrowserStack" is a re-architecture, not a
config change — which shapes Tier 3 below.

---

## The four-tier ladder

| Tier | Name | Proves | Cost | Where |
|---|---|---|---|---|
| 0 | Host smoke | C++ patches build & run | seconds | Linux CI |
| 1 | **On-device smoke** | mobile binary boots & runs JS on the real ABI | ~1 app launch | emulator + simulator |
| 2 | **Curated upstream subset** | broad JS correctness on device | ~10–15 min | emulator + simulator |
| 3 | Real-device suite | arm64 ABI + NAPI + integration on physical hardware | minutes/device | BrowserStack |

### Tier 0 — Host smoke *(have it)*

Keep [`host-smoke.yml`](../.github/workflows/host-smoke.yml) on every push.
Cheapest catch for regressions in the shared `src/`/`lib/` patches before any
cross-compile runs. No change needed.

### Tier 1 — On-device smoke *(implemented; the "at minimum")*

Boot the emulator/simulator, run [`smoke.js`](../tools/mobile-test/smoke/smoke.js)
(`console.log('NODEJS_MOBILE_SMOKE_OK ' + process.version + …)`), assert the
marker shows up in the device output and the process exits 0. **One launch, no
`test.py`.** This is the gate that proves the mobile ABI binary starts and runs
JS — it must pass before Tier 2 is worth attempting.

It runs as two jobs in [`build-mobile.yml`](../.github/workflows/build-mobile.yml)
(`smoke-android`, `smoke-ios`) that `needs:` the combine jobs and download the
`nodejs-mobile-android` / `nodejs-mobile-ios` artifacts — so it smoke-tests the
**exact binary that would ship**, with no rebuild. Logic lives in committed,
locally-runnable scripts under
[`tools/mobile-test/smoke/`](../tools/mobile-test/smoke/).

- **Android — bare embedder, no Gradle.** A 6-line embedder
  ([`node_embedder.cpp`](../tools/mobile-test/smoke/node_embedder.cpp)) links
  `libnode.so` and calls `node::Start`; it is `adb push`ed with the lib +
  `libc++_shared.so` and run directly via `adb shell`, capturing stdout. This
  deliberately bypasses the testnode app: its Gradle stack (6.7.1 / AGP 4.2 /
  `jcenter()`) predates JDK 17 and won't build on a current runner — that
  modernization is a **Tier 2 prerequisite**, not a smoke dependency. Runs on
  `ubuntu` + KVM (1× billing). *Tradeoff:* exercises `libnode` directly, not
  the JNI/app path — that integration is covered by Tier 2/3.
- **iOS — testnode app via `simctl`.** The existing testnode app builds cleanly
  for the simulator (plain xcodeproj, no Gradle). `main.m` already forwards any
  argv after the executable to node, so `node -e <expr>` works with no app
  change; we `xcrun simctl install` + `launch --console` and grep stdout.

*Acceptance (met locally):* both platforms print
`NODEJS_MOBILE_SMOKE_OK v24.15.0 <platform> arm64` and exit 0. Pending: first
green run on CI (x86_64 emulator for Android; newest available simulator for iOS).

### Tier 2 — Curated upstream subset *(the "intermediate"; implemented)*

The sweet spot between smoke and the full suite: an **explicit,
version-controlled allow-list**
([`tier2-parallel-tests.txt`](../tools/mobile-test/tier2-parallel-tests.txt))
of single-process `test/parallel` cases, run through the proxy harness on the
emulator + simulator. The ~150 entries were harvested by running pure-JS test
categories on both a real arm64 Android emulator (API 29) and an iPhone 16
simulator (iOS 26.2) and keeping the intersection of passes; expand it by
re-running that harvest (see "Expanding the curated list"). The list is shared
by both workflows so a regression fails the *same* named test every time (it
replaces the old non-deterministic `-r 1,8` iOS slice).

`test-timers-*` is deliberately excluded: those tests are timing-sensitive and
flake under emulation (they pass in isolation but flake in large batches).
More generally, the proxy relaunches the app once per test, so it is sensitive
to device load — prefer modest batches on a fresh device. Timing tests belong in
the nightly full-suite run with flaky-test retries, not in this deterministic
allow-list.

What this tier required (done in this branch):

- **Modernized the Android testnode app** so it builds on a current toolchain:
  Gradle 6.7.1 → 8.7, AGP 4.2 → 8.5.2, `compileSdk` 26 → 34, plugins/repos
  DSL (no `jcenter()`), and **zero external dependencies** (the layout dropped
  the support-library `ConstraintLayout` for a framework `FrameLayout`). The
  source moved to the `nodejsmobile.test.testnode` package its JNI binding
  requires. This was the Tier 1 "prerequisite" the bare-embedder smoke dodged.
- **Fixed the proxy harness for modern Android.** The old wait streamed
  `logcat` and killed it once it saw the marker; that broke on Android 10+
  (toybox `ps` columns + SELinux "kill: Operation not permitted"). Both
  [`node-android-proxy.sh`](../tools/mobile-test/android/node-android-proxy.sh)
  and [`prepare-android-test.sh`](../tools/mobile-test/android/prepare-android-test.sh)
  now poll the log buffer (dump-and-grep), with no device-side kill.
- **Added the iOS simulator path** (Gap 2):
  [`prepare-ios-sim-tests.sh`](../tools/mobile-test/ios/prepare-ios-sim-tests.sh)
  + [`node-ios-sim-proxy.sh`](../tools/mobile-test/ios/node-ios-sim-proxy.sh)
  drive the app with `xcrun simctl`. `simctl launch` doesn't return the app's
  exit code, so the app writes the verdict to a sandbox file the proxy reads
  (see "How the on-device harness works" above). `main.m` was also fixed to
  rewrite test paths embedded in flags (e.g. `--test-reporter=./test/...`) via
  substring substitution, matching the Android harness.
- **Replaced the log-scraped marker with a sandbox verdict file** on both
  platforms (the reliability fix that makes Tier 2 gateable): native writes the
  real exit code to `result-<token>.txt`; the proxies read it via `run-as` /
  `get_app_container`. The `main-test.js` `-r` shim and all `RESULT:` marker
  plumbing were removed.
- **A `test.py` config fix:** the v24 `sea` suite resolves `out/Release/node`
  at config time; with no host binary that crashes the run. The Android prepare
  symlinks the proxy there (the iOS path uses `--shell`, which sidesteps it).

**Skip policy — what cannot pass on mobile by design:** the upstream-native
`[$system==android]` / `[$system==ios]` sections in `test/*/*.status` already
exclude `child_process` / `cluster` / `fork` / `signal` / OpenSSL-CLI / FIPS /
parent-dir cases. `--arch android` / `--arch ios` activate them. Further
cases are kept out of the curated list:
`parallel/test-os` (`os.homedir()` → `uv_os_homedir` ENOENT: the app sandbox has
no HOME, both platforms); `parallel/test-assert` (one sub-check expects the
JIT `+ actual - expected` diff message, but V8 **jitless** emits the short
`x !== y` form — iOS must run jitless per Apple's no-JIT rule, and Android
`--jitless` reproduces the same failure; cosmetic, not a libnode bug); and three
tests that spawn a **child node process via `process.execPath`**
(`test-buffer-constructor-node-modules`, `test-url-parse-deprecation`,
`test-url-parse-invalid-input`). The reliable verdict exposed these as
*platform-asymmetric*: on the iOS simulator `process.execPath` is the testnode
binary (node-capable) and `posix_spawn` is permitted, so the child runs node and
the test passes; on Android `process.execPath` is `app_process64` (not node), so
the child `SIGABRT`s and the test fails. A both-platforms gate can only hold the
intersection, so they are excluded (they were latent false-passes under the old
lossy capture). nodejs-mobile is a single embedded process — spawning a node
child is not a supported use case on either real device.

*Acceptance (met locally):* the curated list passes on emulator + simulator;
pending the first nightly/labelled CI run.

### Tier 3 — Real devices via BrowserStack *(the ideal; biggest lift)*

Emulators/simulators don't exercise the **arm64 device ABI** or the real
`dlopen`/NAPI load path — i.e. the exact surface where B-1 lives. Real
hardware is the only place that confidence comes from.

Because the relaunch-proxy doesn't fit a device farm (above), **flip the
model**: build a **self-driven test-runner app** that, on launch, runs an
embedded batch of tests in-process and surfaces a single
`ALL_PASSED` / `FAILED:<name>` marker (on-screen label and/or a results
file). Then a **Maestro flow** (App Automate supports Maestro — see the
`browserstack-app-automate-maestro` tooling) launches it on a few
representative arm64 devices and asserts the marker.

**Start small, where the value is highest:**

1. Smoke (Tier 1's check) on 2–3 real arm64 devices — newest + an Android
   16 KB-page device (B-7) + an iOS 17 device.
2. **Load one real NAPI addon** (`@nodejs-mobile/sqlite3`, named in
   [`UPGRADE_BLOCKERS_v24.md`](./UPGRADE_BLOCKERS_v24.md) as a small
   reproducer) and call into it. *This is the actual B-1 check* — the thing
   the symbol grep and emulator can only approximate.

Then optionally grow the embedded batch toward the Tier 2 list. Maps to
release plan **P5.1–P5.3**; needs BrowserStack credentials (or Firebase Test
Lab as an alternative farm).

---

## Next cycle: Option D — in-process multi-Environment engine

Option A (above) is the **chosen v24 gate engine**: one OS process per test
file, real exit code via a sandbox verdict file. It is the most faithful gate
(it re-exercises startup and native load 150× and isolates crashes), at the cost
of ~2 s/test relaunch latency and the `process.exit()` caveat noted above.

**Option D** is the planned next-cycle engine, kept as a deliberate follow-up
rather than a v24 blocker. It uses the Node v24 **embedder API** — already
exported from the mobile `libnode` (`CommonEnvironmentSetup`,
`CreateEnvironment`, `LoadEnvironment`, `SpinEventLoop`, `FreeEnvironment`,
`InitializeOncePerProcess`, `NewIsolate`) — to run each test in a fresh
`Environment` inside one long-lived process. `SpinEventLoop(env).FromMaybe(1)`
returns the **true** in-process exit code (fixing the `process.exit()` caveat),
and dropping the per-test relaunch removes most of the wall-clock cost.
[`test/embedding/embedtest.cc`](../test/embedding/embedtest.cc) is the template.

The trap Option D must avoid: a **persistent shared V8 isolate masks exactly the
startup / native-init / global-state bugs a mobile gate exists to catch**. So
the design constraints are non-negotiable:

- **`NewIsolate` per test** (not a reused isolate) + `SetProcessExitHandler` →
  `node::Stop` so one test's `process.exit()` can't tear down the runner.
- **Flag-bucket the launches.** ~7 curated tests need process-global V8 flags
  that can't change after V8 init (`--allow-natives-syntax` ×4, `--expose-gc`
  ×2, `--zero-fill-buffers` ×1). Group tests by required flags; one process per
  bucket, re-init V8 between buckets.
- **Crash recovery / mid-list restart:** a hard crash takes down the shared
  process, so the runner must detect it, record FAIL for the in-flight test, and
  resume the remainder in a fresh process.

Net: Option D is the better long-term *engine*, but only with isolate-per-test +
flag buckets + crash recovery does it retain Option A's fidelity. Adopt it once
those are in place; until then Option A is the gate.

---

## Cost notes

- **Android emulator now on ubuntu + KVM (done).** It previously targeted
  `macos-13` (billed 10×, and the Intel image is on GitHub's deprecation
  path); `android-emulator-tests.yml` now runs `reactivecircus/android-emulator-runner`
  on `ubuntu-24.04` with KVM at **1× billing** — cheaper and faster.
- **Trigger discipline stays.** Tier 0/1 cheap → run on push/PR. Tier 2
  heavy → nightly cron + `mobile-test` label + manual dispatch (as the
  current workflows do). Tier 3 paid devices → nightly and/or pre-release
  gate only.

---

## Recommended rollout order

1. ~~**Tier 1 on-device smoke**~~ **Done** — `smoke-android` / `smoke-ios` in
   `build-mobile.yml`, validated locally on a real emulator + simulator.
   Remaining: confirm the first green CI run.
2. ~~**Fix Tier 2** to green~~ **Done** — modernized Android app, poll-based
   Android proxy, iOS `simctl` path, ~150-case cross-validated curated
   allow-list. Remaining: confirm the first nightly/labelled CI run on fresh
   runners, then fold the exact invocation into
   [`TESTING.md`](./TESTING.md), and triage `test-os` / `test-assert`.
3. **Tier 3 design spike**: self-driven runner app + Maestro flow + one NAPI
   addon load, on a handful of BrowserStack devices. Gate the release on its
   first green run (release plan Phase 5).

Release should not be tagged until Tier 1 is green on both platforms, the
curated Tier 2 subset is green on CI for both platforms (Android emulator and
iOS simulator), and the NAPI-addon load (Tier 3 step 2, or a real-device
equivalent) has passed at least once — that trio is the minimum credible "it
works on mobile" evidence.

Because Tier 2 is now a release gate, its result must be trustworthy: the
per-test verdict is captured over a reliable channel (a result file in the app
sandbox), not scraped from a shared, rate-limited log stream (logcat /
`simctl --console`) where a single dropped line silently becomes a spurious
failure. See [`TESTING.md`](./TESTING.md) for the harness details.

---

## Open decisions

- **Device farm:** BrowserStack (assumed, tooling exists) vs Firebase Test
  Lab (Android-only, cheaper) vs a self-hosted device. Affects Tier 3 shape.
- **Self-driven runner vs keep the proxy:** the proxy is reused for Tier 1/2
  on emulator/simulator; Tier 3 needs the self-driven app. Decide whether the
  two harnesses share the embedded batch list or diverge.
- **How big is the Tier 2 list:** start ~50 tests (~10 min) and grow, or aim
  for "all single-process `test/parallel`" and accept a longer nightly.
