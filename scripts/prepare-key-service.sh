#!/bin/bash
# Cache the signed key service so ordinary app updates retain its CDHash partition.
set -euo pipefail
umask 077
[[ $# == 3 ]] || { printf '%s\n' 'Usage: prepare-key-service.sh CERTIFICATE_SHA1 KEYCHAIN SIGNING_DIRECTORY' >&2; exit 2; }
certificate=$1
keychain=$2
signing_directory=$3
[[ "$certificate" =~ ^[[:xdigit:]]{40}$ && -f "$keychain" && -d "$signing_directory" ]] || exit 1
certificate=$(printf '%s' "$certificate" | tr '[:lower:]' '[:upper:]')
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
identifier='com.oiloil.find.clipboard-key-service'
bundle_name='OilFindClipboardKeyService.xpc'
cache="$signing_directory/clipboard-key-service"
receipt="$signing_directory/key-service-identity.plist"
service="$cache/$bundle_name"
shared_source="$repo/Sources/OilFindApp/ClipboardKeyAccess.swift"
service_source="$repo/scripts/clipboard-key-service.swift"
source_digest=$(shasum -a 256 "$shared_source" "$service_source" | awk '{print $1}' | shasum -a 256 | awk '{print $1}')
requirement="identifier \"$identifier\" and certificate leaf = H\"$certificate\""
exec 9>"$signing_directory/.key-service.lock"
/usr/bin/lockf -s -t 0 9 || { printf '%s\n' 'Another key-service build is in progress.' >&2; exit 1; }

verify_cache() {
    local stored_certificate stored_source stored_executable actual_executable
    [[ -d "$service" && -f "$cache/manifest.plist" ]] || return 1
    stored_certificate=$(/usr/libexec/PlistBuddy -c 'Print :certificateSHA1' "$cache/manifest.plist")
    stored_source=$(/usr/libexec/PlistBuddy -c 'Print :sourceSHA256' "$cache/manifest.plist")
    stored_executable=$(/usr/libexec/PlistBuddy -c 'Print :executableSHA256' "$cache/manifest.plist")
    actual_executable=$(shasum -a 256 "$service/Contents/MacOS/OilFindClipboardKeyService" | awk '{print $1}')
    [[ "$stored_certificate" == "$certificate" && "$stored_source" == "$source_digest" && "$stored_executable" == "$actual_executable" ]] || return 1
    [[ "$source_digest" == "$(/usr/libexec/PlistBuddy -c 'Print :OilFindKeyServiceSourceSHA256' "$service/Contents/Info.plist")" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :XPCService:JoinExistingSession' "$service/Contents/Info.plist")" == true ]] || return 1
    codesign --verify --deep --strict --test-requirement "=$requirement" "$service"
}
pin_service_identity() {
    if [[ -e "$receipt" ]]; then
        cmp -s "$receipt" "$cache/manifest.plist"
    else
        # Publish a receipt outside the cache so accidental cache loss cannot
        # silently generate a new keychain partition on the next app update.
        local staged_receipt
        staged_receipt=$(mktemp "$signing_directory/.key-service-identity.XXXXXXXX") || return 1
        if ! cp "$cache/manifest.plist" "$staged_receipt" || ! chmod 600 "$staged_receipt" \
            || ! mv "$staged_receipt" "$receipt"; then
            rm -f "$staged_receipt"
            return 1
        fi
    fi
}
if [[ -e "$cache" ]]; then
    if ! verify_cache || ! pin_service_identity; then
        printf '%s\n' 'The fixed key-service cache is invalid or its source changed; previous app and service are preserved. An explicit service migration is required.' >&2
        exit 1
    fi
    printf '%s\n' "$service"
    exit 0
fi
if [[ -e "$receipt" ]]; then
    printf '%s\n' 'The enrolled key-service cache is missing; it must be restored or explicitly migrated, not rebuilt during an app update.' >&2
    exit 1
fi

stage=$(mktemp -d "$signing_directory/.key-service-stage.XXXXXXXX")
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    rm -rf "$stage"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
staged_service="$stage/$bundle_name"
mkdir -p "$staged_service/Contents/MacOS"
architecture=$(uname -m)
case "$architecture" in arm64|x86_64) ;; *) exit 1 ;; esac
/usr/bin/xcrun swiftc -O -swift-version 5 -target "$architecture-apple-macosx14.0" -parse-as-library \
    "$shared_source" "$service_source" -o "$staged_service/Contents/MacOS/OilFindClipboardKeyService" >&2
strip -S "$staged_service/Contents/MacOS/OilFindClipboardKeyService"
cat > "$staged_service/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.oiloil.find.clipboard-key-service</string>
<key>CFBundleExecutable</key><string>OilFindClipboardKeyService</string>
<key>CFBundleName</key><string>Oil Find Clipboard Key Service</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>XPCService</key><dict>
<key>ServiceType</key><string>Application</string>
<key>JoinExistingSession</key><true/>
</dict>
</dict></plist>
PLIST
/usr/bin/plutil -insert OilFindKeyServiceSourceSHA256 -string "$source_digest" "$staged_service/Contents/Info.plist"
codesign --force --sign "$certificate" --keychain "$keychain" --identifier "$identifier" \
    --timestamp=none --requirements "=designated => $requirement" "$staged_service" >&2
codesign --verify --deep --strict --test-requirement "=$requirement" "$staged_service" >&2
executable_digest=$(shasum -a 256 "$staged_service/Contents/MacOS/OilFindClipboardKeyService" | awk '{print $1}')
/usr/bin/plutil -create xml1 "$stage/manifest.plist"
/usr/bin/plutil -insert certificateSHA1 -string "$certificate" "$stage/manifest.plist"
/usr/bin/plutil -insert sourceSHA256 -string "$source_digest" "$stage/manifest.plist"
/usr/bin/plutil -insert executableSHA256 -string "$executable_digest" "$stage/manifest.plist"
chmod 600 "$stage/manifest.plist"
mv "$stage" "$cache"
pin_service_identity || {
    printf '%s\n' 'The key service was preserved but its identity receipt could not be saved; app build stopped.' >&2
    exit 1
}
printf '%s\n' "$service"
