#!/data/data/com.termux/files/usr/bin/bash

set -Eeuo pipefail
export PATH="$PREFIX/bin:$PATH"

# Configuration
readonly INSTALLER_PACKAGE="com.android.vending"

fail() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

log() {
    printf '\n[*] %s\n' "$*"
}

ok() {
    printf '[✓] %s\n' "$*"
}

# Validate arguments
if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    printf 'Usage: %s <package.name>\n' "$(basename "$0")" >&2
    exit 1
fi

readonly PACKAGE_NAME="$1"

if [[ ! "$PACKAGE_NAME" =~ ^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$ ]]; then
    fail "Invalid package name."
fi

command -v rish >/dev/null 2>&1 ||
    fail "rish was not found. Check your Shizuku setup."

# Check Shizuku/Rish
log "Checking Shizuku/Rish connection"

WHOAMI_OUTPUT="$(rish -c 'whoami' 2>&1)" || {
    printf '%s\n' "$WHOAMI_OUTPUT" >&2
    fail "Rish failed. Start Shizuku and authorize Termux."
}

printf '%s\n' "$WHOAMI_OUTPUT"

RISH_USER="$(printf '%s' "$WHOAMI_OUTPUT" | tr -d '\r\n')"

case "$RISH_USER" in
    shell|root)
        ok "Shizuku/Rish is working correctly."
        ;;
    *)
        fail "Unexpected Rish identity. Expected 'shell' or 'root'."
        ;;
esac

# Remote temporary directory
readonly REMOTE_DIR="/data/local/tmp/apk_extract_$$"
TMP_CREATED=0

cleanup() {
    if [ "$TMP_CREATED" -eq 1 ]; then
        log "Removing temporary APK files"
        if ! rish -c "rm -rf '$REMOTE_DIR'" >/dev/null 2>&1; then
            printf '[WARNING] Could not remove %s\n' "$REMOTE_DIR" >&2
        fi
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Create temporary directory
log "Creating temporary directory"

rish -c "mkdir -p '$REMOTE_DIR'" ||
    fail "Could not create the remote temporary directory."

TMP_CREATED=1

# Find installed APK paths
log "Finding APK files for $PACKAGE_NAME"

PATHS="$(rish -c "pm path '$PACKAGE_NAME'")" ||
    fail "Could not query installed APK paths."

[ -n "$PATHS" ] || fail "No APK files were found."

COUNT=0
FAILED=0

# Extract base APK and every split APK
while IFS= read -r LINE; do
    LINE="${LINE%$'\r'}"

    case "$LINE" in
        package:*)
            SRC="${LINE#package:}"
            NAME="${SRC##*/}"

            if [[ ! "$NAME" =~ ^[A-Za-z0-9_.-]+\.apk$ ]]; then
                printf '[ERROR] Unexpected APK filename.\n' >&2
                FAILED=$((FAILED + 1))
                continue
            fi

            log "Extracting $NAME"

            if rish -c \
                "cat '$SRC' > '$REMOTE_DIR/$NAME' &&
                 test -s '$REMOTE_DIR/$NAME'"; then
                ok "Extracted $NAME"
                COUNT=$((COUNT + 1))
            else
                printf '[ERROR] Failed to extract %s\n' "$NAME" >&2
                FAILED=$((FAILED + 1))
            fi
            ;;
    esac
done <<< "$PATHS"

printf '\nExtracted APK files: %s\n' "$COUNT"
printf 'Extraction errors: %s\n' "$FAILED"

[ "$COUNT" -gt 0 ] ||
    fail "No APK files were extracted."

[ "$FAILED" -eq 0 ] ||
    fail "Extraction was incomplete. Installation cancelled."

# Install through Package Manager sessions.
# This avoids relying on the unavailable pm install-multiple command.
log "Installing/updating $PACKAGE_NAME"

set +e
INSTALL_OUTPUT="$(rish -c "
set -eu

INSTALL_DIR='$REMOTE_DIR'
INSTALLER_PACKAGE='$INSTALLER_PACKAGE'
SESSION_ID=''

cleanup_remote() {
    if [ -n \"\$SESSION_ID\" ]; then
        cmd package install-abandon \"\$SESSION_ID\" >/dev/null 2>&1 || true
    fi
    rm -rf \"\$INSTALL_DIR\"
}
trap cleanup_remote EXIT

set -- \"\$INSTALL_DIR\"/*.apk

if [ ! -f \"\$1\" ]; then
    echo 'ERROR: No APK files found.' >&2
    exit 1
fi

TOTAL_SIZE=0

for apk do
    SIZE=\$(wc -c < \"\$apk\")
    TOTAL_SIZE=\$((TOTAL_SIZE + SIZE))
done

printf 'Preparing %s APK file(s)...\n' \"\$#\"

SESSION_OUTPUT=\$(cmd package install-create \
    -r -i \"\$INSTALLER_PACKAGE\" -S \"\$TOTAL_SIZE\") || {
    printf '%s\n' \"\$SESSION_OUTPUT\" >&2
    exit 1
}

printf '%s\n' \"\$SESSION_OUTPUT\"

SESSION_ID=\$(printf '%s\n' \"\$SESSION_OUTPUT\" |
    sed -n 's/.*\\[\\([0-9][0-9]*\\)\\].*/\\1/p' |
    head -n 1)

if [ -z \"\$SESSION_ID\" ]; then
    echo 'ERROR: Could not obtain installation session ID.' >&2
    exit 1
fi

for apk do
    NAME=\$(basename \"\$apk\")
    SIZE=\$(wc -c < \"\$apk\")

    printf 'Writing %s...\n' \"\$NAME\"

    cmd package install-write \
        -S \"\$SIZE\" \"\$SESSION_ID\" \"\$NAME\" \"\$apk\"
done

cmd package install-commit \"\$SESSION_ID\"

# The session was committed successfully.
SESSION_ID=''
" 2>&1)"
INSTALL_STATUS=$?
set -e

printf '%s\n' "$INSTALL_OUTPUT"

if [ "$INSTALL_STATUS" -ne 0 ] ||
   ! printf '%s\n' "$INSTALL_OUTPUT" |
       grep -Eq '(^|[[:space:]])Success([[:space:]]|$)'; then
    fail "Installation failed. Package Manager did not report Success."
fi

ok "Package Manager reported a successful installation."

# Verify that the package is present
log "Verifying installed package"

VERIFY_OUTPUT="$(rish -c "pm path '$PACKAGE_NAME'" 2>&1)" || {
    printf '%s\n' "$VERIFY_OUTPUT" >&2
    fail "Could not verify the installed package."
}

printf '%s\n' "$VERIFY_OUTPUT" |
    grep -q '^package:' ||
    fail "Package verification failed."

ok "Package is installed: $PACKAGE_NAME"

# Display installer metadata when supported
INSTALLER_VERIFY="$(
    rish -c "pm get-installer '$PACKAGE_NAME'" 2>&1
)" || INSTALLER_VERIFY="Installer metadata unavailable"

printf 'Installer metadata: %s\n' "$INSTALLER_VERIFY"

ok "Process completed."
echo "Temporary files will be removed automatically."
