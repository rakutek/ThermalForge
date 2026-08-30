#!/bin/zsh

set -euo pipefail

[[ $# -eq 2 ]] || {
    print -u2 -- "Usage: Scripts/notarize.sh /absolute/path/Kaze.app KEYCHAIN_PROFILE"
    exit 64
}

APP_PATH=$1
KEYCHAIN_PROFILE=$2
[[ "${APP_PATH}" == /*/Kaze.app && -d "${APP_PATH}" ]] || {
    print -u2 -- "The first argument must be an existing absolute Kaze.app path"
    exit 64
}

HELPER_PATH="${APP_PATH}/Contents/Resources/KazeHelper"
CLI_PATH="${APP_PATH}/Contents/Library/Utilities/kaze"
RECOVERY_PATH="${APP_PATH}/Contents/Library/Utilities/kaze-recovery"
PLIST_PATH="${APP_PATH}/Contents/Library/LaunchDaemons/com.producerguy.kaze.helper.plist"
[[ -x "${HELPER_PATH}" && -x "${CLI_PATH}" && -x "${RECOVERY_PATH}" && -f "${PLIST_PATH}" ]] || {
    print -u2 -- "The app bundle is missing its privileged helper"
    exit 65
}
[[ ! -e "${APP_PATH}/Contents/Resources/development-build" ]] || {
    print -u2 -- "Refusing to notarize a development bundle"
    exit 65
}
if /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:KAZE_DEVELOPMENT" \
    "${PLIST_PATH}" >/dev/null 2>&1; then
    print -u2 -- "Refusing to notarize a helper with relaxed IPC authentication"
    exit 65
fi

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
APP_SIGNATURE=$(codesign -d --verbose=4 "${APP_PATH}" 2>&1)
HELPER_SIGNATURE=$(codesign -d --verbose=4 "${HELPER_PATH}" 2>&1)
CLI_SIGNATURE=$(codesign -d --verbose=4 "${CLI_PATH}" 2>&1)
RECOVERY_SIGNATURE=$(codesign -d --verbose=4 "${RECOVERY_PATH}" 2>&1)
APP_TEAM=$(print -r -- "${APP_SIGNATURE}" | sed -n 's/^TeamIdentifier=//p')
HELPER_TEAM=$(print -r -- "${HELPER_SIGNATURE}" | sed -n 's/^TeamIdentifier=//p')
CLI_TEAM=$(print -r -- "${CLI_SIGNATURE}" | sed -n 's/^TeamIdentifier=//p')
RECOVERY_TEAM=$(print -r -- "${RECOVERY_SIGNATURE}" | sed -n 's/^TeamIdentifier=//p')
[[ -n "${APP_TEAM}" && "${APP_TEAM}" != "not set" \
    && "${HELPER_TEAM}" == "${APP_TEAM}" \
    && "${CLI_TEAM}" == "${APP_TEAM}" \
    && "${RECOVERY_TEAM}" == "${APP_TEAM}" ]] || {
    print -u2 -- "Every executable must have the same non-empty Team ID"
    exit 65
}
[[ "${APP_SIGNATURE}" == *"Identifier=com.producerguy.kaze"* \
    && "${HELPER_SIGNATURE}" == *"Identifier=com.producerguy.kaze.helper"* \
    && "${CLI_SIGNATURE}" == *"Identifier=com.producerguy.kaze.cli"* \
    && "${RECOVERY_SIGNATURE}" == *"Identifier=com.producerguy.kaze.recovery"* \
    && "${APP_SIGNATURE}" == *"runtime"* \
    && "${HELPER_SIGNATURE}" == *"runtime"* \
    && "${CLI_SIGNATURE}" == *"runtime"* \
    && "${RECOVERY_SIGNATURE}" == *"runtime"* ]] || {
    print -u2 -- "Identifiers or Hardened Runtime flags are incorrect"
    exit 65
}

NOTARY_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/kaze-notary.XXXXXX")
trap 'rm -rf -- "${NOTARY_TEMP}"' EXIT
UPLOAD_ARCHIVE="${NOTARY_TEMP}/Kaze-upload.zip"
ditto -c -k --keepParent "${APP_PATH}" "${UPLOAD_ARCHIVE}"
xcrun notarytool submit "${UPLOAD_ARCHIVE}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"
spctl --assess --type execute --verbose=4 "${APP_PATH}"

ARCHIVE_PATH="${APP_PATH:h}/Kaze.zip"
ARCHIVE_STAGING="${ARCHIVE_PATH}.staging.$$"
ditto -c -k --keepParent "${APP_PATH}" "${ARCHIVE_STAGING}"
mv -f -- "${ARCHIVE_STAGING}" "${ARCHIVE_PATH}"
shasum -a 256 "${ARCHIVE_PATH}" > "${ARCHIVE_PATH}.sha256"
print -- "Notarized, stapled, and verified ${APP_PATH}"
print -- "Final artifact: ${ARCHIVE_PATH}"
