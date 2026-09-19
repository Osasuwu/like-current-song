"""Windows host — `HKCU\\…\\Run` autostart toggle + venv-bypass launch.

Split out of `hosts/windows.py` in #55. Owns everything needed to make the
resident tray start hidden at login: the registry Run-key read/write, the
launch-command resolution (pythonw vs. the frozen exe), and the
hidden-launch VBScript + venv-launcher-stub bypass it's routed through.
"""

from __future__ import annotations

import sys
from pathlib import Path

from .. import _common

_AUTOSTART_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
_AUTOSTART_NAME = "LikeSpotify"


def _venv_bypass(exe: Path) -> tuple[Path, Path] | None:
    """(base_pythonw, site_packages) to skip a broken venv launcher stub.

    CPython 3.13+ venvs ship a native launcher stub as `Scripts/pythonw.exe`
    that reads `home` from `pyvenv.cfg` and re-execs the base interpreter.
    That re-exec stopped forwarding the hidden window state (`SW_HIDE`) to
    the process it spawns at some point between 2026-06-19 and 2026-06-20 —
    confirmed via `startup.log`, which logged `exe=…python.exe
    console_visible=True` on every login since, despite Run correctly
    targeting the stub's `pythonw.exe`. Launching the base interpreter
    directly skips the stub's re-exec (and its broken window-state
    forwarding) entirely; the caller must put `site_packages` on
    `PYTHONPATH` since the base interpreter won't auto-detect the venv on
    its own (that detection only fires when the venv's *own* executable is
    the one that started the process).

    Returns None when `exe` isn't inside a venv, or its base interpreter
    doesn't ship a `pythonw.exe`.
    """
    venv_root = exe.parent.parent
    cfg_path = venv_root / "pyvenv.cfg"
    if not cfg_path.exists():
        return None
    home = None
    for line in cfg_path.read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition("=")
        if key.strip() == "home":
            home = value.strip()
            break
    if not home:
        return None
    base_pythonw = Path(home) / "pythonw.exe"
    if not base_pythonw.exists():
        return None
    return base_pythonw, venv_root / "Lib" / "site-packages"


def _resident_launch_plan() -> tuple[str, Path | None]:
    """(command, extra_pythonpath) for launching the resident tray.

    Prefers `pythonw.exe` so no console attaches in the common case; falls
    back to `python.exe` when the GUI interpreter isn't beside it. When the
    chosen interpreter is a venv launcher stub, routes around it via
    `_venv_bypass` — `extra_pythonpath` is non-None exactly when the
    returned command needs it on `PYTHONPATH` to find the venv's packages.
    """
    if getattr(sys, "frozen", False):
        return f'"{Path(sys.executable).resolve()}"', None
    exe = Path(sys.executable)
    pythonw = exe.with_name("pythonw.exe")
    runner = pythonw if pythonw.exists() else exe
    bypass = _venv_bypass(runner)
    if bypass is not None:
        base_pythonw, site_packages = bypass
        return f'"{base_pythonw}" -m like_spotify', site_packages
    return f'"{runner}" -m like_spotify', None


def _resident_launch_command() -> str:
    """The bare command that starts the resident tray (interpreter + module).

    Thin wrapper over `_resident_launch_plan` for callers that don't need
    the venv-bypass `PYTHONPATH` (the frozen branch of `_autostart_target`).
    """
    return _resident_launch_plan()[0]


def _autostart_vbs_path() -> Path:
    """Where the hidden-launch VBScript lives — next to config/tokens."""
    return _common.CONFIG_FILE.parent / "autostart_hidden.vbs"


def _write_autostart_vbs() -> Path:
    """Write a VBScript that launches the tray with a hidden window.

    `WScript.Shell.Run(cmd, 0, False)` starts the process with `SW_HIDE`. For
    a plain interpreter that's the whole story; for a venv launcher stub
    that re-execs the base interpreter, `SW_HIDE` alone isn't enough — see
    `_venv_bypass`, whose `site_packages` (when set) is written here as a
    `PYTHONPATH` env var on the same `WScript.Shell` object, so it's
    inherited by the process `Run` spawns. Only the autostart path goes
    through this; running `like-current-song` from a terminal is unaffected (it
    never touches the VBScript).
    """
    cmd, extra_pythonpath = _resident_launch_plan()
    # VBScript string literals escape a double-quote by doubling it.
    def _vbs_str(s: str) -> str:
        return '"' + str(s).replace('"', '""') + '"'

    env_line = ""
    if extra_pythonpath is not None:
        env_line = f'sh.Environment("Process")("PYTHONPATH") = {_vbs_str(extra_pythonpath)}\r\n'
    vbs = (
        'Set sh = CreateObject("WScript.Shell")\r\n'
        f"{env_line}"
        f"sh.Run {_vbs_str(cmd)}, 0, False\r\n"
    )
    path = _autostart_vbs_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    # newline="" — the string already has explicit \r\n; without this,
    # text-mode translates \n to os.linesep too and doubles the \r.
    path.write_text(vbs, encoding="utf-8", newline="")
    return path


# Windowed launcher stubs from `[project.gui-scripts]`. The legacy name is a
# compatibility alias kept since the #101 rename; older Run entries point at
# it until `migrate_legacy_entry` rewrites them.
_GUI_SCRIPT_NAME = "like-current-song-gui.exe"
_LEGACY_GUI_SCRIPT_NAME = "like-spotify-gui.exe"


def _gui_script_path() -> Path | None:
    """The `like-current-song-gui` launcher stub beside `sys.executable`, if any.

    Installed by pip/pipx from the `[project.gui-scripts]` entry point — a
    genuinely windowed-subsystem binary, not a console interpreter with its
    window hidden after the fact. Using it sidesteps the pythonw/venv-stub
    SW_HIDE-forwarding bug entirely (`_venv_bypass` below is now only a
    fallback for installs predating this entry point). Falls back to the
    legacy `like-spotify-gui` alias for an install that only has that one.
    """
    scripts = Path(sys.executable).parent
    for name in (_GUI_SCRIPT_NAME, _LEGACY_GUI_SCRIPT_NAME):
        candidate = scripts / name
        if candidate.exists():
            return candidate
    return None


def _autostart_target() -> str:
    """Registry Run value: launch the tray fully hidden at login.

    A frozen windowed exe has no console, so it's launched directly.
    Otherwise prefer the `like-current-song-gui` shim (see `_gui_script_path`) —
    it needs no VBScript wrapper since it never has a console to hide. Only
    an install without that shim falls back to `wscript.exe` + the
    hidden-launch VBScript.
    """
    if getattr(sys, "frozen", False):
        return _resident_launch_command()
    gui_script = _gui_script_path()
    if gui_script is not None:
        return f'"{gui_script}"'
    vbs = _write_autostart_vbs()
    return f'wscript.exe //B //Nologo "{vbs}"'


def _autostart_enabled() -> bool:
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _AUTOSTART_KEY, 0, winreg.KEY_READ) as k:
            winreg.QueryValueEx(k, _AUTOSTART_NAME)
        return True
    except FileNotFoundError:
        return False


def _autostart_set(enabled: bool) -> None:
    import winreg

    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _AUTOSTART_KEY, 0, winreg.KEY_SET_VALUE) as k:
        if enabled:
            winreg.SetValueEx(k, _AUTOSTART_NAME, 0, winreg.REG_SZ, _autostart_target())
        else:
            try:
                winreg.DeleteValue(k, _AUTOSTART_NAME)
            except FileNotFoundError:
                pass


def _autostart_value() -> str | None:
    """The current Run value, or None when autostart is off."""
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _AUTOSTART_KEY, 0, winreg.KEY_READ) as k:
            value, _type = winreg.QueryValueEx(k, _AUTOSTART_NAME)
    except FileNotFoundError:
        return None
    return str(value)


def _legacy_entry_is_stale(value: str) -> bool:
    """True when `value` launches the legacy `like-spotify-gui` shim and this
    install should take it over.

    That holds when the shim it names no longer exists (e.g. the old pipx
    `like-spotify` package was uninstalled), or when it sits in this
    interpreter's own Scripts dir (same install, just the pre-rename name).
    A legacy entry that points at a *different*, still-working install is
    left alone, so running a dev checkout doesn't hijack the user's
    autostart.
    """
    exe = value.strip().strip('"')
    if Path(exe).name.lower() != _LEGACY_GUI_SCRIPT_NAME:
        return False
    legacy = Path(exe)
    if not legacy.exists():
        return True
    try:
        return legacy.parent.resolve() == Path(sys.executable).parent.resolve()
    except OSError:
        return False


def migrate_legacy_entry() -> bool:
    """Point a pre-#101 autostart entry at the renamed launcher.

    Called once per resident start. Rewrites the Run value only when it
    names the legacy `like-spotify-gui` shim and `_legacy_entry_is_stale`
    says this install owns it; any other entry (or none) is untouched.
    Returns True when the entry was rewritten.
    """
    if getattr(sys, "frozen", False):
        return False
    value = _autostart_value()
    if value is None or not _legacy_entry_is_stale(value):
        return False
    target = _autostart_target()
    if target == value:
        return False
    _autostart_set(True)
    return True
