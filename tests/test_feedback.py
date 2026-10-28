"""Regression tests for TrayFeedback._beep / _synth_tone (feedback.py).

Slice: #56. `hosts/windows.py`'s split in #55 isolated `TrayFeedback` into
its own module but left it untested — exactly where the SND_ASYNC-from-
memory crash (78f1e17) lived. `_play_tone` is an injectable seam
(`TrayFeedback(..., player=...)`) so these tests never touch a real sound
device.
"""

from __future__ import annotations

import re
import struct
import sys
from pathlib import Path

import pytest

from like_spotify.hosts.windows import feedback


# ── _synth_tone / _synth_tones ─────────────────────────────────────────


def test_synth_tone_produces_a_valid_wav_header() -> None:
    data = feedback._synth_tone([(440, 50)], volume=1.0)
    assert data[:4] == b"RIFF"
    assert data[8:12] == b"WAVE"
    assert data[12:16] == b"fmt "


def _peak(wav: bytes) -> int:
    """Largest absolute 16-bit sample after the 44-byte WAV header."""
    body = wav[44:]
    return max(abs(s) for s in struct.unpack(f"<{len(body) // 2}h", body))


def test_synth_tone_volume_scales_peak_amplitude() -> None:
    loud = feedback._synth_tone([(440, 50)], volume=1.0)
    quiet = feedback._synth_tone([(440, 50)], volume=0.1)
    # Volume doesn't change duration, only amplitude.
    assert len(loud) == len(quiet)
    # Samples, not raw bytes: the largest *byte* is 0xFF at any volume.
    assert _peak(loud) > 0
    assert _peak(quiet) == pytest.approx(_peak(loud) / 10, abs=2)


def test_synth_tones_returns_distinct_like_remove_error_undo() -> None:
    tones = feedback._synth_tones(volume=1.0)
    assert set(tones) == {"like", "remove", "error", "undo"}
    assert len(set(tones.values())) == 4


def test_like_rises_and_undo_is_the_same_pair_falling() -> None:
    # #266: undo is the like taken back — same two notes, opposite direction.
    assert feedback._TONE_SEGMENTS["like"] == [(784, 90), (1175, 110)]
    assert feedback._TONE_SEGMENTS["undo"] == [(1175, 90), (784, 110)]


_KOTLIN_TONES = (
    Path(__file__).resolve().parents[1]
    / "android/app/src/main/kotlin/com/osasuwu/like_spotify/FeedbackTones.kt"
)


def test_phone_and_desktop_share_the_like_error_undo_tones() -> None:
    # #266: the phone synthesizes the same segments, so a like sounds the same
    # on both. Parsed from FeedbackTones.kt's `val X = tone(hz to ms, ...)`.
    source = _KOTLIN_TONES.read_text(encoding="utf-8")
    phone = {
        name.lower(): [
            (int(hz), int(ms))
            for hz, ms in re.findall(r"(\d+)\s+to\s+(\d+)", args)
        ]
        for name, args in re.findall(r"val\s+(\w+)\s*=\s*tone\(([^)]*)\)", source)
    }
    shared = {k: v for k, v in feedback._TONE_SEGMENTS.items() if k != "remove"}
    assert phone == shared


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


def test_beep_success_undo_plays_undo_tone() -> None:
    calls: list[bytes] = []
    fb = _make_feedback(player=calls.append)

    fb._beep(success=True, kind="undo")

    assert calls == [fb._tones["undo"]]


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
