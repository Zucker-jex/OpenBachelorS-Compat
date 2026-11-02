#!/usr/bin/env python3
"""Build the OpenBachelorS Termux compatibility package.

The version is derived from the content, so the same overlay always produces
the same version string and the same bytes. That is what lets the Android client
say "已是最新" without any manual bumping.

Layout of the produced zip (flat, no wrapper directory):

    COMPAT_VERSION
    setup.sh
    start.sh
    start.py
    requirements.txt
    obc/sitecustomize.py

Usage:
    python tools/build_compat.py [--out dist]
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OVERLAY_DIR = REPO_ROOT / "overlay"

VERSION_ENTRY = "COMPAT_VERSION"

# Fixed timestamp inside the zip, so builds are byte-identical across machines.
FIXED_DATE_TIME = (1980, 1, 1, 0, 0, 0)

SKIP_DIRS = {"__pycache__", ".git"}
SKIP_SUFFIXES = {".pyc", ".pyo"}

# Files that must be LF-only inside the package: Termux chokes on a stray CR.
TEXT_SUFFIXES = {".sh", ".py", ".txt", ""}


def normalise(path: Path) -> bytes:
    """Read a file and force LF endings for text payloads.

    A Windows checkout can silently hand us CRLF; baking that into the zip
    would break the shebang on the device. Normalising here (and in the client
    build script) keeps the content hash stable across platforms.
    """
    data = path.read_bytes()
    if path.suffix in TEXT_SUFFIXES:
        return data.replace(b"\r\n", b"\n")
    return data


def overlay_files() -> list[Path]:
    files = [
        path
        for path in OVERLAY_DIR.rglob("*")
        if path.is_file()
        and not any(part in SKIP_DIRS for part in path.parts)
        and path.suffix not in SKIP_SUFFIXES
    ]
    return sorted(files, key=lambda path: path.relative_to(OVERLAY_DIR).as_posix())


def content_version(files: list[Path]) -> str:
    """SHA-256 over "relative path + file bytes", truncated to 12 hex chars.

    Must stay byte-for-byte compatible with the version computed by
    scripts/build-android.ps1 in the client repo.
    """
    digest = hashlib.sha256()
    for path in files:
        digest.update(path.relative_to(OVERLAY_DIR).as_posix().encode("utf-8"))
        digest.update(normalise(path))
    return digest.hexdigest()[:12]


def build_zip(files: list[Path], version: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        def add(name: str, data: bytes) -> None:
            info = zipfile.ZipInfo(name, date_time=FIXED_DATE_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, data)

        add(VERSION_ENTRY, version.encode("utf-8"))
        for path in files:
            add(path.relative_to(OVERLAY_DIR).as_posix(), normalise(path))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="dist", help="output directory")
    args = parser.parse_args()

    if not OVERLAY_DIR.is_dir():
        print(f"overlay/ not found at {OVERLAY_DIR}", file=sys.stderr)
        return 1

    files = overlay_files()
    if not files:
        print("overlay/ is empty", file=sys.stderr)
        return 1

    version = content_version(files)
    out_dir = Path(args.out)
    if not out_dir.is_absolute():
        out_dir = REPO_ROOT / out_dir

    archive = out_dir / f"obs-compat-{version}.zip"
    build_zip(files, version, archive)

    print(f"version={version}")
    print(f"archive={archive}")
    print(f"files={len(files)}")
    for path in files:
        print(f"  {path.relative_to(OVERLAY_DIR).as_posix()}")

    # GitHub Actions picks these up.
    step_summary = os.environ.get("GITHUB_OUTPUT")
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as handle:
            handle.write(f"version={version}\n")
            handle.write(f"archive={archive.name}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
