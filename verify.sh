#!/usr/bin/env bash
# verify.sh -- local, offline self-check for the dsh-mac-portable repository.
#
# Purpose
#   Guards the "A tier" promise: this repo contains only original scripts,
#   patches and documentation -- no upstream code, no binaries, no build
#   products, no secrets, and no accidental bloat.
#
# What it checks
#   1. required files exist (README/LICENSE/NOTICE/BRAND/CHANGELOG/docs/scripts);
#   2. every shell script passes `bash -n`;
#   3. scripts/patch-sherpa-minos.py passes a Python syntax check (if a real
#      python3/python interpreter is available);
#   4. no build products or binaries are tracked (node_modules/, *.asar, Mach-O,
#      archives, bundles);
#   5. the working tree stays under 5 MB and no file exceeds 5 MB;
#   6. no plaintext tokens/keys/passwords in tracked text files;
#   7. README keeps the "unofficial" disclaimer and points at the official source;
#   8. scripts are staged with mode 100755 (needed for a fresh clone on macOS);
#   9. `git status --porcelain` is clean (skip with --allow-dirty before the
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
         scripts/fetch-runtime.sh scripts/fetch-dsh.sh scripts/patch-sherpa-minos.py \
         scripts/build-launcher.sh scripts/make-dmg-or-zip.sh \
         docs/BUILD.md docs/COMPLIANCE.md docs/TROUBLESHOOTING.md; do
    if [ -f "$f" ]; then pass "present: $f"; else fail "missing: $f"; fi
done

# --- 2. shell syntax --------------------------------------------------------
section "shell syntax (bash -n)"
SH_COUNT=0
for f in verify.sh scripts/*.sh; do
    [ -f "$f" ] || continue
    SH_COUNT=$((SH_COUNT + 1))
    if bash -n "$f" 2>/tmp/dsh-mp-bashn.$$; then
        pass "bash -n $f"
    else
        fail "bash -n $f: $(tr '\n' ' ' < /tmp/dsh-mp-bashn.$$)"
    fi
    rm -f "/tmp/dsh-mp-bashn.$$"
done
[ "$SH_COUNT" -ge 5 ] && pass "found $SH_COUNT shell scripts" || fail "expected at least 5 shell scripts"

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

# --- 3. python syntax -------------------------------------------------------
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
    if "$PYTHON" - scripts/patch-sherpa-minos.py <<'PY_EOF'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    compile(fh.read(), path, "exec")
PY_EOF
    then
        pass "python compiles: scripts/patch-sherpa-minos.py ($PYTHON)"
    else
        fail "python syntax error: scripts/patch-sherpa-minos.py"
    fi
else
    note "no usable python3/python found; skipped the Python syntax check"
fi

# --- 4. no upstream code or binaries ---------------------------------------
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

# --- 5. size ----------------------------------------------------------------
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

# --- 6. secrets -------------------------------------------------------------
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

# --- 7. documentation disclaimers -----------------------------------------
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
if grep -q 'com\.example\.dsh-mac-portable' scripts/build-launcher.sh; then
    pass "bundle identifier is neutral (com.example.dsh-mac-portable)"
else
    fail "scripts/build-launcher.sh does not set the neutral bundle identifier"
fi
BUNDLE_ID=$(sed -n '/<key>CFBundleIdentifier<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' scripts/build-launcher.sh | head -n 1)
if [ -n "$BUNDLE_ID" ]; then
    pass "bundle identifier: $BUNDLE_ID"
else
    fail "could not read CFBundleIdentifier from scripts/build-launcher.sh"
fi
case "$BUNDLE_ID" in
    *deepseek*) fail "bundle identifier must not contain 'deepseek': $BUNDLE_ID" ;;
    *) pass "bundle identifier contains no upstream brand" ;;
esac
if grep -q 'https://deepseek.com/harness' README.md && grep -q '@deepseek-ai/dsh@next' README.md; then
    pass "README points at the official npm package and download page"
else
    fail "README must link the official npm package and download page"
fi

# --- 8. executable bits in the index --------------------------------------
section "executable bits"
if [ "$IS_GIT" -eq 1 ]; then
    UNTRACKED=$(git status --porcelain -- verify.sh scripts/*.sh scripts/patch-sherpa-minos.py 2>/dev/null | grep '^??' || true)
    if [ -n "$UNTRACKED" ]; then
        fail "scripts are not added to git yet (run git add -A):"
        printf '%s\n' "$UNTRACKED" | sed 's/^/        /' >&2
    fi
    MISSING=$(git ls-files -s -- verify.sh scripts/*.sh scripts/patch-sherpa-minos.py 2>/dev/null \
        | awk '$1 != "100755" {print $4}')
    if [ -z "$MISSING" ]; then
        pass "all scripts are staged as 100755"
    else
        fail "not staged as 100755 (fix: git update-index --chmod=+x <file>):"
        printf '%s\n' "$MISSING" | sed 's/^/        /' >&2
    fi
else
    for f in verify.sh scripts/*.sh scripts/patch-sherpa-minos.py; do
        [ -x "$f" ] || fail "not executable on disk: $f"
    done
    pass "executable bits checked on disk (not a git repo yet)"
fi

# --- 9. clean tree ----------------------------------------------------------
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
