#!/usr/bin/env python3
"""patch-sherpa-minos.py -- lower the macOS ``minos`` of a Mach-O binary.

Purpose
  Some darwin-x64 prebuilds published on npm are compiled against a much newer
  SDK than macOS 11 (Big Sur), for example ``sherpa-onnx.node`` built with
  minos 15.0. On Big Sur such a dylib/addon fails to load even though it only
  uses older APIs. This script rewrites the 4-byte ``minos`` field of every
  ``LC_BUILD_VERSION`` load command in place (nothing else is touched) so the
  binary declares 11.0.0 as its minimum OS.

  Big Sur risk is contained: the file is backed up first (unless --no-backup),
  a code-signed binary is refused unless --force, and every patched byte offset
  is printed so the change can be audited or reverted.

  The same helper is generic: pass any thin 64-bit Mach-O (or a fat binary;
  every architecture slice is patched).

Preconditions
  - Python 3.8+ (macOS: ``xcode-select --install`` provides /usr/bin/python3).
  - The target must be an *unsigned* Mach-O: modifying a signed binary
    invalidates its signature. LC_CODE_SIGNATURE is detected; pass --force only
    if you intend to re-sign afterwards.
  - Write permission on the target and its directory (for the backup).

Usage
  ./scripts/patch-sherpa-minos.py PATH [PATH ...] [options]

  PATH                    one or more Mach-O files, e.g.
                          build/node_modules/sherpa-onnx-darwin-x64/sherpa-onnx.node
  --target VERSION        minimum OS to declare (default: 11.0.0)
  --backup-suffix SUFFIX  backup name appended to PATH (default: .minos-backup)
  --no-backup             do not create a backup (not recommended)
  --dry-run               report what would change; write nothing
  --force                 patch even if LC_CODE_SIGNATURE is present
  --quiet                 only print errors

Exit codes
  0  every file is at or below --target (patched now or already fine)
  1  at least one file could not be handled (not Mach-O, unsupported, signed,
     no LC_BUILD_VERSION, I/O error) -- other files are still processed
  2  usage error (argparse)

License: MIT, Copyright (c) 2026 dsh-mac-portable contributors.
"""

import argparse
import os
import re
import shutil
import struct
import sys

# Mach-O magics as they appear in the first four bytes of the file.
THIN_64 = b"\xcf\xfa\xed\xfe"
THIN_32 = b"\xce\xfa\xed\xfe"
FAT_32 = b"\xca\xfe\xba\xbe"
FAT_64 = b"\xca\xfe\xba\xbf"

MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
LC_BUILD_VERSION = 0x32
LC_CODE_SIGNATURE = 0x1D

VERSION_RE = re.compile(r"^(\d{1,3})\.(\d{1,3})(?:\.(\d{1,3}))?$")


def encode_version(text):
    """'11.0.0' -> 0x000B0000 (major<<16 | minor<<8 | patch)."""
    m = VERSION_RE.match(text)
    if not m:
        raise ValueError("bad version %r (expected MAJOR.MINOR[.PATCH])" % text)
    major, minor, patch = (int(m.group(i) or 0) for i in (1, 2, 3))
    if major > 0xFFFF or minor > 0xFF or patch > 0xFF:
        raise ValueError("version component out of range: %r" % text)
    return (major << 16) | (minor << 8) | patch


def decode_version(value):
    return "%d.%d.%d" % ((value >> 16) & 0xFFFF, (value >> 8) & 0xFF, value & 0xFF)


def slices(path, size):
    """Yield (slice_offset, slice_size) for every architecture in the file."""
    with open(path, "rb") as f:
        magic = f.read(4)
        if magic in (THIN_64, THIN_32):
            yield (0, size)
            return
        if magic not in (FAT_32, FAT_64):
            raise ValueError(
                "not a Mach-O file (magic %s); expected thin or fat Mach-O"
                % magic.hex()
            )
        is64 = magic == FAT_64
        (nfat,) = struct.unpack(">I", f.read(4))
        if nfat == 0 or nfat > 64:
            raise ValueError("implausible fat architecture count: %d" % nfat)
        entry_size = 32 if is64 else 20
        for _ in range(nfat):
            raw = f.read(entry_size)
            if len(raw) != entry_size:
                raise ValueError("truncated fat_arch table")
            if is64:
                _cputype, _cpusub, offset, slen = struct.unpack(">IIQQ", raw[:24])
            else:
                _cputype, _cpusub, offset, slen = struct.unpack(">IIII", raw[:16])
            if offset + slen > size or slen < 32:
                raise ValueError(
                    "fat slice out of bounds (offset=%d size=%d)" % (offset, slen)
                )
            yield (offset, slen)


def inspect_slice(f, base, slen):
    """Parse one Mach-O slice without writing anything.

    Returns (header_size, entries, signed), where entries is a list of
    (platform, minos, cmd_offset) tuples, one per LC_BUILD_VERSION command.
    Raises ValueError on malformed input.
    """
    f.seek(base)
    head = f.read(28)
    if len(head) < 28:
        raise ValueError("truncated Mach-O header")
    (magic,) = struct.unpack("<I", head[0:4])
    if magic == MH_MAGIC_64:
        header_size = 32
        (ncmds, sizeofcmds) = struct.unpack("<II", head[16:24])
    elif magic == MH_MAGIC:
        header_size = 28
        (ncmds, sizeofcmds) = struct.unpack("<II", head[16:24])
    else:
        raise ValueError("unsupported Mach-O magic 0x%08x at 0x%x" % (magic, base))

    if header_size + sizeofcmds > slen:
        raise ValueError("load-command region does not fit the image")
    f.seek(base + header_size)
    cmds = f.read(sizeofcmds)
    if len(cmds) != sizeofcmds:
        raise ValueError("truncated load-command region")

    # Walk every load command, collect LC_BUILD_VERSION entries and detect
    # LC_CODE_SIGNATURE. The signature command is usually near the end, so it
    # must be seen *before* any byte is written.
    offset = 0
    entries = []
    signed = False
    for _ in range(ncmds):
        if offset + 8 > len(cmds):
            raise ValueError("truncated load command at 0x%x" % (base + header_size + offset))
        (cmd, cmdsize) = struct.unpack("<II", cmds[offset : offset + 8])
        if cmdsize < 8 or offset + cmdsize > len(cmds):
            raise ValueError("bad cmdsize for cmd 0x%x" % cmd)
        if cmd == LC_CODE_SIGNATURE:
            signed = True
        if cmd == LC_BUILD_VERSION:
            if cmdsize < 24:
                raise ValueError("LC_BUILD_VERSION too short (%d bytes)" % cmdsize)
            (platform, minos, _sdk) = struct.unpack(
                "<III", cmds[offset + 8 : offset + 20]
            )
            entries.append((platform, minos, offset))
        offset += cmdsize

    return header_size, entries, signed


def patch_slice(f, base, slen, target, dry_run, force, label, quiet=False):
    """Patch LC_BUILD_VERSION.minos inside one Mach-O slice.

    Returns (patched_count, skipped_already_ok_count, signed).
    Raises ValueError on malformed input or on a signed binary without --force.
    """
    header_size, entries, signed = inspect_slice(f, base, slen)
    if not entries:
        return 0, 0, signed

    todo = [e for e in entries if e[1] > target]
    skipped = len(entries) - len(todo)
    if todo and signed and not force:
        raise ValueError(
            "LC_CODE_SIGNATURE present: patching would invalidate the signature "
            "(re-run with --force to override)"
        )

    # Write only the 4-byte minos field, nothing else.
    for platform, minos, cmd_offset in todo:
        field = base + header_size + cmd_offset + 12
        if not dry_run:
            f.seek(field)
            f.write(struct.pack("<I", target))
        if not quiet:
            print(
                "%s: %s platform=%d minos %s -> %s (field 0x%x)"
                % (
                    label,
                    "would patch" if dry_run else "patched",
                    platform,
                    decode_version(minos),
                    decode_version(target),
                    field,
                )
            )
    return len(todo), skipped, signed


def backup(path, suffix):
    dest = path + suffix
    if os.path.exists(dest):
        return dest, False
    shutil.copy2(path, dest)
    return dest, True


def process(path, target, suffix, no_backup, dry_run, force, quiet):
    if not os.path.exists(path):
        print("ERROR: %s: no such file" % path, file=sys.stderr)
        return 1
    if os.path.isdir(path):
        print("ERROR: %s: is a directory (pass the Mach-O file)" % path, file=sys.stderr)
        return 1
    size = os.path.getsize(path)
    if size == 0:
        print("ERROR: %s: empty file" % path, file=sys.stderr)
        return 1

    try:
        spans = list(slices(path, size))
    except (OSError, ValueError, struct.error) as exc:
        print("ERROR: %s: %s" % (path, exc), file=sys.stderr)
        return 1

    labels = [path if len(spans) == 1 else "%s[slice%d]" % (path, i)
              for i in range(len(spans))]

    # Preflight: parse and validate every slice before touching the file or
    # creating a backup, so a bad input leaves no stray .minos-backup behind.
    try:
        with open(path, "rb") as f:
            pre = [
                inspect_slice(f, base, slen) for (base, slen) in spans
            ]
    except (OSError, ValueError, struct.error) as exc:
        print("ERROR: %s: %s" % (path, exc), file=sys.stderr)
        return 1

    total_patched = 0
    total_skipped = 0
    for header_size, entries, _signed in pre:
        total_patched += sum(1 for (_p, minos, _o) in entries if minos > target)
        total_skipped += sum(1 for (_p, minos, _o) in entries if minos <= target)
    any_signed = any(signed for (_h, _e, signed) in pre)

    if total_patched == 0 and total_skipped == 0:
        print(
            "ERROR: %s: no LC_BUILD_VERSION load command found "
            "(not a macOS binary?)" % path,
            file=sys.stderr,
        )
        return 1
    if total_patched and any_signed and not force:
        print(
            "ERROR: %s: LC_CODE_SIGNATURE present: patching would invalidate "
            "the signature (re-run with --force to override)" % path,
            file=sys.stderr,
        )
        return 1

    if total_patched == 0:
        if not quiet:
            print(
                "%s: already at or below %s (%d LC_BUILD_VERSION); nothing to do"
                % (path, decode_version(target), total_skipped)
            )
        return 0

    if not dry_run and not no_backup:
        dest, created = backup(path, suffix)
        if not quiet:
            print("%s: backup %s%s" % (path, "created " if created else "reused  ", dest))

    mode = "rb" if dry_run else "r+b"
    try:
        with open(path, mode) as f:
            for index, ((base, slen), label) in enumerate(zip(spans, labels)):
                patched, skipped, signed = patch_slice(
                    f, base, slen, target, dry_run, force, label
                )
                expected = sum(1 for (_p, m, _o) in pre[index][1] if m > target)
                if patched != expected:
                    raise ValueError("load commands changed underneath us; aborting")
    except (OSError, ValueError, struct.error) as exc:
        print("ERROR: %s: %s" % (path, exc), file=sys.stderr)
        return 1

    if not quiet:
        print(
            "%s: %s %d LC_BUILD_VERSION command(s); %d already <= %s"
            % (
                path,
                "would patch" if dry_run else "patched",
                total_patched,
                total_skipped,
                decode_version(target),
            )
        )
    if any_signed and not dry_run and force:
        print(
            "WARNING: %s is code-signed; re-sign it (codesign --force --sign - %s)"
            % (path, path),
            file=sys.stderr,
        )
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        prog="patch-sherpa-minos.py",
        description="Lower the Mach-O LC_BUILD_VERSION minos field in place.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  ./scripts/patch-sherpa-minos.py \\\n"
            "      build/node_modules/sherpa-onnx-darwin-x64/sherpa-onnx.node\n"
            "  ./scripts/patch-sherpa-minos.py --dry-run --target 11.0.0 some.node\n"
        ),
    )
    parser.add_argument("paths", nargs="+", metavar="PATH", help="Mach-O file(s) to patch")
    parser.add_argument("--target", default="11.0.0", help="minimum OS (default: 11.0.0)")
    parser.add_argument(
        "--backup-suffix",
        default=".minos-backup",
        help="suffix for the backup copy (default: .minos-backup)",
    )
    parser.add_argument("--no-backup", action="store_true", help="skip the backup copy")
    parser.add_argument("--dry-run", action="store_true", help="report only, write nothing")
    parser.add_argument(
        "--force", action="store_true", help="patch even if LC_CODE_SIGNATURE is present"
    )
    parser.add_argument("--quiet", action="store_true", help="only print errors")
    args = parser.parse_args(argv)

    try:
        target = encode_version(args.target)
    except ValueError as exc:
        parser.error(str(exc))
        return 2

    rc = 0
    for path in args.paths:
        rc |= process(
            path,
            target,
            args.backup_suffix,
            args.no_backup,
            args.dry_run,
            args.force,
            args.quiet,
        )
    return 0 if rc == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
