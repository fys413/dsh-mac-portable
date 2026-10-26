#!/bin/sh
# make.sh -- B tier: build DSH.app end to end from the official sources.
#
# One command for macOS 11 Big Sur (Intel x64). Steps, in order:
#   1/5  scripts/fetch-runtime.sh        Node.js 22.18.0 darwin-x64 (SHA256 pinned)
#   2/5  scripts/fetch-dsh.sh            @deepseek-ai/dsh from registry.npmjs.org
#   3/5  scripts/patch-sherpa-minos.py   minos 15.0 -> 11.0 (Apache-2.0 4(b) notice)
#   4/5  scripts/build-launcher.sh       build/DSH.app + Info.plist
#   5/5  scripts/make-dmg-or-zip.sh      dist/*.zip + SHA256SUMS + LICENSES/
#
# The repository itself still ships zero upstream bytes: every upstream file is
# downloaded at build time. Nothing in build/ or dist/ is committed.
#
# Prerequisites
#   macOS 11+ on Intel x64, Xcode Command Line Tools (python3, git),
#   ~2.5 GB free disk, network access to nodejs.org and registry.npmjs.org
#   (use --proxy if needed). bash 3.2+ is enough for the per-step scripts.
#
# Usage
#   ./make.sh                     # full build, unsigned (default)
#   ./make.sh --skip-fetch        # reuse build/runtime and build/node_modules
#   ./make.sh --clean             # remove build/ and dist/ first, then build
#   ./make.sh --sign --dmg        # ad-hoc codesign, and also produce a .dmg
#
# Options
#   --skip-fetch      do not download Node or npm packages; require build/ to be
#                     already populated (fails with a hint if it is not)
#   --clean           remove build/ and dist/ before starting
#   --no-sign         do not sign (default; kept for explicitness/scripts)
#   --sign            ad-hoc codesign the app with `codesign -s -` before packing
#   --dmg             also build a compressed .dmg (needs hdiutil)
#   --version X.Y.Z   CFBundleShortVersionString and artifact name (default 0.1.0)
#   --bundle-id ID    CFBundleIdentifier (default io.github.<user>.dsh-mac-portable,
#                     where <user> is $DSH_BUNDLE_USER/$USER, sanitised; never
#                     contains "deepseek", see BRAND.md)
#   --proxy URL       proxy for nodejs.org and the npm registry (http://host:port)
#   -h, --help        show this help and exit (writes nothing)
#
# Output
#   build/DSH.app                                         the application bundle
#   dist/DSH-Portable-<version>-macos11-x64.zip           app + LICENSES/ + notices
#   dist/SHA256SUMS                                       checksums
#   dist/<name>.dmg                                       only with --dmg
#
# Exit codes
#   0  success
#   1  a step failed (the step's own diagnostic and exit code are shown)
#   2  usage error
#   3  --skip-fetch was used but build/ is incomplete
#   4  --sign was requested but codesign is unavailable
#
# Licence: MIT (see LICENSE). Original to dsh-mac-portable, no upstream code.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR" && pwd -P)
cd "$ROOT"

TOTAL_STEPS=5
VERSION="${DSH_APP_VERSION:-0.1.0}"
BUNDLE_ID=""
BUNDLE_USER="${DSH_BUNDLE_USER:-${USER:-}}"
SKIP_FETCH=0
CLEAN=0
SIGN=0
WANT_DMG=0
PROXY=""

usage() {
    cat <<'EOF'
usage: ./make.sh [--skip-fetch] [--clean] [--no-sign | --sign] [--dmg]
                 [--version X.Y.Z] [--bundle-id ID] [--proxy URL]

Builds DSH.app from the official sources in five steps, then packages
dist/<name>.zip (which also contains LICENSES/ and THIRD_PARTY_NOTICES.md).

  --skip-fetch      reuse build/runtime and build/node_modules (no downloads)
  --clean           delete build/ and dist/ before starting
  --no-sign         do not sign the app (default)
  --sign            ad-hoc codesign with `codesign --force --deep -s -`
  --dmg             also build a compressed .dmg
  --version X.Y.Z   bundle version and artifact name (default: 0.1.0)
  --bundle-id ID    CFBundleIdentifier (default: io.github.<user>.dsh-mac-portable)
  --proxy URL       proxy for nodejs.org and the npm registry
  -h, --help        show this help

exit codes: 0 ok, 1 step failed, 2 usage error, 3 incomplete --skip-fetch,
            4 --sign without codesign. Full details: docs/BUILD.md.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage_die() {
    printf 'error: %s\n\n' "$*" >&2
    usage >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-fetch) SKIP_FETCH=1; shift ;;
        --clean) CLEAN=1; shift ;;
        --no-sign) SIGN=0; shift ;;
        --sign) SIGN=1; shift ;;
        --dmg) WANT_DMG=1; shift ;;
        --version)
            [ "$#" -ge 2 ] || usage_die "--version needs a value"
            VERSION=$2
            shift 2
            ;;
        --version=*) VERSION=${1#*=}; shift ;;
        --bundle-id)
            [ "$#" -ge 2 ] || usage_die "--bundle-id needs a value"
            BUNDLE_ID=$2
            shift 2
            ;;
        --bundle-id=*) BUNDLE_ID=${1#*=}; shift ;;
        --proxy)
            [ "$#" -ge 2 ] || usage_die "--proxy needs a value"
            PROXY=$2
            shift 2
            ;;
        --proxy=*) PROXY=${1#*=}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage_die "unknown argument: $1" ;;
    esac
done

case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) usage_die "--version expects X.Y.Z, got: $VERSION" ;;
esac

# Default bundle identifier: io.github.<sanitised user>.dsh-mac-portable.
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
    *deepseek*)
        usage_die "bundle id must not contain 'deepseek' (brand rule, see BRAND.md): $BUNDLE_ID"
        ;;
esac

[ "$(uname -s)" = "Darwin" ] || die "this build must run on macOS (got $(uname -s)):
  the scripts download darwin-x64 binaries and cannot cross-build.
  On Windows/Linux you can still run: sh -n make.sh && bash -n scripts/*.sh && ./verify.sh"

[ -n "$BUNDLE_ID" ] || die "internal: empty bundle id"
case "$PROXY" in
    '') ;;
    *[[:space:]]*) usage_die "--proxy must not contain whitespace" ;;
esac

if [ "$CLEAN" -eq 1 ]; then
    printf '== clean: removing build/ and dist/\n'
    rm -rf -- "$ROOT/build" "$ROOT/dist"
fi

# ---------------------------------------------------------------------------
# step helpers
# ---------------------------------------------------------------------------
run_step() {
    step_num=$1
    step_name=$2
    step_hint=$3
    shift 3

    printf '\n== [%s/%s] %s\n' "$step_num" "$TOTAL_STEPS" "$step_name"
    if "$@"; then
        return 0
    else
        step_rc=$?
    fi

    printf '\nFAILED: step %s/%s (%s) exited with code %s\n' \
        "$step_num" "$TOTAL_STEPS" "$step_name" "$step_rc" >&2
    printf 'next: %s\n' "$step_hint" >&2
    printf 'see:  docs/TROUBLESHOOTING.md\n' >&2
    exit "$step_rc"
}

step_fetch_runtime() {
    if [ "$SKIP_FETCH" -eq 1 ]; then
        if [ ! -x "$ROOT/build/runtime/node/bin/node" ]; then
            printf 'error: --skip-fetch given, but build/runtime/node/bin/node is missing\n' >&2
            return 3
        fi
        printf 'skipped (build/runtime present)\n'
        return 0
    fi
    if [ -n "$PROXY" ]; then
        "$ROOT/scripts/fetch-runtime.sh" --proxy "$PROXY"
    else
        "$ROOT/scripts/fetch-runtime.sh"
    fi
}

step_fetch_dsh() {
    if [ "$SKIP_FETCH" -eq 1 ]; then
        if [ ! -f "$ROOT/build/node_modules/@deepseek-ai/dsh/lib/bin.js" ]; then
            printf 'error: --skip-fetch given, but build/node_modules/@deepseek-ai/dsh/lib/bin.js is missing\n' >&2
            return 3
        fi
        printf 'skipped (build/node_modules present)\n'
        return 0
    fi
    if [ -n "$PROXY" ]; then
        "$ROOT/scripts/fetch-dsh.sh" --proxy "$PROXY"
    else
        "$ROOT/scripts/fetch-dsh.sh"
    fi
}

step_patch_minos() {
    sherpa="$ROOT/build/node_modules/sherpa-onnx-darwin-x64/sherpa-onnx.node"
    if [ ! -f "$sherpa" ]; then
        printf 'note: %s not found; nothing to patch for this DSH version\n' "$sherpa"
        return 0
    fi
    py=${PYTHON:-}
    if [ -z "$py" ]; then
        for candidate in python3 python; do
            if command -v "$candidate" >/dev/null 2>&1 \
                && "$candidate" -c 'import sys; sys.exit(0)' 2>/dev/null; then
                py=$candidate
                break
            fi
        done
    fi
    if [ -z "$py" ]; then
        printf 'error: python3 not found; it is needed for the Mach-O minos patch\n' >&2
        printf 'hint: xcode-select --install\n' >&2
        return 1
    fi
    "$py" "$ROOT/scripts/patch-sherpa-minos.py" "$sherpa"
}

step_build_app() {
    "$ROOT/scripts/build-launcher.sh" --force \
        --version "$VERSION" --bundle-id "$BUNDLE_ID"
    if [ "$SIGN" -eq 1 ]; then
        if ! command -v codesign >/dev/null 2>&1; then
            printf 'error: --sign requested but codesign is not available\n' >&2
            return 4
        fi
        printf '== ad-hoc signing (codesign -s -); no notarisation is performed\n'
        codesign --force --deep --sign - "$ROOT/build/DSH.app"
    fi
}

step_package() {
    if [ "$WANT_DMG" -eq 1 ]; then
        "$ROOT/scripts/make-dmg-or-zip.sh" --force --dmg --version "$VERSION"
    else
        "$ROOT/scripts/make-dmg-or-zip.sh" --force --version "$VERSION"
    fi
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
printf 'dsh-mac-portable -- B tier build\n'
printf '  repo:      %s\n' "$ROOT"
printf '  version:   %s\n' "$VERSION"
printf '  bundle id: %s\n' "$BUNDLE_ID"
printf '  signing:   %s\n' "$([ "$SIGN" -eq 1 ] && printf 'ad-hoc' || printf 'none (default)')"

run_step 1 "fetch Node.js runtime" \
    "check network/proxy (--proxy http://host:port), or rerun with --skip-fetch if build/runtime is already installed" \
    step_fetch_runtime

run_step 2 "install @deepseek-ai/dsh from npm" \
    "check registry access; pin a version with DSH_VERSION=0.2.1-rc.3, or rerun with --skip-fetch if build/node_modules is complete" \
    step_fetch_dsh

run_step 3 "lower sherpa-onnx minos (15.0 -> 11.0)" \
    "inspect with: python3 scripts/patch-sherpa-minos.py --dry-run build/node_modules/sherpa-onnx-darwin-x64/sherpa-onnx.node" \
    step_patch_minos

run_step 4 "assemble DSH.app" \
    "run: ./scripts/build-launcher.sh --force --version $VERSION --bundle-id $BUNDLE_ID" \
    step_build_app

run_step 5 "package zip (+ SHA256SUMS)" \
    "check free disk and dist/ permissions; see docs/BUILD.md section 6" \
    step_package

printf '\n== done\n'
printf 'app:      %s\n' "$ROOT/build/DSH.app"
printf 'version:  %s\n' "$VERSION"
printf 'bundle:   %s\n' "$BUNDLE_ID"
if [ -d "$ROOT/dist" ]; then
    printf 'artifacts:\n'
    for artifact in "$ROOT"/dist/*; do
        [ -f "$artifact" ] || continue
        printf '  %s\n' "$artifact"
    done
fi
printf '\nnext: open build/DSH.app (unsigned: Gatekeeper will block on first launch;\n'
printf '      see README section 7), or inspect the zip:\n'
printf '      unzip -l dist/DSH-Portable-%s-macos11-x64.zip | grep -E "LICENSES/|THIRD_PARTY"\n' "$VERSION"
