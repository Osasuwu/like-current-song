"""OneShotCliTrigger — second Trigger impl.

Where `TrayHotkeyTrigger` is resident (registers a global hotkey and
sticks around emitting on each press), this one fires exactly once on
`start()` and is done. The user signal is the invocation itself:

    $ like-current-song like-once

Validates that the `Trigger` interface accommodates per-invocation
lifetime alongside the resident tray case. Slice: #27.
"""

from __future__ import annotations

from like_spotify.core.trigger import EmitFn, Trigger


class OneShotCliTrigger(Trigger):
    def __init__(self) -> None:
        self._started = False
        self._stopped = False

    async def start(self, emit: EmitFn) -> None:
        if self._stopped or self._started:
            return
        self._started = True
        await emit()

    async def stop(self) -> None:
        self._stopped = True


def TRIGGER() -> OneShotCliTrigger:
    return OneShotCliTrigger()
