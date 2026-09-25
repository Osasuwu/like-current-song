"""Regression tests for TrayFeedback._beep / _synth_tone (feedback.py).

Slice: #56. `hosts/windows.py`'s split in #55 isolated `TrayFeedback` into
its own module but left it untested — exactly where the SND_ASYNC-from-
memory crash (78f1e17) lived. `_play_tone` is an injectable seam
(`TrayFeedback(..., player=...)`) so these tests never touch a real sound
device.
"""

from __future__ import annotations

import sys

import pytest

from like_spotify.hosts.windows import feedback


# ── _synth_tone / _synth_tones ─────────────────────────────────────────


def test_synth_tone_produces_a_valid_wav_header() -> None:
    data = feedback._synth_tone([(440, 50)], volume=1.0)
    assert data[:4] == b"RIFF"
    assert data[8:12] == b"WAVE"
    assert data[12:16] == b"fmt "


def test_synth_tone_volume_scales_peak_amplitude() -> None:
    loud = feedback._synth_tone([(440, 50)], volume=1.0)
    quiet = feedback._synth_tone([(440, 50)], volume=0.1)
    # Volume doesn't change duration, only amplitude.
    assert len(loud) == len(quiet)
    assert max(loud) >= max(quiet)


def test_synth_tones_returns_distinct_like_remove_error() -> None:
    tones = feedback._synth_tones(volume=1.0)
    assert set(tones) == {"like", "remove", "error"}
    assert tones["like"] != tones["remove"]
    assert tones["remove"] != tones["error"]


# ── TrayFeedback._beep: tone selection ──────────────────────────────────


def _make_feedback(player):
    return feedback.TrayFeedback("ctrl+alt+l", player=player)


def test_beep_success_like_plays_like_tone() -> None:
    calls: list[bytes] = []
    fb = _make_feedback(player=calls.append)

    fb._beep(success=True, kind="like")

    assert calls == [fb._tones["like"]]


def test_beep_success_remove_plays_remove_tone() -> None:
    calls: list[bytes] = []
    fb = _make_feedback(player=calls.append)

    fb._beep(success=True, kind="remove")

    assert calls == [fb._tones["remove"]]


def test_beep_failure_plays_error_tone_regardless_of_kind() -> None:
    calls: list[bytes] = []
    fb = _make_feedback(player=calls.append)

    fb._beep(success=False, kind="remove")

    assert calls == [fb._tones["error"]]


# ── _play_tone: the real winsound seam ──────────────────────────────────
#
# Real `winsound.PlaySound` rejects `SND_MEMORY | SND_ASYNC` outright and
# raises `RuntimeError: Cannot play asynchronously from memory` — every
# beep crashed with this before 78f1e17. A fake winsound that reproduces
# that check pins the fix: `_play_tone` must never pass the async flag.


class _FakeWinsound:
    SND_MEMORY = 4
    SND_ASYNC = 1

    def __init__(self) -> None:
        self.calls: list[tuple[bytes, int]] = []

    def PlaySound(self, data: bytes, flags: int) -> None:
        if flags & self.SND_ASYNC and flags & self.SND_MEMORY:
            raise RuntimeError("Cannot play asynchronously from memory")
        self.calls.append((data, flags))


@pytest.fixture
def fake_winsound(monkeypatch) -> _FakeWinsound:
    fake = _FakeWinsound()
    monkeypatch.setitem(sys.modules, "winsound", fake)
    return fake


def test_play_tone_uses_sync_memory_playback(fake_winsound) -> None:
    feedback._play_tone(b"tonedata")

    assert fake_winsound.calls == [(b"tonedata", fake_winsound.SND_MEMORY)]


def test_play_tone_would_crash_if_async_flag_were_reintroduced(
    fake_winsound,
) -> None:
    """Regression guard: pins the exact crash 78f1e17 fixed, so a future
    edit that reintroduces SND_ASYNC fails loudly in CI instead of on
    every user's first like."""
    with pytest.raises(RuntimeError, match="Cannot play asynchronously"):
        fake_winsound.PlaySound(
            b"tonedata", fake_winsound.SND_MEMORY | fake_winsound.SND_ASYNC
        )


def test_tray_at_rest_shows_the_logo_tile() -> None:
    # The violet tile with a white heart, matching the launcher icon and
    # docs/logo.svg — not a bare heart, which the flashes use.
    icon = feedback._make_logo_icon()
    assert icon.size == (64, 64)
    assert icon.getpixel((32, 3))[:3] == feedback._ICON_BRAND
    assert icon.getpixel((32, 32))[:3] == feedback._ICON_WHITE


def test_flash_hearts_leave_the_corners_clear() -> None:
    icon = feedback._make_heart_icon(feedback._ICON_RED)
    assert icon.getpixel((1, 1))[3] == 0
    assert icon.getpixel((32, 40))[:3] == feedback._ICON_RED
