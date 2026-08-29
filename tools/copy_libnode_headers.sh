#!/bin/bash

set -e

SCRIPT_DIR="$(dirname "$BASH_SOURCE")"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: copy_libnode_headers.sh <ios|android> [target-config-name]"
  exit 1
fi

PLATFORM="$1"
TARGET_CONFIG_NAME="${2:-}"

if [ "$PLATFORM" == "ios" ]; then
  OUT_DIR=out_ios
elif [ "$PLATFORM" == "android" ]; then
  OUT_DIR=out_android
else
  echo "Requires either the string 'ios' or the string 'android' as argument"
  exit 1
fi

cd "$SCRIPT_DIR"
cd ..

HEADERS=$OUT_DIR/libnode/include/node
mkdir -p "$HEADERS"

# Build metadata used by node-gyp consumers. config.gypi is generated for one
# target ABI/flavor, so callers that have just configured a target provide a
# unique name and it is stored outside the shared include tree.
cp common.gypi "$HEADERS/common.gypi"
if [ -n "$TARGET_CONFIG_NAME" ]; then
  if [ ! -f config.gypi ]; then
    echo "config.gypi is missing for target $TARGET_CONFIG_NAME"
    exit 1
  fi
  CONFIG_DIR="$OUT_DIR/libnode/config/$TARGET_CONFIG_NAME"
  mkdir -p "$CONFIG_DIR"
  cp config.gypi "$CONFIG_DIR/config.gypi"
fi

# Public OpenSSL headers plus only the generated configurations relevant to
# the shipped mobile targets. Keep both asm and no-asm variants so the public
# dispatcher headers remain complete; current Android and iOS builds use
# --openssl-no-asm.
OPENSSL_HEADERS="$HEADERS/openssl"
mkdir -p "$OPENSSL_HEADERS/archs"
cp deps/openssl/openssl/include/openssl/*.h "$OPENSSL_HEADERS/"
cp deps/openssl/config/*.h "$OPENSSL_HEADERS/"
if [ "$PLATFORM" == "android" ]; then
  OPENSSL_ARCHS="linux-armv4 linux-aarch64 linux-x86_64"
else
  OPENSSL_ARCHS="darwin64-arm64-cc"
fi
for OPENSSL_ARCH in $OPENSSL_ARCHS; do
  mkdir -p "$OPENSSL_HEADERS/archs/$OPENSSL_ARCH"
  rsync -am --include='*/' --include='*.h' --exclude='*' \
    "deps/openssl/config/archs/$OPENSSL_ARCH/" \
    "$OPENSSL_HEADERS/archs/$OPENSSL_ARCH/"
done

# node headers
cp src/js_native_api.h "$HEADERS/"
cp src/js_native_api_types.h "$HEADERS/"
cp src/node_api_types.h "$HEADERS/"
cp src/node_api.h "$HEADERS/"
cp src/node_buffer.h "$HEADERS/"
cp src/node_mobile_version.h "$HEADERS/"
cp src/node_object_wrap.h "$HEADERS/"
cp src/node_version.h "$HEADERS/"
cp src/node.h "$HEADERS/"

# uv headers
rsync -am --include='*.h' -f 'hide,! */' deps/uv/include/ "$HEADERS"

# v8 headers
cp deps/v8/include/v8*.h "$HEADERS/"
mkdir -p "$HEADERS/libplatform"
cp deps/v8/include/libplatform/*.h "$HEADERS/libplatform/"
mkdir -p "$HEADERS/cppgc"
cp deps/v8/include/cppgc/*.h "$HEADERS/cppgc/"
mkdir -p "$HEADERS/cppgc/internal"
cp deps/v8/include/cppgc/internal/*.h "$HEADERS/cppgc/internal/"

# zlib headers required by native addons that include Node's bundled zlib.
cp deps/zlib/zconf.h "$HEADERS/zconf.h"
cp deps/zlib/zlib.h "$HEADERS/zlib.h"
