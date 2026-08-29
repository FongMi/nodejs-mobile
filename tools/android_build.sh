#!/bin/bash

set -e

ROOT=${PWD}

if [ $# -lt 2 ]; then
  echo "Requires a path to the Android NDK and an SDK version number (optionally: target arch)"
  echo "Usage: android_build.sh <ndk_path> <sdk_version> [target_arch]"
  exit 1
fi

ANDROID_SDK_VERSION="$2"

SCRIPT_DIR="$(dirname "$BASH_SOURCE")"
cd "$SCRIPT_DIR"
SCRIPT_DIR=${PWD}

cd "$ROOT"
cd "$1"
ANDROID_NDK_PATH=${PWD}
cd "$SCRIPT_DIR"
cd ../

BUILD_ARCH() {
  # Clean previous compilation
  make clean
  rm -rf android-toolchain/

  # Compile
  eval '"./android-configure" "$ANDROID_NDK_PATH" $ANDROID_SDK_VERSION $TARGET_ARCH'
  make -j $(getconf _NPROCESSORS_ONLN)

  # Move binaries
  TARGET_ARCH_FOLDER="$TARGET_ARCH"
  if [ "$TARGET_ARCH_FOLDER" == "arm" ]; then
    # Use the Android NDK ABI name.
    TARGET_ARCH_FOLDER="armeabi-v7a"
  elif [ "$TARGET_ARCH_FOLDER" == "arm64" ]; then
    # Use the Android NDK ABI name.
    TARGET_ARCH_FOLDER="arm64-v8a"
  fi

  if [ "$TARGET_ARCH" == "arm" ]; then
    NDK_TRIPLE="arm-linux-androideabi"
  elif [ "$TARGET_ARCH" == "arm64" ]; then
    NDK_TRIPLE="aarch64-linux-android"
  elif [ "$TARGET_ARCH" == "x86" ]; then
    NDK_TRIPLE="i686-linux-android"
  elif [ "$TARGET_ARCH" == "x86_64" ]; then
    NDK_TRIPLE="x86_64-linux-android"
  else
    echo "Unsupported Android architecture: $TARGET_ARCH"
    exit 1
  fi

  mkdir -p "out_android/$TARGET_ARCH_FOLDER/"
  OUTPUT1="out/Release/lib.target/libnode.so"
  OUTPUT2="out/Release/obj.target/libnode.so"
  if [ -f "$OUTPUT1" ]; then
    cp "$OUTPUT1" "out_android/$TARGET_ARCH_FOLDER/libnode.so"
  elif [ -f "$OUTPUT2" ]; then
    cp "$OUTPUT2" "out_android/$TARGET_ARCH_FOLDER/libnode.so"
  else
    echo "Could not find libnode.so file after compilation"
    exit 1
  fi

  # libnode.so depends on the exact libc++ runtime shipped by its NDK. Include
  # that runtime per ABI so consumers do not have to guess which revision to
  # package. Keep the NDK file byte-for-byte intact for hash verification.
  mapfile -d '' NDK_PREBUILT_DIRS < <(find "$ANDROID_NDK_PATH/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 -type d -print0)
  if [ "${#NDK_PREBUILT_DIRS[@]}" -ne 1 ]; then
    echo "Expected exactly one NDK host prebuilt directory, found ${#NDK_PREBUILT_DIRS[@]}"
    exit 1
  fi
  LIBCXX="${NDK_PREBUILT_DIRS[0]}/sysroot/usr/lib/$NDK_TRIPLE/libc++_shared.so"
  if [ ! -f "$LIBCXX" ]; then
    echo "Could not find the NDK libc++ runtime at $LIBCXX"
    exit 1
  fi
  cp "$LIBCXX" "out_android/$TARGET_ARCH_FOLDER/libc++_shared.so"

  # config.gypi is target- and flavor-specific. Store it beside an ABI key
  # instead of placing one ambiguous file in the shared header directory.
  source "$SCRIPT_DIR/copy_libnode_headers.sh" android "$TARGET_ARCH_FOLDER"
}

if [ $# -eq 2 ]; then
  TARGET_ARCH="arm"
  BUILD_ARCH
  # TARGET_ARCH="x86"
  # BUILD_ARCH
  TARGET_ARCH="arm64"
  BUILD_ARCH
  TARGET_ARCH="x86_64"
  BUILD_ARCH
else
  TARGET_ARCH=$3
  BUILD_ARCH
fi

source "$SCRIPT_DIR/copy_libnode_headers.sh" android

cd "$ROOT"
