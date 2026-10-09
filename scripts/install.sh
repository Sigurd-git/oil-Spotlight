#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLICATIONS_DIR="${OILFIND_INSTALL_DIR:-/Applications}"
APP_NAME='Oil Find.app'
BUNDLE_ID='com.oiloil.find'
PROCESS_NAME='OilFind'
SOURCE_APP="$PROJECT_DIR/build/$APP_NAME"
DESTINATION="$APPLICATIONS_DIR/$APP_NAME"

"$PROJECT_DIR/scripts/build-app.sh"
[[ -d "$SOURCE_APP" ]] || { printf 'Built app is missing: %s\n' "$SOURCE_APP" >&2; exit 1; }

# Refuse to replace another app bundle or a bundle with an unexpected identity.
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")
[[ "$bundle_id" == "$BUNDLE_ID" ]] || { printf 'Unexpected app bundle identifier: %s\n' "$bundle_id" >&2; exit 1; }

if pgrep -x "$PROCESS_NAME" >/dev/null; then
    osascript -e "quit app id \"$BUNDLE_ID\"" &
    QUIT_REQUEST_PID=$!
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! pgrep -x "$PROCESS_NAME" >/dev/null; then break; fi
        sleep 0.1
    done
    if kill -0 "$QUIT_REQUEST_PID" 2>/dev/null; then kill "$QUIT_REQUEST_PID" 2>/dev/null || true; fi
    wait "$QUIT_REQUEST_PID" 2>/dev/null || true
    if pgrep -x "$PROCESS_NAME" >/dev/null; then
        printf '%s did not quit within 5 seconds.\n' "$PROCESS_NAME" >&2
        exit 1
    fi
fi

[[ -d "$APPLICATIONS_DIR" && -w "$APPLICATIONS_DIR" ]] || {
    printf 'Application install directory is not writable: %s\n' "$APPLICATIONS_DIR" >&2
    exit 1
}
stage="$APPLICATIONS_DIR/.oilfind-stage.$$.app"
backup="$APPLICATIONS_DIR/.oilfind-backup.$$.app"
promoted=0
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -e "$stage" ]]; then rm -rf "$stage"; fi
    if [[ $status -ne 0 && -e "$backup" ]]; then
        if [[ -e "$DESTINATION" ]]; then rm -rf "$DESTINATION"; fi
        mv "$backup" "$DESTINATION" || {
            printf 'Install failed; previous app is preserved at %s\n' "$backup" >&2
            exit "$status"
        }
    elif [[ $status -ne 0 && $promoted == 1 && -e "$DESTINATION" ]]; then
        rm -rf "$DESTINATION"
    fi
    if [[ $status -eq 0 && -e "$backup" ]]; then rm -rf "$backup"; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ditto "$SOURCE_APP" "$stage"
codesign --verify --deep --strict "$stage"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$stage/Contents/Info.plist")" == "$BUNDLE_ID" ]] || {
    printf 'Staged app failed bundle identifier verification.\n' >&2
    exit 1
}

if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$backup"; fi
mv "$stage" "$DESTINATION" || exit 1
promoted=1
codesign --verify --deep --strict "$DESTINATION" || exit 1
open "$DESTINATION" || exit 1
