"""Tests for PromoteToBestAction (#26, #245)."""

from __future__ import annotations

import logging
import threading
import time
from pathlib import Path

import pytest

from like_spotify.core.errors import AuthError
from like_spotify.core.types import CurrentTrack, LikeContext
from like_spotify.extensions.promote_to_best import PromoteToBestAction
from like_spotify.extensions.spotify import SpotifyMusicProvider
from like_spotify.hosts import _common


def _track(track_id: str = "trk-a") -> CurrentTrack:
    return CurrentTrack(
        provider="spotify",
        provider_track_id=track_id,
        title="Song",
        artists=("Artist",),
    )


class FakeSpotifyProvider(SpotifyMusicProvider):
    def __init__(
        self,
        existing_playlist_id: str | None = None,
        find_or_create_raises: Exception | None = None,
        add_raises: Exception | None = None,
        playlist_members: set[str] | None = None,
        fail_first_adds: int = 0,
    ):
        # Bypass real constructor.
        self._client_id = "cid"
        self._token_path = Path("/dev/null")
        self._tokens = {
            "access_token": "tt",
            "refresh_token": "rt",
            "expires_at": time.time() + 3600,
        }
        self._lock = threading.Lock()
        self._user_id_cache = None
        self._existing = existing_playlist_id
        self._find_raises = find_or_create_raises
        self._add_raises = add_raises
        self._fail_first_adds = fail_first_adds
        # What the playlist holds, as the provider would report it: starts with
        # `playlist_members` and grows with every successful add.
        self.members: set[str] = set(playlist_members or ())
        self.find_or_create_calls: list[str] = []
        self.member_reads: list[str] = []
        self.add_calls: list[tuple[str, str]] = []

    async def find_or_create_playlist(self, name: str) -> str:
        self.find_or_create_calls.append(name)
        if self._find_raises is not None:
            raise self._find_raises
        return self._existing or "playlist-new"

    async def get_playlist_track_ids(self, playlist_id: str) -> set[str]:
        self.member_reads.append(playlist_id)
        return set(self.members)

    async def add_track_to_playlist(self, track_id: str, playlist_id: str) -> None:
        if self._add_raises is not None:
            raise self._add_raises
        if self._fail_first_adds > 0:
            self._fail_first_adds -= 1
            raise RuntimeError("503 from the playlist endpoint")
        self.add_calls.append((track_id, playlist_id))
        self.members.add(track_id)


@pytest.fixture
def promoted(tmp_path) -> Path:
    return tmp_path / "promoted_tracks.json"


def _ctx(count: int | None, provider=None, track_id: str = "trk-a") -> LikeContext:
    c = LikeContext(track=_track(track_id), music_provider=provider)
    c.like_count = count
    return c


@pytest.mark.asyncio
async def test_no_action_below_threshold(promoted) -> None:
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")
    action = PromoteToBestAction(playlist_name="Best", threshold=3, promoted_path=promoted)

    await action.run(_ctx(2, provider))

    assert provider.find_or_create_calls == []
    assert provider.add_calls == []


@pytest.mark.asyncio
async def test_action_fires_on_threshold_press(promoted) -> None:
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")
    action = PromoteToBestAction(playlist_name="Best", threshold=3, promoted_path=promoted)

    await action.run(_ctx(3, provider))

    assert provider.find_or_create_calls == ["Best"]
    assert provider.add_calls == [("trk-a", "pl1")]


@pytest.mark.asyncio
async def test_action_fires_when_the_count_lands_past_the_threshold(promoted) -> None:
    """#245: the threshold was lowered below a count the track already has, or
    a like was counted where this host can't see it. The count never sits on
    the threshold, and the track is still promoted."""
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")
    action = PromoteToBestAction(playlist_name="Best", threshold=3, promoted_path=promoted)

    await action.run(_ctx(5, provider))

    assert provider.add_calls == [("trk-a", "pl1")]


@pytest.mark.asyncio
async def test_action_does_not_fire_again_after_promoting(promoted) -> None:
    """AC: a 4th, 5th… like does not re-add — and does not even read the
    playlist again, the memory answers."""
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")
    action = PromoteToBestAction(playlist_name="Best", threshold=3, promoted_path=promoted)

    for c in [3, 4, 5, 6, 100]:
        await action.run(_ctx(c, provider))

    assert provider.add_calls == [("trk-a", "pl1")]
    assert provider.member_reads == ["pl1"]


@pytest.mark.asyncio
async def test_track_already_in_the_playlist_is_remembered_not_added(promoted) -> None:
    """Promoted before this memory existed, or by another device sharing the
    counter: past the threshold, not remembered, already in the playlist.
    Spotify accepts duplicates, so adding it would put a second copy there."""
    provider = FakeSpotifyProvider(existing_playlist_id="pl1", playlist_members={"trk-a"})
    action = PromoteToBestAction(playlist_name="Best", threshold=3, promoted_path=promoted)

    await action.run(_ctx(7, provider))
    # The user then takes it out of the playlist by hand; a later like must
    # respect that rather than re-add it.
    provider.members.clear()
    await action.run(_ctx(8, provider))

    assert provider.add_calls == []
    assert provider.member_reads == ["pl1"]


@pytest.mark.asyncio
async def test_failed_add_is_retried_on_the_next_like(promoted) -> None:
    provider = FakeSpotifyProvider(existing_playlist_id="pl1", fail_first_adds=1)
    action = PromoteToBestAction(playlist_name="Best", threshold=3, promoted_path=promoted)

    await action.run(_ctx(3, provider))
    assert provider.add_calls == []

    await action.run(_ctx(4, provider))
    assert provider.add_calls == [("trk-a", "pl1")]


@pytest.mark.asyncio
async def test_promoted_track_is_not_added_again_after_a_host_restart(
    tmp_path, monkeypatch
) -> None:
    """The memory outlives the process: the host builds a fresh action on every
    start, and it must find what the previous one promoted."""
    monkeypatch.setattr(_common, "PROMOTED_TRACKS_FILE", tmp_path / "promoted.json")
    monkeypatch.setattr(_common, "LIKE_COOLDOWN_FILE", tmp_path / "cooldown.json")
    cfg = {"actions": {"promote_to_best": {"playlist_name": "Best", "threshold": 3}}}
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")

    def build() -> PromoteToBestAction:
        _pre, post = _common.build_action_chains(cfg, storage=None)
        return next(a for a in post if isinstance(a, PromoteToBestAction))

    await build().run(_ctx(3, provider))
    # Taken out of the playlist by hand while the host was down: only the
    # memory can tell the restarted host it was promoted already.
    provider.members.clear()
    await build().run(_ctx(4, provider))

    assert provider.add_calls == [("trk-a", "pl1")]


@pytest.mark.asyncio
async def test_memory_is_per_track(promoted) -> None:
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")
    action = PromoteToBestAction(playlist_name="Best", threshold=3, promoted_path=promoted)

    await action.run(_ctx(3, provider, "trk-a"))
    await action.run(_ctx(4, provider, "trk-b"))

    assert provider.add_calls == [("trk-a", "pl1"), ("trk-b", "pl1")]


@pytest.mark.asyncio
async def test_playlist_id_cached_across_runs(promoted) -> None:
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")
    action = PromoteToBestAction(playlist_name="Best", threshold=3, promoted_path=promoted)

    await action.run(_ctx(3, provider, "trk-a"))
    await action.run(_ctx(3, provider, "trk-b"))

    # find_or_create called once total — second call uses cached id.
    assert provider.find_or_create_calls == ["Best"]
    assert provider.add_calls == [("trk-a", "pl1"), ("trk-b", "pl1")]


@pytest.mark.asyncio
async def test_non_spotify_provider_is_noop(caplog, promoted) -> None:
    action = PromoteToBestAction(playlist_name="Best", threshold=3, promoted_path=promoted)
    ctx = _ctx(3, object())  # not a SpotifyMusicProvider
    with caplog.at_level(logging.DEBUG, logger="like_spotify.extensions"):
        await action.run(ctx)

    # "Did not raise" proves nothing here: without the capability guard the
    # missing playlist method is swallowed into a warning.
    assert caplog.records == []


@pytest.mark.asyncio
async def test_storage_unavailable_count_none_is_noop(promoted) -> None:
    """When the Pipeline could not increment Storage, like_count is None.
    Without a real count we can't decide threshold — silent skip."""
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")
    action = PromoteToBestAction(playlist_name="Best", threshold=3, promoted_path=promoted)

    await action.run(_ctx(None, provider))

    assert provider.find_or_create_calls == []
    assert provider.add_calls == []


@pytest.mark.asyncio
async def test_constructor_validates_inputs(promoted) -> None:
    with pytest.raises(ValueError, match="playlist_name is required"):
        PromoteToBestAction(playlist_name="", promoted_path=promoted)
    with pytest.raises(ValueError, match="playlist_name is required"):
        PromoteToBestAction(playlist_name="   ", promoted_path=promoted)
    with pytest.raises(ValueError, match="threshold must be >= 1"):
        PromoteToBestAction(playlist_name="Best", threshold=0, promoted_path=promoted)
    # The smallest valid threshold is accepted.
    PromoteToBestAction(playlist_name="Best", threshold=1, promoted_path=promoted)


@pytest.mark.asyncio
async def test_auth_error_logged_not_raised(caplog, promoted) -> None:
    provider = FakeSpotifyProvider(
        find_or_create_raises=AuthError("scope expired")
    )
    action = PromoteToBestAction(playlist_name="Best", threshold=3, promoted_path=promoted)

    # Must not raise.
    with caplog.at_level(logging.WARNING, logger="like_spotify.extensions"):
        await action.run(_ctx(3, provider))
    assert provider.add_calls == []
    # Logged, and the user is told how to fix it.
    assert [r.levelno for r in caplog.records] == [logging.WARNING]
    message = caplog.records[0].getMessage()
    assert "scope expired" in message
    assert "like-current-song --setup" in message
