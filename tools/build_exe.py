"""Build the standalone Windows exe, check it, and print its SHA-256 (#214).

The one entry point for both the maintainer cutting a release and CI:

    pip install -e .[dev,ytmusic]
    python tools/build_exe.py

Output: dist/LikeCurrentSong.exe. The build fails, and prints why, when the
bundle check finds a credential or a missing module (see `check_bundle.py`).
Attach the exe to the GitHub Release by hand and paste the printed SHA-256
into the release notes, the same way the APK is published.
"""

from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = ROOT / "tools" / "LikeCurrentSong.spec"
EXE = ROOT / "dist" / "LikeCurrentSong.exe"

sys.path.insert(0, str(ROOT / "tools"))
import check_bundle  # noqa: E402


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    if sys.platform != "win32":
        print(
            "The standalone exe is Windows-only; build it on Windows.", file=sys.stderr
        )
        return 2
    subprocess.run(
        [sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", str(SPEC)],
        cwd=ROOT,
        check=True,
    )
    if check_bundle.main([str(EXE)]) != 0:
        return 1
    print(f"\nBuilt {EXE.relative_to(ROOT)} ({EXE.stat().st_size / 1e6:.1f} MB)")
    print(f"SHA-256: {sha256(EXE)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
