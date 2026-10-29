"""Tray-hotkey Trigger — default flavor.

Global keyboard hotkey emits a like intent. The hotkey callback fires on
the `keyboard` library's worker thread; we schedule the async emit on the
host's event loop via `run_coroutine_threadsafe`.
"""

from __future__ import annotations

import asyncio

import keyboard

from like_spotify.core.trigger import EmitFn, Trigger

DEFAULT_HOTKEY = "ctrl+shift+alt+w"


def same_hotkey(a: str, b: str) -> bool:
    """True when two combos name the same keys: case and the spaces around
    '+' do not matter. Two triggers on one combo would both fire on every
    press, so every place that accepts a hotkey refuses a duplicate."""

    def norm(combo: str) -> str:
        return "+".join(part.strip().lower() for part in combo.strip().split("+"))

    return norm(a) == norm(b)


class TrayHotkeyTrigger(Trigger):
    def __init__(self, hotkey: str = DEFAULT_HOTKEY) -> None:
        self.hotkey = hotkey
        self._loop: asyncio.AbstractEventLoop | None = None
        self._emit: EmitFn | None = None
        self._registered = False

    async def start(self, emit: EmitFn) -> None:
        self._loop = asyncio.get_running_loop()
        self._emit = emit
        keyboard.add_hotkey(self.hotkey, self._on_hotkey, suppress=False)
        self._registered = True

    async def stop(self) -> None:
        if not self._registered:
            return
        try:
            keyboard.remove_hotkey(self.hotkey)
        except (KeyError, ValueError):
            pass
        self._registered = False

    def _on_hotkey(self) -> None:
        if self._loop is None or self._emit is None:
            return
        asyncio.run_coroutine_threadsafe(self._emit(), self._loop)


def TRIGGER(hotkey: str = DEFAULT_HOTKEY) -> TrayHotkeyTrigger:
    return TrayHotkeyTrigger(hotkey=hotkey)
