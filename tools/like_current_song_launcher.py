"""PyInstaller entry script.

`python -m like_spotify` works for editable installs, but PyInstaller spec
files prefer a concrete file path. This launcher exists only to give the
.spec a target — runtime behavior is identical to `python -m like_spotify`.

One addition, for CI only: `--self-check [REPORT]` imports what the app
imports lazily and exits 0 when everything loads. A module can sit in the
archive and still fail to import frozen (a missing DLL, Tcl's data files),
and a windowed exe has no stderr, so a traceback goes to REPORT when given.
It lives here, not in the app's CLI, because only the frozen build needs it.
"""

import sys

from like_spotify.hosts import main


def _self_check(report: str | None) -> int:
    try:
        import tkinter

        import like_spotify.hosts.settings.window  # noqa: F401
        import winrt.windows.media.control  # noqa: F401

        tkinter.Tcl()  # needs the bundled Tcl library, but opens no window
    except Exception:
        if report:
            import traceback

            with open(report, "w", encoding="utf-8") as f:
                traceback.print_exc(file=f)
        return 1
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--self-check"]:
        sys.exit(_self_check(sys.argv[2] if len(sys.argv) > 2 else None))
    sys.exit(main())
