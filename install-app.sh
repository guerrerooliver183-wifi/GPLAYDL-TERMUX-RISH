#!/data/data/com.termux/files/usr/bin/bash

# PHASE 2: download and install any configured package.
# Requires phase one to have configured gplaydl. Rish is optional when using ADB mode.
# Usage: ./gplay-installer.sh <PACKAGE_NAME>

set -Eeuo pipefail

# Temporary PATH: does not modify ~/.bashrc or permanent configuration.
export PATH="$PREFIX/bin:$PATH"

DEFAULT_SHELL_MODE="rish"
DEFAULT_ADB_SERIAL=""
SHELL_MODE="$DEFAULT_SHELL_MODE"
ADB_SERIAL="$DEFAULT_ADB_SERIAL"
PACKAGE_NAME=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --shell=adb) SHELL_MODE="adb" ;;
        --shell=rish) SHELL_MODE="rish" ;;
        --shell) [ "$#" -ge 2 ] || { printf '[ERROR] Missing value for --shell.\n' >&2; exit 1; }; case "$2" in adb|rish) SHELL_MODE="$2" ;; *) printf '[ERROR] Invalid shell mode: %s\n' "$2" >&2; exit 1 ;; esac; shift ;;
        -s) [ "$#" -ge 2 ] && [ -n "$2" ] || { printf '[ERROR] Option -s requires an ADB serial.\n' >&2; exit 1; }; ADB_SERIAL="$2"; shift ;;
        --help|-h) printf 'Usage: %s [--shell=adb|rish] [-s serial] <package.name>\n' "$(basename "$0")"; exit 0 ;;
        -*) printf '[ERROR] Unknown option: %s\n' "$1" >&2; exit 1 ;;
        *) [ -z "$PACKAGE_NAME" ] || { printf '[ERROR] Only one package name may be supplied.\n' >&2; exit 1; }; PACKAGE_NAME="$1" ;;
    esac
    shift
done
[ -n "$PACKAGE_NAME" ] || { printf 'Usage: %s [--shell=adb|rish] [-s serial] <package.name>\n' "$(basename "$0")" >&2; exit 1; }
[ -z "$ADB_SERIAL" ] || [ "$SHELL_MODE" = "adb" ] || { printf '[ERROR] Option -s can only be used with --shell=adb.\n' >&2; exit 1; }
if [[ ! "$PACKAGE_NAME" =~ ^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$ ]]; then printf '[ERROR] Invalid package name.\n' >&2; exit 1; fi
readonly PACKAGE_NAME SHELL_MODE ADB_SERIAL
readonly INSTALLER_PACKAGE="com.android.vending"
readonly TEMP_DIR="$HOME/TEMP"
readonly APK_TRANSFER_DIR="$HOME/storage/shared/TEMP_GPLAYDL"

fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
log()  { printf '\n[*] %s\n' "$*"; }
ok()   { printf '[✓] %s\n' "$*"; }

remote_exec() {
    local command="$1" output status
    if [ "$SHELL_MODE" = "adb" ]; then
        if [ -n "$ADB_SERIAL" ]; then if output="$(adb -s "$ADB_SERIAL" shell "$command" 2>&1)"; then status=0; else status=$?; fi
        else if output="$(adb shell "$command" 2>&1)"; then status=0; else status=$?; fi; fi
        if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -Fq 'no devices/emulators found'; then
            printf '\n[ERROR] adb: no devices/emulators found. Connect and authorize a device, or specify -s <serial>. Exiting.\n' >&2
            return 1
        fi
        if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -Fq 'more than one device/emulator'; then
            printf '\n[ERROR] Multiple ADB devices or emulators detected.\nTip: Run "adb devices" and rerun with "--shell=adb -s <serial>".\nExample: %s --shell=adb -s 127.0.0.1:5555 com.example.app\nExiting.\n' "$(basename "$0")" >&2
            return 1
        fi
        [ -z "$output" ] || printf '%s\n' "$output"
        return "$status"
    fi
    rish -c "$command"
}

cleanup() {
    rm -rf -- "$TEMP_DIR" "$APK_TRANSFER_DIR"
}
trap cleanup EXIT

command -v gplaydl >/dev/null 2>&1 || fail "gplaydl was not found. Run the setup script first."
if [ "$SHELL_MODE" = "rish" ]; then command -v rish >/dev/null 2>&1 || fail "rish was not found. Run the setup script first."; else command -v adb >/dev/null 2>&1 || fail "adb was not found. Install Android platform-tools and ensure adb is in PATH."; fi

if [ "$SHELL_MODE" = "rish" ]; then
    log "Checking Shizuku/Rish"
    WHOAMI_OUTPUT="$(remote_exec 'whoami' 2>&1)" || { printf '%s\n' "$WHOAMI_OUTPUT"; fail "Rish failed. Start Shizuku and authorize Termux."; }
    RISH_IDENTITY="$(printf '%s\n' "$WHOAMI_OUTPUT" | awk '/^[[:space:]]*(shell|root)[[:space:]]*$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }')"
    if [ "$RISH_IDENTITY" != "shell" ] && [ "$RISH_IDENTITY" != "root" ]; then fail "Rish output did not contain a standalone 'shell' or 'root' line. Output was: $WHOAMI_OUTPUT"; fi
    ok "Shizuku/Rish is working correctly (identity: $RISH_IDENTITY)."
else
    log "Checking ADB connection"
    remote_exec 'whoami' >/dev/null || fail "ADB could not execute a shell command. Check that a device is connected and authorized."
    ok "ADB shell is working correctly."
fi

log "Downloading $PACKAGE_NAME with gplaydl"
rm -rf -- "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
gplaydl download "$PACKAGE_NAME" -o "$TEMP_DIR" || fail "gplaydl could not complete the download."

mapfile -d '' APK_FILES < <(find "$TEMP_DIR" -maxdepth 1 -type f -iname '*.apk' -print0)
[ "${#APK_FILES[@]}" -gt 0 ] || fail "The download finished, but no APK files were found."
ok "Found ${#APK_FILES[@]} APK file(s)."

log "Copying APK files to shared storage"
rm -rf -- "$APK_TRANSFER_DIR"
mkdir -p "$APK_TRANSFER_DIR"
for apk in "${APK_FILES[@]}"; do
    cp -f -- "$apk" "$APK_TRANSFER_DIR/"
done

mapfile -d '' TRANSFERRED_APKS < <(find "$APK_TRANSFER_DIR" -maxdepth 1 -type f -iname '*.apk' -print0)
[ "${#TRANSFERRED_APKS[@]}" -gt 0 ] || fail "Could not copy the APK files."
ok "Prepared ${#TRANSFERRED_APKS[@]} APK file(s) for installation."

if [ "$SHELL_MODE" = "adb" ]; then
    log "Installing APK splits through ADB"
    set +e
    if [ -n "$ADB_SERIAL" ]; then
        INSTALL_OUTPUT="$(adb -s "$ADB_SERIAL" install-multiple -r -i "$INSTALLER_PACKAGE" "${TRANSFERRED_APKS[@]}" 2>&1)"
    else
        INSTALL_OUTPUT="$(adb install-multiple -r -i "$INSTALLER_PACKAGE" "${TRANSFERRED_APKS[@]}" 2>&1)"
    fi
    INSTALL_STATUS=$?
    set -e
else
    log "Installing APK splits through Shizuku/Rish"
    set +e
    INSTALL_OUTPUT="$(remote_exec '
set -eu
SOURCE_DIR="/sdcard/TEMP_GPLAYDL"
INSTALL_DIR="/data/local/tmp/TEMP_GPLAYDL"
INSTALLER_PACKAGE="com.android.vending"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
set -- "$SOURCE_DIR"/*.apk
if [ "$#" -eq 0 ] || [ ! -f "$1" ]; then
    echo "No APK files were found in $SOURCE_DIR" >&2
    exit 1
fi
for apk do cp -f "$apk" "$INSTALL_DIR/"; done
set -- "$INSTALL_DIR"/*.apk
printf "Installing %s APK file(s)...\\n" "$#"
TOTAL_SIZE=0
for apk do
    SIZE=$(wc -c < "$apk")
    TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
done
SESSION_OUTPUT=$(cmd package install-create -r -i "$INSTALLER_PACKAGE" -S "$TOTAL_SIZE")
SESSION_ID=$(printf "%s\\n" "$SESSION_OUTPUT" | sed -n "s/.*\\[\\([0-9][0-9]*\\)\\].*/\\1/p")
[ -n "$SESSION_ID" ] || {
    printf "%s\\n" "$SESSION_OUTPUT" >&2
    echo "Could not create an installation session." >&2
    rm -rf "$INSTALL_DIR"
    exit 1
}
abandon_session() {
    cmd package install-abandon "$SESSION_ID" >/dev/null 2>&1 || true
    rm -rf "$INSTALL_DIR"
}
trap abandon_session EXIT
for apk do
    NAME=$(basename "$apk")
    SIZE=$(wc -c < "$apk")
    cmd package install-write -S "$SIZE" "$SESSION_ID" "$NAME" "$apk"
done
cmd package install-commit "$SESSION_ID"
trap - EXIT
rm -rf "$INSTALL_DIR"
' 2>&1)"
    INSTALL_STATUS=$?
    set -e
fi
printf '%s\\n' "$INSTALL_OUTPUT"
if [ "$INSTALL_STATUS" -ne 0 ] || ! printf '%s\\n' "$INSTALL_OUTPUT" | grep -Eq '(^|[[:space:]])Success([[:space:]]|$)'; then
    fail "APK installation failed. See the installer output above."
fi

log "Verifying the installation"
if ! remote_exec "pm path '$PACKAGE_NAME'" >/dev/null 2>&1; then
    fail "Installation failed or Android could not find the package."
fi

ok "Package installed successfully."
echo '[✓] Temporary files will be removed automatically.'