"""Settings window (#100) — a GUI over everything `--setup` configures.

Layers:
    model.py    — config.json <-> `Settings`, validation, save. Pure; tested.
    services.py — OAuth connect + autostart side effects. Toolkit-free.
    window.py   — the tkinter view. Imported only by `run()`, so importing
                  this package never pulls in tkinter (headless boxes and
                  Python builds without Tk keep working).

Entry points: `like-spotify --settings`, and the tray's "Settings…" item,
which launches that same command as a child process (see
`hosts/windows/resident.py` for why it's a process, not a thread).
"""

from __future__ import annotations

import sys


def run(*, from_tray: bool = False) -> int:
    """Open the window and block until it closes. Returns a process exit code."""
    try:
        from . import window
    except ImportError as e:  # Python built without Tk (some Linux distros)
        print(
            "The settings window needs tkinter, which this Python lacks "
            f"({e}).\nInstall it (e.g. `sudo apt install python3-tk`) or use "
            "`like-spotify --setup` instead.",
            file=sys.stderr,
        )
        return 2
    return window.run(from_tray=from_tray)
