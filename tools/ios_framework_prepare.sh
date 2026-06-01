#!/bin/bash

set -e

ROOT=${PWD}

SCRIPT_DIR="$(dirname "$BASH_SOURCE")"
cd "$SCRIPT_DIR"
SCRIPT_DIR=${PWD}

#should be the node's source root
cd ../

LIBRARY_PATH='out/Release'
TARGET_LIBRARY_PATH='tools/ios-framework/bin'
NODELIB_PROJECT_PATH='tools/ios-framework'
XCODE_PROJECT_PATH='tools/ios-framework/NodeMobile.xcodeproj/project.pbxproj'

# Flavor switch (mobile-only; see doc_mobile/README.md "The lite variant"). "full"
# (default) is unchanged; "lite" is the comapeo-tuned build. Read here and
# threaded into both configure blocks and the static-lib link list.
FLAVOR="${NODEJS_MOBILE_FLAVOR:-full}"
if [ "$FLAVOR" != "full" ] && [ "$FLAVOR" != "lite" ]; then
  echo "Error: NODEJS_MOBILE_FLAVOR must be 'full' or 'lite'"; exit 1
fi
echo "iOS build flavor: $FLAVOR"

INTL="small-icu"
LITE_FLAGS=""
if [ "$FLAVOR" = "lite" ]; then
  INTL="none"
  # iOS lite: --v8-lite-mode is the ~20MB lever — it drops the compiled JIT and
  # the V8 WASM engine, both already dead on iOS (runtime is jitless; undici's
  # WASM is served by the polywasm JS shim). --without-{amaro,inspector,sqlite}
  # are comapeo-unused features.
  LITE_FLAGS="--without-amaro --without-inspector --without-sqlite --v8-lite-mode"
fi

declare -a outputs_common=(
  "libabseil.a"
  "libada.a"
  "libbrotli.a"
  "libcares.a"
  "libgtest.a"
  "libgtest_main.a"
  "libhistogram.a"
  "libllhttp.a"
  "libmerve.a"
  "libnbytes.a"
  "libncrypto.a"
  "libnghttp2.a"
  "libnode.a"
  "libopenssl.a"
  "libsimdjson.a"
  "libsimdutf.a"
  "libuv.a"
  "libuvwasi.a"
  "libv8_base_without_compiler.a"
  "libv8_compiler.a"
  "libv8_initializers.a"
  "libv8_libbase.a"
  "libv8_libplatform.a"
  "libv8_snapshot.a"
  "libv8_zlib.a"
  "libhighway.a"
  "libzlib.a"
  "libzstd.a"
)
# Static libs present only in the full flavor. lite's configure flags mean these
# are never built, so for lite they are neither copied nor linked (their
# Frameworks-phase lines are scrubbed from the pbxproj in build_framework_* via
# the existing grep -vF idiom):
#   libcrdtp                 -- --without-inspector
#   libsqlite                -- --without-sqlite
#   libicu*                  -- --with-intl=none (no ICU)
#   libv8_initializers_slow  -- not built under --v8-lite-mode
# NB: libv8_snapshot stays in outputs_common — it is the runtime isolate-setup
# lib (setup-isolate-deserialize) linked by BOTH flavors. libv8_init
# (setup-isolate-full) is only a dependency of the host mksnapshot tool and is
# never linked into the framework.
declare -a outputs_full_only=(
  "libcrdtp.a"
  "libsqlite.a"
  "libicudata.a"
  "libicui18n.a"
  "libicustubdata.a"
  "libicuucx.a"
  "libv8_initializers_slow.a"
)
declare -a outputs_x64_only=()
declare -a outputs_arm64_only=(
  "libzlib_data_chunk_simd.a"
)

if [ "$FLAVOR" = "lite" ]; then
  declare -a outputs_arm64=("${outputs_common[@]}" "${outputs_arm64_only[@]}")
else
  declare -a outputs_arm64=("${outputs_common[@]}" "${outputs_full_only[@]}" "${outputs_arm64_only[@]}")
fi

build_for_arm64_device() {
  make clean
  GYP_DEFINES="target_arch=arm64 host_os=mac target_os=ios"
  export GYP_DEFINES
  ./configure \
    --dest-os=ios \
    --dest-cpu=arm64 \
    --with-intl=$INTL \
    $LITE_FLAGS \
    --cross-compiling \
    --enable-static \
    --openssl-no-asm \
    --v8-options=--jitless \
    --without-node-code-cache \
    --without-node-snapshot
  make -j$(getconf _NPROCESSORS_ONLN)

  # Move compilation outputs
  mkdir -p $TARGET_LIBRARY_PATH/arm64-device
  for output_file in "${outputs_arm64[@]}"; do
    cp $LIBRARY_PATH/$output_file $TARGET_LIBRARY_PATH/arm64-device/
  done
}

build_for_arm64_simulator() {
  make clean
  GYP_DEFINES="target_arch=arm64 host_os=mac target_os=ios"
  export GYP_DEFINES
  ./configure \
    --dest-os=ios \
    --dest-cpu=arm64 \
    --with-intl=$INTL \
    $LITE_FLAGS \
    --cross-compiling \
    --enable-static \
    --openssl-no-asm \
    --v8-options=--jitless \
    --without-node-code-cache \
    --without-node-snapshot \
    --ios-simulator
  make -j$(getconf _NPROCESSORS_ONLN)

  # Move compilation outputs
  mkdir -p $TARGET_LIBRARY_PATH/arm64-simulator
  for output_file in "${outputs_arm64[@]}"; do
      cp $LIBRARY_PATH/$output_file $TARGET_LIBRARY_PATH/arm64-simulator/
  done
}

build_framework_for_arm64_device() {
  # Move libraries to the correct location
  for output_file in "${outputs_arm64[@]}"; do
    rm -f $TARGET_LIBRARY_PATH/$output_file
    mv $TARGET_LIBRARY_PATH/arm64-device/$output_file $TARGET_LIBRARY_PATH/$output_file
  done
  # Remove libraries that do not exist for this target
  cp $XCODE_PROJECT_PATH $XCODE_PROJECT_PATH.bak
  for output_file in "${outputs_x64_only[@]}"; do
    grep -vF "$output_file" $XCODE_PROJECT_PATH > temp && mv temp $XCODE_PROJECT_PATH
  done
  # Lite flavor: inspector/sqlite are --without'd, so their static libs are not
  # built — strip their Frameworks-phase lines so the link doesn't fail.
  if [ "$FLAVOR" = "lite" ]; then
    for output_file in "${outputs_full_only[@]}"; do
      grep -vF "$output_file" $XCODE_PROJECT_PATH > temp && mv temp $XCODE_PROJECT_PATH
    done
  fi
  # Compile the Framework Xcode project for arm64 device
  xcodebuild build \
    -project $NODELIB_PROJECT_PATH/NodeMobile.xcodeproj \
    -target "NodeMobile" \
    -configuration Release \
    -arch arm64 \
    -sdk "iphoneos" \
    SYMROOT=$FRAMEWORK_TARGET_DIR/iphoneos-arm64
  mv $XCODE_PROJECT_PATH.bak $XCODE_PROJECT_PATH
}

build_framework_for_arm64_simulator() {
  # Move libraries to the correct location
  for output_file in "${outputs_arm64[@]}"; do
    rm -f $TARGET_LIBRARY_PATH/$output_file
    mv $TARGET_LIBRARY_PATH/arm64-simulator/$output_file $TARGET_LIBRARY_PATH/$output_file
  done
  # Remove libraries that do not exist for this target
  cp $XCODE_PROJECT_PATH $XCODE_PROJECT_PATH.bak
  for output_file in "${outputs_x64_only[@]}"; do
    grep -vF "$output_file" $XCODE_PROJECT_PATH > temp && mv temp $XCODE_PROJECT_PATH
  done
  # Lite flavor: inspector/sqlite are --without'd, so their static libs are not
  # built — strip their Frameworks-phase lines so the link doesn't fail.
  if [ "$FLAVOR" = "lite" ]; then
    for output_file in "${outputs_full_only[@]}"; do
      grep -vF "$output_file" $XCODE_PROJECT_PATH > temp && mv temp $XCODE_PROJECT_PATH
    done
  fi
  # Compile the Framework Xcode project for arm64 simulator
  xcodebuild build \
    -project $NODELIB_PROJECT_PATH/NodeMobile.xcodeproj \
    -target "NodeMobile" \
    -configuration Release \
    -arch arm64 \
    -sdk "iphonesimulator" \
    SYMROOT=$FRAMEWORK_TARGET_DIR/iphonesimulator-arm64
  mv $XCODE_PROJECT_PATH.bak $XCODE_PROJECT_PATH
}

combine_frameworks() {
  # x86_64 (Intel Mac) simulator support was dropped for v24: Intel Macs are
  # EOL and Apple Silicon runs the arm64 simulator natively. The xcframework
  # ships an arm64 device slice and an arm64 simulator slice.
  XCFRAMEWORK=$FRAMEWORK_TARGET_DIR/NodeMobile.xcframework
  xcodebuild -create-xcframework \
    -framework $FRAMEWORK_TARGET_DIR/iphoneos-arm64/Release-iphoneos/NodeMobile.framework \
    -framework $FRAMEWORK_TARGET_DIR/iphonesimulator-arm64/Release-iphonesimulator/NodeMobile.framework \
    -output $XCFRAMEWORK

  echo "Framework built: $XCFRAMEWORK"
}

# Create a path to build the framework into
set_framework_target_dir() {
  if [ -z "$1" ]; then
    mkdir -p out_ios
    cd out_ios
    FRAMEWORK_TARGET_DIR=${PWD}
    cd ../
  else
    rm -rf out_ios_$1
    mkdir -p out_ios_$1
    cd out_ios_$1
    FRAMEWORK_TARGET_DIR=${PWD}
    cd ../
  fi
}

# Interpret the command line arguments
if [[ $1 == "arm64" ]]; then
  set_framework_target_dir $1
  build_for_arm64_device
  build_framework_for_arm64_device
elif [[ $1 == "arm64-simulator" ]]; then
  set_framework_target_dir $1
  build_for_arm64_simulator
  build_framework_for_arm64_simulator
elif [[ $1 == "combine_frameworks" ]]; then
  set_framework_target_dir
  combine_frameworks
elif [[ $1 == "--help" ]]; then
  echo "Usage: ios_framework_prepare.sh arm64|arm64-simulator|combine_frameworks"
  exit 1
else
  build_for_arm64_device
  build_for_arm64_simulator

  set_framework_target_dir "arm64"
  build_framework_for_arm64_device
  set_framework_target_dir "arm64-simulator"
  build_framework_for_arm64_simulator
  set_framework_target_dir
  combine_frameworks

  source $SCRIPT_DIR/copy_libnode_headers.sh ios
fi

cd "$ROOT"
