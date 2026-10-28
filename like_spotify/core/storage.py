from abc import ABC, abstractmethod

from .types import CurrentTrack


class Storage(ABC):
    """Persistence for per-track like counters.

    The shipped impl is `GoogleSheetsStorage` (a cross-device counter in a
    spreadsheet the user owns); `tests/test_storage_contract.py` holds the
    invariants any further impl has to satisfy. Failure is non-fatal — the
    like must succeed even if the storage is misconfigured or unreachable;
    the host treats `None` as 'counter silently unavailable'. Silence is the
    right answer for a blip, not for a failure that will repeat until the
    user fixes something: raise a `UserActionRequired` (core/errors.py) for
    those and the pipeline tells them what the message says (#168).

    Track identity is delegated to the impl: most will key on
    `track.provider_track_id`, but a sheet-style impl may want
    title/artist for human-readable rows.
    """

    @abstractmethod
    async def increment(
        self,
        user_id: str,
        track: CurrentTrack,
        was_already_liked: bool = False,
    ) -> int:
        """Atomically bump the like counter for (user, track). Returns new count.

        `was_already_liked` is the provider's "this was already in your liked
        collection before we ever saw it" signal (#24 backfill). Callers MAY
        pass `True` on every press (the pipeline re-probes each time);
        impls MUST only honour it on the very first INSERT — treat that
        first encounter as count=2 instead of 1 — and ignore the flag on
        every subsequent UPDATE. Backfill is therefore idempotent regardless
        of how many times True is passed afterwards.
        """

    async def undo_increment(self, user_id: str, track: CurrentTrack) -> int:
        """Reverse the most recent `increment` this instance made for
        (user, track); return the count now stored (0 when the undone
        increment had created the row).

        Called by `Pipeline.undo_last` (#270), only within seconds of that
        increment and at most once per increment. After it, the key must
        read as if the undone press never happened: `get_count` returns
        the previous count, and an undone *first* increment leaves no
        trace, so the next press is a first encounter again and still gets
        the backfill flag. Each increment is reversible once: with none
        left to reverse for the key, raise `LookupError` and change nothing,
        so a repeated undo never reaches the press before.

        Not abstract, so a storage written before undo existed keeps
        working: the default raises `NotImplementedError`, which the
        pipeline logs as "not undoable" and leaves the counter as it is.
        """
        raise NotImplementedError(
            f"{type(self).__name__} cannot reverse an increment"
        )

    @abstractmethod
    async def get_count(self, user_id: str, track: CurrentTrack) -> int:
        """Current count for (user, track). 0 if never liked."""

    @abstractmethod
    async def record_artist_track(
        self, user_id: str, artist_id: str, track_id: str
    ) -> int:
        """Record that user has liked a track by this artist; return the
        distinct-tracks-per-artist count for (user, artist).

        Idempotent: re-recording the same (user, artist, track) triple
        does NOT increment the count. Used by `FollowArtistAction` (#26)
        to decide when to auto-follow an artist crossing a like-threshold.
        """
