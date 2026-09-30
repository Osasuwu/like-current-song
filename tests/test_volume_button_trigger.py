"""Smoke tests for the VolumeButtonTrigger skeleton's pure pattern matcher.

The HID read loop is intentionally a NotImplementedError stub (issue
#29 ships the skeleton; implementation is a separate good-first-PR per
CONTRIBUTING.md). We don't test `_listen`. We DO test:

1. The double-tap window matcher is correct in isolation. Future
   implementers shouldn't break the matcher when adding the HID loop.
2. The factory returns a Trigger instance the host can wire.

The "two presses inside window → emit" path needs an event loop
because the trigger schedules via `run_coroutine_threadsafe`. We
exercise it via a tiny harness.
"""

from __future__ import annotations

import asyncio

import pytest

from like_spotify.core.trigger import Trigger
from like_spotify.extensions.volume_button_trigger import (
    TRIGGER,
    DOUBLE_TAP_WINDOW_MS,
    VolumeButtonTrigger,
)


def test_factory_returns_trigger_instance() -> None:
    assert isinstance(TRIGGER(), Trigger)
    assert isinstance(TRIGGER(), VolumeButtonTrigger)


def test_factory_propagates_window_override() -> None:
    trigger = TRIGGER(double_tap_window_ms=123)
    assert trigger._window_ms == 123


def test_single_press_does_not_emit() -> None:
    trigger = VolumeButtonTrigger(double_tap_window_ms=300)
    # No loop wired — emit path is dormant. _on_volume_up should just
    # store the timestamp and return.
    trigger._on_volume_up(now_ms=0)
    assert trigger._last_press_ms == 0


def test_two_presses_inside_window_match() -> None:
    """The matcher consumes the first stamp on a match — a third press
    must NOT count as a second double-tap with the matched event."""
    trigger = VolumeButtonTrigger(double_tap_window_ms=300)
    trigger._on_volume_up(now_ms=0)
    trigger._on_volume_up(now_ms=100)  # inside the window → match
    assert trigger._last_press_ms is None  # consumed


def test_two_presses_outside_window_do_not_match() -> None:
    trigger = VolumeButtonTrigger(double_tap_window_ms=300)
    trigger._on_volume_up(now_ms=0)
    trigger._on_volume_up(now_ms=1000)
    # The second press becomes the new candidate — not a match.
    assert trigger._last_press_ms == 1000


@pytest.mark.asyncio
async def test_three_presses_spaced_widely_do_not_match() -> None:
    """Three single presses each > window apart must never emit."""
    trigger = VolumeButtonTrigger(double_tap_window_ms=200)
    calls = 0

    async def emit() -> None:
        nonlocal calls
        calls += 1

    # The end state alone cannot tell "never matched" from "matched the
    # first two, then stored the third" — so count the emits.
    trigger._loop = asyncio.get_running_loop()
    trigger._emit = emit

    trigger._on_volume_up(now_ms=0)
    trigger._on_volume_up(now_ms=500)
    trigger._on_volume_up(now_ms=1000)

    await asyncio.sleep(0.05)
    assert calls == 0
    # Last single press is the candidate; no match was ever consumed.
    assert trigger._last_press_ms == 1000


@pytest.mark.asyncio
async def test_double_tap_schedules_emit_on_running_loop() -> None:
    """End-to-end: when the trigger has a loop + emit wired (as the host
    arranges in `start`), a matched double-tap fires `emit` exactly once.
    """
    trigger = VolumeButtonTrigger(double_tap_window_ms=300)
    calls = 0

    async def emit() -> None:
        nonlocal calls
        calls += 1

    # Manually wire what `start` would wire — we don't run `_listen`.
    trigger._loop = asyncio.get_running_loop()
    trigger._emit = emit

    trigger._on_volume_up(now_ms=0)
    trigger._on_volume_up(now_ms=50)  # match

    # `run_coroutine_threadsafe` returns a `concurrent.futures.Future`
    # that completes once the coroutine has been scheduled and awaited.
    # Yielding once lets the scheduled coroutine run.
    await asyncio.sleep(0.05)
    assert calls == 1


@pytest.mark.asyncio
async def test_listen_is_not_implemented_yet() -> None:
    """Guard rail: the skeleton must NOT silently pretend to listen.
    A future implementer replacing this with a real HID loop will
    delete this test as part of their PR."""
    trigger = VolumeButtonTrigger()
    with pytest.raises(NotImplementedError):
        await trigger._listen()


def test_module_window_constant_matches_class_default() -> None:
    assert VolumeButtonTrigger()._window_ms == DOUBLE_TAP_WINDOW_MS
