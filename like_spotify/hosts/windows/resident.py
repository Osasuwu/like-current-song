"""Windows host — resident tray wiring, one-shot subcommands, startup log.

Split out of `hosts/windows.py` in #55. Owns process-level concerns: the
single-instance mutex, `like-once`/`remove-once` one-shot subcommands, the
login-time startup log + shell-readiness wait, and `_run_resident_host`
(wires `Pipeline` + `Trigger` + the tray icon built by `tray.build_icon`).
This is the module's entry point — `main()` lives here.
"""

from __future__ import annotations

import asyncio
import ctypes
import os
import sys
import threading
import time

from like_spotify.core.pipeline import Pipeline
from like_spotify.extensions.tray_hotkey_trigger import (
    DEFAULT_HOTKEY,
    TRIGGER as make_tray_hotkey_trigger,
)

from .. import _common, _setup
from .._stub import CliFeedback
from . import tray
from .autostart import _autostart_enabled, _autostart_set
from .feedback import TrayFeedback

# ── Single-instance guard ──────────────────────────────────────────────


def _ensure_single_instance() -> None:
    kernel32 = ctypes.windll.kernel32
    kernel32.CreateMutexW(None, True, "LikeSpotify_SingleInstance")
    if kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
        sys.exit(0)


# ── Error reporting ────────────────────────────────────────────────────


def _msgbox(text: str, title: str = "Like Spotify", icon: int = 0x10) -> None:
    try:
        ctypes.windll.user32.MessageBoxW(0, text, title, icon)
        return
    except Exception:
        pass
    _common.msgbox(text, title)


# ── one-shot subcommands (Windows still supports them) ─────────────────


def _resolved_provider_or_hint():
    """(provider, None, cfg) when ready, else (None, exit_code, cfg) after a
    hint box. Mirrors the `_stub.py` copy — cfg is returned either way so the
    caller can build the pipeline without reloading config."""
    cfg = _common.load_config()
    provider = _common.build_provider(cfg)
    if provider is None:
        _msgbox(
            "Not configured. Run from a terminal:\n\n    like-spotify --setup\n",
            title="Like Spotify — setup required",
        )
        return None, 2, cfg
    if not provider.has_tokens:
        _msgbox(
            "Not authenticated. Run from a terminal:\n\n    like-spotify --setup\n",
            title="Like Spotify — auth required",
        )
        return None, 2, cfg
    return provider, None, cfg


def _run_like_once() -> int:
    provider, err, cfg = _resolved_provider_or_hint()
    if provider is None:
        return err

    feedback = CliFeedback()
    storage = _common.build_storage(cfg)
    pre_actions, post_actions = _common.build_action_chains(cfg, storage)
    pipeline = Pipeline(
        provider=provider,
        feedback=feedback,
        storage=storage,
        pre_like_actions=pre_actions,
        post_like_actions=post_actions,
    )
    return _common.run_one_shot(pipeline, feedback)


def _run_remove_once() -> int:
    provider, err, cfg = _resolved_provider_or_hint()
    if provider is None:
        return err

    feedback = CliFeedback()
    pipeline = _common.build_remove_pipeline(cfg, provider, feedback)
    if pipeline is None:
        _msgbox(
            "No archive playlist configured. Run from a terminal:\n\n"
            "    like-spotify --setup\n",
            title="Like Spotify — setup required",
        )
        return 2
    return _common.run_one_shot(pipeline, feedback)


# ── Startup logging + shell-readiness ───────────────────────────────────
#
# The resident tray is launched at login by the HKCU\…\Run key through
# pythonw.exe — no console, so a crash or a lost tray-icon add leaves no
# trace and the heart silently never appears ("снова не запустилось").
# Two coupled defenses:
#   1. `_log` — append the launch context + any fatal traceback to a file,
#      so the *next* failed boot is diagnosable by fact, not by guess.
#   2. `_wait_for_shell` — at login the Run entry can fire before explorer
#      has created the notification area (`Shell_TrayWnd`); adding the icon
#      then is silently dropped. Block until the taskbar exists so we stop
#      racing the shell. Post-login the window is already up → returns at
#      once. The race is timing-dependent, which is why autostart works on
#      one boot and not the next.


def _log(msg: str) -> None:
    """Append one timestamped line to `<config-dir>/startup.log` (best effort).

    Path is derived from `_common.CONFIG_FILE` so tests that redirect the
    config dir capture the log too, and so it sits next to config/tokens.
    Never raises — logging must not be the thing that kills startup.
    """
    try:
        log_file = _common.CONFIG_FILE.parent / "startup.log"
        log_file.parent.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        with log_file.open("a", encoding="utf-8") as f:
            f.write(f"{ts} [pid {os.getpid()}] {msg}\n")
    except Exception:
        pass


def _taskbar_present() -> bool:
    """True when the shell notification area window exists.

    Injectable seam: `_wait_for_shell` is the loop worth testing, and it
    polls through here so tests can drive readiness without a real desktop.
    """
    return bool(ctypes.windll.user32.FindWindowW("Shell_TrayWnd", None))


def _console_state() -> str:
    """Describe this process's console window for the launch log.

    The autostart fix hinges on *not* getting a visible console at login
    (the pipx/pythoncore venv redirector re-execs the console interpreter —
    see `autostart._write_autostart_vbs`). Recording the console HWND and
    its visibility makes the fix self-verifying: `hwnd=0` means a windowed
    interpreter (ideal), `visible=False` means a console exists but is
    hidden (the VBScript did its job). Best effort — never raises.
    """
    try:
        hwnd = ctypes.windll.kernel32.GetConsoleWindow()
        visible = bool(hwnd) and bool(ctypes.windll.user32.IsWindowVisible(hwnd))
        return f"console_hwnd={hwnd} console_visible={visible}"
    except Exception:
        return "console_hwnd=? console_visible=?"


def _wait_for_shell(timeout: float = 60.0, interval: float = 0.5) -> bool:
    """Block until the taskbar exists, or `timeout` seconds pass.

    Returns True if the shell came up in time, False on timeout (or if the
    shell API is unavailable — then we don't block, just proceed). Polls
    every `interval` seconds. Returns immediately when the taskbar is
    already present (the normal post-login case).
    """
    deadline = time.monotonic() + timeout
    while True:
        try:
            if _taskbar_present():
                return True
        except Exception:
            # No Win32 shell API (non-Windows / unusual host) — don't hang.
            return False
        if time.monotonic() >= deadline:
            return False
        time.sleep(interval)


# ── Main ───────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    args = _common.parse_args(argv if argv is not None else sys.argv[1:])

    if args.config:
        return _common.print_config_paths()
    if args.setup:
        return _setup.do_setup(reauth=args.reauth)
    if args.command == "like-once":
        return _run_like_once()
    if args.command == "remove-once":
        return _run_remove_once()

    # Resident tray host — the login-launched path. Log the launch context
    # and funnel any startup crash to the log before pythonw lets it die
    # silently (the whole reason "снова не запустилось" left no trace).
    _log(
        f"launch — cwd={os.getcwd()} exe={sys.executable!r} "
        f"frozen={getattr(sys, 'frozen', False)} argv={sys.argv[1:]} "
        f"{_console_state()}"
    )
    try:
        return _run_resident_host()
    except SystemExit:
        raise  # single-instance guard / normal exit — not a fault
    except BaseException:
        import traceback

        _log("FATAL during resident host startup:\n" + traceback.format_exc())
        raise


def _run_resident_host() -> int:
    cfg = _common.load_config()
    provider = _common.build_provider(cfg)
    if provider is None:
        _msgbox(
            "Not configured. Run from a terminal:\n\n    like-spotify --setup\n",
            title="Like Spotify — setup required",
        )
        return 2

    _ensure_single_instance()
    hotkey = cfg.get("trigger", {}).get("hotkey", DEFAULT_HOTKEY)

    if not provider.has_tokens:
        _msgbox(
            "Not authenticated. Run from a terminal:\n\n    like-spotify --setup\n",
            title="Like Spotify — auth required",
        )
        return 2

    feedback = TrayFeedback(
        hotkey=hotkey, volume=_common.resolve_feedback_volume(cfg)
    )
    storage = _common.build_storage(cfg)
    pre_actions, post_actions = _common.build_action_chains(cfg, storage)
    pipeline = Pipeline(
        provider=provider,
        feedback=feedback,
        storage=storage,
        pre_like_actions=pre_actions,
        post_like_actions=post_actions,
    )
    trigger = make_tray_hotkey_trigger(hotkey=hotkey)

    # ── Second hotkey: remove-without-like (only when an archive is set) ──
    # Skip when no archive playlist is configured (nothing to remove from)
    # or when the remove hotkey collides with the like hotkey — registering
    # two handlers on one combo would fire both pipelines per press.
    remove_hotkey = _common.resolve_remove_hotkey(cfg)
    remove_pipeline = _common.build_remove_pipeline(cfg, provider, feedback)
    remove_enabled = remove_pipeline is not None and remove_hotkey != hotkey
    remove_trigger = (
        make_tray_hotkey_trigger(hotkey=remove_hotkey) if remove_enabled else None
    )

    loop = asyncio.new_event_loop()
    loop_thread = threading.Thread(target=loop.run_forever, daemon=True)
    loop_thread.start()

    async def emit() -> None:
        await pipeline.run_once()

    async def emit_remove() -> None:
        await remove_pipeline.run_once()

    asyncio.run_coroutine_threadsafe(trigger.start(emit), loop).result()
    if remove_trigger is not None:
        asyncio.run_coroutine_threadsafe(
            remove_trigger.start(emit_remove), loop
        ).result()

    def on_like(_icon, _item):
        asyncio.run_coroutine_threadsafe(pipeline.run_once(), loop)

    def on_remove(_icon, _item):
        asyncio.run_coroutine_threadsafe(remove_pipeline.run_once(), loop)

    def on_toggle_autostart(icon, _item):
        _autostart_set(not _autostart_enabled())
        icon.update_menu()

    def on_open_log(_icon, _item):
        log_file = _common.CONFIG_FILE.parent / "startup.log"
        try:
            os.startfile(log_file)  # noqa: S606 — user-owned path, tray click only
        except OSError:
            _msgbox(f"No log file yet:\n\n{log_file}", title="Like Spotify — log")

    def on_quit(icon, _item):
        for t in (trigger, remove_trigger):
            if t is None:
                continue
            try:
                asyncio.run_coroutine_threadsafe(t.stop(), loop).result(timeout=2)
            except Exception:
                pass
        loop.call_soon_threadsafe(loop.stop)
        icon.stop()

    icon = tray.build_icon(
        feedback=feedback,
        hotkey=hotkey,
        remove_enabled=remove_enabled,
        remove_hotkey=remove_hotkey,
        on_like=on_like,
        on_remove=on_remove,
        on_toggle_autostart=on_toggle_autostart,
        on_open_log=on_open_log,
        on_quit=on_quit,
    )

    def _startup_notify():
        time.sleep(0.5)
        msg = f"Press {hotkey.upper()} to like the current track"
        if remove_enabled:
            msg += f"\n{remove_hotkey.upper()} removes it from the archive"
        try:
            icon.notify(msg, "Like Spotify")
        except Exception:
            pass

    # Don't race the shell: at login the Run entry can fire before explorer
    # has built the notification area, and the icon add is then silently
    # dropped — process alive, no heart. Wait for the taskbar first.
    if _wait_for_shell():
        _log("shell ready — entering tray loop")
    else:
        _log("Shell_TrayWnd absent after 60s — adding tray icon anyway, proceeding")

    # Welcome balloon: its 0.5s delay is meant to land just after the icon
    # appears, so start it only now. On a cold boot the shell wait above can
    # run for seconds; firing earlier would call notify() before icon.run()
    # exists, and the balloon would be silently dropped.
    threading.Thread(target=_startup_notify, daemon=True).start()
    icon.run()
    return 0
