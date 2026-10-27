#!/data/data/com.termux/files/usr/bin/bash

# PHASE 1: prepare Termux, install/configure gplaydl, and configure Rish.
# At the end, create a second script to download and install
# ANY configured package through gplaydl + Shizuku/Rish.

set -Eeuo pipefail

# Temporary PATH: does not modify ~/.bashrc or permanent configuration.
export PATH="$PREFIX/bin:$PATH"

readonly SHELL_SCRIPT="install-app.sh"
readonly DEX_TARGET="$HOME/rish_shizuku.dex"
readonly RISH_BIN="$PREFIX/bin/rish"
readonly RISH_APPLICATION_ID="com.termux"

fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
log()  { printf '\n[*] %s\n' "$*"; }
ok()   { printf '[✓] %s\n' "$*"; }

# Select the remote execution backend before doing any setup work.
SHELL_MODE="rish"
ADB_SERIAL=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --shell=adb) SHELL_MODE="adb"; shift ;;
        --shell=rish) SHELL_MODE="rish"; shift ;;
        --shell)
            [ "$#" -ge 2 ] || fail "Option --shell requires 'adb' or 'rish'."
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
            printf 'Usage: %s [--shell=adb|rish] [-s serial]\n' "$(basename "$0")"
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done
[ "$SHELL_MODE" = "adb" ] || [ -z "$ADB_SERIAL" ] || fail "Option -s can only be used with --shell=adb."
if [ -n "$ADB_SERIAL" ] && [[ ! "$ADB_SERIAL" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    fail "Invalid ADB serial. Use the serial shown by 'adb devices'."
fi
readonly SHELL_MODE ADB_SERIAL

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' was not found."
}

log "Checking Termux"
require_command pkg

log "Updating repositories"
pkg update -y || fail "Could not update the repositories."

log "Installing dependencies"
pkg install -y python openssl clang || fail "Could not install the dependencies."
require_command python

log "Installing or updating gplaydl"
# Do not upgrade pip globally to avoid conflicts with the Termux package.
python -m pip install --upgrade gplaydl || fail "Could not install gplaydl."
require_command gplaydl
ok "gplaydl is available."

cat <<'EOF'

================================================================
 MANUAL GPLAYDL LINKING
================================================================

Do the following:
  1. Install and open gplaydl Authenticator on your phone.
  2. Add a secondary or disposable Google account.
  3. Open "Link gplaydl" in the app.
  4. Run the command below and enter the code:

     gplaydl link

The script will wait while you complete this process.
EOF

if ! gplaydl link; then
    fail "gplaydl linking did not complete successfully."
fi
ok "gplaydl was linked successfully."

log "Requesting storage access"
require_command termux-setup-storage
termux-setup-storage
sleep 1

if [ "$SHELL_MODE" = "rish" ]; then
# Accept the usual Shizuku export paths.
SHIZUKU_DIR=""
for candidate in \
    "$HOME/storage/shared/Shizuku" \
    "/sdcard/Shizuku" \
    "$HOME/storage/shared/rish" \
    "/sdcard/rish"; do
    if [ -d "$candidate" ]; then
        SHIZUKU_DIR="$candidate"
        break
    fi
done

[ -n "$SHIZUKU_DIR" ] || fail "The Shizuku export directory was not found. Export rish and rish_shizuku.dex from 'Shizuku > Use Shizuku in terminal apps > Export files' to a folder named Shizuku or rish."

RISH_SOURCE=""
DEX_SOURCE=""
while IFS= read -r -d '' file; do
    [ "$(basename "$file")" = "rish" ] && RISH_SOURCE="$file"
done < <(find "$SHIZUKU_DIR" -type f -name rish -print0 2>/dev/null)
while IFS= read -r -d '' file; do
    [ "$(basename "$file")" = "rish_shizuku.dex" ] && DEX_SOURCE="$file"
done < <(find "$SHIZUKU_DIR" -type f -name rish_shizuku.dex -print0 2>/dev/null)

[ -n "$RISH_SOURCE" ] || fail "The Rish file exported by Shizuku was not found."
[ -n "$DEX_SOURCE" ] || fail "The exported rish_shizuku.dex was not found."
ok "Shizuku files found in $SHIZUKU_DIR"

log "Installing Rish"
mkdir -p "$PREFIX/bin"

# Store the DEX in Termux's private directory and make it non-writable.
cp -f -- "$DEX_SOURCE" "$DEX_TARGET" || fail "Could not copy rish_shizuku.dex."
chmod 400 "$DEX_TARGET" || fail "Could not set the DEX permissions."

# Explicit wrapper: Rish always uses the correct private DEX even if the
# exported rish file looks for the DEX next to the executable.
cat > "$RISH_BIN" <<'RISH_WRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
set -e
DEX="$HOME/rish_shizuku.dex"
[ -r "$DEX" ] || { echo "$DEX was not found" >&2; exit 1; }
export RISH_APPLICATION_ID="com.termux"
exec /system/bin/app_process -Djava.class.path="$DEX" /system/bin --nice-name=rish rikka.shizuku.shell.ShizukuShellLoader "$@"
RISH_WRAPPER
chmod 700 "$RISH_BIN" || fail "Could not make rish executable."
export RISH_APPLICATION_ID
hash -r 2>/dev/null || true
require_command rish

cat <<'EOF'

================================================================
 SHIZUKU CHECK
================================================================

Make sure Shizuku is running and Termux has been authorized.
EOF

WHOAMI_OUTPUT="$(rish -c 'whoami' 2>&1)" || {
    printf '%s\n' "$WHOAMI_OUTPUT"
    fail "Rish could not execute commands. Make sure Shizuku is running and Termux is authorized."
}
printf '%s\n' "$WHOAMI_OUTPUT"
# Rish may print an authorization notice before the actual identity.
# Accept only a complete line that is exactly "shell" or "root", ignoring
# surrounding whitespace; do not match those words inside unrelated messages.
RISH_IDENTITY="$(printf '%s\n' "$WHOAMI_OUTPUT" | awk '
    /^[[:space:]]*(shell|root)[[:space:]]*$/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        print
        exit
    }
')"
if [ "$RISH_IDENTITY" != "shell" ] && [ "$RISH_IDENTITY" != "root" ]; then
    fail "Rish output did not contain a standalone 'shell' or 'root' line. Output was: $WHOAMI_OUTPUT"
fi
ok "Shizuku/Rish is working correctly (identity: $RISH_IDENTITY)."
ok "Shizuku/Rish is working correctly."

else
    require_command adb
    log "Checking ADB shell connection"
    if [ -n "$ADB_SERIAL" ]; then
        if ADB_CHECK_OUTPUT="$(adb -s "$ADB_SERIAL" shell id 2>&1)"; then
            :
        else
            ADB_CHECK_STATUS=$?
            printf '%s\n' "$ADB_CHECK_OUTPUT" >&2
            if printf '%s\n' "$ADB_CHECK_OUTPUT" | grep -Fq 'adb: more than one device/emulator'; then
                printf "[ERROR] Multiple ADB devices or emulators detected.\n" >&2
                printf "Tip: Run 'adb devices' to list devices, then rerun with '-s <serial>'.\n" >&2
                printf 'Exiting.\n' >&2
            fi
            fail "Could not run a command through ADB shell. Check the device connection and authorization (exit status: $ADB_CHECK_STATUS)."
        fi
    else
        if ADB_CHECK_OUTPUT="$(adb shell id 2>&1)"; then
            :
        else
            ADB_CHECK_STATUS=$?
            printf '%s\n' "$ADB_CHECK_OUTPUT" >&2
            if printf '%s\n' "$ADB_CHECK_OUTPUT" | grep -Fq 'adb: more than one device/emulator'; then
                printf "[ERROR] Multiple ADB devices or emulators detected.\n" >&2
                printf "Tip: Run 'adb devices' to list devices, then rerun with '-s <serial>'.\n" >&2
                printf 'Exiting.\n' >&2
            fi
            fail "Could not run a command through ADB shell. Check the device connection and authorization (exit status: $ADB_CHECK_STATUS)."
        fi
    fi
    printf '%s\n' "$ADB_CHECK_OUTPUT"
    ok "ADB shell is working. Shizuku checks were skipped."
fi

# Create phase two; it remains available for future runs as a universal installer.
log "Creating $SHELL_SCRIPT"
cat > "$HOME/$SHELL_SCRIPT" <<'GENERATED_SCRIPT'
#!/data/data/com.termux/files/usr/bin/bash

# PHASE 2: download and install any configured package.
# Requires phase one to have configured gplaydl and Rish first.
# Usage: ./gplay-installer.sh <PACKAGE_NAME>

set -Eeuo pipefail

# Temporary PATH: does not modify ~/.bashrc or permanent configuration.
export PATH="$PREFIX/bin:$PATH"

readonly DEFAULT_SHELL_MODE="__DEFAULT_SHELL_MODE__"
readonly DEFAULT_ADB_SERIAL="__DEFAULT_ADB_SERIAL__"
SHELL_MODE="$DEFAULT_SHELL_MODE"
ADB_SERIAL=""
if [ "$DEFAULT_SHELL_MODE" = "adb" ]; then ADB_SERIAL="$DEFAULT_ADB_SERIAL"; fi
PACKAGE_NAME=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --shell=adb) SHELL_MODE="adb"; ADB_SERIAL=""; shift ;;
        --shell=rish) SHELL_MODE="rish"; ADB_SERIAL=""; shift ;;
        --shell)
            [ "$#" -ge 2 ] || { printf 'Usage: %s [--shell=adb|rish] [-s serial] <package.name>\n' "$(basename "$0")" >&2; exit 1; }
            case "$2" in
                adb) SHELL_MODE="adb"; ADB_SERIAL="" ;;
                rish) SHELL_MODE="rish"; ADB_SERIAL="" ;;
                *) printf '[ERROR] Invalid shell mode: %s. Use adb or rish.\n' "$2" >&2; exit 1 ;;
            esac
            shift 2
            ;;
        -s)
            [ "$#" -ge 2 ] || { printf '[ERROR] Option -s requires an ADB device serial.\n' >&2; exit 1; }
            ADB_SERIAL="$2"
            shift 2
            ;;
        --help|-h)
            printf 'Usage: %s [--shell=adb|rish] [-s serial] <package.name>\n' "$(basename "$0")"
            exit 0
            ;;
        -*) printf '[ERROR] Unknown option: %s\n' "$1" >&2; exit 1 ;;
        *)
            [ -z "$PACKAGE_NAME" ] || { printf '[ERROR] Only one package name may be provided.\n' >&2; exit 1; }
            PACKAGE_NAME="$1"
            shift
            ;;
    esac
done
[ -n "$PACKAGE_NAME" ] || { printf 'Usage: %s [--shell=adb|rish] [-s serial] <package.name>\n' "$(basename "$0")" >&2; exit 1; }
[ "$SHELL_MODE" = "adb" ] || [ -z "$ADB_SERIAL" ] || { printf '[ERROR] Option -s can only be used with --shell=adb.\n' >&2; exit 1; }
if [ -n "$ADB_SERIAL" ] && [[ ! "$ADB_SERIAL" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    printf '[ERROR] Invalid ADB serial. Use the serial shown by adb devices.\n' >&2; exit 1
fi
readonly PACKAGE_NAME SHELL_MODE ADB_SERIAL
readonly INSTALLER_PACKAGE="com.android.vending"
readonly TEMP_DIR="$HOME/TEMP"
readonly APK_TRANSFER_DIR="$HOME/storage/shared/TEMP_GPLAYDL"

fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
log()  { printf '\n[*] %s\n' "$*"; }
ok()   { printf '[✓] %s\n' "$*"; }

cleanup() {
    rm -rf -- "$TEMP_DIR" "$APK_TRANSFER_DIR"
}
trap cleanup EXIT

command -v gplaydl >/dev/null 2>&1 || fail "gplaydl was not found. Run the setup script first."
if [ "$SHELL_MODE" = "adb" ]; then
    command -v adb >/dev/null 2>&1 || fail "adb was not found. Install Android Platform Tools and ensure adb is on PATH."
else
    command -v rish >/dev/null 2>&1 || fail "rish was not found. Run the setup script with --shell=rish first."
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
            printf 'Exiting.\n' >&2
        fi
        return "$status"
    fi
}

if [ "$SHELL_MODE" = "adb" ]; then
    remote_exec 'id' || fail "ADB shell check failed. Check device connection and authorization."
}

log "Checking Shizuku/Rish"
WHOAMI_OUTPUT="$(remote_exec 'whoami' 2>&1)" || {
    printf '%s\n' "$WHOAMI_OUTPUT"
    fail "Rish failed. Start Shizuku and authorize Termux."
}
# Rish may print an authorization notice before the actual identity.
# Accept only a complete line that is exactly "shell" or "root", ignoring
# surrounding whitespace; do not match those words inside unrelated messages.
RISH_IDENTITY="$(printf '%s\n' "$WHOAMI_OUTPUT" | awk '
    /^[[:space:]]*(shell|root)[[:space:]]*$/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        print
        exit
    }
')"
if [ "$RISH_IDENTITY" != "shell" ] && [ "$RISH_IDENTITY" != "root" ]; then
    fail "Rish output did not contain a standalone 'shell' or 'root' line. Output was: $WHOAMI_OUTPUT"
fi
ok "Shizuku/Rish is working correctly (identity: $RISH_IDENTITY)."
ok "Shizuku/Rish is working correctly."

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

log "Installing APK splits through Shizuku"
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

# system_server cannot read APKs directly from shared storage on some Android
# versions, so copy them to the shell-readable temporary directory first.
for apk do
    cp -f "$apk" "$INSTALL_DIR/"
done

set -- "$INSTALL_DIR"/*.apk
printf "Installing %s APK file(s)...\n" "$#"

# Use a PackageInstaller session, the adb shell-compatible equivalent of
# adb install-multiple on Android versions where pm install-multiple is absent.
TOTAL_SIZE=0
for apk do
    SIZE=$(wc -c < "$apk")
    TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
done

SESSION_OUTPUT=$(cmd package install-create -r -i "$INSTALLER_PACKAGE" -S "$TOTAL_SIZE")
SESSION_ID=$(printf "%s\n" "$SESSION_OUTPUT" | sed -n "s/.*\\[\\([0-9][0-9]*\\)\\].*/\\1/p")
[ -n "$SESSION_ID" ] || {
    printf "%s\n" "$SESSION_OUTPUT" >&2
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
printf '%s\n' "$INSTALL_OUTPUT"

if [ "$INSTALL_STATUS" -ne 0 ] || ! printf '%s\n' "$INSTALL_OUTPUT" | grep -q 'Success'; then
    fail "The APK installation did not report Success."
fi

log "Verifying the installation"
if ! remote_exec "pm path '$PACKAGE_NAME'" >/dev/null 2>&1; then
    fail "Installation failed or Android could not find the package."
fi

ok "Package installed successfully."
echo '[✓] Temporary files will be removed automatically.'
GENERATED_SCRIPT

sed -i "s|__DEFAULT_SHELL_MODE__|$SHELL_MODE|g; s|__DEFAULT_ADB_SERIAL__|$ADB_SERIAL|g" "$HOME/$SHELL_SCRIPT" || fail "Could not write the selected shell mode into $SHELL_SCRIPT."
chmod 700 "$HOME/$SHELL_SCRIPT" || fail "Could not make $SHELL_SCRIPT executable."
ok "Installation and configuration completed."
printf '\nRun afterward passing any package name:\n  bash ~/%s <package.name>\n' "$SHELL_SCRIPT"
printf '\nExample:\n  ~/%s com.google.android.googlequicksearchbox\n' "$SHELL_SCRIPT"
printf '\nThe gplaydl configuration and Shizuku DEX will be preserved.\n'
