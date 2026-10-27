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

# Parse arguments
SHELL_MODE="rish"
ADB_SERIAL=""
PACKAGE_NAME=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --shell=adb) SHELL_MODE="adb"; shift ;;
        --shell=rish) SHELL_MODE="rish"; shift ;;
        --shell)
            [ "$#" -ge 2 ] || { printf 'Usage: %s [--shell=adb|rish] [-s serial] <package.name>\n' "$(basename "$0")" >&2; exit 1; }
            case "$2" in
                adb|rish) SHELL_MODE="$2" ;;
                *) fail "Invalid shell mode: $2. Use adb or rish." ;;
            esac
            shift 2
            ;;
        -s)
            [ "$#" -ge 2 ] || fail "Option -s requires an ADB device serial."
            ADB_SERIAL="$2"
            shift 2
            ;;
        --help|-h)
            printf 'Usage: %s [--shell=adb|rish] [-s serial] <package.name>\n' "$(basename "$0")"
            printf 'Examples:\n  %s --shell=rish com.example.app\n  %s --shell=adb com.example.app\n  %s --shell=adb -s 127.0.0.1:5555 com.example.app\n' "$(basename "$0")" "$(basename "$0")" "$(basename "$0")"
            exit 0
            ;;
        -*) fail "Unknown option: $1" ;;
        *)
            [ -z "$PACKAGE_NAME" ] || fail "Only one package name may be provided."
            PACKAGE_NAME="$1"
            shift
            ;;
    esac
done

[ -n "$PACKAGE_NAME" ] || {
    printf 'Usage: %s [--shell=adb|rish] [-s serial] <package.name>\n' "$(basename "$0")" >&2
    exit 1
}
[ "$SHELL_MODE" = "adb" ] || [ -z "$ADB_SERIAL" ] || fail "Option -s can only be used with --shell=adb."
if [ -n "$ADB_SERIAL" ] && [[ ! "$ADB_SERIAL" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    fail "Invalid ADB serial. Use the serial shown by 'adb devices'."
fi
readonly PACKAGE_NAME SHELL_MODE ADB_SERIAL

if [[ ! "$PACKAGE_NAME" =~ ^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$ ]]; then
    fail "Invalid package name."
fi

if [ "$SHELL_MODE" = "adb" ]; then
    command -v adb >/dev/null 2>&1 || fail "adb was not found. Install Android Platform Tools and ensure adb is on PATH."
else
    command -v rish >/dev/null 2>&1 || fail "rish was not found. Check your Shizuku setup."
fi

remote_exec() {
    local output status
    if [ "$SHELL_MODE" = "adb" ]; then
        if [ -n "$ADB_SERIAL" ]; then
            if output="$(adb -s "$ADB_SERIAL" shell "$1" 2>&1)"; then status=0; else status=$?; fi
        else
            if output="$(adb shell "$1" 2>&1)"; then status=0; else status=$?; fi
        fi
    else
        if output="$(rish -c "$1" 2>&1)"; then status=0; else status=$?; fi
    fi
    [ -z "$output" ] || printf '%s\n' "$output"
    if [ "$status" -ne 0 ]; then
        if printf '%s\n' "$output" | grep -Fq 'adb: more than one device/emulator'; then
            printf '\n[ERROR] Multiple ADB devices or emulators detected.\n' >&2
            printf "Tip: Run 'adb devices' to list available devices, then rerun with '-s <serial>'.\n" >&2
            printf 'Example: bash %s --shell=adb -s 127.0.0.1:5555 %s\n' "$(basename "$0")" "$PACKAGE_NAME" >&2
            printf 'Exiting.\n' >&2
        fi
        return "$status"
    fi
}

if [ "$SHELL_MODE" = "adb" ]; then
    log "Checking ADB shell connection"
    ADB_CHECK_OUTPUT="$(remote_exec 'id')" || fail "Could not run a command through ADB shell. Check the device connection and authorization."
    ok "ADB shell is working."
fi

# Check Shizuku/Rish
log "Checking Shizuku/Rish connection"

WHOAMI_OUTPUT="$(remote_exec 'whoami' 2>&1)" || {
    printf '%s\n' "$WHOAMI_OUTPUT" >&2
    fail "Rish failed. Start Shizuku and authorize Termux."
}

printf '%s\n' "$WHOAMI_OUTPUT"

RISH_USER="$(printf '%s\n' "$WHOAMI_OUTPUT" | awk '
    /^[[:space:]]*(shell|root)[[:space:]]*$/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        print
        exit
    }
')"

if [ "$RISH_USER" != "shell" ] && [ "$RISH_USER" != "root" ]; then
    fail "Rish output did not contain a standalone 'shell' or 'root' line. Output was: $WHOAMI_OUTPUT"
fi

ok "Shizuku/Rish is working correctly (identity: $RISH_USER)."

# Remote temporary directory
readonly REMOTE_DIR="/data/local/tmp/apk_extract_$$"
TMP_CREATED=0

cleanup() {
    if [ "$TMP_CREATED" -eq 1 ]; then
        log "Removing temporary APK files"
        if ! remote_exec "rm -rf '$REMOTE_DIR'" >/dev/null 2>&1; then
            printf '[WARNING] Could not remove %s\n' "$REMOTE_DIR" >&2
        fi
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Create temporary directory
log "Creating temporary directory"

remote_exec "mkdir -p '$REMOTE_DIR'" ||
    fail "Could not create the remote temporary directory."

TMP_CREATED=1

# Find installed APK paths. Preserve and validate every package: line.
log "Finding APK files for $PACKAGE_NAME"

PATHS="$(remote_exec "pm path '$PACKAGE_NAME'")" ||
    fail "Could not query installed APK paths."

[ -n "$PATHS" ] || fail "No APK files were found."

EXPECTED_COUNT="$(printf '%s\n' "$PATHS" | grep -c '^package:' || true)"
[ "$EXPECTED_COUNT" -gt 0 ] || fail "Package Manager returned no APK paths."

COUNT=0
FAILED=0

# Extract the base APK and every split APK.
for LINE in $PATHS; do
    LINE="${LINE%$'\r'}"

    case "$LINE" in
        package:*)
            SRC="${LINE#package:}"
            NAME="${SRC##*/}"

            if [[ ! "$NAME" =~ ^[A-Za-z0-9_.-]+\.apk$ ]]; then
                printf '[ERROR] Unexpected APK filename: %s\n' "$NAME" >&2
                FAILED=$((FAILED + 1))
                continue
            fi

            log "Extracting $NAME"

            if remote_exec "cat '$SRC' > '$REMOTE_DIR/$NAME' && test -s '$REMOTE_DIR/$NAME'" </dev/null; then
                ok "Extracted $NAME"
                COUNT=$((COUNT + 1))
            else
                printf '[ERROR] Failed to extract %s\n' "$NAME" >&2
                FAILED=$((FAILED + 1))
            fi
            ;;
        *)
            if [ -n "$LINE" ]; then
                printf '[WARNING] Ignoring unexpected Package Manager output: %s\n' "$LINE" >&2
            fi
            ;;
    esac
done

printf '\nAPK paths reported: %s\n' "$EXPECTED_COUNT"
printf 'APK files extracted: %s\n' "$COUNT"
printf 'Extraction errors: %s\n' "$FAILED"

[ "$COUNT" -gt 0 ] || fail "No APK files were extracted."
[ "$FAILED" -eq 0 ] || fail "Extraction was incomplete. Installation cancelled."

# Independently verify that every reported APK was copied.
ACTUAL_COUNT="$(remote_exec "find '$REMOTE_DIR' -maxdepth 1 -type f -name '*.apk' | wc -l" | tr -d '[:space:]')"

[ "$ACTUAL_COUNT" = "$EXPECTED_COUNT" ] ||
    fail "APK count mismatch: Package Manager reported $EXPECTED_COUNT, but $ACTUAL_COUNT file(s) were extracted. Installation cancelled."

ok "All $ACTUAL_COUNT APK file(s), including splits, are ready."

# Install through Package Manager sessions.
log "Installing/updating $PACKAGE_NAME"

set +e
INSTALL_OUTPUT="$(remote_exec "
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

SESSION_OUTPUT=\$(cmd package install-create -r -i \"\$INSTALLER_PACKAGE\" -S \"\$TOTAL_SIZE\") || {
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

    cmd package install-write -S \"\$SIZE\" \"\$SESSION_ID\" \"\$NAME\" \"\$apk\"
done

cmd package install-commit \"\$SESSION_ID\"

# Commit succeeded; do not abandon the completed session.
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

VERIFY_OUTPUT="$(remote_exec "pm path '$PACKAGE_NAME'" 2>&1)" || {
    printf '%s\n' "$VERIFY_OUTPUT" >&2
    fail "Could not verify the installed package."
}

printf '%s\n' "$VERIFY_OUTPUT" |
    grep -q '^package:' ||
    fail "Package verification failed."

ok "Package is installed: $PACKAGE_NAME"

# Installer metadata lookup is not supported by every Android pm implementation.
INSTALLER_VERIFY="$(remote_exec "pm get-installer '$PACKAGE_NAME'" 2>&1 || true)"
if printf '%s\n' "$INSTALLER_VERIFY" | grep -q 'Unknown command'; then
    echo "Installer metadata lookup is not supported by this device; skipping."
else
    printf 'Installer metadata: %s\n' "$INSTALLER_VERIFY"
fi

ok "Process completed."
echo "Temporary files will be removed automatically."
