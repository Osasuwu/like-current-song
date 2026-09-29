"""Inspect a built LikeCurrentSong.exe before it's published (#214).

Two jobs, both run by `tools/build_exe.py` and by CI on every PR:

* **No credentials ship.** The exe goes to strangers, so every user brings
  their own Spotify / Google app. A file that holds a token, a keystore, or
  a filled-in client secret must never end up inside it. This is a
  denylist, not an allowlist: it names what must not be there, so a new
  dependency's data files don't need a rule each.
* **Nothing is missing.** Everything the Settings window and the extensions
  import lazily has to be in the archive, or the frozen app fails the first
  time a user reaches that path, long after the build looked fine.

Usage: python tools/check_bundle.py dist/LikeCurrentSong.exe
Exit code 0 when the bundle is clean, 1 with one line per problem otherwise.
"""

from __future__ import annotations

import fnmatch
import re
import sys
from collections.abc import Iterable
from pathlib import Path

# File names that only ever hold a secret. Matched against the basename,
# case-insensitively. `.pem` is deliberately absent: certifi's CA bundle is
# one, and it is public.
DENIED_NAMES = (
    ".env",
    ".env.*",
    "*token*.json",
    "client_secret*.json",
    "credentials.json",
    "config.json",
    "key.properties",
    "*.jks",
    "*.keystore",
)

# Values that are a live secret wherever they appear: in a data file, or as
# a string constant compiled into a module.
SECRET_PATTERNS = (
    ("Google client secret", re.compile(rb"GOCSPX-[A-Za-z0-9_-]{10,}")),
    ("Google refresh token", re.compile(rb"1//0[A-Za-z0-9_-]{20,}")),
    ("Google access token", re.compile(rb"ya29\.[A-Za-z0-9_-]{20,}")),
    ("filled-in client_secret", re.compile(rb'"client_secret"\s*:\s*"[^"\s]+"')),
    ("filled-in refresh_token", re.compile(rb'"refresh_token"\s*:\s*"[^"\s]+"')),
)

# Imported lazily, so a missing one only shows up on a user's machine.
LAZY_MODULES = (
    "like_spotify.hosts.settings.window",
    "like_spotify.extensions.ytmusic.smtc",
    "winrt.windows.media.control",
    "tkinter",
)


def required_modules() -> list[str]:
    """Every extension package in the source tree, plus `LAZY_MODULES`.

    Read from disk rather than listed, so a new extension is required the
    moment its folder exists.
    """
    import like_spotify.extensions as extensions

    root = Path(extensions.__file__).parent
    found = sorted(
        f"like_spotify.extensions.{d.name}"
        for d in root.iterdir()
        if d.is_dir() and (d / "__init__.py").exists()
    )
    return [*found, *LAZY_MODULES]


def denied_name(name: str) -> bool:
    base = name.replace("\\", "/").rsplit("/", 1)[-1].lower()
    return any(fnmatch.fnmatchcase(base, pattern) for pattern in DENIED_NAMES)


# Native code is third-party and makes up most of the bytes; its names are
# still checked, its contents aren't scanned.
_UNSCANNED_SUFFIXES = (".dll", ".pyd", ".exe")


def find_problems(
    files: Iterable[tuple[str, bytes]],
    modules: dict[str, bytes],
    required: Iterable[str],
) -> list[str]:
    """Problems with a bundle, given its contents.

    `files` is every entry outside the PYZ as (name, data); `modules` maps each
    bundled module name to its raw (compiled) bytes. Pure, so it's tested
    without building anything.
    """
    problems = []
    for name, data in files:
        if denied_name(name):
            problems.append(f"credential-like file bundled: {name}")
        if name.lower().endswith(_UNSCANNED_SUFFIXES):
            continue
        problems += [
            f"{label} in {name}" for label, rx in SECRET_PATTERNS if rx.search(data)
        ]
    for module, data in modules.items():
        problems += [
            f"{label} in module {module}"
            for label, rx in SECRET_PATTERNS
            if rx.search(data)
        ]
    problems += [
        f"module missing from bundle: {m}" for m in required if m not in modules
    ]
    return problems


def read_bundle(exe: Path) -> tuple[list[tuple[str, bytes]], dict[str, bytes]]:
    """(files, modules) of a PyInstaller onefile exe, as `find_problems` takes."""
    from PyInstaller.archive.readers import CArchiveReader

    carchive = CArchiveReader(str(exe))
    files, modules = [], {}
    for name, entry in carchive.toc.items():
        typecode = entry[-1]
        if typecode == "z":  # the PYZ: every pure-Python module
            pyz = carchive.open_embedded_archive(name)
            for module in pyz.toc:
                modules[module] = pyz.extract(module, raw=True) or b""
        else:  # data files, DLLs, bootstrap scripts: PyInstaller 6 stores
            # data files as binaries (`b`), so no typecode means "just data"
            files.append((name, carchive.extract(name) or b""))
    return files, modules


def check(exe: Path) -> list[str]:
    files, modules = read_bundle(exe)
    return find_problems(files, modules, required_modules())


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print("usage: python tools/check_bundle.py <path-to-exe>", file=sys.stderr)
        return 2
    exe = Path(args[0])
    if not exe.is_file():
        print(f"no such file: {exe}", file=sys.stderr)
        return 2
    problems = check(exe)
    for problem in problems:
        print(f"bundle check: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"bundle check: {exe.name} is clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
