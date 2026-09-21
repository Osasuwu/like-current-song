"""Windows host — resident tray wiring, one-shot subcommands, startup log.

Split out of `hosts/windows.py` in #55. Owns process-level concerns: the
single-instance mutex, `like-once`/`discard-once` one-shot subcommands, the
login-time startup log + shell-readiness wait, and `_run_resident_host`
(wires `Pipeline` + `Trigger` + the tray icon built by `tray.build_icon`).
Since #100 the wiring is rebuildable (`_build_wiring` / `_HostRuntime.reload`)
so a save in the settings window — spawned as a child process by
`_SettingsLauncher` — applies live, with a restart offer as the fallback.
This is the module's entry point — `main()` lives here.
"""

from __future__ import annotations

import asyncio
import ctypes
import os
import subprocess
import sys
import threading
import time
from dataclasses import dataclass

from like_spotify.core.pipeline import DiscardPipeline, Pipeline
from like_spotify.extensions.tray_hotkey_trigger import (
    DEFAULT_HOTKEY,
    TRIGGER as make_tray_hotkey_trigger,
)

from .. import _common, _setup
from .._stub import CliFeedback
from . import tray
from .autostart import _autostart_enabled, _autostart_set, migrate_legacy_entry
from .feedback import TrayFeedback

# ── Single-instance guard ──────────────────────────────────────────────


def _ensure_single_instance():
    """Take the named mutex or exit. Returns the handle so a restart can
    release it before launching the replacement process."""
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.CreateMutexW(None, True, "LikeSpotify_SingleInstance")
    if kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
        sys.exit(0)
    return handle


def _release_single_instance(handle) -> None:
    try:
        kernel32 = ctypes.windll.kernel32
        kernel32.ReleaseMutex(handle)
        kernel32.CloseHandle(handle)
    except Exception:
        pass


# ── Error reporting ────────────────────────────────────────────────────


def _msgbox(text: str, title: str = "Like Current Song", icon: int = 0x10) -> None:
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
            "Not configured. Run from a terminal:\n\n    like-current-song --setup\n",
            title="Like Current Song — setup required",
        )
        return None, 2, cfg
    if not provider.has_tokens:
        _msgbox(
            "Not authenticated. Run from a terminal:\n\n    like-current-song --setup\n",
            title="Like Current Song — auth required",
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


def _run_discard_once() -> int:
    provider, err, cfg = _resolved_provider_or_hint()
    if provider is None:
        return err

    feedback = CliFeedback()
    pipeline = _common.build_discard_pipeline(cfg, provider, feedback)
    if pipeline is None:
        # Both legs are out: no archive playlist to remove from, and a
        # music service that can't be told "not this one" either.
        _msgbox(
            "Nothing to discard with: this music service has no dislike, "
            "and no archive playlist is configured. Run from a terminal:\n\n"
            "    like-current-song --setup\n",
            title="Like Current Song — setup required",
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
    if args.settings:
        from ..settings import run as run_settings  # lazy: keeps tkinter out of the tray

        return run_settings(from_tray=args.from_tray)
    if args.command == "like-once":
        return _run_like_once()
    if args.command == "discard-once":
        return _run_discard_once()

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


# ── Wiring (rebuildable, so a settings save applies live) ──────────────


class _NotReady(Exception):
    """Config can't drive the tray yet (no provider / not signed in)."""


@dataclass
class _Wiring:
    """Everything built from one config snapshot. No side effects until
    `_HostRuntime` starts `trigger` / `remove_trigger`."""

    hotkey: str
    remove_hotkey: str
    volume: float
    pipeline: Pipeline
    discard_pipeline: DiscardPipeline | None
    trigger: object
    discard_trigger: object | None

    @property
    def discard_enabled(self) -> bool:
        return self.discard_trigger is not None


def _build_wiring(cfg: dict, feedback, *, make_trigger=make_tray_hotkey_trigger) -> _Wiring:
    provider = _common.build_provider(cfg)
    if provider is None:
        raise _NotReady("the music service isn't configured")
    if not provider.has_tokens:
        raise _NotReady("you're not signed in to the music service")

    hotkey = cfg.get("trigger", {}).get("hotkey", DEFAULT_HOTKEY)
    storage = _common.build_storage(cfg)
    pre_actions, post_actions = _common.build_action_chains(cfg, storage)
    pipeline = Pipeline(
        provider=provider,
        feedback=feedback,
        storage=storage,
        pre_like_actions=pre_actions,
        post_like_actions=post_actions,
    )

    # ── Second hotkey: discard-without-like ───────────────────────────────
    # Skipped only when a press could do nothing at all — no archive
    # playlist *and* a provider with no dislike (`build_discard_pipeline`
    # owns that call) — or when the discard hotkey collides with the like
    # hotkey, since registering two handlers on one combo would fire both
    # pipelines per press. Note a dislike-capable provider now earns the
    # hotkey on its own, so a user who never archives still gets it (#172).
    remove_hotkey = _common.resolve_remove_hotkey(cfg)
    discard_pipeline = _common.build_discard_pipeline(cfg, provider, feedback)
    discard_enabled = discard_pipeline is not None and remove_hotkey != hotkey
    return _Wiring(
        hotkey=hotkey,
        remove_hotkey=remove_hotkey,
        volume=_common.resolve_feedback_volume(cfg),
        pipeline=pipeline,
        discard_pipeline=discard_pipeline if discard_enabled else None,
        trigger=make_trigger(hotkey=hotkey),
        discard_trigger=make_trigger(hotkey=remove_hotkey) if discard_enabled else None,
    )


class _HostRuntime:
    """The live tray state: event loop + current `_Wiring`.

    `reload(cfg)` swaps the wiring in place: build the new one first (a
    config that can't run leaves the old one untouched), stop the old
    hotkeys, start the new ones, and roll back to the old hotkeys if the
    new ones won't register. Trigger callbacks read `self.wiring` at call
    time, so nothing needs re-binding.
    """

    def __init__(self, loop, feedback, wiring: _Wiring, *, make_trigger=make_tray_hotkey_trigger):
        self.loop = loop
        self.feedback = feedback
        self.wiring = wiring
        self._make_trigger = make_trigger
        self._lock = threading.Lock()

    def _call(self, coro, timeout: float = 5.0):
        return asyncio.run_coroutine_threadsafe(coro, self.loop).result(timeout=timeout)

    async def _emit_like(self) -> None:
        await self.wiring.pipeline.run_once()

    async def _emit_discard(self) -> None:
        if self.wiring.discard_pipeline is not None:
            await self.wiring.discard_pipeline.run_once()

    def _start_triggers(self, w: _Wiring) -> None:
        started = []
        try:
            self._call(w.trigger.start(self._emit_like))
            started.append(w.trigger)
            if w.discard_trigger is not None:
                self._call(w.discard_trigger.start(self._emit_discard))
                started.append(w.discard_trigger)
        except BaseException:
            for t in started:
                self._stop_trigger(t)
            raise

    def _stop_trigger(self, t) -> None:
        try:
            self._call(t.stop(), timeout=2)
        except Exception:
            pass

    def _stop_triggers(self, w: _Wiring) -> None:
        for t in (w.trigger, w.discard_trigger):
            if t is not None:
                self._stop_trigger(t)

    def start(self) -> None:
        self._start_triggers(self.wiring)

    def stop(self) -> None:
        self._stop_triggers(self.wiring)

    def like(self) -> None:
        asyncio.run_coroutine_threadsafe(self._emit_like(), self.loop)

    def discard(self) -> None:
        asyncio.run_coroutine_threadsafe(self._emit_discard(), self.loop)

    def state(self) -> tuple[str, bool, str | None, str]:
        """`(like hotkey, discard enabled, discard hotkey, discard label)`.

        The label comes from the pipeline rather than the tray so the menu
        item, the startup balloon and the feedback all name the same press
        — which now varies with what the provider can actually do (#172).
        """
        w = self.wiring
        label = w.discard_pipeline.label if w.discard_pipeline is not None else ""
        return w.hotkey, w.discard_enabled, w.remove_hotkey, label

    def reload(self, cfg: dict) -> None:
        """Apply `cfg` live. Raises `_NotReady` (nothing changed) or the
        trigger's error (old hotkeys restored)."""
        with self._lock:
            new = _build_wiring(cfg, self.feedback, make_trigger=self._make_trigger)
            old = self.wiring
            self._stop_triggers(old)
            self.wiring = new
            try:
                self._start_triggers(new)
            except BaseException:
                self.wiring = old
                try:
                    self._start_triggers(old)
                except Exception:
                    _log("could not restore previous hotkeys after a failed reload")
                raise
            set_volume = getattr(self.feedback, "set_volume", None)
            if set_volume is not None:
                set_volume(new.volume)


# ── Settings window + restart ──────────────────────────────────────────
#
# The window runs as a CHILD PROCESS, not a thread. pystray owns the main
# thread's Win32 message loop and Tk wants its own thread-affine
# interpreter + mainloop; running Tk on a side thread of this process
# invites "Tcl_AsyncDelete: async handler deleted by the wrong thread"
# crashes, and a Tk crash would take the hotkeys down with it. A separate
# process can't block or crash the tray, keeps the keyboard hooks
# untouched, and needs no Tk in the resident process at all. The tray
# learns about a save by comparing config.json before/after.


def _self_command(*args: str) -> list[str]:
    """argv that re-launches this app (frozen .exe or `-m like_spotify`)."""
    if getattr(sys, "frozen", False):
        return [sys.executable, *args]
    return [sys.executable, "-m", "like_spotify", *args]


def _spawn(argv: list[str]) -> subprocess.Popen:
    return subprocess.Popen(
        argv, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), close_fds=True
    )


def _config_snapshot() -> bytes | None:
    try:
        return _common.CONFIG_FILE.read_bytes()
    except OSError:
        return None


class _SettingsLauncher:
    """One settings window at a time; calls `on_saved()` after a save."""

    def __init__(self, on_saved, *, spawn=_spawn) -> None:
        self._on_saved = on_saved
        self._spawn = spawn
        self._proc = None
        self._lock = threading.Lock()

    def open(self) -> bool:
        """Launch the window. False if one is already open."""
        with self._lock:
            if self._proc is not None and self._proc.poll() is None:
                return False
            before = _config_snapshot()
            self._proc = self._spawn(_self_command("--settings", "--from-tray"))
            proc = self._proc
        threading.Thread(target=self._watch, args=(proc, before), daemon=True).start()
        return True

    def _watch(self, proc, before) -> None:
        proc.wait()
        if _config_snapshot() != before:
            self._on_saved()


def _ask_yes_no(text: str, title: str = "Like Current Song") -> bool:
    MB_YESNO, MB_ICONWARNING, IDYES = 0x04, 0x30, 6
    try:
        return ctypes.windll.user32.MessageBoxW(0, text, title, MB_YESNO | MB_ICONWARNING) == IDYES
    except Exception:
        return False


def _offer_settings(problem: str, title: str) -> bool:
    """First-run path: offer the window instead of only pointing at --setup.
    Returns True if the window was shown (the caller re-reads config)."""
    if not _ask_yes_no(
        f"{problem}\n\nOpen Settings now?\n\n(Or run `like-current-song --setup` from a terminal.)",
        title,
    ):
        return False
    from ..settings import run as run_settings

    return run_settings() == 0


# ── Resident host ──────────────────────────────────────────────────────


def _run_resident_host() -> int:
    feedback = None
    while True:
        cfg = _common.load_config()
        if feedback is None:
            feedback = TrayFeedback(
                hotkey=cfg.get("trigger", {}).get("hotkey", DEFAULT_HOTKEY),
                volume=_common.resolve_feedback_volume(cfg),
            )
        try:
            wiring = _build_wiring(cfg, feedback)
            break
        except _NotReady as e:
            configured = _common.build_provider(cfg) is not None
            title = "Like Current Song — " + ("sign-in required" if configured else "setup required")
            before = _config_snapshot()
            if not _offer_settings(f"Like Current Song can't start: {e}.", title):
                return 2
            if _config_snapshot() == before and not configured:
                return 2  # window closed without saving — don't loop forever

    mutex = _ensure_single_instance()
    feedback.set_volume(wiring.volume)
    try:
        if migrate_legacy_entry():
            _log("autostart: migrated legacy like-spotify-gui entry to like-current-song-gui")
    except Exception:
        import traceback

        _log("autostart migration failed:\n" + traceback.format_exc())

    loop = asyncio.new_event_loop()
    threading.Thread(target=loop.run_forever, daemon=True).start()
    runtime = _HostRuntime(loop, feedback, wiring)
    runtime.start()
    icon = None  # built below; callbacks only fire once it runs

    def shutdown() -> None:
        runtime.stop()
        loop.call_soon_threadsafe(loop.stop)
        icon.stop()

    def restart() -> None:
        runtime.stop()
        _release_single_instance(mutex)  # let the new process take the mutex
        try:
            _spawn(_self_command())
        except OSError as e:
            _msgbox(f"Couldn't restart Like Current Song: {e}\n\nStart it again from the Start menu.")
        loop.call_soon_threadsafe(loop.stop)
        icon.stop()

    def on_settings_saved() -> None:
        try:
            runtime.reload(_common.load_config())
        except _NotReady as e:
            _msgbox(
                f"Settings saved, but {e} yet, so the tray keeps using the "
                "previous settings. Connect your account in Settings… to "
                "switch over.",
                title="Like Current Song — settings",
                icon=0x40,
            )
            return
        except Exception as e:
            import traceback

            _log("live settings reload failed:\n" + traceback.format_exc())
            if _ask_yes_no(
                "Settings saved, but the running tray couldn't switch to them "
                f"({e}).\n\nA restart is needed. Restart Like Current Song now?",
                title="Like Current Song — restart needed",
            ):
                restart()
            return
        icon.title = tray.icon_title(runtime.wiring.hotkey)
        icon.update_menu()
        try:
            icon.notify(
                f"Settings applied. Like: {runtime.wiring.hotkey.upper()}", "Like Current Song"
            )
        except Exception:
            pass

    settings = _SettingsLauncher(on_settings_saved)

    def on_settings(_icon, _item):
        if not settings.open():
            try:
                icon.notify("Settings is already open", "Like Current Song")
            except Exception:
                pass

    def on_toggle_autostart(icon, _item):
        _autostart_set(not _autostart_enabled())
        icon.update_menu()

    def on_open_log(_icon, _item):
        log_file = _common.CONFIG_FILE.parent / "startup.log"
        try:
            os.startfile(log_file)  # noqa: S606 — user-owned path, tray click only
        except OSError:
            _msgbox(f"No log file yet:\n\n{log_file}", title="Like Current Song — log")

    icon = tray.build_icon(
        feedback=feedback,
        state=runtime.state,
        on_like=lambda _icon, _item: runtime.like(),
        on_discard=lambda _icon, _item: runtime.discard(),
        on_settings=on_settings,
        on_toggle_autostart=on_toggle_autostart,
        on_open_log=on_open_log,
        on_quit=lambda _icon, _item: shutdown(),
    )

    def _startup_notify():
        time.sleep(0.5)
        hotkey, discard_enabled, remove_hotkey, discard_label = runtime.state()
        msg = f"Press {hotkey.upper()} to like the current track"
        if discard_enabled:
            msg += f"\n{remove_hotkey.upper()}: {discard_label.lower()}"
        try:
            icon.notify(msg, "Like Current Song")
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


