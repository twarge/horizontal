#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCCT_VERSION="${OCCT_VERSION:-8.0.0}"
SOURCE_DIR="${OCCT_SOURCE_DIR:-$ROOT_DIR/Vendor/OCCT}"
RAPIDJSON_DIR="${RAPIDJSON_DIR:-$ROOT_DIR/Vendor/RapidJSON}"
IOS_PLATFORM="${OCCT_IOS_PLATFORM:-all}"
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

build_slice() {
  local label="$1"
  local sdk="$2"
  local install_dir="$ROOT_DIR/Vendor/OpenCascadeStatic/$label"
  local build_dir="${OCCT_BUILD_DIR:-/private/tmp/occt-build/$label-$OCCT_VERSION}"

  cmake -S "$SOURCE_DIR" -B "$build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_INSTALL_PREFIX="$install_dir" \
    -DINSTALL_DIR="$install_dir" \
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
    -D3RDPARTY_RAPIDJSON_INCLUDE_DIR="$RAPIDJSON_DIR/include"

  cmake --build "$build_dir" --target install --parallel "$JOBS"

  echo "Installed OpenCascade $OCCT_VERSION $label static archives to $install_dir"
}

case "$IOS_PLATFORM" in
  all)
    build_slice ios-simulator-arm64 iphonesimulator
    build_slice ios-arm64 iphoneos
    ;;
  simulator)
    build_slice ios-simulator-arm64 iphonesimulator
    ;;
  device)
    build_slice ios-arm64 iphoneos
    ;;
  *)
    cat >&2 <<EOF
Unknown OCCT_IOS_PLATFORM value: $IOS_PLATFORM

Use one of: all, simulator, device
EOF
    exit 1
    ;;
esac
