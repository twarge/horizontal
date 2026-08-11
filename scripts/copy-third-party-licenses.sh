#!/bin/sh
# Copies every third-party licence text into the built app bundle.
#
# The About panel tells the user where to find each full licence
# (Contents/Resources/ThirdPartyLicenses/<component>/...). Those paths were
# advertised long before anything put files there, so the shipped app pointed at
# licences it did not carry. For OCCT that is not cosmetic: it is statically
# linked under LGPL 2.1, which requires the licence to accompany the binary.
#
# Only what the binary actually contains is listed. poly2tri and js-dxf are
# vendored but compiled into nothing, so shipping their notices would claim the
# app includes software it does not.
#
# Run as a build phase. Sources are the vendored trees; a missing one is a
# warning rather than a build failure, because submodules are not always checked
# out and a developer build should not be blocked by that — but a RELEASE build
# fails, since shipping without them is the thing this exists to prevent.
set -eu

SRCROOT_DIR="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# TARGET_BUILD_DIR, not BUILT_PRODUCTS_DIR: in an archive (DEPLOYMENT_LOCATION=YES)
# the app is assembled under DSTROOT and BUILT_PRODUCTS_DIR only holds a SYMLINK
# to it. Writing through that symlink lands on a path the script sandbox never
# granted — it matches resolved paths — so every archive died here with
# "Sandbox: cp deny file-write-create". The two are the same directory in an
# ordinary build. The build phase declares its outputs against TARGET_BUILD_DIR
# too, so the sandbox allow-list and this destination stay the same path.
DEST="${TARGET_BUILD_DIR:-${BUILT_PRODUCTS_DIR:-.}}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-Resources}/ThirdPartyLicenses"
CONFIG="${CONFIGURATION:-Debug}"

missing=0

install_license() {
    component="$1"
    source_path="$2"
    if [ ! -f "$source_path" ]; then
        echo "warning: third-party licence missing for ${component}: ${source_path}"
        missing=$((missing + 1))
        return
    fi
    mkdir -p "${DEST}/${component}"
    cp -f "$source_path" "${DEST}/${component}/$(basename "$source_path")"
}

OCCT_DOC="${SRCROOT_DIR}/Vendor/OpenCascadeStatic/macos-arm64/share/doc/opencascade"
install_license OpenCascade "${OCCT_DOC}/LICENSE_LGPL_21.txt"
install_license OpenCascade "${OCCT_DOC}/OCCT_LGPL_EXCEPTION.txt"
install_license RapidJSON   "${SRCROOT_DIR}/Vendor/RapidJSON/license.txt"
install_license Clipper     "${SRCROOT_DIR}/Vendor/Clipper/License.txt"
install_license earcut      "${SRCROOT_DIR}/Vendor/earcut/LICENSE"
install_license Hershey     "${SRCROOT_DIR}/Vendor/Hersheyish/LICENSE"

if [ "$missing" -gt 0 ] && [ "$CONFIG" != "Debug" ]; then
    echo "error: ${missing} third-party licence text(s) missing from a ${CONFIG} build; the About panel advertises them and OCCT's LGPL requires it"
    exit 1
fi
