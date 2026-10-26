#!/usr/bin/env bash
# build-launcher.sh -- assemble a minimal, debranded DSH.app from the staged
#                     runtime and node_modules produced by the fetch-* scripts.
#
# What it does
#   1. writes DSH.app/Contents/Info.plist, PkgInfo and MacOS/DSH (POSIX sh);
#   2. optionally assembles Contents/Resources/runtime/ from
#        build/runtime/node       (Node.js distribution, see fetch-runtime.sh)
#        build/node_modules       (npm payload, see fetch-dsh.sh);
#   3. syntax-checks the generated launcher with `sh -n` before declaring success.
#
# The launcher itself is embedded below as a quoted heredoc, so this file stays
# the single source of truth: change the launcher here, never inside the .app.
#
# Prerequisites
#   macOS 11+ on Intel x64 (only platform this project targets);
#   bash 3.2+ (stock /bin/bash is enough), /bin/sh, python3 is NOT required here;
#   scripts/fetch-runtime.sh and scripts/fetch-dsh.sh already succeeded, unless
#   --skeleton is used.
#
# Usage
#   ./scripts/build-launcher.sh                 # full app under build/
#   ./scripts/build-launcher.sh --skeleton      # metadata + launcher only
#   ./scripts/build-launcher.sh --link          # symlink runtime (dev only)
#   ./scripts/build-launcher.sh --dest /tmp/X.app --force
#   ./scripts/build-launcher.sh --bundle-id io.github.me.dsh-mac-portable
#
# Options
#   --dest PATH     output bundle path (default: build/DSH.app)
#   --skeleton      skip runtime assembly; the app will not start
#   --link          symlink build/runtime + build/node_modules instead of copying
#                   (fast iteration; produces an app that only works in place)
#   --force         replace an existing destination bundle
#   --version X.Y.Z CFBundleShortVersionString + CFBundleVersion (default: 0.1.0),
#                   also the default --version in make.sh
#   --bundle-id ID  CFBundleIdentifier (default: io.github.<user>.dsh-mac-portable,
#                   where <user> is $DSH_BUNDLE_USER or $USER, sanitised; a
#                   literal "deepseek" in the identifier is rejected, see BRAND.md)
#   -h, --help      show this help
#
# Exit codes
#   0  success
#   1  unexpected failure (mkdir/copy/plist/syntax check)
#   2  usage error
#   3  missing input (runtime, node binary, or npm payload)
#   4  destination exists and --force was not given
#   5  generated launcher failed its `sh -n` syntax check
#
# Licence: MIT (see LICENSE). This script is original to dsh-mac-portable and
# contains no upstream code.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)

APP_VERSION="0.1.0"
BUNDLE_ID="${DSH_BUNDLE_ID:-}"
BUNDLE_USER="${DSH_BUNDLE_USER:-${USER:-}}"
DEST="$ROOT/build/DSH.app"
SKELETON=0
LINK_RUNTIME=0
FORCE=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage_die() { printf 'error: %s\n\n' "$*" >&2; usage >&2; exit 2; }

usage() {
    cat <<'EOF'
usage: build-launcher.sh [--dest PATH] [--skeleton] [--link] [--force]
                         [--version X.Y.Z] [--bundle-id ID]

Builds DSH.app from build/runtime/node and build/node_modules.
See the header of this script for the full description and exit codes.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dest) [ "$#" -ge 2 ] || usage_die "--dest needs a value"; DEST=$2; shift 2 ;;
        --dest=*) DEST=${1#*=}; shift ;;
        --skeleton) SKELETON=1; shift ;;
        --link) LINK_RUNTIME=1; shift ;;
        --force) FORCE=1; shift ;;
        --version) [ "$#" -ge 2 ] || usage_die "--version needs a value"; APP_VERSION=$2; shift 2 ;;
        --version=*) APP_VERSION=${1#*=}; shift ;;
        --bundle-id) [ "$#" -ge 2 ] || usage_die "--bundle-id needs a value"; BUNDLE_ID=$2; shift 2 ;;
        --bundle-id=*) BUNDLE_ID=${1#*=}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage_die "unknown argument: $1" ;;
    esac
done

case "$APP_VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) usage_die "--version expects X.Y.Z, got: $APP_VERSION" ;;
esac

# Default identifier: io.github.<user>.dsh-mac-portable. The user part is taken
# from $DSH_BUNDLE_USER/$USER and sanitised, so no real name or dot leaks in.
if [ -z "$BUNDLE_ID" ]; then
    if [ -z "$BUNDLE_USER" ]; then
        BUNDLE_USER=$(id -un 2>/dev/null || printf 'user')
    fi
    BUNDLE_USER=$(printf '%s' "$BUNDLE_USER" \
        | LC_ALL=C tr '[:upper:]' '[:lower:]' \
        | LC_ALL=C tr -cd 'a-z0-9-')
    [ -n "$BUNDLE_USER" ] || BUNDLE_USER=user
    BUNDLE_ID="io.github.$BUNDLE_USER.dsh-mac-portable"
fi
case "$BUNDLE_ID" in
    *.*) ;;
    *) usage_die "--bundle-id must be a reverse-DNS identifier (got: $BUNDLE_ID)" ;;
esac
case "$BUNDLE_ID" in
    *[!A-Za-z0-9.-]*) usage_die "--bundle-id may only contain A-Z a-z 0-9 . - (got: $BUNDLE_ID)" ;;
    .*|*..*|*.) usage_die "--bundle-id must not start/end with '.' or contain '..' (got: $BUNDLE_ID)" ;;
esac
case "$(printf '%s' "$BUNDLE_ID" | LC_ALL=C tr '[:upper:]' '[:lower:]')" in
    *deepseek*) usage_die "bundle id must not contain 'deepseek' (see BRAND.md): $BUNDLE_ID" ;;
esac

# Resolve a relative --dest against the caller's cwd, not against $ROOT.
case "$DEST" in
    /*|[A-Za-z]:/*) ;;
    *) DEST="$PWD/$DEST" ;;
esac

NODE_SRC="$ROOT/build/runtime/node"
MODULES_SRC="$ROOT/build/node_modules"
BUILD_INFO="$ROOT/build/BUILD-INFO.txt"

if [ "$SKELETON" -eq 0 ]; then
    [ -x "$NODE_SRC/bin/node" ] || {
        printf 'error: missing runtime: %s/bin/node\n' "$NODE_SRC" >&2
        printf 'hint: run scripts/fetch-runtime.sh first, or pass --skeleton\n' >&2
        exit 3
    }
    [ -f "$MODULES_SRC/@deepseek-ai/dsh/lib/bin.js" ] || {
        printf 'error: missing npm payload: %s/@deepseek-ai/dsh/lib/bin.js\n' "$MODULES_SRC" >&2
        printf 'hint: run scripts/fetch-dsh.sh first, or pass --skeleton\n' >&2
        exit 3
    }
fi

if [ -e "$DEST" ]; then
    [ "$FORCE" -eq 1 ] || {
        printf 'error: destination exists: %s (pass --force to replace)\n' "$DEST" >&2
        exit 4
    }
    rm -rf -- "$DEST"
fi

CONTENTS="$DEST/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RES"

# --- Info.plist -------------------------------------------------------------
# Neutral identifiers only: no ai.deepseek.* / com.deepseek.* bundle id, no
# upstream display name. See BRAND.md.
PLIST="$CONTENTS/Info.plist"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>DSH Portable</string>
    <key>CFBundleExecutable</key>
    <string>DSH</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DSH Portable</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Unofficial build. Not affiliated with DeepSeek. Project code MIT licensed.</string>
</dict>
</plist>
PLIST_EOF
printf 'APPL????' > "$CONTENTS/PkgInfo"

# --- launcher ---------------------------------------------------------------
EXE="$MACOS/DSH"
cat > "$EXE" <<'LAUNCHER_EOF'
#!/bin/sh
# DSH Portable -- launcher (unofficial build; generated by build-launcher.sh)
#
# Starts the DSH web server with the bundled Node.js runtime, waits for it to
# print the token-protected localhost URL, opens a browser, and keeps the server
# alive until this launcher exits.
#
# Logs (0600, directory 0700):
#   ~/Library/Logs/DSH-Portable/portable.log       redacted console log
#   ~/Library/Logs/DSH-Portable/portable.raw.log   unredacted, debugging only
#   ~/Library/Logs/DSH-Portable/service.url        localhost URL with token
#
# Environment variables:
#   DSH_PORTABLE_WAIT_SECONDS  startup timeout in seconds (default 600)
#   DSH_PORTABLE_BROWSER       preferred browser name, e.g. "Google Chrome"
#   DSH_PORTABLE_LOG_DIR       override the log directory
#   DSH_PORTABLE_ARGS          extra CLI arguments (word-split, intentional)
#
# Exit codes: 0 clean shutdown, 1 generic error, 3 runtime missing,
#             4 startup timeout or early exit, 5 no browser could be opened.
set -u

APP_NAME="DSH Portable"
SELF=$0
case "$SELF" in
    */*) ;;
    *) SELF=$(command -v -- "$SELF" 2>/dev/null || printf '%s' "$SELF") ;;
esac
MACOS_DIR=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd -P) || exit 1
CONTENTS=$(CDPATH= cd -- "$MACOS_DIR/.." && pwd -P) || exit 1
RES="$CONTENTS/Resources"
RT="$RES/runtime"
NODE="$RT/node/bin/node"
BIN="$RT/node_modules/@deepseek-ai/dsh/lib/bin.js"

LOG_ROOT=${DSH_PORTABLE_LOG_DIR:-"$HOME/Library/Logs/DSH-Portable"}
LOG="$LOG_ROOT/portable.log"
RAW="$LOG_ROOT/portable.raw.log"
LOCK="$LOG_ROOT/instance.lock"
URLFILE="$LOG_ROOT/service.url"
PIPE="$LOG_ROOT/portable.pipe"
WAIT_SECONDS=${DSH_PORTABLE_WAIT_SECONDS:-600}
BROWSER_PREF=${DSH_PORTABLE_BROWSER:-}

umask 077
mkdir -p "$LOG_ROOT" 2>/dev/null || exit 1

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true
}

alert() {
    printf '%s: %s\n' "$APP_NAME" "$*" >&2
    log "ERROR: $*"
    if command -v osascript >/dev/null 2>&1; then
        osascript \
            -e 'on run argv' \
            -e 'display alert "DSH Portable" message (item 1 of argv) as critical' \
            -e 'end run' "$*" >/dev/null 2>&1 || true
    fi
}

open_url() {
    _url=$1
    if [ -n "$BROWSER_PREF" ]; then
        if open -a "$BROWSER_PREF" "$_url" >/dev/null 2>&1; then
            log "opened $BROWSER_PREF"
            return 0
        fi
        log "could not open $BROWSER_PREF; falling back"
    fi
    # Safari 16 cannot run the web UI reliably (missing Promise.withResolvers),
    # so Chromium-family and Firefox browsers are tried first.
    for _app in "Google Chrome" "Microsoft Edge" "Brave Browser" "Firefox" \
                "Chromium" "Vivaldi" "Arc"; do
        if [ -d "/Applications/$_app.app" ] || [ -d "$HOME/Applications/$_app.app" ]; then
            if open -a "$_app" "$_url" >/dev/null 2>&1; then
                log "opened $_app"
                return 0
            fi
        fi
    done
    if open "$_url" >/dev/null 2>&1; then
        log "opened default browser (Safari may render a blank page)"
        return 0
    fi
    return 1
}

if [ ! -x "$NODE" ]; then
    alert "runtime missing: $NODE -- rebuild with scripts/build-launcher.sh"
    exit 3
fi
if [ ! -f "$BIN" ]; then
    alert "payload missing: $BIN -- rebuild with scripts/build-launcher.sh"
    exit 3
fi

# --- single instance --------------------------------------------------------
if [ -f "$LOCK" ]; then
    _pid=$(sed -n '1p' "$LOCK" 2>/dev/null || true)
    _url=$(sed -n '1p' "$URLFILE" 2>/dev/null || true)
    case "$_pid" in
        ''|*[!0-9]*) : ;;
        *)
            if kill -0 "$_pid" 2>/dev/null && \
               ps -p "$_pid" -o args= 2>/dev/null | grep -q -e 'dsh-mac-portable' -e '@deepseek-ai/dsh'; then
                if [ -n "$_url" ]; then
                    open_url "$_url" || alert "already running; open $_url manually"
                    exit 0
                fi
                alert "already running (pid $_pid); see $LOG"
                exit 1
            fi
            ;;
    esac
    rm -f "$LOCK"
fi

NODE_PID=
READER_PID=
GUARD_PID=

cleanup() {
    _rc=$?
    trap - EXIT INT TERM HUP
    [ -n "$GUARD_PID" ] && kill "$GUARD_PID" 2>/dev/null || true
    [ -n "$READER_PID" ] && kill "$READER_PID" 2>/dev/null || true
    if [ -n "$NODE_PID" ]; then
        kill "$NODE_PID" 2>/dev/null || true
        wait "$NODE_PID" 2>/dev/null || true
    fi
    rm -f "$PIPE" "$LOCK"
    log "launcher exiting (rc=$_rc)"
    exit "$_rc"
}
trap cleanup EXIT INT TERM HUP

log "--- start: $APP_NAME, node $("$NODE" -p 'process.version' 2>/dev/null || echo '?')"
printf '%s\n' "$$" > "$LOCK"
rm -f "$URLFILE"

# --- FIFO: redact secrets before they reach the readable log ----------------
rm -f "$PIPE"
if ! mkfifo "$PIPE"; then
    alert "cannot create fifo: $PIPE"
    exit 1
fi
(
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line" >>"$RAW" 2>/dev/null || true
        clean=$(printf '%s\n' "$line" | sed -E \
            -e 's/(token=)[A-Za-z0-9._~%+-]*/\1***/g' \
            -e 's/(Bearer )[A-Za-z0-9._~%+\/-]*/\1***/g' 2>/dev/null || printf '%s' "$line")
        printf '%s\n' "$clean" >>"$LOG" 2>/dev/null || true
        case "$line" in
            *token=*)
                url=$(printf '%s\n' "$line" | sed -n -E \
                    's#.*\((http://127\.0\.0\.1:[0-9][0-9]*/?token=[^[:space:]"]*)\).*#\1#p' \
                    2>/dev/null | head -n 1)
                if [ -n "$url" ]; then
                    printf '%s\n' "$url" > "$URLFILE.tmp" 2>/dev/null && mv "$URLFILE.tmp" "$URLFILE" 2>/dev/null || true
                fi
                ;;
        esac
    done < "$PIPE"
) &
READER_PID=$!

# --- start the server -------------------------------------------------------
# Finder may pass -psn_0_12345; never forward those to Node.
START_ARGS=
for _arg in "$@"; do
    case "$_arg" in
        -psn_*) ;;
        *) START_ARGS="${START_ARGS}${START_ARGS:+ }$_arg" ;;
    esac
done
if [ -z "$START_ARGS" ]; then
    START_ARGS=${DSH_PORTABLE_ARGS:-}
fi
# Word splitting of START_ARGS is deliberate: it carries multiple CLI flags.
# shellcheck disable=SC2086
"$NODE" "$BIN" $START_ARGS >>"$PIPE" 2>&1 &
NODE_PID=$!
log "server pid $NODE_PID; waiting up to ${WAIT_SECONDS}s for the URL"

# --- orphan guard -----------------------------------------------------------
# If this launcher dies without running its trap (SIGKILL, crash), take the
# server down with it instead of leaving an orphan holding the port.
(
    while kill -0 "$$" 2>/dev/null; do sleep 5; done
    kill "$NODE_PID" 2>/dev/null || true
) &
GUARD_PID=$!

# --- wait for the token URL -------------------------------------------------
_waited=0
while [ ! -s "$URLFILE" ]; do
    if ! kill -0 "$NODE_PID" 2>/dev/null; then
        alert "server exited during startup; last lines of $LOG: $(tail -n 3 "$LOG" 2>/dev/null | tr '\n' ' ')"
        exit 4
    fi
    if [ "$_waited" -ge "$WAIT_SECONDS" ]; then
        alert "server did not report a URL within ${WAIT_SECONDS}s; see $LOG"
        exit 4
    fi
    sleep 1
    _waited=$((_waited + 1))
done

URL=$(sed -n '1p' "$URLFILE")
log "ready after ${_waited}s"
open_url "$URL" || alert "no browser could be opened; visit $URL manually"

wait "$NODE_PID"
exit $?
LAUNCHER_EOF
chmod 0755 "$EXE"

sh -n "$EXE" || {
    printf 'error: generated launcher has a syntax error: %s\n' "$EXE" >&2
    exit 5
}

# --- runtime payload --------------------------------------------------------
if [ "$SKELETON" -eq 0 ]; then
    mkdir -p "$RES/runtime"
    if [ "$LINK_RUNTIME" -eq 1 ]; then
        ln -sfn "$NODE_SRC" "$RES/runtime/node"
        ln -sfn "$MODULES_SRC" "$RES/runtime/node_modules"
        printf 'note: --link used; %s is not self-contained\n' "$DEST" >&2
    else
        if command -v ditto >/dev/null 2>&1; then
            ditto "$NODE_SRC" "$RES/runtime/node"
            ditto "$MODULES_SRC" "$RES/runtime/node_modules"
        else
            mkdir -p "$RES/runtime/node"
            cp -R "$NODE_SRC/." "$RES/runtime/node/"
            cp -R "$MODULES_SRC" "$RES/runtime/node_modules"
        fi
    fi
    # Strip macOS metadata that would otherwise make the bundle non-reproducible.
    find "$DEST" -name '.DS_Store' -type f -delete 2>/dev/null || true
    find "$DEST" -name '._*' -type f -delete 2>/dev/null || true
    if [ -f "$BUILD_INFO" ]; then
        cp "$BUILD_INFO" "$RES/BUILD-INFO.txt"
    fi
fi

# --- plist sanity -----------------------------------------------------------
if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$PLIST" >/dev/null || {
        printf 'error: plutil rejected %s\n' "$PLIST" >&2
        exit 1
    }
fi

# --- report -----------------------------------------------------------------
printf 'built: %s\n' "$DEST"
printf '  version:   %s\n' "$APP_VERSION"
printf '  bundle id: %s\n' "$BUNDLE_ID"
printf '  launcher:  %s\n' "$EXE"
if [ "$SKELETON" -eq 1 ]; then
    printf '  runtime:   (skeleton: not assembled)\n'
elif [ "$LINK_RUNTIME" -eq 1 ]; then
    printf '  runtime:   symlinked to build/ (not distributable)\n'
else
    printf '  runtime:   bundled (%s)\n' "$(du -sh "$RES/runtime" 2>/dev/null | awk '{print $1}')"
fi
printf '  next:      ./scripts/make-dmg-or-zip.sh\n'
