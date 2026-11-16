#!/usr/bin/env python3
"""Snapshot a synthetic fixture without following symlinks.

Usage: python3 extension-binding-diagnostics.py ROOT DESTINATION
DESTINATION receives a valid fixture.tar (at most 8 MiB), with at most 256 KiB
from each regular file, plus an 8 KiB truncation.txt manifest. Budgets include
archive headers, end records, and padding; oversized files retain their prefix.
"""
import io
import os
from pathlib import Path
import stat
import sys
import tarfile

ARCHIVE_LIMIT = 8 * 1024 * 1024
FILE_LIMIT = 256 * 1024
MANIFEST_LIMIT = 8 * 1024


def snapshot(root, destination):
    truncated = 0
    omitted = 0
    details = []

    def note(kind, name):
        nonlocal truncated, omitted
        if kind == "truncated":
            truncated += 1
        else:
            omitted += 1
        if len(details) < 16:
            details.append(f"{kind}: {str(name)[:256]}")

    def paths():
        yield root
        for current, directories, files in os.walk(
                root, followlinks=False, onerror=lambda error: note("omitted", error.filename)):
            directories.sort()
            for name in sorted(directories + files):
                yield Path(current) / name

    with tarfile.open(destination / "fixture.tar", "w", dereference=False) as archive:
        for source in paths():
            name = "." if source == root else "./" + source.relative_to(root).as_posix()
            try:
                info = archive.gettarinfo(str(source), arcname=name)
                if info is None:
                    note("omitted", name)
                    continue
                data = b""
                original_size = info.size
                if info.isfile():
                    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    with os.fdopen(fd, "rb") as stream:
                        opened = os.fstat(stream.fileno())
                        if not stat.S_ISREG(opened.st_mode):
                            note("omitted", name)
                            continue
                        original_size = opened.st_size
                        data = stream.read(min(original_size, FILE_LIMIT))
                        original_size = max(original_size, os.fstat(stream.fileno()).st_size)
                    info.size = len(data)
                header_size = len(info.tobuf(archive.format, archive.encoding, archive.errors))
                # tarfile closes with two zero blocks and pads to RECORDSIZE.
                available = (ARCHIVE_LIMIT // tarfile.RECORDSIZE) * tarfile.RECORDSIZE
                available -= archive.offset + header_size + 2 * tarfile.BLOCKSIZE
                if available < 0:
                    note("omitted", name)
                    break  # The archive is full; at least this entry was omitted.
                if info.isfile():
                    info.size = min(info.size, (available // tarfile.BLOCKSIZE) * tarfile.BLOCKSIZE)
                    data = data[:info.size]
                    if info.size < original_size:
                        note("truncated", name)
                archive.addfile(info, io.BytesIO(data) if info.isfile() else None)
            except (OSError, ValueError) as error:
                note("omitted", name)
                if len(details) < 16:
                    details.append(f"reason: {str(error)[:256]}")
    manifest = [
        f"archive_limit_bytes={ARCHIVE_LIMIT}",
        f"file_limit_bytes={FILE_LIMIT}",
        f"manifest_limit_bytes={MANIFEST_LIMIT}",
        f"truncation={int(bool(truncated or omitted))}",
        f"truncated_files={truncated}",
        f"omitted_entries_at_least={omitted}",
        *details,
    ]
    report = ("\n".join(manifest) + "\n").encode("utf-8", errors="backslashreplace")
    if len(report) > MANIFEST_LIMIT:
        marker = b"\n[manifest details truncated]\n"
        prefix = report[:MANIFEST_LIMIT - len(marker)].decode("utf-8", errors="ignore").encode("utf-8")
        report = prefix + marker
    (destination / "truncation.txt").write_bytes(report)


if __name__ == "__main__":
    snapshot(Path(sys.argv[1]), Path(sys.argv[2]))
