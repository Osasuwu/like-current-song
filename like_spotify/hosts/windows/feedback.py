"""Windows host — tray icon rendering + synthesized-tone beep feedback.

Split out of `hosts/windows.py` in #55. Owns everything `TrayFeedback`
needs to confirm a like/remove/error to the user: the logo and heart icon
bitmaps and the PCM tone synthesis played through `winsound.PlaySound`.
"""

from __future__ import annotations

import math
import struct
import threading
import time
from array import array
from collections.abc import Callable

from .. import _common

# ── Tray icon + feedback ───────────────────────────────────────────────


# The logo's heart in a 100-unit box, as cubic Bézier segments — the same
# curves as `docs/logo.svg` and the Android launcher icon. The pause-play
# mark those carry inside the heart is left out here: at tray size it is a
# smudge.
_HEART = (
    ((50, 88), (20, 66), (6, 50), (6, 32)),
    ((6, 32), (6, 18), (17, 8), (30, 8)),
    ((30, 8), (39, 8), (46, 13), (50, 20)),
    ((50, 20), (54, 13), (61, 8), (70, 8)),
    ((70, 8), (83, 8), (94, 18), (94, 32)),
    ((94, 32), (94, 50), (80, 66), (50, 88)),
)

_ICON_SIZE = 64
# Drawn this many times larger and scaled down: Pillow's polygons have no
# anti-aliasing of their own.
_SUPERSAMPLE = 4


def _heart_points(scale: float, dx: float, dy: float, steps: int = 16):
    """[_HEART] flattened to a polygon, scaled by [scale] and moved by (dx, dy)."""
    points = []
    for p0, p1, p2, p3 in _HEART:
        for i in range(steps):
            t = i / steps
            u = 1 - t
            a, b, c, d = u**3, 3 * u * u * t, 3 * u * t * t, t**3
            points.append((
                dx + scale * (a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0]),
                dy + scale * (a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]),
            ))
    return points


def _draw_icon(tile: tuple[int, int, int] | None, heart: tuple[int, int, int]):
    from PIL import Image, ImageDraw

    s = _ICON_SIZE * _SUPERSAMPLE
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if tile is not None:
        d.rounded_rectangle([0, 0, s - 1, s - 1], radius=s * 0.22, fill=tile)
    # The heart spans 88 x 80 units, centred on (50, 48).
    scale = s * (0.66 if tile is not None else 1.0) / 100
    d.polygon(
        _heart_points(scale, s / 2 - 50 * scale, s / 2 - 48 * scale),
        fill=heart,
    )
    return img.resize((_ICON_SIZE, _ICON_SIZE), Image.LANCZOS)


def _make_logo_icon():
    """The logo: a white heart on the violet tile. The tray at rest, and the
    Settings window."""
    return _draw_icon(_ICON_BRAND, _ICON_WHITE)


def _make_heart_icon(color: tuple[int, int, int]):
    """A bare heart in [color] — the flash a like or a failure shows."""
    return _draw_icon(None, color)


# The logo's violet, the same as `docs/logo.svg` and the launcher icon.
_ICON_BRAND = (91, 63, 217)
_ICON_WHITE = (255, 255, 255)
_ICON_RED = (255, 60, 60)


_TONE_SAMPLE_RATE = 44100


def _synth_tone(segments: list[tuple[int, int]], volume: float = 1.0) -> bytes:
    """Render (frequency_hz, duration_ms) segments to an in-memory PCM16
    mono WAV buffer, playable via `winsound.PlaySound(..., SND_MEMORY)`.

    Exists because the two built-in `winsound` options both failed on
    real hardware: `MessageBeep` plays a named system-event sound, which
    Focus Assist / Do Not Disturb suppresses like any notification sound;
    `Beep` drives the legacy PC-speaker/timer tone, which modern audio
    codecs leave unwired to the physical speakers (confirmed silent here —
    only a brief hiccup in whatever else was playing). A synthesized tone
    plays as an ordinary audio-session buffer instead, mirroring the
    phone's `ToneGenerator(AudioManager.STREAM_MUSIC, ...)` feedback
    (`FeedbackPlayer.kt`) rather than routing through any OS notification
    channel.

    `volume` (0.0-1.0, see `_common.resolve_feedback_volume`) scales a
    24000-peak waveform, so 0.5 reproduces the level this shipped at
    before the setting existed.
    """
    peak = 24000 * max(0.0, min(1.0, volume))
    fade = int(_TONE_SAMPLE_RATE * 0.005)  # 5ms fade in/out — avoids clicks
    gap = int(_TONE_SAMPLE_RATE * 0.03)  # 30ms silence between notes
    samples = array("h")
    for freq, duration_ms in segments:
        n = int(_TONE_SAMPLE_RATE * duration_ms / 1000)
        for i in range(n):
            amp = 1.0
            if i < fade:
                amp = i / fade
            elif i > n - fade:
                amp = (n - i) / fade
            value = math.sin(2 * math.pi * freq * i / _TONE_SAMPLE_RATE)
            samples.append(int(value * amp * peak))
        samples.extend([0] * gap)
    data = samples.tobytes()
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + len(data),
        b"WAVE",
        b"fmt ",
        16,
        1,  # PCM
        1,  # mono
        _TONE_SAMPLE_RATE,
        _TONE_SAMPLE_RATE * 2,  # byte rate (16-bit mono)
        2,  # block align
        16,  # bits per sample
        b"data",
        len(data),
    )
    return header + data


def _synth_tones(volume: float) -> dict[str, bytes]:
    """Rising two-note chime (like), a single mid tone (remove), a low
    double buzz (error) — distinct enough to tell apart without looking
    at the tray. Rebuilt per `TrayFeedback` instance so `volume` (from
    `trigger.feedback_volume`) takes effect.
    """
    return {
        "like": _synth_tone([(784, 90), (1175, 110)], volume=volume),
        "remove": _synth_tone([(587, 150)], volume=volume),
        "error": _synth_tone([(220, 90), (220, 90)], volume=volume),
    }


def _play_tone(data: bytes) -> None:
    """Play a synthesized-tone WAV buffer through the default sound device.

    `SND_MEMORY` only, deliberately no `SND_ASYNC`: winsound rejects
    `SND_MEMORY | SND_ASYNC` outright (buffer lifetime can't be guaranteed
    for async playback from memory) and raises
    `RuntimeError: Cannot play asynchronously from memory` — see 78f1e17,
    which fixed a crash on every beep. `_beep` already runs on its own
    daemon thread, so synchronous playback here doesn't block the caller.
    """
    import winsound

    winsound.PlaySound(data, winsound.SND_MEMORY)


class TrayFeedback:
    """Owns the tray icon + flash / beep / balloon feedback."""

    def __init__(
        self,
        hotkey: str,
        volume: float = _common.DEFAULT_FEEDBACK_VOLUME,
        *,
        player: Callable[[bytes], None] = _play_tone,
    ) -> None:
        self._hotkey = hotkey
        self._icon_default = _make_logo_icon()
        self._icon_success = _make_heart_icon(_ICON_WHITE)
        self._icon_error = _make_heart_icon(_ICON_RED)
        self._icon = None  # set in run()
        self._tones = _synth_tones(volume)
        self._player = player

    def attach(self, icon) -> None:
        self._icon = icon

    def set_volume(self, volume: float) -> None:
        """Re-synthesize the tones — the tray applies a settings save live."""
        self._tones = _synth_tones(volume)

    def __call__(
        self, success: bool, title: str, message: str, *, kind: str = "like"
    ) -> None:
        threading.Thread(
            target=self._beep, args=(success, kind), daemon=True
        ).start()
        threading.Thread(target=self._flash, args=(success,), daemon=True).start()
        if self._icon is not None:
            try:
                self._icon.notify(message or title, "Like Current Song")
            except Exception:
                pass

    def _flash(self, success: bool) -> None:
        if self._icon is None:
            return
        self._icon.icon = self._icon_success if success else self._icon_error
        time.sleep(0.4)
        self._icon.icon = self._icon_default

    def _beep(self, success: bool, kind: str) -> None:
        """Audible confirmation through the default sound device.

        Plays a synthesized tone (`_synth_tone`, see module docstring)
        through `self._player` (`_play_tone` by default) rather than
        `MessageBeep` or `Beep` — both proved unreliable/silent on real
        hardware. Distinct tones per outcome so like / remove / error are
        distinguishable without looking at the tray. `player` is an
        injectable seam so tests can capture playback without touching
        `winsound`/real audio.
        """
        if not success:
            tone = self._tones["error"]
        elif kind == "remove":
            tone = self._tones["remove"]
        else:
            tone = self._tones["like"]
        self._player(tone)

    @property
    def default_icon(self):
        return self._icon_default
