#!/bin/zsh

set -euo pipefail

PROJECT_DIR=${0:A:h}
APP_PATH="/Applications/Kaze.app"

"${PROJECT_DIR}/Scripts/package-app.sh" --output "${APP_PATH}" "$@"
open "${APP_PATH}"

print -- "Kaze is installed at ${APP_PATH}."
print -- "Choose ‘Register / Update’ in the menu, then approve the helper in System Settings."
