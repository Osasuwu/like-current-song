"""Settings window clipboard support: pasting works whatever the keyboard
layout. Everything else in the window is covered through the model."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from like_spotify.hosts.settings import window

tk = pytest.importorskip("tkinter")
from tkinter import ttk  # noqa: E402

VK_V, VK_C, VK_X, VK_A = 86, 67, 88, 65


@pytest.mark.parametrize(
    "keysym, keycode, expected",
    [
        ("Cyrillic_em", VK_V, "<<Paste>>"),
        ("Cyrillic_es", VK_C, "<<Copy>>"),
        ("Cyrillic_che", VK_X, "<<Cut>>"),
        ("Cyrillic_ef", VK_A, "<<SelectAll>>"),
    ],
)
def test_non_latin_layout_maps_by_physical_key(keysym, keycode, expected) -> None:
    assert window._clipboard_event(keysym, keycode) == expected


@pytest.mark.parametrize("keysym", ["v", "V", "c", "x", "a"])
def test_latin_letters_are_left_to_tk(keysym) -> None:
    # Tk's own binding already fires for these; mapping them too would paste twice.
    assert window._clipboard_event(keysym, VK_V) is None


def test_other_keys_are_ignored() -> None:
    assert window._clipboard_event("Cyrillic_ka", 82) is None
    assert window._clipboard_event("Return", 13) is None


@pytest.fixture
def root():
    try:
        r = tk.Tk()
    except tk.TclError as exc:  # no display
        pytest.skip(f"Tk unavailable: {exc}")
    r.withdraw()
    yield r
    r.destroy()


def test_ctrl_v_pastes_on_a_cyrillic_layout(root) -> None:
    # Tk can't synthesise a Cyrillic keysym while a Latin layout is active,
    # so the handler gets the event the binding would pass it.
    entry = ttk.Entry(root)
    entry.pack()
    root.clipboard_clear()
    root.clipboard_append("my-client-id")
    event = SimpleNamespace(keysym="Cyrillic_em", keycode=VK_V, widget=entry)

    assert window._on_ctrl_key(event) == "break"
    entry.update()

    assert entry.get() == "my-client-id"


@pytest.mark.parametrize("cls", ["TEntry", "TCombobox"])
def test_handler_is_bound_on_text_fields(root, cls) -> None:
    window._install_clipboard_support(root)

    assert "_on_ctrl_key" in root.bind_class(cls, "<Control-KeyPress>")
    assert root.bind_class(cls, "<Button-3>")
