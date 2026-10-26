#!/bin/bash
# fetch-dsh.sh -- install the public @deepseek-ai/dsh npm package for darwin/x64.
#
# Purpose
#   Run the pinned Node/npm from build/runtime (see fetch-runtime.sh) and install
#   the upstream DSH package into build/node_modules with npm's platform flags
#   forced to darwin/x64.
#
#   Why --ignore-scripts
#     1. Supply chain: npm lifecycle scripts execute arbitrary package code at
#        install time. This step installs a ~600-package tree; not running their
#        install hooks keeps the tree byte-identical to the published tarballs.
#     2. Correctness: --os/--cpu only tell npm which *optional* prebuilds to
#        fetch. A postinstall would still run in the *build host* context and
#        could pick the host platform's binaries (or try to compile with tools
#        that are not present), silently producing a bundle that cannot load.
#     3. Native addons are prebuilt: sherpa-onnx, sharp-libvips, koffi,
#        node-pty and ripgrep ship darwin-x64 binaries, so no rebuild is needed.
#     Trade-off: if a dependency truly requires a postinstall step, its binary
#     or generated file will be missing. scripts/verify-runtime is not provided
#     (A-tier repo); check the build by launching the app and by running
#     docs/BUILD.md section 5 (`node -e "require(...)"` smoke tests).
#
#   Why @next (not latest)
#     The pinned runtime target (macOS 11, Intel x64) and the minos patch below
#     were validated against the `next` dist-tag. For a reproducible release set
#     DSH_VERSION to an exact version, e.g. DSH_VERSION=0.2.1-rc.3.
#
# Preconditions
#   - macOS (same reason as fetch-runtime.sh: darwin-x64 target, no cross-build).
#   - ./scripts/fetch-runtime.sh has run: build/runtime/node/bin/node and
#     build/runtime/node/lib/node_modules/npm/bin/npm-cli.js must exist.
#   - Network access to registry.npmjs.org (optionally via --proxy or the
#     standard HTTPS_PROXY environment variable).
#
# Usage
#   ./scripts/fetch-dsh.sh [--version VER] [--prefix DIR] [--proxy URL]
#                          [--force] [--help]
#
#   --version VER   dist-tag or exact version (default: $DSH_VERSION or "next")
#   --prefix DIR    install root; node_modules is created inside (default: build)
#   --proxy URL     pass --proxy/--https-proxy to npm
#   --force         wipe an existing node_modules before installing
#
# Exit codes
#   0  success
#   1  runtime failure (missing runtime, npm failed, entry point missing)
#   2  usage error
#
# Output
#   build/node_modules/@deepseek-ai/dsh/...   the CLI
#   build/package.json, build/package-lock.json  resolved tree (git-ignored)
#   build/BUILD-INFO.txt                      versions + flags used
set -euo pipefail

VERSION="${DSH_VERSION:-next}"
HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
ROOT=$(cd -- "$HERE/.." && pwd -P)
PREFIX="$ROOT/build"
PROXY=""
FORCE=0

usage() {
  sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)     [ $# -ge 2 ] || die "missing value for --version"; VERSION="$2"; shift 2 ;;
    --version=*)   VERSION="${1#--version=}"; shift ;;
    --prefix)      [ $# -ge 2 ] || die "missing value for --prefix"; PREFIX="$2"; shift 2 ;;
    --prefix=*)    PREFIX="${1#--prefix=}"; shift ;;
    --proxy)       [ $# -ge 2 ] || die "missing value for --proxy"; PROXY="$2"; shift 2 ;;
    --proxy=*)     PROXY="${1#--proxy=}"; shift ;;
    --force)       FORCE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "this script must run on macOS (got $(uname -s))"

NODE_BIN="$ROOT/build/runtime/node/bin/node"
NPM_CLI="$ROOT/build/runtime/node/lib/node_modules/npm/bin/npm-cli.js"
[ -x "$NODE_BIN" ] || die "runtime missing: $NODE_BIN
Run ./scripts/fetch-runtime.sh first."
[ -f "$NPM_CLI" ] || die "npm missing: $NPM_CLI
Run ./scripts/fetch-runtime.sh first."

mkdir -p "$PREFIX"
if [ "$FORCE" -eq 1 ]; then
  printf '== removing existing tree: %s/node_modules\n' "$PREFIX"
  rm -rf "$PREFIX/node_modules" "$PREFIX/package.json" "$PREFIX/package-lock.json"
fi

NPM_ARGS=(
  install --prefix "$PREFIX" "@deepseek-ai/dsh@$VERSION"
  --os=darwin --cpu=x64 --ignore-scripts --no-audit --no-fund --loglevel=warn
)
if [ -n "$PROXY" ]; then
  NPM_ARGS+=(--proxy "$PROXY" --https-proxy "$PROXY")
fi

printf '== installing @deepseek-ai/dsh@%s (darwin/x64, --ignore-scripts)\n' "$VERSION"
"$NODE_BIN" "$NPM_CLI" "${NPM_ARGS[@]}"

ENTRY="$PREFIX/node_modules/@deepseek-ai/dsh/lib/bin.js"
[ -f "$ENTRY" ] || die "install finished but the CLI entry is missing: $ENTRY"

DSH_VER="$("$NODE_BIN" -p "require('$PREFIX/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || echo unknown)"
NPM_VER="$("$NODE_BIN" "$NPM_CLI" --version 2>/dev/null || echo unknown)"
NODE_VER="$("$NODE_BIN" -p 'process.version' 2>/dev/null || echo unknown)"

{
  printf 'built_at   = %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'dsh_version= %s\n' "$DSH_VER"
  printf 'requested  = %s\n' "$VERSION"
  printf 'node       = %s\n' "$NODE_VER"
  printf 'npm        = %s\n' "$NPM_VER"
  printf 'npm_flags  = --os=darwin --cpu=x64 --ignore-scripts --no-audit --no-fund\n'
  printf 'host       = %s %s\n' "$(uname -s)" "$(uname -m)"
} >"$PREFIX/BUILD-INFO.txt"

printf '== done\n'
printf 'dsh     : %s\n' "$DSH_VER"
printf 'entry   : %s\n' "$ENTRY"
printf 'info    : %s\n' "$PREFIX/BUILD-INFO.txt"
printf 'next    : ./scripts/patch-sherpa-minos.py\n'
