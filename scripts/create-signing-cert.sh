#!/bin/bash
# Configure a persistent local identity without changing certificate trust settings.
# --local leaves the private key only in the login keychain after temporary cleanup.
# The default mode exports an encrypted backup when creating a new identity.
set -euo pipefail
umask 077

NAME="Oil Find Self-Signed"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KEYCHAIN="${OILFIND_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
CONFIG="${OILFIND_LOCAL_SIGNING_CONFIG:-$HOME/Library/Application Support/Oil Find Signing/identity.plist}"
BACKUP_DIR="$HOME/Documents/Oil Find Signing"
P12="$BACKUP_DIR/oil-find-signing.p12"
EXPORT_BACKUP=1
case "${1:-}" in
    '') [[ $# == 0 ]] || exit 2 ;;
    --local) [[ $# == 1 ]] || exit 2; EXPORT_BACKUP=0 ;;
    *) printf '%s\n' 'Usage: scripts/create-signing-cert.sh [--local]' >&2; exit 2 ;;
esac
[[ -f "$KEYCHAIN" ]] || { printf 'Signing keychain is unavailable: %s\n' "$KEYCHAIN" >&2; exit 1; }
KEYCHAIN="$(cd "$(dirname "$KEYCHAIN")" && pwd -P)/$(basename "$KEYCHAIN")"
CONFIG_DIR=$(dirname "$CONFIG")
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
CONFIG_DIR=$(cd "$CONFIG_DIR" && pwd -P)
CONFIG="$CONFIG_DIR/$(basename "$CONFIG")"
# The open descriptor holds the lock until this shell exits, including SIGKILL.
exec 9>"$CONFIG_DIR/.configure.lock"
/usr/bin/lockf -s -t 0 9 || { printf '%s\n' 'Another signing configuration is in progress.' >&2; exit 1; }
# A killed process cannot run its trap; reclaim only this configuration's work.
if [[ -e "$CONFIG_DIR/.configure-work" || -L "$CONFIG_DIR/.configure-work" ]]; then
    [[ -d "$CONFIG_DIR/.configure-work" && ! -L "$CONFIG_DIR/.configure-work" ]] || {
        printf '%s\n' 'Unexpected signing work path; it was not removed.' >&2; exit 1;
    }
    rm -rf "$CONFIG_DIR/.configure-work"
fi
WORK=''
STAGED_CONFIG=''
STAGED_BACKUP=''
BACKUP_CREATED=0
restore_backup_message() {
    printf 'Encrypted signing backup retained: %s\nRestore this same identity before retrying:\n' "$P12" >&2
    printf '  security import %q -k %q -T /usr/bin/codesign\n' "$P12" "$KEYCHAIN" >&2
}
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi
    if [[ -n "$STAGED_CONFIG" ]]; then rm -f "$STAGED_CONFIG"; fi
    if [[ -n "$STAGED_BACKUP" ]]; then rm -f "$STAGED_BACKUP"; fi
    if [[ $status -ne 0 && $BACKUP_CREATED == 1 ]]; then restore_backup_message; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

identity_exists() {
    security find-identity -p codesigning "$KEYCHAIN" | awk -v identity="$1" \
        '$2 == identity { found = 1 } END { exit !found }'
}
existing_backup_status() {
    if [[ $EXPORT_BACKUP == 1 ]]; then
        if [[ -f "$P12" ]]; then
            printf 'Existing encrypted backup was not changed: %s\n' "$P12"
        else
            printf '%s\n' 'Existing identity reused; no encrypted backup was created. Back up this identity in Keychain Access if needed.'
        fi
    fi
}
save_configuration() {
    STAGED_CONFIG=$(mktemp "$CONFIG_DIR/.identity.XXXXXX")
    /usr/bin/plutil -create xml1 "$STAGED_CONFIG"
    /usr/bin/plutil -insert version -integer 1 "$STAGED_CONFIG"
    /usr/bin/plutil -insert certificateSHA1 -string "$1" "$STAGED_CONFIG"
    /usr/bin/plutil -insert keychainPath -string "$KEYCHAIN" "$STAGED_CONFIG"
    chmod 600 "$STAGED_CONFIG"
    mv "$STAGED_CONFIG" "$CONFIG"
    STAGED_CONFIG=''
    printf 'Stable local signing configured: %s\nCertificate SHA-1: %s\n' "$CONFIG" "$1"
}
if [[ -e "$CONFIG" ]]; then
    pinned=$(/usr/libexec/PlistBuddy -c 'Print :certificateSHA1' "$CONFIG")
    configured_keychain=$(/usr/libexec/PlistBuddy -c 'Print :keychainPath' "$CONFIG")
    [[ "$pinned" =~ ^[[:xdigit:]]{40}$ && "$configured_keychain" == "$KEYCHAIN" ]] || {
        printf '%s\n' 'Existing signing configuration is invalid; it was not replaced.' >&2; exit 1;
    }
    pinned=$(printf '%s' "$pinned" | tr '[:lower:]' '[:upper:]')
    identity_exists "$pinned" || {
        printf '%s\n' 'The configured identity is missing; restore its private key instead of creating a replacement.' >&2; exit 1;
    }
    printf 'Stable local signing is already configured: %s\n' "$CONFIG"
    existing_backup_status
    exit 0
fi

# Keychain tracking needs a stable certificate requirement, not a global trust anchor.
existing=$(security find-identity -p codesigning "$KEYCHAIN" | awk -v name="\"$NAME\"" \
    'index($0, name) && length($2) == 40 { print $2 }' | sort -u)
if [[ -n "$existing" ]]; then
    [[ $(printf '%s\n' "$existing" | wc -l | tr -d ' ') == 1 ]] || {
        printf '%s\n' 'Multiple local signing identities exist; select one explicitly before configuring.' >&2; exit 1;
    }
    save_configuration "$existing"
    existing_backup_status
    exit 0
fi
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    printf '%s\n' 'A signing certificate exists without its private key; restore the key before continuing.' >&2
    exit 1
fi
if [[ -e "$P12" ]]; then
    restore_backup_message
    exit 1
fi
if [[ $EXPORT_BACKUP == 1 ]]; then
    printf 'An encrypted signing backup will be saved to: %s\n' "$P12"
    read -r -s -p 'Backup password (at least 8 characters): ' PASSWORD; printf '\n'
    read -r -s -p 'Repeat password: ' CONFIRM; printf '\n'
    [[ "$PASSWORD" == "$CONFIRM" && ${#PASSWORD} -ge 8 ]] || {
        printf '%s\n' 'Passwords must match and contain at least 8 characters.' >&2; exit 1;
    }
fi

WORK="$CONFIG_DIR/.configure-work"
mkdir "$WORK"
cat > "$WORK/certificate.cnf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = Oil Find Self-Signed
[extensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -keyout "$WORK/private.pem" -out "$WORK/certificate.pem" -config "$WORK/certificate.cnf" 2>/dev/null
fingerprint=$(/usr/bin/openssl x509 -in "$WORK/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
[[ "$fingerprint" =~ ^[[:xdigit:]]{40}$ ]] || { printf '%s\n' 'Invalid generated certificate fingerprint.' >&2; exit 1; }
if [[ $EXPORT_BACKUP == 1 ]]; then
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    P12PASS="$PASSWORD" /usr/bin/openssl pkcs12 -export -inkey "$WORK/private.pem" -in "$WORK/certificate.pem" \
        -name "$NAME" -out "$WORK/backup.p12" -passout env:P12PASS
    STAGED_BACKUP=$(mktemp "$BACKUP_DIR/.oil-find-signing.XXXXXXXX")
    if ! cp "$WORK/backup.p12" "$STAGED_BACKUP" || ! mv "$STAGED_BACKUP" "$P12"; then
        rm -f "$STAGED_BACKUP"
        exit 1
    fi
    BACKUP_CREATED=1
    STAGED_BACKUP=''
    unset PASSWORD CONFIRM
fi
# The transport password is read from a private file, never passed in arguments.
# Only Apple's codesign tool is trusted by the new signing key's initial ACL.
/usr/bin/openssl rand -hex 32 > "$WORK/password"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/private.pem" -in "$WORK/certificate.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "file:$WORK/password"
/usr/bin/xcrun swiftc -swift-version 5 "$SCRIPT_DIR/import-signing-identity.swift" -o "$WORK/import-identity"
"$WORK/import-identity" "$KEYCHAIN" "$WORK/identity.p12" "$WORK/password"
rm -f "$WORK/private.pem" "$WORK/identity.p12" "$WORK/password"
identity_exists "$fingerprint" || { printf '%s\n' 'Imported signing identity is unavailable.' >&2; exit 1; }
save_configuration "$fingerprint"
printf '%s\n' 'No trust settings, keychain search lists, or clipboard-key access rules were changed.'
