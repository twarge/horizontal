#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCCT_MACOS_INSTALL_DIR="${OCCT_MACOS_INSTALL_DIR:-${OCCT_INSTALL_DIR:-$ROOT_DIR/Vendor/OpenCascadeStatic/macos-arm64}}"
OCCT_IOS_SIMULATOR_INSTALL_DIR="${OCCT_IOS_SIMULATOR_INSTALL_DIR-$ROOT_DIR/Vendor/OpenCascadeStatic/ios-simulator-arm64}"
OCCT_IOS_DEVICE_INSTALL_DIR="${OCCT_IOS_DEVICE_INSTALL_DIR-$ROOT_DIR/Vendor/OpenCascadeStatic/ios-arm64}"
OUTPUT_DIR="${OCCT_XCFRAMEWORK_OUTPUT:-$ROOT_DIR/Vendor/OpenCascadeStatic/OpenCascadeStairs.xcframework}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/occt-xcframework.XXXXXX")"

OCCT_LIBRARIES=(
  TKDESTEP
  TKDEIGES
  TKDECascade
  TKDESTL
  TKDEPLY
  TKDEOBJ
  TKDEGLTF
  TKRWMesh
  TKXCAF
  TKDE
  TKXSBase
  TKVCAF
  TKCAF
  TKLCAF
  TKCDF
  TKBO
  TKBool
  TKPrim
  TKV3d
  TKService
  TKMesh
  TKShHealing
  TKHLR
  TKTopAlgo
  TKGeomAlgo
  TKBRep
  TKGeomBase
  TKG3d
  TKG2d
  TKMath
  TKernel
)

if [[ -e "$OUTPUT_DIR" ]]; then
  cat >&2 <<EOF
XCFramework output already exists:
  $OUTPUT_DIR

Move it aside or set OCCT_XCFRAMEWORK_OUTPUT to a new path.
EOF
  exit 1
fi

XCFRAMEWORK_ARGS=()
MERGED_LIBRARIES=()

merge_install_dir() {
  local label="$1"
  local install_dir="$2"
  local headers_dir="$install_dir/include/opencascade"
  local merged_library="$WORK_DIR/libOpenCascadeStairs-$label.a"
  local library_paths=()

  if [[ ! -d "$headers_dir" ]]; then
    cat >&2 <<EOF
OpenCascade headers were not found at:
  $headers_dir

Build the static OCCT install first.
EOF
    exit 1
  fi

  for library in "${OCCT_LIBRARIES[@]}"; do
    local path="$install_dir/lib/lib${library}.a"
    if [[ ! -f "$path" ]]; then
      cat >&2 <<EOF
Required OpenCascade archive was not found:
  $path

Rebuild the static OCCT install.
EOF
      exit 1
    fi
    library_paths+=("$path")
  done

  xcrun libtool -static -o "$merged_library" "${library_paths[@]}"
  xcrun ranlib "$merged_library"

  XCFRAMEWORK_ARGS+=("-library" "$merged_library" "-headers" "$headers_dir")
  MERGED_LIBRARIES+=("$label: $merged_library")
}

mkdir -p "$(dirname "$OUTPUT_DIR")"

merge_install_dir "macos-arm64" "$OCCT_MACOS_INSTALL_DIR"

if [[ -n "$OCCT_IOS_SIMULATOR_INSTALL_DIR" && -d "$OCCT_IOS_SIMULATOR_INSTALL_DIR" ]]; then
  merge_install_dir "ios-simulator-arm64" "$OCCT_IOS_SIMULATOR_INSTALL_DIR"
fi

if [[ -n "$OCCT_IOS_DEVICE_INSTALL_DIR" ]]; then
  merge_install_dir "ios-arm64" "$OCCT_IOS_DEVICE_INSTALL_DIR"
fi

xcodebuild -create-xcframework \
  "${XCFRAMEWORK_ARGS[@]}" \
  -output "$OUTPUT_DIR"

cat <<EOF
Built OpenCascade XCFramework:
  $OUTPUT_DIR

Merged static archives:
EOF

for merged_library in "${MERGED_LIBRARIES[@]}"; do
  printf '  %s\n' "$merged_library"
done
