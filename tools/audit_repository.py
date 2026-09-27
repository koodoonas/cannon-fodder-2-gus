#!/usr/bin/env python3
"""Fail if a release tree contains game material or private test artifacts."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


FORBIDDEN_SUFFIXES = {
    ".7z", ".amf", ".avi", ".bin", ".cf", ".com", ".dat", ".exe",
    ".img", ".iso", ".lha", ".m8", ".m12", ".m18", ".m24", ".mod",
    ".nfo", ".rar", ".raw", ".smp", ".sqz", ".tab", ".wav", ".zip",
}
ALLOWED_BINARIES = {
    Path("dist/CF2GUS.COM"),
}
FORBIDDEN_SHA256 = {
    # Verified packed executable and private materialized test fixture.
    "bff98b997e893b3bcbe78b8bbdc5dd31e7d378dac0004ffb7de66d42c82fae1b",
    "b9e6bc5a9d82c27149411785a4634ea3ddedb9c7f246c685dcc2970c60462ba7",
}
ARCHIVE_MAGICS = (b"PK\x03\x04", b"Rar!\x1a\x07", b"7z\xbc\xaf\x27\x1c")


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def audit(root: Path) -> list[str]:
    failures: list[str] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or ".git" in path.parts:
            continue
        relative = path.relative_to(root)
        allowed_binary = relative in ALLOWED_BINARIES
        if not allowed_binary and path.suffix.casefold() in FORBIDDEN_SUFFIXES:
            failures.append(f"forbidden asset/archive type: {relative}")
            continue
        if digest(path) in FORBIDDEN_SHA256:
            failures.append(f"known game executable content: {relative}")
        with path.open("rb") as handle:
            magic = handle.read(8)
        if any(magic.startswith(signature) for signature in ARCHIVE_MAGICS):
            failures.append(f"archive content is not allowed: {relative}")
        if not allowed_binary and magic.startswith(b"MZ"):
            failures.append(f"DOS executable content is not allowed: {relative}")
    return failures


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path, default=Path.cwd())
    args = parser.parse_args()
    root = args.root.resolve()
    failures = audit(root)
    if failures:
        for failure in failures:
            print(f"ERROR: {failure}")
        raise SystemExit(1)
    print("Repository audit passed: no game assets or private test artifacts found.")


if __name__ == "__main__":
    main()
