#!/bin/zsh

set -euo pipefail

APP_PATH="/Applications/Kaze.app"

if launchctl print system/com.producerguy.kaze.helper >/dev/null 2>&1; then
    print -u2 -- "The privileged helper is still registered."
    print -u2 -- "Open Kaze, choose Apple Automatic, then choose Unregister."
    exit 1
fi

if [[ ! -e "${APP_PATH}" ]]; then
    print -- "Kaze is not installed."
    exit 0
fi

TRASH_PATH="${HOME}/.Trash/Kaze-$(date +%Y%m%d-%H%M%S).app"
mv -- "${APP_PATH}" "${TRASH_PATH}"
print -- "Moved Kaze to ${TRASH_PATH}. It can be recovered from Trash."
