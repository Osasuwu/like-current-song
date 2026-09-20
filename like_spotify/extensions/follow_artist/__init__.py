"""FollowArtistAction — default flavor PostLikeAction (#26).

Records each (user, artist, track) liked combination in Storage; when
a distinct-track count for an artist crosses a configured threshold
(default 5), auto-follow that artist. Idempotency is owned by
`Storage.record_artist_track` (returns the same count when called
twice with the same triple).

Triggers ONLY when the post-record count EQUALS the threshold, so a
6th, 7th… liked track from the same artist does NOT re-follow.

Runs against any `PlaylistCapableProvider` (Spotify follows the artist,
YouTube Music subscribes to the artist's channel); other providers are a
silent no-op. Storage absence is also a silent no-op
— without a persistent counter we have no idempotency guarantee.
"""

from __future__ import annotations

import logging

from like_spotify.core.actions import PostLikeAction
from like_spotify.core.errors import AuthError
from like_spotify.core.music_provider import PlaylistCapableProvider
from like_spotify.core.storage import Storage
from like_spotify.core.types import LikeContext

DOMAIN = "follow_artist"
DEFAULT_THRESHOLD = 5

logger = logging.getLogger(__name__)


class FollowArtistAction(PostLikeAction):
    def __init__(self, storage: Storage, threshold: int = DEFAULT_THRESHOLD) -> None:
        if storage is None:
            raise ValueError("storage is required (per-artist counter source)")
        if threshold < 1:
            raise ValueError("threshold must be >= 1")
        self._storage = storage
        self._threshold = threshold

    async def run(self, ctx: LikeContext) -> None:
        provider = ctx.music_provider
        if not isinstance(provider, PlaylistCapableProvider):
            return
        artist_ids = ctx.track.artist_ids
        if not artist_ids:
            return

        try:
            user_id = await provider.user_id()
        except Exception as e:
            logger.warning("follow-artist: could not resolve user_id: %s", e)
            return

        for artist_id in artist_ids:
            try:
                count = await self._storage.record_artist_track(
                    user_id, artist_id, ctx.track.provider_track_id
                )
            except Exception as e:
                logger.warning(
                    "follow-artist: record_artist_track failed (%s): %s",
                    artist_id,
                    e,
                )
                continue

            if count != self._threshold:
                continue

            try:
                await provider.follow_artist(artist_id)
            except AuthError as e:
                logger.warning(
                    "follow-artist unauthorized (%s) — re-run "
                    "`like-current-song --setup` to grant follow scope",
                    e,
                )
            except Exception as e:
                logger.warning("follow-artist API failed (%s): %s", artist_id, e)


def POST_LIKE_ACTION(
    storage: Storage, threshold: int = DEFAULT_THRESHOLD
) -> FollowArtistAction:
    return FollowArtistAction(storage=storage, threshold=threshold)
