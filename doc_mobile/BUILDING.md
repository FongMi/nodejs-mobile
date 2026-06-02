# Build Instructions

nodejs-mobile builds one native library per target, and **each target builds on
one host OS only:**

| Target  | Output                       | Build host           |
|---------|------------------------------|----------------------|
| Android | `libnode.so` (per ABI)       | **Linux only**       |
| iOS     | `NodeMobile.xcframework`     | **macOS only** (Xcode) |

> **Why Android can't be built on macOS.** node's bundled gyp archives static
> libs as GNU thin archives (`ar crsT … @file-list` response files) and links
> the cross-build's *host* build-tools (e.g. `node_js2c`) with the ELF-linker
> option `-Wl,--start-group`. Apple's `/usr/bin/ar` and `ld64` support neither,
> so a macOS host fails — first at the archiver (`ar: @…ar-file-list: No such
> file or directory`), and even with `AR_host` pointed at the NDK's `llvm-ar`,
> then at the host link (`ld: unknown options: --start-group`). `--start-group`
> is ELF-only and no Mach-O linker implements it, so there is no drop-in macOS
> fix. This is a property of node's build system, not the mobile patches, and it
> affects `full` and `lite` identically. Build Android on Linux (CI uses
> `ubuntu-24.04`).

## Python (both targets)

Both build paths run gyp / V8 code generation under Python. Use a **Python 3.13**
(3.12 also works) venv with `setuptools` installed — gyp-next declares
`setuptools` as a build-time dependency and a bare venv does not bundle it. CI
does the same:

```sh
python3.13 -m venv .venv
. .venv/bin/activate
pip install setuptools
```

---

## Android — build on Linux

### Prerequisites

```sh
sudo apt-get install -y build-essential git gcc-multilib g++-multilib
```

Install Android NDK **r27d** (`27.3.13750724`) via the SDK Manager (the
`ubuntu-24.04` GitHub runner already ships an NDK 27 at `$ANDROID_NDK_LATEST_HOME`):

```sh
sdkmanager "ndk;27.3.13750724"
```

### 1) Clone and check out `mobile/v24`

`main` is the legacy Node 18 line; current Node 24 work lives on `mobile/v24`
(see [`MAINTENANCE_MODEL.md`](./MAINTENANCE_MODEL.md)).

```sh
git clone https://github.com/nodejs-mobile/nodejs-mobile
cd nodejs-mobile
git checkout mobile/v24
```

### 2) Build with the helper script

```sh
./tools/android_build.sh <ndk-path> <sdk-version> [arch]
```

- `<ndk-path>` — the installed NDK, e.g. `~/Android/Sdk/ndk/27.3.13750724`
- `<sdk-version>` — minimum Android SDK version as a number, e.g. `24`
- `[arch]` — `arm`, `arm64`, or `x86_64`; omit to build all three.

```sh
./tools/android_build.sh ~/Android/Sdk/ndk/27.3.13750724 24
```

Output: `out_android/<abi>/libnode.so` for each ABI (`armeabi-v7a`, `arm64-v8a`,
`x86_64`).

To configure and build a single architecture manually instead:

```sh
./android-configure <ndk-path> <sdk-version> <arch>
make
# -> out/Release/lib.target/libnode.so
```

---

## iOS — build on macOS

### Prerequisites

Xcode with the Command Line Tools (`xcode-select --install`, which also installs
`git`).

### 1) Clone and check out `mobile/v24`

```sh
git clone https://github.com/nodejs-mobile/nodejs-mobile
cd nodejs-mobile
git checkout mobile/v24
```

### 2) Build with the helper script

```sh
./tools/ios_framework_prepare.sh [arm64|arm64-simulator]
```

With no argument it builds **both** arm64 slices — device (`iphoneos`) and
simulator (`iphonesimulator`) — and combines them. The script configures gyp to
build Node.js and its dependencies as static libraries with V8 set to run
jitless (Apple's no-JIT rule), staging the libs through
`tools/ios-framework/bin/` into the `tools/ios-framework/NodeMobile.xcodeproj`
project. Pass `arm64` or `arm64-simulator` to build only one slice during
development. (x86_64 / Intel-simulator support was dropped for v24: Intel Macs
are EOL and Apple Silicon runs the arm64 simulator natively.)

Output: **`out_ios/NodeMobile.xcframework`** (device + simulator arm64 slices).

---

## Lite flavor (both targets)

To build the size-reduced binary instead of the default, set
`NODEJS_MOBILE_FLAVOR=lite` (see the [lite variant](./README.md#the-lite-variant)).
