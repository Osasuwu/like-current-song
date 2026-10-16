"""PromoteToBestAction — default flavor PostLikeAction (#26, #245).

Once a track's like count is at or past a configured threshold (default 3)
and this app has not promoted it yet, add the track to a "best" playlist
(created on first trigger if it doesn't exist yet).

"At or past", not "equals": the count can land past the threshold without
ever sitting on it — the user lowered the threshold below a count the track
already has, or a like was counted somewhere this host can't see. An
exact-match rule never promotes that track at all (#245; follow-artist had
the same bug, #197/#244).

Two things keep the 4th, 5th… like from adding the track again:

- the promoted-memory, a small JSON list under the config dir of the tracks
  this app has promoted, written only after the track is in the playlist —
  so a failed add is retried on the next like;
- a membership check against the playlist before the add. The memory is per
  device and starts empty, while the like count is shared between devices
  and was counted long before the memory existed. A track another device
  promoted, or one promoted before this memory existed, is past the
  threshold and not remembered here — adding it would put a second copy in
  the playlist, because both providers accept duplicates. Found already
  there, it is only remembered.

The trigger uses `ctx.like_count` (populated by the Pipeline from the last
`Storage.increment` call). Runs against any provider that speaks
`PlaylistCapableProvider` (Spotify, YouTube Music); others are a silent
no-op.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

from like_spotify.core.actions import PostLikeAction
from like_spotify.core.errors import AuthError
from like_spotify.core.music_provider import PlaylistCapableProvider
from like_spotify.core.types import LikeContext

DOMAIN = "promote_to_best"
DEFAULT_THRESHOLD = 3
DEFAULT_PLAYLIST_NAME = "Best of the best of the best"

logger = logging.getLogger(__name__)


class _PromotedStore:
    """Local JSON list of the tracks this app has promoted to the best playlist.

    Keys are `<provider>:<track_id>`: a Spotify track id and a YouTube video id
    share no namespace. An unreadable file reads as empty — the cost is one
    membership check per track, never a duplicate.
    """

    def __init__(self, path: Path) -> None:
        self._path = path

    def contains(self, key: str) -> bool:
        return key in self._load()

    def add(self, key: str) -> None:
        state = self._load()
        if key in state:
            return
        state.add(key)
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            self._path.write_text(json.dumps(sorted(state)), encoding="utf-8")
        except OSError:
            logger.warning("promote-to-best: failed to persist state to %s", self._path)

    def _load(self) -> set[str]:
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return set()
        if not isinstance(data, list):
            return set()
        return {item for item in data if isinstance(item, str)}


class PromoteToBestAction(PostLikeAction):
    def __init__(
        self,
        playlist_name: str = DEFAULT_PLAYLIST_NAME,
        threshold: int = DEFAULT_THRESHOLD,
        *,
        promoted_path: Path,
    ) -> None:
        name = (playlist_name or "").strip()
        if not name:
            raise ValueError("playlist_name is required (non-empty)")
        if threshold < 1:
            raise ValueError("threshold must be >= 1")
        self._playlist_name = name
        self._threshold = threshold
        self._promoted = _PromotedStore(promoted_path)
        self._playlist_id: str | None = None  # cached after first use

    async def run(self, ctx: LikeContext) -> None:
        provider = ctx.music_provider
        if not isinstance(provider, PlaylistCapableProvider):
            return  # cross-flavour silence
        if ctx.like_count is None or ctx.like_count < self._threshold:
            return
        promoted_key = f"{ctx.track.provider}:{ctx.track.provider_track_id}"
        if self._promoted.contains(promoted_key):
            return  # promoted once already; later likes leave it alone

        track_id = ctx.track.provider_track_id
        try:
            if self._playlist_id is None:
                self._playlist_id = await provider.find_or_create_playlist(
                    self._playlist_name
                )
            members = await provider.get_playlist_track_ids(self._playlist_id)
            if track_id not in members:
                await provider.add_track_to_playlist(track_id, self._playlist_id)
        except AuthError as e:
            logger.warning(
                "promote-to-best unauthorized (%s) — re-run "
                "`like-current-song --setup` to grant playlist scopes",
                e,
            )
            return
        except Exception as e:
            logger.warning("promote-to-best failed: %s", e)
            return
        self._promoted.add(promoted_key)


def POST_LIKE_ACTION(
    playlist_name: str = DEFAULT_PLAYLIST_NAME,
    threshold: int = DEFAULT_THRESHOLD,
    *,
    promoted_path: Path,
) -> PromoteToBestAction:
    return PromoteToBestAction(
        playlist_name=playlist_name, threshold=threshold, promoted_path=promoted_path
    )
