#!/bin/bash
# fetch-runtime.sh -- download and install the pinned Node.js darwin-x64 runtime.
#
# Purpose
#   Fetch node-v22.18.0-darwin-x64.tar.gz from nodejs.org, verify its SHA256
#   against the value pinned below, and unpack node + npm into build/runtime/.
#   build/runtime/node/bin/node and build/runtime/node/lib/node_modules/npm are
#   exactly what scripts/build-launcher.sh later assembles into DSH.app.
#
# Preconditions
#   - macOS 11+ (Big Sur) on Intel x64. The tarball is a darwin-x64 build; the
#     script refuses to run on non-Darwin hosts on purpose (no cross-builds).
#   - curl, tar and either shasum (macOS) or sha256sum (coreutils).
#   - ~50 MB for the tarball plus ~120 MB for the unpacked tree; write access to
#     the repository root. Network access to nodejs.org (or a proxy via --proxy).
#
# Usage
#   ./scripts/fetch-runtime.sh [--dest DIR] [--proxy URL] [--force]
#                              [--verify-only] [--help]
#
#   --dest DIR      install root (default: <repo>/build/runtime)
#   --proxy URL     pass a proxy to curl (http://host:port)
#   --force         re-download even if the destination already looks correct
#   --verify-only   download + verify SHA256 only, do not unpack; for CI
#
# Exit codes
#   0  success (downloaded, verified, installed -- or already installed)
#   1  runtime failure (network, SHA256 mismatch, missing source files, bad dest)
#   2  usage error (unknown option, missing option value)
#
# Notes
#   The SHA256 below is a trust anchor: it must never be "updated to whatever
#   the server returned". Bump it only together with NODE_VERSION, after
#   checking the value on https://nodejs.org/dist/v22.18.0/SHASUMS256.txt.
set -euo pipefail

NODE_VERSION="22.18.0"
NODE_SHA256="9c8aa1e5ff5780b38cc1134e2263d84e2f4308eb84c02515e3af33936ca02cdc"
TARBALL="node-v${NODE_VERSION}-darwin-x64.tar.gz"
SRC_DIR="node-v${NODE_VERSION}-darwin-x64"
BASE_URL="https://nodejs.org/dist/v${NODE_VERSION}"

HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
ROOT=$(cd -- "$HERE/.." && pwd -P)
DEST="$ROOT/build/runtime"

PROXY=""
FORCE=0
VERIFY_ONLY=0

usage() {
  sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)        [ $# -ge 2 ] || die "missing value for --dest"; DEST="$2"; shift 2 ;;
    --dest=*)      DEST="${1#--dest=}"; shift ;;
    --proxy)       [ $# -ge 2 ] || die "missing value for --proxy"; PROXY="$2"; shift 2 ;;
    --proxy=*)     PROXY="${1#--proxy=}"; shift ;;
    --force)       FORCE=1; shift ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "this script must run on macOS (got $(uname -s))"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar  >/dev/null 2>&1 || die "tar is required"

sha256_of() { # $1=file ; prints the lowercase hex digest
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "need shasum or sha256sum to verify the download"
  fi
}

# Fast path: a previous run already installed the exact version we pin.
if [ "$VERIFY_ONLY" -eq 0 ] && [ "$FORCE" -eq 0 ] && [ -x "$DEST/node/bin/node" ]; then
  _have=$("$DEST/node/bin/node" -p 'process.version' 2>/dev/null || true)
  if [ "$_have" = "v${NODE_VERSION}" ]; then
    printf 'runtime already installed: %s (%s) -- use --force to replace\n' "$DEST" "$_have"
    exit 0
  fi
fi

WORK="${TMPDIR:-/tmp}/dsh-fetch-runtime.$$"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM

printf '== downloading %s\n' "$TARBALL"
if [ -n "$PROXY" ]; then
  curl -fL --retry 3 --connect-timeout 20 --proxy "$PROXY" \
    -o "$WORK/$TARBALL" "$BASE_URL/$TARBALL"
else
  curl -fL --retry 3 --connect-timeout 20 \
    -o "$WORK/$TARBALL" "$BASE_URL/$TARBALL"
fi

printf '== verifying SHA256\n'
ACTUAL=$(sha256_of "$WORK/$TARBALL")
if [ "$ACTUAL" != "$NODE_SHA256" ]; then
  die "SHA256 mismatch for $TARBALL
  expected: $NODE_SHA256
  actual  : $ACTUAL
Refusing to install an unverified runtime. Check the mirror/proxy in use."
fi
printf '   ok: %s\n' "$ACTUAL"

if [ "$VERIFY_ONLY" -eq 1 ]; then
  printf '== verify-only: download and SHA256 are good; nothing installed\n'
  exit 0
fi

printf '== extracting %s\n' "$TARBALL"
tar -xzf "$WORK/$TARBALL" -C "$WORK"
SRC="$WORK/$SRC_DIR"
[ -f "$SRC/bin/node" ] || die "node binary missing in tarball: $SRC/bin/node"
[ -f "$SRC/lib/node_modules/npm/bin/npm-cli.js" ] || die "npm missing in tarball"

printf '== installing into %s\n' "$DEST"
mkdir -p "$DEST/node/bin" "$DEST/node/lib/node_modules"
rm -rf "$DEST/node/lib/node_modules/npm"
cp -f "$SRC/bin/node" "$DEST/node/bin/node"
chmod 755 "$DEST/node/bin/node"
cp -R "$SRC/lib/node_modules/npm" "$DEST/node/lib/node_modules/npm"
# Keep upstream notices next to the binary: Node is MIT and npm Artistic-2.0.
cp -f "$SRC/LICENSE" "$DEST/node/LICENSE" 2>/dev/null || true
cp -f "$SRC/README.md" "$DEST/node/README.md" 2>/dev/null || true

"$DEST/node/bin/node" -p 'process.version' >/dev/null 2>&1 \
  || die "installed node does not run on this host: $DEST/node/bin/node"

printf '== done\n'
printf 'runtime: %s\n' "$DEST"
printf 'node   : %s\n' "$("$DEST/node/bin/node" -p 'process.version')"
printf 'next   : ./scripts/fetch-dsh.sh\n'
