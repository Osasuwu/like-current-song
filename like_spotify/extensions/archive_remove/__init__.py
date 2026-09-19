"""ArchiveRemoveAction — default flavor PostLikeAction.

Removes the just-liked track from the user's "archive" playlist
(typically a Discover-Weekly snapshot rotation, but the name is
configurable). Runs against any provider that speaks
`PlaylistCapableProvider` (Spotify, YouTube Music); other providers are
silently skipped so the chain stays composable across flavors.

Idempotency (#23 AC): the first action invocation does one playlist
lookup + one paged track fetch to populate an in-memory snapshot.
Every subsequent like checks membership against that cache and only
issues a DELETE when the track is actually present — so on the
per-like hot path, a not-in-archive track makes ZERO playlist API
calls. The DELETE itself is also idempotent on Spotify's side; the
cache exists to honour the AC literally and to avoid burning API
quota on common-case likes that aren't archived.
"""

from __future__ import annotations

import logging

from like_spotify.core.actions import PostLikeAction
from like_spotify.core.errors import AuthError
from like_spotify.core.music_provider import PlaylistCapableProvider
from like_spotify.core.types import LikeContext

DOMAIN = "archive_remove"

logger = logging.getLogger(__name__)


class ArchiveRemoveAction(PostLikeAction):
    """Remove the just-liked track from the configured archive playlist."""

    def __init__(self, playlist_name: str) -> None:
        normalized = (playlist_name or "").strip()
        if not normalized:
            raise ValueError("archive playlist_name is required (non-empty)")
        self._playlist_name = normalized
        # Lazy: first call resolves id + fetches track set.
        self._resolved = False
        self._playlist_id: str | None = None
        self._track_ids: set[str] = set()

    async def run(self, ctx: LikeContext) -> None:
        provider = ctx.music_provider
        if not isinstance(provider, PlaylistCapableProvider):
            # Other flavours don't speak the playlist capability. Silent no-op.
            return

        if not self._resolved:
            await self._resolve(provider)
        if not self._playlist_id:
            return

        track_id = ctx.track.provider_track_id
        if track_id not in self._track_ids:
            # Per-like hot path AC: not in archive → no DELETE issued.
            # (One-time resolve fetch may have run during the first action
            # invocation; see module docstring.)
            return

        await provider.remove_track_from_playlist(track_id, self._playlist_id)
        # Update local snapshot so a re-trigger in the same session stays no-op.
        self._track_ids.discard(track_id)

    async def _resolve(self, provider: PlaylistCapableProvider) -> None:
        self._resolved = True
        try:
            pid = await provider.find_playlist_by_name(self._playlist_name)
        except AuthError as e:
            # 401/403 here usually means the cached OAuth token predates the
            # playlist scope widening (#23). Re-running --setup grants the
            # new scopes. Stay silent on the per-like path; let the user see
            # this in the log.
            logger.warning(
                "archive playlist lookup unauthorized (%s) — re-run "
                "`like-spotify --setup` to grant playlist scopes",
                e,
            )
            return
        except Exception as e:
            logger.warning("archive playlist lookup failed: %s", e)
            return
        if not pid:
            logger.info(
                "archive playlist %r not found — action is a no-op",
                self._playlist_name,
            )
            return
        self._playlist_id = pid
        try:
            self._track_ids = await provider.get_playlist_track_ids(pid)
        except Exception as e:
            logger.warning("archive playlist track fetch failed: %s", e)
            self._track_ids = set()


def POST_LIKE_ACTION(playlist_name: str) -> ArchiveRemoveAction:
    """Factory called by the host. Signature widens in #28 (manifest deps)."""
    return ArchiveRemoveAction(playlist_name=playlist_name)
