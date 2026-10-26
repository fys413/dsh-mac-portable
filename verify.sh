#!/usr/bin/env bash
# verify.sh -- local, offline self-check for the dsh-mac-portable repository.
#
# Purpose
#   Guards the "A tier" promise: this repo contains only original scripts,
#   patches and documentation -- no upstream code, no binaries, no build
#   products, no secrets, and no accidental bloat.
#
# What it checks
#   1. required files exist (README/LICENSE/NOTICE/BRAND/CHANGELOG/docs/scripts,
#      the B-tier make.sh, THIRD_PARTY_NOTICES.md, LICENSES/*.txt and the CI
#      workflow);
#   2. every shell script passes `bash -n`, including make.sh (also `sh -n`);
#   3. scripts/patch-sherpa-minos.py passes a Python syntax check (if a real
#      python3/python interpreter is available);
#   4. make.sh keeps its documented options and step order;
#   5. no build products or binaries are tracked (node_modules/, *.asar, Mach-O,
#      archives, bundles);
#   6. the working tree stays under 5 MB and no file exceeds 5 MB;
#   7. no plaintext tokens/keys/passwords in tracked text files;
#   8. README keeps the "unofficial" disclaimer and points at the official source;
#   9. the bundle identifier is reverse-DNS, configurable and free of upstream
#      branding; the version reaches Info.plist;
#  10. licence texts and the third-party notices exist and are wired into the
#      packaging step;
#  11. scripts are staged with mode 100755 (needed for a fresh clone on macOS);
#  12. `git status --porcelain` is clean (skip with --allow-dirty before the
#      first commit).
#
# Prerequisites
#   bash 3.2+ (stock macOS), git, grep, find, du. python3 is optional; from the
#   repo root: chmod +x scripts/*.sh verify.sh.
#
# Usage
#   ./verify.sh                # strict, expects a clean git tree
#   ./verify.sh --allow-dirty  # for the first run, before `git commit`
#
# Exit codes
#   0  all checks passed
#   1  at least one check failed
#   2  usage error
#
# Licence: MIT (see LICENSE). Original to dsh-mac-portable.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR" && pwd -P)
cd "$ROOT"

ALLOW_DIRTY=0
case "${1:-}" in
    --allow-dirty) ALLOW_DIRTY=1 ;;
    "") ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'usage: verify.sh [--allow-dirty]\n' >&2; exit 2 ;;
esac

OK=0
BAD=0
pass() { OK=$((OK + 1)); printf 'ok    %s\n' "$*"; }
fail() { BAD=$((BAD + 1)); printf 'FAIL  %s\n' "$*" >&2; }
note() { printf 'note  %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

IS_GIT=0
if git rev-parse --git-dir >/dev/null 2>&1; then
    IS_GIT=1
fi

tracked_files() {
    if [ "$IS_GIT" -eq 1 ]; then
        git ls-files
    else
        find . -type f -not -path './.git/*' | sed 's#^\./##'
    fi
}

# --- 1. layout --------------------------------------------------------------
section "repository layout"
for f in README.md LICENSE NOTICE.md BRAND.md CHANGELOG.md .gitignore verify.sh \
         make.sh THIRD_PARTY_NOTICES.md \
         LICENSES/Apache-2.0.txt LICENSES/LGPL-3.0.txt LICENSES/README.md \
         .github/workflows/verify.yml \
         scripts/fetch-runtime.sh scripts/fetch-dsh.sh scripts/patch-sherpa-minos.py \
         scripts/make-icns.py \
         scripts/build-launcher.sh scripts/make-dmg-or-zip.sh \
         docs/BUILD.md docs/COMPLIANCE.md docs/TROUBLESHOOTING.md; do
    if [ -f "$f" ]; then pass "present: $f"; else fail "missing: $f"; fi
done

# --- 2. shell syntax --------------------------------------------------------
section "shell syntax (bash -n)"
SH_COUNT=0
for f in make.sh verify.sh scripts/*.sh; do
    [ -f "$f" ] || continue
    SH_COUNT=$((SH_COUNT + 1))
    if bash -n "$f" 2>/tmp/dsh-mp-bashn.$$; then
        pass "bash -n $f"
    else
        fail "bash -n $f: $(tr '\n' ' ' < /tmp/dsh-mp-bashn.$$)"
    fi
    rm -f "/tmp/dsh-mp-bashn.$$"
done
[ "$SH_COUNT" -ge 6 ] && pass "found $SH_COUNT shell scripts" || fail "expected at least 6 shell scripts"
if sh -n make.sh 2>/tmp/dsh-mp-shn.$$; then
    pass "make.sh passes sh -n (POSIX sh, as on stock macOS)"
else
    fail "make.sh: $(tr '\n' ' ' < /tmp/dsh-mp-shn.$$)"
fi
rm -f "/tmp/dsh-mp-shn.$$"

# Launcher heredoc: extract and syntax-check it without building the app.
LAUNCHER_TMP=$(mktemp /tmp/dsh-mp-launcher.XXXXXX) || LAUNCHER_TMP=
if [ -n "$LAUNCHER_TMP" ]; then
    if sed -n "/^cat > \"\$EXE\" <<'LAUNCHER_EOF'$/,/^LAUNCHER_EOF$/p" scripts/build-launcher.sh \
        | sed '1d;$d' > "$LAUNCHER_TMP" && [ -s "$LAUNCHER_TMP" ]; then
        if sh -n "$LAUNCHER_TMP" 2>/tmp/dsh-mp-shn.$$; then
            pass "embedded launcher passes sh -n"
        else
            fail "embedded launcher: $(tr '\n' ' ' < /tmp/dsh-mp-shn.$$)"
        fi
        rm -f "/tmp/dsh-mp-shn.$$"
    else
        fail "could not extract the embedded launcher from scripts/build-launcher.sh"
    fi
    rm -f "$LAUNCHER_TMP"
fi

# --- 3. B-tier entry point --------------------------------------------------
section "make.sh (B tier)"
if head -n 1 make.sh | grep -qx '#!/bin/sh'; then
    pass "make.sh uses a POSIX sh shebang"
else
    fail "make.sh must start with #!/bin/sh"
fi
if grep -q 'set -euo pipefail' make.sh; then
    pass "make.sh runs with set -euo pipefail"
else
    fail "make.sh must use set -euo pipefail"
fi
for opt in --skip-fetch --clean --no-sign --sign --dmg --version --bundle-id --proxy; do
    if grep -q -- "$opt" make.sh; then
        pass "make.sh documents $opt"
    else
        fail "make.sh is missing $opt"
    fi
done
# The five steps must be invoked in the documented order. Match the invocation
# (a quoted path), not the header comment that mentions the same script.
STEP_PREV=0
STEP_OK=1
for pat in '/scripts/fetch-runtime\.sh"' '/scripts/fetch-dsh\.sh"' \
           '/scripts/patch-sherpa-minos\.py"' '/scripts/build-launcher\.sh" --force' \
           '/scripts/make-dmg-or-zip\.sh" --force'; do
    STEP_LINE=$(grep -n "$pat" make.sh | head -n 1 | cut -d: -f1 || true)
    if [ -z "$STEP_LINE" ]; then
        fail "make.sh does not invoke a script matching $pat"
        STEP_OK=0
        break
    fi
    if [ "$STEP_LINE" -le "$STEP_PREV" ]; then
        fail "make.sh step order is wrong near $pat (line $STEP_LINE <= $STEP_PREV)"
        STEP_OK=0
        break
    fi
    STEP_PREV=$STEP_LINE
done
[ "$STEP_OK" -eq 1 ] && pass "make.sh invokes fetch-runtime, fetch-dsh, minos patch, launcher, packaging in order"

# --- 4. python syntax -------------------------------------------------------
section "python syntax"
PYTHON=${PYTHON:-}
if [ -z "$PYTHON" ]; then
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1; then
            if "$candidate" -c 'print(1)' 2>/dev/null | grep -qx 1; then
                PYTHON=$candidate
                break
            fi
        fi
    done
fi
if [ -n "$PYTHON" ]; then
    for pyfile in scripts/patch-sherpa-minos.py scripts/make-icns.py; do
        if "$PYTHON" - "$pyfile" <<'PY_EOF'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    compile(fh.read(), path, "exec")
PY_EOF
        then
            pass "python compiles: $pyfile ($PYTHON)"
        else
            fail "python syntax error: $pyfile"
        fi
    done
else
    note "no usable python3/python found; skipped the Python syntax check"
fi

# --- 5. no upstream code or binaries ---------------------------------------
section "no upstream code or binaries tracked"
if [ "$IS_GIT" -eq 1 ]; then
    if git ls-files | grep -qE '(^|/)(node_modules|build|dist)/|\.asar$|\.node$|\.dylib$|\.tar\.gz$|\.zip$|\.dmg$|DSH\.app/'; then
        fail "tracked files include build products or binaries:"
        git ls-files | grep -E '(^|/)(node_modules|build|dist)/|\.asar$|\.node$|\.dylib$|\.tar\.gz$|\.zip$|\.dmg$|DSH\.app/' | sed 's/^/        /' >&2
    else
        pass "no node_modules/, build/, dist/, .asar, .node, archives or bundles tracked"
    fi
    if git ls-files | grep -q '^node_modules/@deepseek-ai/dsh/'; then
        fail "upstream DSH source tree is tracked"
    else
        pass "no @deepseek-ai/dsh source copy in git"
    fi
else
    note "not a git repository yet; checking the working tree instead"
    if find . -path ./.git -prune -o \( -name '*.asar' -o -name '*.node' -o -name '*.dylib' \) -print | grep -q .; then
        fail "binary artifacts present in the working tree"
    else
        pass "no .asar/.node/.dylib in the working tree"
    fi
fi

# --- 6. size ----------------------------------------------------------------
section "size"
TOTAL_KB=$(du -sk . | awk '{print $1}')
if [ "$TOTAL_KB" -lt 5120 ]; then
    pass "repository size: $((TOTAL_KB / 1024)) MB (limit 5 MB)"
else
    fail "repository size is $((TOTAL_KB / 1024)) MB, over the 5 MB limit"
fi
BIG=$(find . -path ./.git -prune -o -type f -size +5120k -print 2>/dev/null | head -n 5)
if [ -z "$BIG" ]; then
    pass "no file larger than 5 MB in the working tree"
else
    fail "files larger than 5 MB found:"
    printf '        %s\n' "$BIG" >&2
fi
HUNDRED=$(find . -path ./.git -prune -o -type f -size +102400k -print 2>/dev/null | head -n 5)
if [ -n "$HUNDRED" ]; then
    fail "files larger than 100 MB found (GitHub rejects them):"
    printf '        %s\n' "$HUNDRED" >&2
else
    pass "no file larger than 100 MB"
fi

# --- 7. secrets -------------------------------------------------------------
section "secret scan"
FILES=$(tracked_files | grep -v '^verify\.sh$' || true)
if [ -z "$FILES" ]; then
    note "no files to scan"
else
    # shellcheck disable=SC2086
    HITS=$(printf '%s\n' "$FILES" | while IFS= read -r f; do
        [ -f "$f" ] || continue
        grep -nEI \
            -e '(token|secret|password|passwd|api[_-]?key)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9]' \
            -e 'gh[pousr]_[A-Za-z0-9]{20,}' \
            -e 'sk-[A-Za-z0-9]{20,}' \
            -e 'AKIA[0-9A-Z]{16}' \
            -e 'BEGIN [A-Z ]*PRIVATE KEY' \
            -e 'Bearer [A-Za-z0-9._-]{20,}' \
            "$f" 2>/dev/null | sed "s#^#$f:#" || true
    done)
    if [ -z "$HITS" ]; then
        pass "no plaintext token/secret/password/private key in tracked files"
    else
        fail "possible secrets found:"
        printf '%s\n' "$HITS" | sed 's/^/        /' >&2
    fi
fi

# --- 8. disclaimers and branding -----------------------------------------
section "disclaimers and branding"
if grep -q '非官方' README.md; then
    pass 'README contains the Chinese unofficial disclaimer'
else
    fail 'README is missing the "非官方" disclaimer'
fi
if grep -qiE 'unofficial|not affiliated' README.md; then
    pass "README contains an English unofficial/not-affiliated statement"
else
    fail "README is missing an English unofficial/not-affiliated statement"
fi
if grep -qF 'BUNDLE_ID="io.github.$BUNDLE_USER.dsh-mac-portable"' scripts/build-launcher.sh; then
    pass "default bundle identifier is io.github.<user>.dsh-mac-portable"
else
    fail "scripts/build-launcher.sh does not derive the neutral default bundle identifier"
fi
if grep -q -- '--bundle-id' scripts/build-launcher.sh make.sh; then
    pass "bundle identifier is configurable (--bundle-id)"
else
    fail "bundle identifier is not configurable via --bundle-id"
fi
if grep -qF '<string>${BUNDLE_ID}</string>' scripts/build-launcher.sh; then
    pass "Info.plist uses the configured CFBundleIdentifier"
else
    fail "Info.plist does not use \${BUNDLE_ID}"
fi
PLIST_VERSIONS=$(grep -cF '<string>${APP_VERSION}</string>' scripts/build-launcher.sh || true)
if [ "$PLIST_VERSIONS" -eq 2 ]; then
    pass "Info.plist writes --version to CFBundleShortVersionString and CFBundleVersion"
else
    fail "expected 2 versioned plist strings, found $PLIST_VERSIONS"
fi
if grep -q -e 'com\.example\.dsh-mac-portable' scripts/build-launcher.sh README.md \
        docs/BUILD.md docs/COMPLIANCE.md BRAND.md NOTICE.md; then
    fail "stale com.example.dsh-mac-portable identifier in the script or docs"
else
    pass "no hard-coded com.example.dsh-mac-portable identifier remains"
fi
if grep -q '\*deepseek\*' scripts/build-launcher.sh && grep -q '\*deepseek\*' make.sh; then
    pass "both entry points reject 'deepseek' inside a bundle identifier"
else
    fail "bundle-id validation for the 'deepseek' brand rule is missing"
fi
if grep -q 'https://deepseek.com/harness' README.md && grep -q '@deepseek-ai/dsh@next' README.md; then
    pass "README points at the official npm package and download page"
else
    fail "README must link the official npm package and download page"
fi

# --- 9. third-party compliance ---------------------------------------------
section "third-party compliance"
for f in LICENSES/Apache-2.0.txt LICENSES/LGPL-3.0.txt THIRD_PARTY_NOTICES.md; do
    if [ -s "$f" ]; then pass "non-empty: $f"; else fail "missing or empty: $f"; fi
done
if grep -q 'Apache License' LICENSES/Apache-2.0.txt; then
    pass "LICENSES/Apache-2.0.txt contains the Apache License text"
else
    fail "LICENSES/Apache-2.0.txt does not look like the Apache License"
fi
if grep -q 'GNU LESSER GENERAL PUBLIC LICENSE' LICENSES/LGPL-3.0.txt; then
    pass "LICENSES/LGPL-3.0.txt contains the LGPL text"
else
    fail "LICENSES/LGPL-3.0.txt does not look like the LGPL"
fi
for needle in 'sherpa-onnx' '15.0.0' '11.0.0' 'LGPL-3.0-or-later' \
              'https://github.com/lovell/sharp-libvips'; do
    if grep -qF -- "$needle" THIRD_PARTY_NOTICES.md; then
        pass "THIRD_PARTY_NOTICES.md mentions $needle"
    else
        fail "THIRD_PARTY_NOTICES.md is missing $needle"
    fi
done
if grep -q 'LICENSES' scripts/make-dmg-or-zip.sh \
        && grep -q 'THIRD_PARTY_NOTICES.md' scripts/make-dmg-or-zip.sh; then
    pass "packaging step adds LICENSES/ and THIRD_PARTY_NOTICES.md to the artifact"
else
    fail "scripts/make-dmg-or-zip.sh does not package the licence files"
fi

# --- 10. CI workflow --------------------------------------------------------
section "CI workflow"
CI_FILE=.github/workflows/verify.yml
if grep -q 'runs-on: macos-13' "$CI_FILE"; then
    pass "CI runs on macos-13"
else
    fail "CI does not pin runs-on: macos-13"
fi
if grep -q 'push, pull_request' "$CI_FILE"; then
    pass "CI triggers on push and pull_request"
else
    fail "CI does not trigger on push and pull_request"
fi
if grep -qF './verify.sh' "$CI_FILE" && grep -qF './make.sh --help' "$CI_FILE"; then
    pass "CI runs ./verify.sh and the read-only ./make.sh --help"
else
    fail "CI is missing ./verify.sh or ./make.sh --help"
fi

# --- 11. executable bits in the index --------------------------------------
section "executable bits"
if [ "$IS_GIT" -eq 1 ]; then
    UNTRACKED=$(git status --porcelain -- make.sh verify.sh scripts/*.sh scripts/patch-sherpa-minos.py 2>/dev/null | grep '^??' || true)
    if [ -n "$UNTRACKED" ]; then
        fail "scripts are not added to git yet (run git add -A):"
        printf '%s\n' "$UNTRACKED" | sed 's/^/        /' >&2
    fi
    MISSING=$(git ls-files -s -- make.sh verify.sh scripts/*.sh scripts/patch-sherpa-minos.py 2>/dev/null \
        | awk '$1 != "100755" {print $4}')
    if [ -z "$MISSING" ]; then
        pass "all scripts are staged as 100755"
    else
        fail "not staged as 100755 (fix: git update-index --chmod=+x <file>):"
        printf '%s\n' "$MISSING" | sed 's/^/        /' >&2
    fi
else
    for f in make.sh verify.sh scripts/*.sh scripts/patch-sherpa-minos.py; do
        [ -x "$f" ] || fail "not executable on disk: $f"
    done
    pass "executable bits checked on disk (not a git repo yet)"
fi

# --- 12. clean tree ---------------------------------------------------------
section "git status"
if [ "$IS_GIT" -eq 0 ]; then
    note "git repository not initialised; skipped the clean-tree check"
else
    DIRTY=$(git status --porcelain)
    if [ -z "$DIRTY" ]; then
        pass "git status --porcelain is empty"
    elif [ "$ALLOW_DIRTY" -eq 1 ]; then
        note "working tree is dirty (allowed by --allow-dirty):"
        printf '%s\n' "$DIRTY" | sed 's/^/        /'
    else
        fail "working tree is dirty; commit or stash, or pass --allow-dirty"
        printf '%s\n' "$DIRTY" | sed 's/^/        /' >&2
    fi
fi

# --- summary ----------------------------------------------------------------
section "summary"
printf 'files tracked: %s\n' "$(tracked_files | wc -l | tr -d ' ')"
printf 'repo size:     %s\n' "$(du -sh . | awk '{print $1}')"
printf 'checks:        %d ok, %d failed\n' "$OK" "$BAD"
if [ "$BAD" -eq 0 ]; then
    printf '\nverify: PASS\n'
    exit 0
fi
printf '\nverify: FAIL\n' >&2
exit 1
