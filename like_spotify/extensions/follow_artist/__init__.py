"""FollowArtistAction — default flavor PostLikeAction (#26, #244).

Records each (user, artist, track) liked combination in Storage; once an
artist's distinct-track count is at or past a configured threshold
(default 5) and this app has not followed them yet, auto-follow that
artist. Counting a re-liked track only once is owned by
`Storage.record_artist_track` (returns the same count when called twice
with the same triple).

"At or past", not "equals": the count can land past the threshold without
ever sitting on it — another device recorded some of the artist's tracks in
the shared sheet, the user lowered the threshold below a count they already
have, a row was pasted into the sheet by hand. An exact-match rule never
follows that artist at all (#244, the desktop port of Android's #197).
What keeps a 6th, 7th… liked track from re-following is the followed-memory:
a small JSON list under the config dir of the artists this app has followed,
written only after a follow went through, so a failed follow is retried on
the next like. It is per device, like Android's `followed_artists`.

Undo (#270) unfollows only the artists this press followed. Before a follow
the action asks the provider whether the user already follows the artist;
one they do is only remembered, so an undo never unfollows an artist the
user chose to follow. When that check fails the follow goes ahead, and an
undo leaves that artist followed and says so rather than guess. The undo
also hands each artist-track record the press made back to
`Storage.undo_record_artist_track` (#283), followed or not: a record that
added the track takes it back off, so the artist's count reads what it read
before the press and an already-counted track cannot bring the follow back
one real track early. A storage without that undo leaves the record and the
undo says so.

Runs against any `PlaylistCapableProvider` (Spotify follows the artist,
YouTube Music subscribes to the artist's channel); other providers are a
silent no-op. Storage absence is also a silent no-op
— without a persistent counter there is nothing to compare to the threshold.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

from like_spotify.core.actions import PostLikeAction
from like_spotify.core.errors import AuthError
from like_spotify.core.music_provider import (
    PlaylistCapableProvider,
    UnfollowCapableProvider,
)
from like_spotify.core.storage import Storage
from like_spotify.core.types import LikeContext

DOMAIN = "follow_artist"
DEFAULT_THRESHOLD = 5
# `ctx.extras` key: {artist_id: how the follow this press made can be
# undone} — `_NEW`, `_UNKNOWN` (the already-following check failed) or
# `_IRREVERSIBLE` (the provider cannot unfollow).
_FOLLOWED = "follow_artist.followed"
# `ctx.extras` key: [(user_id, artist_id)] for each record this press made,
# in order — the ones `undo` hands back to `Storage.undo_record_artist_track`.
_RECORDED = "follow_artist.recorded"
_NEW = "new"
_UNKNOWN = "unknown"
_IRREVERSIBLE = "irreversible"

logger = logging.getLogger(__name__)


class _FollowedStore:
    """Local JSON list of the artists this app has auto-followed.

    Keys are `<provider>:<artist_id>`: a Spotify artist id and a YouTube
    channel id share no namespace, and switching provider must not make one
    look followed on the other. An unreadable file reads as empty — the cost
    is one repeat follow call, which both providers accept as a no-op.
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
            logger.warning("follow-artist: failed to persist state to %s", self._path)

    def discard(self, key: str) -> None:
        state = self._load()
        if key not in state:
            return
        state.discard(key)
        try:
            self._path.write_text(json.dumps(sorted(state)), encoding="utf-8")
        except OSError:
            logger.warning("follow-artist: failed to persist state to %s", self._path)

    def _load(self) -> set[str]:
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return set()
        if not isinstance(data, list):
            return set()
        return {item for item in data if isinstance(item, str)}


class FollowArtistAction(PostLikeAction):
    def __init__(
        self,
        storage: Storage,
        threshold: int = DEFAULT_THRESHOLD,
        *,
        followed_path: Path,
    ) -> None:
        if storage is None:
            raise ValueError("storage is required (per-artist counter source)")
        if threshold < 1:
            raise ValueError("threshold must be >= 1")
        self._storage = storage
        self._threshold = threshold
        self._followed = _FollowedStore(followed_path)

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
            recorded = ctx.extras.setdefault(_RECORDED, [])
            assert isinstance(recorded, list)
            recorded.append((user_id, artist_id))

            followed_key = f"{ctx.track.provider}:{artist_id}"
            if count < self._threshold or self._followed.contains(followed_key):
                continue

            how = _IRREVERSIBLE
            if isinstance(provider, UnfollowCapableProvider):
                try:
                    if await provider.is_following_artist(artist_id):
                        # The user's own follow: remember it, never undo it.
                        self._followed.add(followed_key)
                        continue
                    how = _NEW
                except Exception as e:
                    logger.warning(
                        "follow-artist: already-following check failed (%s): %s",
                        artist_id,
                        e,
                    )
                    how = _UNKNOWN

            try:
                await provider.follow_artist(artist_id)
            except AuthError as e:
                logger.warning(
                    "follow-artist unauthorized (%s) — re-run "
                    "`like-current-song --setup` to grant follow scope",
                    e,
                )
                continue
            except Exception as e:
                logger.warning("follow-artist API failed (%s): %s", artist_id, e)
                continue
            self._followed.add(followed_key)
            followed = ctx.extras.setdefault(_FOLLOWED, {})
            assert isinstance(followed, dict)
            followed[artist_id] = how

    async def undo(self, ctx: LikeContext) -> None:
        """Unfollow, then unrecord; each leg runs whatever the other did.
        A leg that failed raises `RuntimeError` (naming every leg left
        undone); one that cannot be reversed at all raises
        `NotImplementedError`, which the pipeline reports as not undoable."""
        failed: list[str] = []
        irreversible: list[str] = []
        await self._unfollow(ctx, failed, irreversible)
        await self._unrecord(ctx, failed, irreversible)
        if failed:
            raise RuntimeError("; ".join(failed + irreversible))
        if irreversible:
            raise NotImplementedError("; ".join(irreversible))

    async def _unrecord(
        self, ctx: LikeContext, failed: list[str], irreversible: list[str]
    ) -> None:
        """Hand each record this press made back to the storage (#283), so
        the artist's count reads what it read before the press."""
        recorded = ctx.extras.get(_RECORDED) or []
        assert isinstance(recorded, list)
        left: list[str] = []
        for user_id, artist_id in recorded:
            try:
                await self._storage.undo_record_artist_track(
                    user_id, artist_id, ctx.track.provider_track_id
                )
            except NotImplementedError:
                left.append(artist_id)
            except Exception as e:
                failed.append(f"{artist_id}: artist-track record not restored ({e})")
        if left:
            irreversible.append(
                f"{type(self._storage).__name__} cannot reverse an artist-track "
                f"record; {', '.join(left)} left counted"
            )

    async def _unfollow(
        self, ctx: LikeContext, failed: list[str], irreversible: list[str]
    ) -> None:
        """Unfollow each artist this press followed (#270)."""
        followed = ctx.extras.get(_FOLLOWED)
        if not followed:
            return
        assert isinstance(followed, dict)
        provider = ctx.music_provider
        left: list[str] = []
        for artist_id, how in followed.items():
            if how == _IRREVERSIBLE or not isinstance(
                provider, UnfollowCapableProvider
            ):
                left.append(artist_id)
                continue
            if how == _UNKNOWN:
                failed.append(
                    f"{artist_id} left followed (could not tell whether "
                    f"it was followed before)"
                )
                continue
            try:
                await provider.unfollow_artist(artist_id)
            except Exception as e:
                failed.append(f"{artist_id}: unfollow failed ({e})")
                continue
            self._followed.discard(f"{ctx.track.provider}:{artist_id}")
        if left:
            irreversible.append(
                f"{type(provider).__name__} cannot unfollow; "
                f"{', '.join(left)} left followed"
            )


def POST_LIKE_ACTION(
    storage: Storage, threshold: int = DEFAULT_THRESHOLD, *, followed_path: Path
) -> FollowArtistAction:
    return FollowArtistAction(
        storage=storage, threshold=threshold, followed_path=followed_path
    )
