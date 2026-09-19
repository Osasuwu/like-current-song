"""Host-selection + stub-host behaviour.

Slice: #27 (host split + cross-platform `like-once`).

We only smoke the platform-dispatch logic and the CLI failure paths of
the stub host — the resident tray path needs a Win32 desktop and lives
behind an integration / manual-test boundary.
"""

from __future__ import annotations

import os
from collections.abc import Iterator
from pathlib import Path
from unittest.mock import patch

import pytest

from like_spotify.hosts import _stub, select_host, windows
from like_spotify.hosts.windows import autostart, resident


# ── select_host() dispatch ─────────────────────────────────────────────


def test_select_host_picks_windows_on_win32() -> None:
    with patch("like_spotify.hosts.sys.platform", "win32"):
        host = select_host()
    assert host.__module__ == "like_spotify.hosts.windows"


@pytest.mark.parametrize("platform", ["darwin", "linux", "freebsd"])
def test_select_host_picks_stub_off_win32(platform: str) -> None:
    with patch("like_spotify.hosts.sys.platform", platform):
        host = select_host()
    assert host.__module__ == "like_spotify.hosts._stub"


# ── Windows resident-host startup: shell-readiness + logging ───────────
#
# The tray path itself needs a Win32 desktop (manual boundary), but the
# two startup defenses added to fix login-time autostart races are pure
# logic behind injectable seams, so they unit-test on any OS.


def test_wait_for_shell_returns_at_once_when_taskbar_present(monkeypatch) -> None:
    monkeypatch.setattr(resident, "_taskbar_present", lambda: True)
    slept: list[float] = []
    monkeypatch.setattr(resident.time, "sleep", lambda s: slept.append(s))

    assert resident._wait_for_shell() is True
    assert slept == []  # the common post-login case must not block


def test_wait_for_shell_polls_until_taskbar_appears(monkeypatch) -> None:
    states = iter([False, False, True])
    monkeypatch.setattr(resident, "_taskbar_present", lambda: next(states))
    slept: list[float] = []
    monkeypatch.setattr(resident.time, "sleep", lambda s: slept.append(s))

    assert resident._wait_for_shell(interval=0.01) is True
    assert len(slept) == 2  # polled twice before the taskbar came up


def test_wait_for_shell_times_out(monkeypatch) -> None:
    monkeypatch.setattr(resident, "_taskbar_present", lambda: False)
    monkeypatch.setattr(resident.time, "sleep", lambda s: None)

    assert resident._wait_for_shell(timeout=0.0) is False


def test_wait_for_shell_does_not_hang_when_probe_raises(monkeypatch) -> None:
    def boom() -> bool:
        raise OSError("no shell API")

    monkeypatch.setattr(resident, "_taskbar_present", boom)
    assert resident._wait_for_shell() is False


def test_log_appends_line_to_config_dir(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(
        "like_spotify.hosts._common.CONFIG_FILE", tmp_path / "config.json"
    )
    resident._log("hello world")

    log = tmp_path / "startup.log"
    assert log.exists()
    contents = log.read_text(encoding="utf-8")
    assert "hello world" in contents
    assert f"[pid {os.getpid()}]" in contents


def test_log_never_raises_on_bad_path(monkeypatch) -> None:
    # A config dir that can't be created must not take the process down.
    monkeypatch.setattr(
        "like_spotify.hosts._common.CONFIG_FILE", Path("\x00bad") / "c.json"
    )
    resident._log("should be swallowed")  # must not raise


# ── Autostart hidden-launch wrapper ────────────────────────────────────
#
# At login the pipx/pythoncore venv `pythonw.exe` redirector re-execs the
# *console* `python.exe`, so a console window appears despite Run pointing
# at pythonw. The fix routes autostart through `wscript.exe` + a hidden
# VBScript (`SW_HIDE`). The wrapper + quote escaping are pure logic.


def test_write_autostart_vbs_emits_hidden_run(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(
        "like_spotify.hosts._common.CONFIG_FILE", tmp_path / "config.json"
    )
    monkeypatch.setattr(
        autostart,
        "_resident_launch_plan",
        lambda: ('"C:\\py\\pythonw.exe" -m like_spotify', None),
    )

    path = autostart._write_autostart_vbs()

    assert path == tmp_path / "autostart_hidden.vbs"
    vbs = path.read_text(encoding="utf-8")
    assert "WScript.Shell" in vbs
    # SW_HIDE (window style 0), non-blocking — this is what kills the console.
    assert ", 0, False" in vbs
    # Inner double-quotes must be VBScript-escaped (doubled) so the path
    # with spaces survives.
    assert '"""C:\\py\\pythonw.exe"" -m like_spotify"' in vbs
    assert "PYTHONPATH" not in vbs
    # write_text(..., newline="") must be used — plain text-mode write
    # doubles the \r since the string already has explicit \r\n.
    assert "\r\r" not in path.read_bytes().decode("utf-8")


def test_write_autostart_vbs_sets_pythonpath_for_venv_bypass(
    tmp_path, monkeypatch
) -> None:
    # When _resident_launch_plan reports a venv bypass (base pythonw.exe +
    # site-packages), the VBScript must export PYTHONPATH before Run so the
    # base interpreter can still find the package.
    monkeypatch.setattr(
        "like_spotify.hosts._common.CONFIG_FILE", tmp_path / "config.json"
    )
    monkeypatch.setattr(
        autostart,
        "_resident_launch_plan",
        lambda: (
            '"C:\\base\\pythonw.exe" -m like_spotify',
            Path("C:\\venv\\Lib\\site-packages"),
        ),
    )

    path = autostart._write_autostart_vbs()

    vbs = path.read_text(encoding="utf-8")
    assert 'sh.Environment("Process")("PYTHONPATH") = "C:\\venv\\Lib\\site-packages"' in vbs
    # The env line must precede Run so the child process inherits it.
    assert vbs.index("PYTHONPATH") < vbs.index("sh.Run")


def test_autostart_target_routes_through_wscript(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(
        "like_spotify.hosts._common.CONFIG_FILE", tmp_path / "config.json"
    )
    monkeypatch.setattr(autostart.sys, "frozen", False, raising=False)
    monkeypatch.setattr(
        autostart, "_resident_launch_plan", lambda: ('"py.exe" -m like_spotify', None)
    )
    # An editable dev install puts like-spotify-gui.exe next to the venv's
    # python, which `_autostart_target` prefers. Hide it so this test covers
    # the VBScript branch regardless of how the test env was installed.
    monkeypatch.setattr(autostart, "_gui_script_path", lambda: None)

    target = autostart._autostart_target()

    assert target.startswith("wscript.exe //B //Nologo ")
    assert "autostart_hidden.vbs" in target
    # The VBScript is written as a side effect so the Run value points at a
    # real file.
    assert (tmp_path / "autostart_hidden.vbs").exists()


def test_venv_bypass_resolves_base_pythonw(tmp_path, monkeypatch) -> None:
    # Build a fake venv: Scripts/pythonw.exe + pyvenv.cfg pointing at a fake
    # base install that has its own pythonw.exe.
    base_dir = tmp_path / "base"
    base_dir.mkdir()
    base_pythonw = base_dir / "pythonw.exe"
    base_pythonw.write_bytes(b"")

    venv_root = tmp_path / "venv"
    scripts = venv_root / "Scripts"
    scripts.mkdir(parents=True)
    stub = scripts / "pythonw.exe"
    stub.write_bytes(b"")
    (venv_root / "pyvenv.cfg").write_text(
        f"home = {base_dir}\nversion = 3.14.2\n", encoding="utf-8"
    )

    result = autostart._venv_bypass(stub)

    assert result == (base_pythonw, venv_root / "Lib" / "site-packages")


def test_venv_bypass_none_outside_a_venv(tmp_path) -> None:
    # No pyvenv.cfg beside the executable's venv root — not a venv at all
    # (e.g. a frozen exe's directory, or a base install run directly).
    exe_dir = tmp_path / "Scripts"
    exe_dir.mkdir()
    exe = exe_dir / "pythonw.exe"
    exe.write_bytes(b"")

    assert autostart._venv_bypass(exe) is None


def test_autostart_target_prefers_gui_script_shim(tmp_path, monkeypatch) -> None:
    # A `like-spotify-gui` shim beside the interpreter is windowed-subsystem
    # already — no VBScript/pythonw-bypass indirection needed or wanted.
    monkeypatch.setattr(
        "like_spotify.hosts._common.CONFIG_FILE", tmp_path / "config.json"
    )
    monkeypatch.setattr(autostart.sys, "frozen", False, raising=False)
    scripts = tmp_path / "Scripts"
    scripts.mkdir()
    python_exe = scripts / "python.exe"
    python_exe.write_bytes(b"")
    gui_exe = scripts / "like-spotify-gui.exe"
    gui_exe.write_bytes(b"")
    monkeypatch.setattr(autostart.sys, "executable", str(python_exe), raising=False)

    target = autostart._autostart_target()

    assert target == f'"{gui_exe}"'
    assert "wscript" not in target
    assert not (tmp_path / "autostart_hidden.vbs").exists()


def test_gui_script_path_none_when_shim_missing(tmp_path, monkeypatch) -> None:
    scripts = tmp_path / "Scripts"
    scripts.mkdir()
    python_exe = scripts / "python.exe"
    python_exe.write_bytes(b"")
    monkeypatch.setattr(autostart.sys, "executable", str(python_exe), raising=False)

    assert autostart._gui_script_path() is None


def test_autostart_target_frozen_launches_exe_directly(monkeypatch) -> None:
    # A frozen windowed exe has no console — no VBScript indirection needed.
    monkeypatch.setattr(autostart.sys, "frozen", True, raising=False)
    monkeypatch.setattr(
        autostart.sys, "executable", "C:\\app\\LikeSpotify.exe", raising=False
    )

    target = autostart._autostart_target()

    assert "wscript" not in target
    assert "LikeSpotify.exe" in target


# ── Stub host: surface CLI failures cleanly ────────────────────────────


@pytest.fixture
def empty_config(tmp_path, monkeypatch) -> Iterator[None]:
    """Point the shared config helpers at a writable tmp dir so the test
    runs hermetically (no `~/.like_spotify` reads/writes)."""
    cfg_file = tmp_path / "config.json"
    token_file = tmp_path / "spotify_token.json"
    monkeypatch.setattr("like_spotify.hosts._common.CONFIG_FILE", cfg_file)
    monkeypatch.setattr("like_spotify.hosts._common.SPOTIFY_TOKEN_FILE", token_file)
    yield


def test_stub_run_without_client_id_prints_hint_and_exits(
    empty_config, capsys, monkeypatch
) -> None:
    """No `--setup` yet: the default `run` should explain itself, not crash."""
    monkeypatch.delenv("SPOTIFY_CLIENT_ID", raising=False)
    monkeypatch.setattr("like_spotify.hosts._stub.sys.platform", "darwin")

    rc = _stub.main([])

    assert rc == 2
    err = capsys.readouterr().err
    # macOS hint mentions like-once and the macos.py file.
    assert "like-once" in err
    assert "macos.py" in err


def test_stub_like_once_without_client_id_exits_with_setup_hint(
    empty_config, capsys, monkeypatch
) -> None:
    monkeypatch.delenv("SPOTIFY_CLIENT_ID", raising=False)
    rc = _stub.main(["like-once"])
    assert rc == 2
    err = capsys.readouterr().err
    assert "--setup" in err


def test_stub_config_subcommand_prints_paths(empty_config, capsys) -> None:
    rc = _stub.main(["--config"])
    assert rc == 0
    out = capsys.readouterr().out
    assert "Config:" in out
    assert "Spotify token:" in out


# ── CliFeedback formatting ─────────────────────────────────────────────


def test_cli_feedback_success_goes_to_stdout(capsys) -> None:
    fb = _stub.CliFeedback()
    fb(True, "Liked", "Song — Artist")
    out, err = capsys.readouterr()
    assert "[ok] Liked — Song — Artist" in out
    assert err == ""
    assert fb.calls == [(True, "Liked", "Song — Artist")]


def test_cli_feedback_failure_goes_to_stderr(capsys) -> None:
    fb = _stub.CliFeedback()
    fb(False, "Like failed", "boom")
    out, err = capsys.readouterr()
    assert "[err] Like failed — boom" in err
    assert out == ""


def test_cli_feedback_omits_dash_when_message_empty(capsys) -> None:
    fb = _stub.CliFeedback()
    fb(False, "Nothing playing", "")
    err = capsys.readouterr().err.strip()
    assert err == "[err] Nothing playing"


def test_cli_feedback_accepts_kind_keyword(capsys) -> None:
    """The remove pipeline calls feedback with kind="remove"; CLI has no
    audio but must accept (and record) the keyword for parity."""
    fb = _stub.CliFeedback()
    fb(True, "Removed from Archive", "Song — Artist", kind="remove")
    out = capsys.readouterr().out
    assert "[ok] Removed from Archive — Song — Artist" in out
    assert fb.calls == [(True, "Removed from Archive", "Song — Artist")]
    assert fb.kinds == ["remove"]
