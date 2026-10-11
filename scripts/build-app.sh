#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION=release
APP_PATH="$PROJECT_DIR/build/Oil Find.app"
case "${1:-}" in
    '') [[ $# -eq 0 ]] || exit 2 ;;
    --debug) [[ $# -eq 1 ]] || exit 2; CONFIGURATION=debug; APP_PATH="$PROJECT_DIR/build/debug/Oil Find.app" ;;
    *) printf '%s\n' 'Usage: scripts/build-app.sh [--debug]' >&2; exit 2 ;;
esac
BUILD_COMMAND=(swift build -c "$CONFIGURATION")
case "${OILFIND_BUILD_SYSTEM:-}" in
    '') ;;
    native|swiftbuild|xcode) BUILD_COMMAND+=(--build-system "$OILFIND_BUILD_SYSTEM") ;;
    *) printf '%s\n' 'OILFIND_BUILD_SYSTEM must be native, swiftbuild or xcode.' >&2; exit 2 ;;
esac
LOCAL_SIGNING_CONFIG="${OILFIND_LOCAL_SIGNING_CONFIG:-$HOME/Library/Application Support/Oil Find Signing/identity.plist}"
case "${OILFIND_REQUIRE_STABLE_SIGNING:-0}" in
    0|1) ;;
    *) printf '%s\n' 'OILFIND_REQUIRE_STABLE_SIGNING must be 0 or 1.' >&2; exit 2 ;;
esac
LOCAL_IDENTITY=''
LOCAL_KEYCHAIN=''
LOCAL_REQUIREMENT=''
if [[ -e "$LOCAL_SIGNING_CONFIG" && ( -z "${OILFIND_SIGN_IDENTITY:-}" || "${OILFIND_REQUIRE_STABLE_SIGNING:-0}" == 1 ) ]]; then
    LOCAL_IDENTITY=$(/usr/libexec/PlistBuddy -c 'Print :certificateSHA1' "$LOCAL_SIGNING_CONFIG")
    LOCAL_KEYCHAIN=$(/usr/libexec/PlistBuddy -c 'Print :keychainPath' "$LOCAL_SIGNING_CONFIG")
    [[ "$LOCAL_IDENTITY" =~ ^[[:xdigit:]]{40}$ && -f "$LOCAL_KEYCHAIN" ]] || {
        printf 'Invalid local signing configuration: %s\n' "$LOCAL_SIGNING_CONFIG" >&2; exit 1;
    }
    LOCAL_IDENTITY=$(printf '%s' "$LOCAL_IDENTITY" | tr '[:lower:]' '[:upper:]')
    identities=$(security find-identity -p codesigning "$LOCAL_KEYCHAIN")
    printf '%s\n' "$identities" | awk -v identity="$LOCAL_IDENTITY" '$2 == identity { found = 1 } END { exit !found }' || {
        printf '%s\n' 'The pinned local signing identity is unavailable; previous app is preserved.' >&2; exit 1;
    }
    if [[ -n "${OILFIND_SIGN_IDENTITY:-}" && "$OILFIND_SIGN_IDENTITY" != "$LOCAL_IDENTITY" ]]; then
        printf '%s\n' 'Explicit signing identity conflicts with the pinned local identity.' >&2; exit 1
    fi
    LOCAL_REQUIREMENT="identifier \"com.oiloil.find\" and certificate leaf = H\"$LOCAL_IDENTITY\""
elif [[ "${OILFIND_REQUIRE_STABLE_SIGNING:-0}" == 1 ]]; then
    printf 'Stable local signing is required. Configure it with scripts/create-signing-cert.sh --local (%s).\n' "$LOCAL_SIGNING_CONFIG" >&2
    exit 1
fi
"${BUILD_COMMAND[@]}"
BINARY_DIR="$("${BUILD_COMMAND[@]}" --show-bin-path)"
APP_PARENT="$(dirname "$APP_PATH")"
mkdir -p "$APP_PARENT"
STAGE_DIR="$(mktemp -d "$APP_PARENT/.oilfind-stage.XXXXXX")"
STAGED_APP="$STAGE_DIR/Oil Find.app"
PREVIOUS_APP="$STAGE_DIR/previous.app"
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    # Restore the previous bundle if promotion failed or was interrupted.
    if [[ -e "$PREVIOUS_APP" && ! -e "$APP_PATH" ]]; then
        if ! mv "$PREVIOUS_APP" "$APP_PATH"; then
            printf 'Could not restore previous app; retained at %s\n' "$PREVIOUS_APP" >&2
            exit 1
        fi
    fi
    rm -rf "$STAGE_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BINARY_DIR/OilFind" "$STAGED_APP/Contents/MacOS/OilFind"
if [[ "$CONFIGURATION" == release ]]; then
    # Release bundles omit debug symbols containing local source paths.
    strip -S "$STAGED_APP/Contents/MacOS/OilFind"
fi
cp "Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
fi
# Copy only resource bundles declared by the active package, including optional targets.
swift package describe --type json | python3 -c '
import json, pathlib, shutil, sys
package = json.load(sys.stdin)
binary, resources = map(pathlib.Path, sys.argv[1:])
for target in package["targets"]:
    if target.get("resources"):
        name = package["name"] + "_" + target["c99name"] + ".bundle"
        shutil.copytree(binary / name, resources / name)
' "$BINARY_DIR" "$STAGED_APP/Contents/Resources"
if [[ -n "$LOCAL_IDENTITY" ]]; then
    # Do not re-sign nested code: the cached service must retain its partition ID.
    key_service=$(scripts/prepare-key-service.sh "$LOCAL_IDENTITY" "$LOCAL_KEYCHAIN" "$(dirname "$LOCAL_SIGNING_CONFIG")")
    mkdir -p "$STAGED_APP/Contents/XPCServices"
    ditto "$key_service" "$STAGED_APP/Contents/XPCServices/OilFindClipboardKeyService.xpc"
    /usr/bin/plutil -insert OilFindUsesKeyService -bool true "$STAGED_APP/Contents/Info.plist"
fi
SELF_SIGNED="Oil Find Self-Signed"
if [[ -n "$LOCAL_IDENTITY" ]]; then
    codesign --force --sign "$LOCAL_IDENTITY" --keychain "$LOCAL_KEYCHAIN" --identifier com.oiloil.find \
        --timestamp=none --requirements "=designated => $LOCAL_REQUIREMENT" "$STAGED_APP"
elif [[ -n "${OILFIND_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$OILFIND_SIGN_IDENTITY" --identifier com.oiloil.find --options runtime --timestamp "$STAGED_APP"
elif security find-identity -v -p codesigning | grep -q "\"$SELF_SIGNED\""; then
    # Stable identity: macOS keeps Full Disk Access across updates. See scripts/create-signing-cert.sh.
    codesign --force --sign "$SELF_SIGNED" --identifier com.oiloil.find "$STAGED_APP"
else
    codesign --force --sign - --identifier com.oiloil.find "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"
if [[ -n "$LOCAL_REQUIREMENT" ]]; then
    codesign --verify --strict --test-requirement "=$LOCAL_REQUIREMENT" "$STAGED_APP"
fi
if [[ -e "$APP_PATH" ]]; then
    mv "$APP_PATH" "$PREVIOUS_APP"
fi
mv "$STAGED_APP" "$APP_PATH"
printf '%s\n' "$APP_PATH"
