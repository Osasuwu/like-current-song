"""extensions — default-flavor implementations of the five core seams.

Filesystem-convention plugin layout (Music Assistant-style): each subdir
is one extension keyed by `domain`, with `__init__.py` exporting one of
TRIGGER / PRE_LIKE_ACTION / MUSIC_PROVIDER / POST_LIKE_ACTION / STORAGE,
plus a `manifest.json` describing metadata + pip requirements.

The manifest is metadata for humans and tooling today; nothing reads it
at runtime. A host picks an extension up by importing it and registering
its factory in `like_spotify/hosts/_common.py` -- automatic discovery,
and honouring `requirements` at first enable, is #144.
"""
