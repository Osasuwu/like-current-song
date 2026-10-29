"""extensions — default-flavor implementations of the five core seams.

Filesystem-convention plugin layout (Music Assistant-style): each subdir
is one extension keyed by `domain`, with `__init__.py` exporting one of
TRIGGER / PRE_LIKE_ACTION / MUSIC_PROVIDER / POST_LIKE_ACTION / STORAGE,
plus a `manifest.json` describing metadata + pip requirements.

Hosts read each manifest at startup (`like_spotify/hosts/_extensions.py`,
#144), so a new subdir with a valid manifest is loaded without editing
`like_spotify/hosts/_common.py`. Unmet `requirements` are reported, not
installed. The shipped extensions keep hand-written builders there as the
fallback for construction a manifest can't declare.
"""
