# Testing nodejs-mobile

How the mobile test harness works, what CI runs, and how to run the tests
locally on an Android emulator, an iOS simulator, or a physical device.

## How a test PASSes

The harness runs the **real upstream `tools/test.py`** on the host, but points
its `node` executable at a per-platform **proxy script**. For each test case the
proxy relaunches the testnode app on the device (`am start` on Android, `xcrun
simctl launch` on an iOS simulator, `ios-deploy` on an iOS device), passing the
test-file path and a unique per-launch token. The app runs the file in-process
via the embedded `node_start()`; when node returns, native code writes a `PASS`
/ `FAIL` verdict (the real exit code) to a per-launch file in the app's private
sandbox (`result-<token>.txt`). The proxy reads that file back and reports to
`test.py`.

The verdict rides a **durable sandbox file, never the log stream** — `logcat`
and `simctl --console` are shared, lossy streams that truncate and ring-buffer-
evict, which silently turned dropped lines into false failures under the old
log-scraping design. The token prevents a stale file or a spawned grandchild
from being mis-attributed.

**Caveat:** the post-run verdict is written only when the event loop drains
normally. A test that calls `process.exit()` routes through libc `exit()` before
node unwinds, so only an `atexit` `FAIL` fallback fires — such a test would be
mis-scored. None of the curated tests call `process.exit()`.

## What CI runs

Every workflow that consumes a binary builds and tests **both flavors**
(`full` and `lite`).

| Workflow | Runner | Trigger | Proves |
|---|---|---|---|
| `host-smoke.yml` | ubuntu | push `mobile/**` | C++ patches compile; `node -e` runs on the host build |
| `validate-patch-stack.yml` | ubuntu | push `mobile/**` | every commit in the stack passes `./android-configure` (~1 min/commit) |
| `mobile-napi-smoke.yml` | ubuntu | PR | NAPI symbols present in the Android `libnode.so` `.dynsym` (cheap B-1 tripwire) |
| `build-mobile.yml` → `smoke-{android,ios}` | ubuntu+KVM / macos | push `mobile/**` | the exact shipping artifact boots and runs JS (Tier 1) — emulator / simulator |
| `android-emulator-tests.yml` | ubuntu+KVM | nightly · `mobile-test` label · dispatch | curated `test/parallel` subset + crc-native addon load, on an x86_64 emulator (Tier 2) |
| `ios-simulator-tests.yml` | macos | nightly · `mobile-test` label · dispatch | same curated subset + crc-native addon load, on an arm64 simulator (Tier 2) |

The Tier-2 workflows reuse the `libnode` artifact the `Build` workflow already
produced for the commit (via `gh run download`) — they do **not** rebuild. So
**`Build` must be green for the commit before** you add the `mobile-test` label
or dispatch a Tier-2 workflow.

### The curated subset

`tools/mobile-test/tier2-parallel-tests.txt` is the allow-list (~150 single-
process `test/parallel` cases) shared by both Tier-2 workflows, so a regression
fails the same named test on both platforms. The runner invocation is:

```sh
# Android emulator
grep -vE '^[[:space:]]*#|^[[:space:]]*$' tools/mobile-test/tier2-parallel-tests.txt \
  | xargs ./tools/test.py -j 1 --flaky-tests=skip --timeout=300 --arch android

# iOS simulator
grep -vE '^[[:space:]]*#|^[[:space:]]*$' tools/mobile-test/tier2-parallel-tests.txt \
  | xargs ./tools/test.py -j 1 --flaky-tests=skip --timeout=300 \
      --arch ios --shell=./tools/mobile-test/ios/node-ios-sim-proxy.sh
```

`-j 1` is required (the proxy relaunches the app once per test; parallel
relaunches on one device cause spurious timeouts). `--timeout=300` is larger
than the proxy's own ~120 s verdict poll so the proxy is the authoritative
deadline. Tests that can't run on mobile (`child_process`, `cluster`, `fork`,
signals, OpenSSL-CLI, …) are skipped via the upstream
`[$system==android]` / `[$system==ios]` sections of `test/*/*.status` — kept out
of the test bodies.

### The NAPI addon gate

After the curated subset, each Tier-2 workflow builds the **crc-native** N-API
addon (`tools/mobile-test/addon/`) against that build's library and loads it in
the testnode app — proving a real `.node` addon `dlopen`s and runs (the
"blocker B-1" check the symbol-grep smoke only approximates).

## Running tests locally

`tools/test.py` and the prepare scripts run on the host; the device/emulator
runs the app. A specific device/emulator can be targeted with `DEVICE_ID=<id>`
(`adb devices` / `ios-deploy --detect` / `xcrun simctl list` to find it).

> **WASI symlink side-effect.** The prepare scripts delete the dangling symlinks
> under `test/fixtures/wasi/subdir/` (Android asset packaging and iOS app
> install reject them). Restore them before committing:
> `git checkout -- test/fixtures/wasi/subdir/`.

### Android emulator (or device)

Requires a **Linux** host (Android can't cross-build on macOS — see
[BUILDING.md](./BUILDING.md)), NDK r27d, JDK 17, and `adb`.

```sh
./tools/android_build.sh "$ANDROID_NDK_HOME" 24 x86_64   # build libnode (x86_64 for an emulator)
./tools/mobile-test/android/prepare-android-test.sh      # build+install the app, copy test assets, drop the proxy
# then run the curated subset (command above), or a single test:
echo test/parallel/test-buffer-alloc.js | xargs ./tools/test.py -j 1 --arch android
```

### iOS simulator

Requires macOS + Xcode.

```sh
./tools/ios_framework_prepare.sh arm64-simulator              # build the simulator framework
./tools/mobile-test/ios/prepare-ios-sim-tests.sh              # build+install the app on a booted simulator, copy assets
echo test/parallel/test-buffer-alloc.js \
  | xargs ./tools/test.py -j 1 --arch ios --shell=./tools/mobile-test/ios/node-ios-sim-proxy.sh
```

### iOS physical device

Requires macOS + Xcode, an arm64 device with a valid development certificate,
and [`ios-deploy`](https://github.com/ios-control/ios-deploy) (`npm i -g ios-deploy`).
Sign `tools/mobile-test/ios/testnode/testnode.xcodeproj` in Xcode first (set a
Team; change the bundle id if it's taken).

```sh
./tools/ios_framework_prepare.sh arm64                        # build the device framework
./tools/mobile-test/ios/prepare-ios-tests.sh                  # build+install on the connected device, copy assets
echo test/parallel/test-buffer-alloc.js \
  | xargs ./tools/test.py -j 1 --arch ios --shell=./tools/mobile-test/ios/node-ios-proxy.sh
```

### Running the addon gate locally

```sh
# Android (after prepare-android-test.sh):
./tools/mobile-test/addon/build-android-addon.sh "$ANDROID_NDK_HOME" x86_64 out_android/x86_64 out_android/libnode/include/node ./crcnative.node
./tools/mobile-test/addon/run-android-addon.sh ./crcnative.node
# iOS simulator (after prepare-ios-sim-tests.sh): see tools/mobile-test/addon/build-ios-addon.sh + run-ios-addon.sh
```
