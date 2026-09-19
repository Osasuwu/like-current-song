"""Windows SMTC (System Media Transport Controls) now-playing reader.

Every Chromium/Firefox tab using the Media Session API, and the YT Music
desktop app, publishes a session here. We take the first session that is
actually playing, preferring the one Windows considers current.

Needs the optional `ytmusic` extra (`pip install like-spotify[ytmusic]`).
Imported lazily so the rest of the package stays importable without it
and on non-Windows platforms.
"""

from __future__ import annotations

import sys

from like_spotify.core.errors import TransientError

from . import NowPlaying

# GlobalSystemMediaTransportControlsSessionPlaybackStatus.PLAYING
_PLAYING = 4


async def read_now_playing() -> NowPlaying | None:
    if sys.platform != "win32":
        raise TransientError(
            "YouTube Music now-playing detection is Windows-only for now"
        )
    try:
        from winrt.windows.media.control import (
            GlobalSystemMediaTransportControlsSessionManager as SessionManager,
        )
    except ImportError as e:
        raise TransientError(
            "YouTube Music support needs the extra: pip install like-spotify[ytmusic]"
        ) from e

    manager = await SessionManager.request_async()
    current = manager.get_current_session()
    sessions = list(manager.get_sessions())
    if current is not None:
        # Windows' own pick first; it is usually the one the user touched last.
        sessions.sort(
            key=lambda s: s.source_app_user_model_id
            != current.source_app_user_model_id
        )

    for session in sessions:
        info = session.get_playback_info()
        if info is None or int(info.playback_status) != _PLAYING:
            continue
        props = await session.try_get_media_properties_async()
        if props is None or not props.title:
            continue
        return NowPlaying(
            title=props.title,
            artist=props.artist or "",
            album=props.album_title or None,
        )
    return None
