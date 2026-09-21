from abc import ABC, abstractmethod
from typing import Protocol, runtime_checkable

from .types import CurrentTrack


class MusicProvider(ABC):
    """Read 'what is playing' and write 'I like this'. Nothing else.

    Stays narrow on purpose. Charts, history, social — out of scope;
    if a future need arises, it's a new extension point, not a method here.
    """

    @abstractmethod
    async def get_currently_playing(self) -> CurrentTrack | None: ...

    @abstractmethod
    async def like(self, track: CurrentTrack) -> None: ...

    @abstractmethod
    async def is_liked(self, track: CurrentTrack) -> bool:
        """True iff the user already had this track in their liked collection.

        Read before `like()` to power the #24 backfill: first encounter of
        a pre-existing like counts as 2. Cheap O(1) lookup is expected.
        """

    @abstractmethod
    async def user_id(self) -> str:
        """Stable per-user id. Storage keys against it.

        Expected O(1) after setup (cached post-auth value). Async because
        a future provider may need a lazy fetch on first call.
        """


@runtime_checkable
class PlaylistCapableProvider(Protocol):
    """Optional capability: named-playlist read/write + follow-artist.

    Extras that don't belong on the base `MusicProvider` (per
    docs/design/interfaces.md §4.6 — stay at one flag until >=3 real
    capability axes emerge; this is that first axis). Call sites that need
    them check `isinstance(provider, PlaylistCapableProvider)` instead of
    an `isinstance(provider, SpotifyMusicProvider)` or
    `getattr(provider, "...", None)` probe each. Providers satisfy it
    structurally, no inheritance required — `SpotifyMusicProvider` and
    `YouTubeMusicProvider` both do.

    Ids are the provider's own: `track_id` is `CurrentTrack.provider_track_id`
    and `artist_id` is an entry of `CurrentTrack.artist_ids`. A provider
    that can't name an artist for a track leaves `artist_ids` empty, and
    `follow_artist` is then simply never called for it.

    Every write is idempotent from the caller's view: removing a track that
    isn't in the playlist, or following an artist already followed, is not
    an error.
    """

    async def find_playlist_by_name(self, name: str) -> str | None:
        """Id of a playlist in the user's library with this name
        (case-insensitive, trimmed), or None when there is none."""
        ...

    async def find_or_create_playlist(self, name: str) -> str:
        """Like `find_playlist_by_name`, but create a private playlist when
        missing. Returns its id."""
        ...

    async def get_playlist_track_ids(self, playlist_id: str) -> set[str]: ...

    async def add_track_to_playlist(self, track_id: str, playlist_id: str) -> None: ...

    async def remove_track_from_playlist(
        self, track_id: str, playlist_id: str
    ) -> None:
        """Remove every occurrence of the track from the playlist."""
        ...

    async def follow_artist(self, artist_id: str) -> None: ...


@runtime_checkable
class DislikeCapableProvider(Protocol):
    """Optional capability: say "not this one" to the service itself.

    The second capability axis, declared and checked exactly like
    `PlaylistCapableProvider` above — structural, no inheritance, and
    deliberately *not* a method on the `MusicProvider` ABC, so a provider
    written against CONTRIBUTING.md before this existed keeps importing and
    running. Call sites check `isinstance(provider, DislikeCapableProvider)`
    and stay silent when it doesn't qualify.

    What the signal *is* differs per service, and the protocol only promises
    the strongest one that service offers. YouTube Music has a real
    thumbs-down (`videos.rate`), which feeds its recommendations. Spotify's
    Web API has no dislike at all — the X in the client is client-only — so
    its strongest negative is taking the track back out of the library. Both
    are honest answers to "I don't want this"; neither is the other.

    Idempotent from the caller's view: disliking a track that is already
    disliked, or removing one that was never liked, is not an error.
    """

    async def dislike(self, track: CurrentTrack) -> None:
        """The strongest negative signal this service supports."""
        ...
