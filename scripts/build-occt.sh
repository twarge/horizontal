#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCCT_TAG="${OCCT_TAG:-V8_0_0}"
OCCT_VERSION="${OCCT_VERSION:-8.0.0}"
SOURCE_DIR="${OCCT_SOURCE_DIR:-$ROOT_DIR/Vendor/OCCT}"
RAPIDJSON_DIR="${RAPIDJSON_DIR:-$ROOT_DIR/Vendor/RapidJSON}"
BUILD_DIR="${OCCT_BUILD_DIR:-/private/tmp/occt-build/macos-arm64-$OCCT_VERSION}"
INSTALL_DIR="$ROOT_DIR/Vendor/OpenCascadeStatic/macos-arm64"
JOBS="${JOBS:-}"

if [[ -z "$JOBS" ]]; then
  JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || true)"
fi

if [[ -z "$JOBS" ]]; then
  JOBS=8
fi

if [[ ! -f "$SOURCE_DIR/CMakeLists.txt" || ! -d "$SOURCE_DIR/src" ]]; then
  cat >&2 <<EOF
OpenCascade source was not found at:
  $SOURCE_DIR

Initialize the OCCT submodule first:
  git submodule update --init --recursive Vendor/OCCT
EOF
  exit 1
fi

if [[ ! -f "$RAPIDJSON_DIR/include/rapidjson/rapidjson.h" ]]; then
  cat >&2 <<EOF
RapidJSON headers were not found at:
  $RAPIDJSON_DIR

Initialize the RapidJSON submodule first:
  git submodule update --init --recursive Vendor/RapidJSON
EOF
  exit 1
fi

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
  -DINSTALL_DIR="$INSTALL_DIR" \
  -DBUILD_LIBRARY_TYPE=Static \
  -DBUILD_MODULE_Draw=OFF \
  -DBUILD_DOC_Overview=OFF \
  -DBUILD_SAMPLES_QT=OFF \
  -DBUILD_SAMPLES_MFC=OFF \
  -DBUILD_MODULE_UwpSample=OFF \
  -DUSE_TBB=OFF \
  -DUSE_TCL=OFF \
  -DUSE_FREETYPE=OFF \
  -DUSE_FREEIMAGE=OFF \
  -DUSE_RAPIDJSON=ON \
  -DINSTALL_RAPIDJSON=ON \
  -D3RDPARTY_RAPIDJSON_DIR="$RAPIDJSON_DIR" \
  -D3RDPARTY_RAPIDJSON_INCLUDE_DIR="$RAPIDJSON_DIR/include" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64

cmake --build "$BUILD_DIR" --target install --parallel "$JOBS"

echo "Installed OpenCascade $OCCT_VERSION static archives to $INSTALL_DIR"
