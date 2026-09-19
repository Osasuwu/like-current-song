"""Windows host — per-process DPI awareness for the settings window (#100).

Without it Windows bitmap-scales a Tk window on a scaled display, which
makes all its text blurry. Kept here so `ctypes.windll` stays inside
`hosts/windows/`.
"""

from __future__ import annotations

import ctypes

PROCESS_SYSTEM_DPI_AWARE = 1


def enable_dpi_awareness() -> None:
    """Best effort. Must run before the first window is created."""
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(PROCESS_SYSTEM_DPI_AWARE)
    except Exception:
        pass
