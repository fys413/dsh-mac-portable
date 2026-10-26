#!/usr/bin/env bash
# make-dmg-or-zip.sh -- package a built DSH.app as a distributable zip (and
#                       optionally a compressed DMG), plus SHA256SUMS.
#
# What it does
#   1. refuses to package an app that contains symlinks (use a copied runtime,
#      not `build-launcher.sh --link`);
#   2. strips .DS_Store / ._* and forces 0755 on the launcher and on
#      runtime/node/bin/node so the archive keeps its executable bits;
#   3. creates dist/<name>.zip with `ditto` when available, else `zip -qry`;
#   4. re-opens the zip and asserts that Contents/MacOS/DSH is stored with an
#      executable mode (zips built on other platforms often lose it);
#   5. writes dist/SHA256SUMS and, with --dmg, a compressed UDZO disk image.
#
# Prerequisites
#   macOS 11+ on Intel x64; scripts/build-launcher.sh produced a bundle; `zip`
#   plus either `ditto` (preferred) or `zip`; `shasum` (or sha256sum); python3
#   for the mode check (Xcode CLT provides it; the check is skipped with a
#   warning if no Python is found).
#
# Usage
#   ./scripts/make-dmg-or-zip.sh
#   ./scripts/make-dmg-or-zip.sh --app build/DSH.app --name dsh-portable-x64 --dmg
#
# Options
#   --app PATH      bundle to package (default: build/DSH.app)
#   --out DIR       output directory (default: dist)
#   --name BASE     artifact basename (default: DSH-Portable-<version>-macos11-x64)
#   --version X.Y.Z version used in the default name (default: 0.1.0)
#   --dmg           also build a compressed .dmg via hdiutil
#   --force         overwrite existing artifacts
#   -h, --help      show this help
#
# Exit codes
#   0  success
#   1  unexpected failure (copy/zip/sha256)
#   2  usage error
#   3  input bundle missing or incomplete
#   4  required tool missing (zip / hdiutil)
#   5  artifact verification failed (executable bit lost)
#   6  bundle contains symlinks
#
# Licence: MIT (see LICENSE). Original to dsh-mac-portable, no upstream code.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)

APP="$ROOT/build/DSH.app"
OUT="$ROOT/dist"
VERSION="0.1.0"
NAME=""
WANT_DMG=0
FORCE=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: make-dmg-or-zip.sh [--app PATH] [--out DIR] [--name BASE]
                          [--version X.Y.Z] [--dmg] [--force]

Packages a DSH.app into a zip (and optionally a dmg) with SHA256SUMS.
See the header of this script for the full description and exit codes.
EOF
}

usage_die() { printf 'error: %s\n\n' "$*" >&2; usage >&2; exit 2; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app) [ "$#" -ge 2 ] || usage_die "--app needs a value"; APP=$2; shift 2 ;;
        --app=*) APP=${1#*=}; shift ;;
        --out) [ "$#" -ge 2 ] || usage_die "--out needs a value"; OUT=$2; shift 2 ;;
        --out=*) OUT=${1#*=}; shift ;;
        --name) [ "$#" -ge 2 ] || usage_die "--name needs a value"; NAME=$2; shift 2 ;;
        --name=*) NAME=${1#*=}; shift ;;
        --version) [ "$#" -ge 2 ] || usage_die "--version needs a value"; VERSION=$2; shift 2 ;;
        --version=*) VERSION=${1#*=}; shift ;;
        --dmg) WANT_DMG=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage_die "unknown argument: $1" ;;
    esac
done

[ -n "$NAME" ] || NAME="DSH-Portable-$VERSION-macos11-x64"

case "$APP" in /*|[A-Za-z]:/*) ;; *) APP="$PWD/$APP" ;; esac
case "$OUT" in /*|[A-Za-z]:/*) ;; *) OUT="$PWD/$OUT" ;; esac

EXE="$APP/Contents/MacOS/DSH"
[ -d "$APP" ] || { printf 'error: no such bundle: %s\n' "$APP" >&2
    printf 'hint: run scripts/build-launcher.sh first\n' >&2; exit 3; }
[ -f "$EXE" ] || { printf 'error: bundle has no launcher: %s\n' "$EXE" >&2; exit 3; }
[ -f "$APP/Contents/Info.plist" ] || { printf 'error: bundle has no Info.plist\n' >&2; exit 3; }
if [ ! -f "$APP/Contents/Resources/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js" ]; then
    printf 'warning: runtime payload missing from the bundle; packaging a stub\n' >&2
fi

# --- refuse symlinks --------------------------------------------------------
LINK=$(find "$APP" -type l -print 2>/dev/null | head -n 1)
if [ -n "$LINK" ]; then
    printf 'error: bundle contains a symlink: %s\n' "$LINK" >&2
    printf 'hint: rebuild without --link so the app is self-contained\n' >&2
    exit 6
fi

command -v zip >/dev/null 2>&1 || { printf 'error: zip not found\n' >&2; exit 4; }

# --- normalise metadata and modes ------------------------------------------
find "$APP" \( -name '.DS_Store' -o -name '._*' \) -type f -delete 2>/dev/null || true
chmod 0755 "$EXE"
[ -f "$APP/Contents/Resources/runtime/node/bin/node" ] && \
    chmod 0755 "$APP/Contents/Resources/runtime/node/bin/node" || true

mkdir -p "$OUT"
ZIP="$OUT/$NAME.zip"
DMG="$OUT/$NAME.dmg"

if [ -e "$ZIP" ] && [ "$FORCE" -eq 0 ]; then
    printf 'error: %s exists (pass --force to overwrite)\n' "$ZIP" >&2
    exit 1
fi
if [ "$WANT_DMG" -eq 1 ] && [ -e "$DMG" ] && [ "$FORCE" -eq 0 ]; then
    printf 'error: %s exists (pass --force to overwrite)\n' "$DMG" >&2
    exit 1
fi

# --- zip --------------------------------------------------------------------
rm -f "$ZIP"
APP_DIR=$(dirname -- "$APP")
APP_BASE=$(basename -- "$APP")
if command -v ditto >/dev/null 2>&1; then
    # ditto keeps mode bits, extended attributes and the bundle layout.
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
else
    ( cd "$APP_DIR" && zip -qry "$ZIP" "$APP_BASE" )
fi
[ -s "$ZIP" ] || die "zip was not created: $ZIP"

# --- verify the executable bit survived ------------------------------------
PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then PYTHON=$candidate; break; fi
done
if [ -n "$PYTHON" ]; then
    "$PYTHON" - "$ZIP" "$APP_BASE" <<'PY_EOF' || exit 5
import stat
import sys
import zipfile

zip_path, app_base = sys.argv[1], sys.argv[2]
want = app_base + "/Contents/MacOS/DSH"
with zipfile.ZipFile(zip_path) as zf:
    names = zf.namelist()
    if want not in names:
        sys.exit("verification failed: %s missing from the archive" % want)
    mode = zf.getinfo(want).external_attr >> 16
    if not stat.S_ISREG(mode) or not (mode & 0o111):
        sys.exit("verification failed: %s stored without an executable mode (%o)"
                 % (want, mode & 0o777))
print("verified: %s is executable inside the zip" % want)
PY_EOF
else
    printf 'warning: no python3/python found; skipped the zip mode check\n' >&2
fi

# --- optional dmg -----------------------------------------------------------
if [ "$WANT_DMG" -eq 1 ]; then
    command -v hdiutil >/dev/null 2>&1 || { printf 'error: hdiutil not found\n' >&2; exit 4; }
    rm -f "$DMG"
    hdiutil create -quiet -volname "DSH Portable" -srcfolder "$APP" \
        -ov -format UDZO "$DMG" >/dev/null
    [ -s "$DMG" ] || die "dmg was not created: $DMG"
fi

# --- checksums --------------------------------------------------------------
SHA256SUMS="$OUT/SHA256SUMS"
: > "$SHA256SUMS"
if command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | awk '{print $1}'; }
else
    die "neither shasum nor sha256sum is available"
fi
printf '%s  %s\n' "$(sha256 "$ZIP")" "$(basename -- "$ZIP")" >> "$SHA256SUMS"
if [ "$WANT_DMG" -eq 1 ]; then
    printf '%s  %s\n' "$(sha256 "$DMG")" "$(basename -- "$DMG")" >> "$SHA256SUMS"
fi

# --- report -----------------------------------------------------------------
printf 'artifact(s):\n'
printf '  zip: %s (%s)\n' "$ZIP" "$(du -h "$ZIP" | awk '{print $1}')"
if [ "$WANT_DMG" -eq 1 ]; then
    printf '  dmg: %s (%s)\n' "$DMG" "$(du -h "$DMG" | awk '{print $1}')"
fi
printf '  sums: %s\n' "$SHA256SUMS"
printf 'next: attach these files to a GitHub Release (never git add them)\n'
