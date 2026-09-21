"""Windows host — pystray Icon/Menu construction for the resident tray.

Split out of `hosts/windows.py` in #55. Owns only the menu/icon shape;
the flash/beep/balloon side effects it triggers live in `feedback.py`,
and the click handlers it wires in come from `resident.py` (they close
over the pipeline/event loop, which this module doesn't need to know
about).

Labels and visibility are callables over `state()` so a settings save
that swaps the hotkeys (#100) only needs `icon.update_menu()`, not a new
icon.
"""

from __future__ import annotations

from collections.abc import Callable

from .autostart import _autostart_enabled


def icon_title(hotkey: str) -> str:
    return f"Like Current Song  [{hotkey.upper()}]"


def build_icon(
    *,
    feedback,
    state: Callable[[], tuple[str, bool, str | None, str]],
    on_like: Callable,
    on_discard: Callable,
    on_settings: Callable,
    on_toggle_autostart: Callable,
    on_open_log: Callable,
    on_quit: Callable,
):
    """Build the resident host's pystray.Icon and attach `feedback` to it.

    `state()` returns the live
    `(hotkey, discard_enabled, discard_hotkey, discard_label)`.
    """
    import pystray  # local import: heavy

    def like_text(_item) -> str:
        return f"Like current track  [{state()[0].upper()}]"

    def discard_text(_item) -> str:
        # The label is the pipeline's, not ours: what one press does
        # depends on the provider's capabilities and whether an archive
        # playlist is configured, and only the pipeline knows both.
        _hotkey, _enabled, discard_hotkey, label = state()
        return f"{label}  [{(discard_hotkey or '').upper()}]"

    menu = pystray.Menu(
        pystray.MenuItem(like_text, on_like, default=True),
        pystray.MenuItem(discard_text, on_discard, visible=lambda _item: state()[1]),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Settings…", on_settings),
        pystray.MenuItem(
            "Start with Windows",
            on_toggle_autostart,
            checked=lambda _item: _autostart_enabled(),
        ),
        pystray.MenuItem("Open log", on_open_log),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quit", on_quit),
    )

    icon = pystray.Icon(
        name="LikeSpotify",
        icon=feedback.default_icon,
        title=icon_title(state()[0]),
        menu=menu,
    )
    feedback.attach(icon)
    return icon
