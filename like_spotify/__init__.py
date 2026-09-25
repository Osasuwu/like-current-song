"""like-current-song — pluggable hotkey-to-like framework.

Five seams (Trigger, MusicProvider, Storage, PreLikeAction, PostLikeAction)
live in ``core/``; the implementations live in ``extensions/`` and are wired
in by the builder registries in ``hosts/_common.py``.
"""

from importlib.metadata import PackageNotFoundError, version

try:
    # pyproject.toml is the single source of the version.
    __version__ = version("like-current-song")
except PackageNotFoundError:  # running from a checkout that was never installed
    __version__ = "0+unknown"
