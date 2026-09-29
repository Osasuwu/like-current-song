# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the standalone Windows build (#214).

Build it through `tools/build_exe.py`, which also runs the bundle check and
prints the SHA-256 for the release notes:

    python tools/build_exe.py

Output: dist/LikeCurrentSong.exe (single file, windowed, no credentials).
"""

import os

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

from like_spotify.hosts.windows.feedback import _make_logo_icon

# Every module in the package, not a hand-kept list: `_common.py` imports the
# extensions statically, but the Settings window and the ytmusic reader are
# imported lazily, and a list is one more thing to forget when an extension
# lands. `samples/` is documentation, not runtime.
hiddenimports = [
    m for m in collect_submodules("like_spotify") if not m.startswith("like_spotify.samples")
]
# The ytmusic extra. `winrt.windows` is a namespace package, which
# `collect_submodules` can't walk, so the three projections are named.
hiddenimports += [
    "winrt.windows.foundation",
    "winrt.windows.foundation.collections",
    "winrt.windows.media.control",
]

# Metadata only, nothing reads it at runtime; shipped so the bundle mirrors
# the wheel.
datas = collect_data_files("like_spotify", includes=["**/manifest.json"])

# The file icon is the tray logo at 256 px, drawn from the same code, so there
# is no binary to keep in step with `docs/logo.svg`.
icon_path = os.path.join(workpath, "LikeCurrentSong.ico")
os.makedirs(workpath, exist_ok=True)
_make_logo_icon(256).save(icon_path, sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (256, 256)])

a = Analysis(
    [os.path.join(SPECPATH, "like_current_song_launcher.py")],
    pathex=[],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure, a.zipped_data)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="LikeCurrentSong",
    icon=icon_path,
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    # UPX-packed binaries trip antivirus heuristics far more often; the size
    # saving isn't worth a quarantined download.
    upx=False,
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
