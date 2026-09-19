# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the LikeSpotify tray host.

Build:
    python -m PyInstaller --noconfirm tools/LikeSpotify.spec

Output: dist/LikeSpotify.exe (single-file, windowed).
"""

from PyInstaller.utils.hooks import collect_data_files

block_cipher = None

datas = collect_data_files("like_spotify", includes=["**/manifest.json"])

a = Analysis(
    ["like_spotify_launcher.py"],
    pathex=[],
    binaries=[],
    datas=datas,
    hiddenimports=[
        "keyboard",
        "keyboard._winkeyboard",
        "pystray",
        "pystray._win32",
        "PIL._tkinter_finder",
        "like_spotify.extensions.one_shot_cli_trigger",
        "like_spotify.extensions.spotify",
        "like_spotify.extensions.tray_hotkey_trigger",
        "like_spotify.hosts.windows",
        # Settings window (#100): imported lazily, so name it explicitly.
        # tkinter itself is bundled by PyInstaller's standard hook.
        "like_spotify.hosts.settings.window",
        "tkinter",
        "tkinter.ttk",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="LikeSpotify",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
