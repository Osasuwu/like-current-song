"""PromoteToBestOfAction — default flavor PostLikeAction (#26).

When a track's like count crosses a configured threshold (default 3),
add the track to a "best of" playlist (create the playlist on first
trigger if it doesn't exist yet). Idempotent — we only add when the
count EQUALS the threshold, so the 4th, 5th… likes do not re-add.

The trigger uses `ctx.like_count` (populated by the Pipeline from the
last `Storage.increment` call); falling back to a fresh
`Storage.get_count` is unnecessary — by the time PostLikeAction fires,
the count is already in the context. Runs against any provider that
speaks `PlaylistCapableProvider` (Spotify, YouTube Music); others are a
silent no-op.
"""

from __future__ import annotations

import logging

from like_spotify.core.actions import PostLikeAction
from like_spotify.core.errors import AuthError
from like_spotify.core.music_provider import PlaylistCapableProvider
from like_spotify.core.types import LikeContext

DOMAIN = "promote_to_best_of"
DEFAULT_THRESHOLD = 3
DEFAULT_PLAYLIST_NAME = "Best of the best of the best"

logger = logging.getLogger(__name__)


class PromoteToBestOfAction(PostLikeAction):
    def __init__(
        self,
        playlist_name: str = DEFAULT_PLAYLIST_NAME,
        threshold: int = DEFAULT_THRESHOLD,
    ) -> None:
        name = (playlist_name or "").strip()
        if not name:
            raise ValueError("playlist_name is required (non-empty)")
        if threshold < 1:
            raise ValueError("threshold must be >= 1")
        self._playlist_name = name
        self._threshold = threshold
        self._playlist_id: str | None = None  # cached after first use

    async def run(self, ctx: LikeContext) -> None:
        provider = ctx.music_provider
        if not isinstance(provider, PlaylistCapableProvider):
            return  # cross-flavour silence
        if ctx.like_count is None or ctx.like_count != self._threshold:
            return  # idempotency: only the threshold-crossing press triggers

        try:
            if self._playlist_id is None:
                self._playlist_id = await provider.find_or_create_playlist(
                    self._playlist_name
                )
            await provider.add_track_to_playlist(
                ctx.track.provider_track_id, self._playlist_id
            )
        except AuthError as e:
            logger.warning(
                "promote-to-best-of unauthorized (%s) — re-run "
                "`like-spotify --setup` to grant playlist scopes",
                e,
            )
        except Exception as e:
            logger.warning("promote-to-best-of failed: %s", e)


def POST_LIKE_ACTION(
    playlist_name: str = DEFAULT_PLAYLIST_NAME,
    threshold: int = DEFAULT_THRESHOLD,
) -> PromoteToBestOfAction:
    return PromoteToBestOfAction(playlist_name=playlist_name, threshold=threshold)
