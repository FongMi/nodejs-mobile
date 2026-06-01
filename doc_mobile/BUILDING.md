# Build Instructions

## Prerequisites to build the Android library on Linux Ubuntu/Debian:

### Basic build tools:
```sh
sudo apt-get install -y build-essential git python gcc-multilib g++-multilib
```

### Install Android NDK r27 for Linux:

Use the Android SDK Manager or Android Studio to install NDK version 27:

```sh
sdkmanager "ndk;27.2.12479018"
```

## Prerequisites to build the Android library on macOS:

### Git:

Run `git` in a terminal window, it will show a prompt to install it if not already present.
As an alternative, installing one of these will install `git`:
* Xcode, with the Command Line Tools.
* [Homebrew](https://brew.sh/)
* [Git-SCM](https://git-scm.com/download/mac)

### Install Android NDK r27 for macOS:

Use the Android SDK Manager or Android Studio to install NDK version 27:

```sh
sdkmanager "ndk;27.2.12479018"
```

## Building the Android library on Linux or macOS:

> **Build environment (important):**
> - **Python 3.12** is required. Newer Python (3.13/3.14) breaks the V8 gyp code
>   generation; CI pins 3.12 in a venv with `setuptools` installed. Do the same
>   locally: `python3.12 -m venv .venv && . .venv/bin/activate && pip install setuptools`.
> - **Build Android on Linux** (CI uses `ubuntu-24.04`). node's bundled gyp
>   archives static libs as GNU thin archives (`ar crsT … @file-list` response
>   files) and links the cross-build's *host* build-tools (e.g. `node_js2c`) with
>   the ELF-linker option `-Wl,--start-group`. Apple's `/usr/bin/ar` and `ld64`
>   support neither, so a macOS host fails — first at the archiver
>   (`ar: @…ar-file-list: No such file or directory`), and even with `AR_host`
>   pointed at the NDK's `llvm-ar`, then at the host link
>   (`ld: unknown options: --start-group`). `--start-group` is ELF-only and no
>   Mach-O linker implements it, so there is no drop-in macOS fix; build in a
>   Linux environment/container (this affects full and lite identically — it is a
>   property of node's build system, not of the mobile patches).

### 1) Clone this repo and check out the `mobile/v24` branch:

`main` is the legacy Node 18 line; the current Node 24 work lives on `mobile/v24`
(see [`MAINTENANCE_MODEL.md`](./MAINTENANCE_MODEL.md)).

```sh
git clone https://github.com/nodejs-mobile/nodejs-mobile
cd nodejs-mobile
git checkout mobile/v24
```

### 2a) Using the Android helper script:

The `tools/android_build.sh` script takes as first argument the Android NDK path (in our case is `~/AndroidSDK/ndk/27.2.12479018`). The second argument must be the Android SDK version as a two-digit number. The third argument is the target architecture, which can be one of the following: `arm`, `x86`, `arm64` or `x86_64`. You can omit the third argument, and it will build all available architectures.

Run (example arguments):

```sh
./tools/android_build.sh ~/AndroidSDK/ndk/27.2.12479018 23
```

When done, each built shared library will be placed in `out_android/$(ARCHITECTURE)/libnode.so`.

### 2b) Configure and build manually:
Run the `android-configure` script to configure the build with the path to the downloaded NDK and the desired target architecture.

```sh
source ./android-configure ../AndroidSDK/ndk/27.2.12479018 arm
```

Start the build phase:
```sh
make
```

This will create the Android `armeabi-v7a` shared library in `out/Release/lib.target/libnode.so`.

## Prerequisites to build the iOS .framework library on macOS:

### Xcode 11 with Command Line Tools

Install Xcode 11 or higher, from the App Store, and then install the Command Line Tools by running the following command:

```sh
xcode-select --install
```

That installs `git`, as well.

### CMake

To install `CMake`, you can use a package installer like [Homebrew](https://brew.sh/).

First, install `HomeBrew`, if you don't have it already.

```sh
/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
```

Then, use it to install `CMake`:

```sh
brew install cmake
```

## Building the iOS library using CocoaPods:

Add this to your `Podfile`:

```ruby
pod 'NodeMobile', :git => 'https://github.com/janeasystems/nodejs-mobile.git'
```

## Building the iOS .framework library on macOS:

### 1) Clone this repo and check out the `mobile/v24` branch:

```sh
git clone https://github.com/nodejs-mobile/nodejs-mobile
cd nodejs-mobile
git checkout mobile/v24
```

### 2) Run the helper script:

```sh
./tools/ios_framework_prepare.sh
```

That configures `gyp` to build Node.js and its dependencies as static libraries
for iOS, with `v8` set to run jitless (Apple's no-JIT rule). It builds two
arm64 slices — one for the device (`iphoneos`) and one for the simulator
(`iphonesimulator`) — copying their static libs through
`tools/ios-framework/bin/` into the `tools/ios-framework/NodeMobile.xcodeproj`
project. (x86_64/Intel-simulator support was dropped for v24: Intel Macs are EOL
and Apple Silicon runs the arm64 simulator natively.)

To build only one slice during development, pass `arm64` or `arm64-simulator`;
with no argument it builds both and combines them. The output is an
**`.xcframework`** bundling the device and simulator arm64 slices:
`out_ios/NodeMobile.xcframework`.

To build the comapeo-tuned smaller binary instead of the default, set
`NODEJS_MOBILE_FLAVOR=lite` (see the [lite variant](./README.md#the-lite-variant)).
