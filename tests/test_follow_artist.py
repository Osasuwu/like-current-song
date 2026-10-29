"""Tests for FollowArtistAction (#26, #244)."""

from __future__ import annotations

import logging
import threading
import time
from pathlib import Path

import pytest

from like_spotify.core.errors import AuthError
from like_spotify.core.storage import Storage
from like_spotify.core.types import CurrentTrack, LikeContext
from like_spotify.extensions.follow_artist import FollowArtistAction
from like_spotify.extensions.spotify import SpotifyMusicProvider
from like_spotify.hosts import _common


class FakeStorage(Storage):
    def __init__(self):
        self._seen: set[tuple[str, str, str]] = set()

    async def increment(self, user_id, track, was_already_liked=False) -> int:
        return 1

    async def get_count(self, user_id, track) -> int:
        return 0

    async def record_artist_track(self, user_id, artist_id, track_id) -> int:
        self._seen.add((user_id, artist_id, track_id))
        return sum(
            1 for u, a, _t in self._seen if u == user_id and a == artist_id
        )


class FakeSpotifyProvider(SpotifyMusicProvider):
    def __init__(
        self,
        user_id_value: str = "user-1",
        follow_raises: Exception | None = None,
        fail_first_follows: int = 0,
    ):
        self._client_id = "cid"
        self._token_path = Path("/dev/null")
        self._tokens = {
            "access_token": "tt",
            "refresh_token": "rt",
            "expires_at": time.time() + 3600,
        }
        self._lock = threading.Lock()
        self._user_id_cache = user_id_value
        self._follow_raises = follow_raises
        self._fail_first_follows = fail_first_follows
        self.follow_calls: list[str] = []

    async def user_id(self) -> str:
        return self._user_id_cache  # type: ignore[return-value]

    async def follow_artist(self, artist_id: str) -> None:
        if self._follow_raises is not None:
            raise self._follow_raises
        if self._fail_first_follows > 0:
            self._fail_first_follows -= 1
            raise RuntimeError("503 from the follow endpoint")
        self.follow_calls.append(artist_id)

    async def is_following_artist(self, artist_id: str) -> bool:
        # The real method would call Spotify with the token above (#270).
        return False


def _track(track_id: str, artist_ids: tuple[str, ...] = ("art1",)) -> CurrentTrack:
    return CurrentTrack(
        provider="spotify",
        provider_track_id=track_id,
        title="t",
        artists=("Artist",),
        artist_ids=artist_ids,
    )


def _ctx(track: CurrentTrack, provider: SpotifyMusicProvider) -> LikeContext:
    return LikeContext(track=track, music_provider=provider)


@pytest.fixture
def followed(tmp_path) -> Path:
    """Where the action remembers whom it has followed — per test, never ~."""
    return tmp_path / "followed_artists.json"


@pytest.mark.asyncio
async def test_follow_fires_on_distinct_threshold(followed) -> None:
    """AC: like 5th distinct track from same artist → artist followed."""
    provider = FakeSpotifyProvider()
    storage = FakeStorage()
    action = FollowArtistAction(storage=storage, followed_path=followed, threshold=5)

    for i in range(1, 6):
        await action.run(_ctx(_track(f"trk-{i}"), provider))

    assert provider.follow_calls == ["art1"]


@pytest.mark.asyncio
async def test_follow_does_not_repeat_after_threshold(followed) -> None:
    provider = FakeSpotifyProvider()
    storage = FakeStorage()
    action = FollowArtistAction(storage=storage, followed_path=followed, threshold=3)

    for i in range(1, 8):  # 7 distinct tracks
        await action.run(_ctx(_track(f"trk-{i}"), provider))

    # Followed exactly once, on the 3rd distinct track.
    assert provider.follow_calls == ["art1"]


@pytest.mark.asyncio
async def test_follow_fires_when_the_count_lands_past_the_threshold(followed) -> None:
    """#244: six of the artist's tracks are already in the shared sheet (liked
    on the phone while follow was off here), so this press reads 7, never 5.
    An exact-match rule would never follow them."""
    provider = FakeSpotifyProvider()
    storage = FakeStorage()
    for i in range(1, 7):
        storage._seen.add(("user-1", "art1", f"phone-{i}"))
    action = FollowArtistAction(storage=storage, followed_path=followed, threshold=5)

    await action.run(_ctx(_track("trk-7"), provider))

    assert provider.follow_calls == ["art1"]


@pytest.mark.asyncio
async def test_failed_follow_is_retried_on_the_next_like(followed) -> None:
    """Only a follow that went through is remembered; a failed one is tried
    again the next time the artist is liked."""
    provider = FakeSpotifyProvider(fail_first_follows=1)
    storage = FakeStorage()
    action = FollowArtistAction(storage=storage, followed_path=followed, threshold=1)

    await action.run(_ctx(_track("trk-1"), provider))
    assert provider.follow_calls == []
    await action.run(_ctx(_track("trk-2"), provider))

    assert provider.follow_calls == ["art1"]


@pytest.mark.asyncio
async def test_followed_artist_is_not_followed_again_after_a_host_restart(
    tmp_path, monkeypatch
) -> None:
    """#244: the followed-memory outlives the resident host. Each
    `build_action_chains` call is a fresh host start (or a settings reload),
    and the artist stays past the threshold on every later like."""
    monkeypatch.setattr(_common, "FOLLOWED_ARTISTS_FILE", tmp_path / "followed.json")
    monkeypatch.setattr(_common, "LIKE_COOLDOWN_FILE", tmp_path / "cooldown.json")
    cfg = {"actions": {"follow_artist": {"threshold": 2}}}
    provider = FakeSpotifyProvider()
    storage = FakeStorage()

    def start_host() -> FollowArtistAction:
        _pre, post = _common.build_action_chains(cfg, storage)
        return next(a for a in post if isinstance(a, FollowArtistAction))

    first = start_host()
    await first.run(_ctx(_track("trk-1"), provider))
    await first.run(_ctx(_track("trk-2"), provider))
    assert provider.follow_calls == ["art1"]

    restarted = start_host()
    await restarted.run(_ctx(_track("trk-3"), provider))

    assert provider.follow_calls == ["art1"]


@pytest.mark.asyncio
async def test_idempotent_on_repeat_track(followed) -> None:
    """Re-liking the same track from the same artist doesn't push the
    distinct count forward → no follow on repeats."""
    provider = FakeSpotifyProvider()
    storage = FakeStorage()
    action = FollowArtistAction(storage=storage, followed_path=followed, threshold=2)

    # Same track twice → distinct count stays at 1.
    await action.run(_ctx(_track("trk-1"), provider))
    await action.run(_ctx(_track("trk-1"), provider))
    assert provider.follow_calls == []

    # New track → distinct count becomes 2 → follow fires.
    await action.run(_ctx(_track("trk-2"), provider))
    assert provider.follow_calls == ["art1"]


@pytest.mark.asyncio
async def test_multi_artist_track_records_each_independently(followed) -> None:
    provider = FakeSpotifyProvider()
    storage = FakeStorage()
    action = FollowArtistAction(storage=storage, followed_path=followed, threshold=2)

    # Both artists hit count 1 after first track.
    await action.run(_ctx(_track("trk-1", artist_ids=("art1", "art2")), provider))
    assert provider.follow_calls == []
    # Second track contributes to BOTH artists; both should reach 2 and follow.
    await action.run(_ctx(_track("trk-2", artist_ids=("art1", "art2")), provider))
    assert sorted(provider.follow_calls) == ["art1", "art2"]


@pytest.mark.asyncio
async def test_no_artist_ids_is_noop(followed) -> None:
    provider = FakeSpotifyProvider()
    storage = FakeStorage()
    action = FollowArtistAction(storage=storage, followed_path=followed, threshold=1)

    await action.run(_ctx(_track("trk-1", artist_ids=()), provider))
    assert provider.follow_calls == []


@pytest.mark.asyncio
async def test_non_spotify_provider_is_noop(caplog, followed) -> None:
    storage = FakeStorage()
    action = FollowArtistAction(storage=storage, followed_path=followed, threshold=1)
    ctx = LikeContext(track=_track("trk-1"), music_provider=object())
    with caplog.at_level(logging.DEBUG, logger="like_spotify.extensions"):
        await action.run(ctx)

    # "Did not raise" proves nothing here: without the capability guard the
    # missing `user_id` method is swallowed into a warning. A no-op means the
    # action neither complained nor counted the track.
    assert caplog.records == []
    assert storage._seen == set()


@pytest.mark.asyncio
async def test_follow_auth_error_logged_not_raised(caplog, followed) -> None:
    provider = FakeSpotifyProvider(follow_raises=AuthError("scope expired"))
    storage = FakeStorage()
    action = FollowArtistAction(storage=storage, followed_path=followed, threshold=1)

    with caplog.at_level(logging.WARNING, logger="like_spotify.extensions"):
        await action.run(_ctx(_track("trk-1"), provider))

    # Not raised — and the user is told how to fix it, which is the only
    # trace a denied follow leaves.
    assert provider.follow_calls == []
    assert [r.levelno for r in caplog.records] == [logging.WARNING]
    message = caplog.records[0].getMessage()
    assert "scope expired" in message
    assert "like-current-song --setup" in message


@pytest.mark.asyncio
async def test_constructor_validates_inputs(followed) -> None:
    with pytest.raises(ValueError, match="storage is required"):
        FollowArtistAction(storage=None, followed_path=followed, threshold=5)  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="threshold must be >= 1"):
        FollowArtistAction(storage=FakeStorage(), followed_path=followed, threshold=0)
