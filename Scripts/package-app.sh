#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
OUTPUT_PATH="${PROJECT_DIR}/dist/Kaze.app"
SIGNING_IDENTITY=${CODESIGN_IDENTITY:-}
ADHOC=0

while (( $# > 0 )); do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || { print -u2 -- "--output needs a path"; exit 64; }
            OUTPUT_PATH=$2
            shift 2
            ;;
        --identity)
            [[ $# -ge 2 ]] || { print -u2 -- "--identity needs a value"; exit 64; }
            SIGNING_IDENTITY=$2
            shift 2
            ;;
        --adhoc)
            ADHOC=1
            SIGNING_IDENTITY="-"
            shift
            ;;
        *)
            print -u2 -- "Unknown option: $1"
            exit 64
            ;;
    esac
done

if [[ -z "${SIGNING_IDENTITY}" ]]; then
    print -u2 -- "A signing identity is required. Set CODESIGN_IDENTITY, pass --identity, or use --adhoc for a non-installable development bundle."
    exit 64
fi
if [[ "${SIGNING_IDENTITY}" == "-" && ${ADHOC} -ne 1 ]]; then
    print -u2 -- "Use --adhoc explicitly for an ad-hoc development bundle."
    exit 64
fi

case "${OUTPUT_PATH}" in
    /*/Kaze.app) ;;
    *) print -u2 -- "Output must be an absolute path ending in Kaze.app"; exit 64 ;;
esac

cd "${PROJECT_DIR}"
swift build -c release

BUILD_DIR=$(swift build -c release --show-bin-path)
STAGING_PATH="${OUTPUT_PATH}.staging.$$"
rm -rf -- "${STAGING_PATH}"
mkdir -p -- \
    "${STAGING_PATH}/Contents/MacOS" \
    "${STAGING_PATH}/Contents/Resources" \
    "${STAGING_PATH}/Contents/Library/LaunchDaemons" \
    "${STAGING_PATH}/Contents/Library/Utilities"

cp -- "${BUILD_DIR}/KazeApp" "${STAGING_PATH}/Contents/MacOS/KazeApp"
cp -- "${BUILD_DIR}/KazeHelper" "${STAGING_PATH}/Contents/MacOS/KazeHelper"
cp -- "${BUILD_DIR}/kaze" "${STAGING_PATH}/Contents/Library/Utilities/kaze"
cp -- "${BUILD_DIR}/kaze-recovery" "${STAGING_PATH}/Contents/Library/Utilities/kaze-recovery"
cp -- "${PROJECT_DIR}/Packaging/Info.plist" "${STAGING_PATH}/Contents/Info.plist"
cp -- "${PROJECT_DIR}/Packaging/com.producerguy.kaze.helper.plist" \
    "${STAGING_PATH}/Contents/Library/LaunchDaemons/com.producerguy.kaze.helper.plist"
cp -- "${PROJECT_DIR}/Kaze.icns" "${STAGING_PATH}/Contents/Resources/AppIcon.icns"

if (( ADHOC )); then
    : > "${STAGING_PATH}/Contents/Resources/development-build"
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" \
        "${STAGING_PATH}/Contents/Library/LaunchDaemons/com.producerguy.kaze.helper.plist"
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:KAZE_DEVELOPMENT string 1" \
        "${STAGING_PATH}/Contents/Library/LaunchDaemons/com.producerguy.kaze.helper.plist"
fi

SIGN_ARGS=(--force --options runtime --sign "${SIGNING_IDENTITY}")
if (( ! ADHOC )); then
    SIGN_ARGS+=(--timestamp)
fi

codesign "${SIGN_ARGS[@]}" --identifier com.producerguy.kaze.helper \
    "${STAGING_PATH}/Contents/MacOS/KazeHelper"
codesign "${SIGN_ARGS[@]}" --identifier com.producerguy.kaze.cli \
    "${STAGING_PATH}/Contents/Library/Utilities/kaze"
codesign "${SIGN_ARGS[@]}" --identifier com.producerguy.kaze.recovery \
    "${STAGING_PATH}/Contents/Library/Utilities/kaze-recovery"
codesign "${SIGN_ARGS[@]}" --identifier com.producerguy.kaze "${STAGING_PATH}"
codesign --verify --deep --strict --verbose=2 "${STAGING_PATH}"

if (( ! ADHOC )); then
    [[ ! -e "${STAGING_PATH}/Contents/Resources/development-build" ]] || {
        print -u2 -- "Refusing to package a production bundle with the development marker"
        exit 65
    }
    if /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:KAZE_DEVELOPMENT" \
        "${STAGING_PATH}/Contents/Library/LaunchDaemons/com.producerguy.kaze.helper.plist" >/dev/null 2>&1; then
        print -u2 -- "Refusing to package a production helper with relaxed IPC authentication"
        exit 65
    fi
    SIGNATURE_INFO=$(codesign -d --verbose=4 "${STAGING_PATH}" 2>&1)
    [[ "${SIGNATURE_INFO}" == *"TeamIdentifier="* && "${SIGNATURE_INFO}" != *"TeamIdentifier=not set"* ]] || {
        print -u2 -- "Production signing identity did not provide a Team ID"
        exit 65
    }
fi

mkdir -p -- "${OUTPUT_PATH:h}"
if [[ -e "${OUTPUT_PATH}" ]]; then
    mv -- "${OUTPUT_PATH}" "${OUTPUT_PATH}.previous.$$"
fi
mv -- "${STAGING_PATH}" "${OUTPUT_PATH}"
rm -rf -- "${OUTPUT_PATH}.previous.$$"

print -- "Packaged ${OUTPUT_PATH}"
if (( ADHOC )); then
    print -- "Development-only ad-hoc bundle: SMAppService may reject registration."
else
    print -- "Developer-signed bundle ready for notarization."
fi
