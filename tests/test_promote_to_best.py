"""Tests for PromoteToBestAction (#26)."""

from __future__ import annotations

import threading
import time
from pathlib import Path

import pytest

from like_spotify.core.errors import AuthError
from like_spotify.core.types import CurrentTrack, LikeContext
from like_spotify.extensions.promote_to_best import PromoteToBestAction
from like_spotify.extensions.spotify import SpotifyMusicProvider


def _track() -> CurrentTrack:
    return CurrentTrack(
        provider="spotify",
        provider_track_id="trk-a",
        title="Song",
        artists=("Artist",),
    )


class FakeSpotifyProvider(SpotifyMusicProvider):
    def __init__(
        self,
        existing_playlist_id: str | None = None,
        find_or_create_raises: Exception | None = None,
        add_raises: Exception | None = None,
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
        self.find_or_create_calls: list[str] = []
        self.add_calls: list[tuple[str, str]] = []

    async def find_or_create_playlist(self, name: str) -> str:
        self.find_or_create_calls.append(name)
        if self._find_raises is not None:
            raise self._find_raises
        return self._existing or "playlist-new"

    async def add_track_to_playlist(self, track_id: str, playlist_id: str) -> None:
        if self._add_raises is not None:
            raise self._add_raises
        self.add_calls.append((track_id, playlist_id))


def _ctx(count: int) -> LikeContext:
    c = LikeContext(track=_track(), music_provider=None)
    c.like_count = count
    return c


@pytest.mark.asyncio
async def test_no_action_below_threshold() -> None:
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")
    action = PromoteToBestAction(playlist_name="Best", threshold=3)

    ctx = _ctx(2)
    ctx.music_provider = provider
    await action.run(ctx)

    assert provider.find_or_create_calls == []
    assert provider.add_calls == []


@pytest.mark.asyncio
async def test_action_fires_on_threshold_press() -> None:
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")
    action = PromoteToBestAction(playlist_name="Best", threshold=3)

    ctx = _ctx(3)
    ctx.music_provider = provider
    await action.run(ctx)

    assert provider.find_or_create_calls == ["Best"]
    assert provider.add_calls == [("trk-a", "pl1")]


@pytest.mark.asyncio
async def test_action_does_not_fire_after_threshold() -> None:
    """AC: like a 4th time → not re-added (idempotent)."""
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")
    action = PromoteToBestAction(playlist_name="Best", threshold=3)

    for c in [4, 5, 6, 100]:
        ctx = _ctx(c)
        ctx.music_provider = provider
        await action.run(ctx)

    assert provider.add_calls == []


@pytest.mark.asyncio
async def test_playlist_id_cached_across_runs() -> None:
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")
    action = PromoteToBestAction(playlist_name="Best", threshold=3)

    # First trigger at threshold.
    ctx1 = _ctx(3)
    ctx1.music_provider = provider
    await action.run(ctx1)
    # Hypothetical re-trigger via another track also hitting threshold.
    ctx2 = LikeContext(
        track=CurrentTrack(
            provider="spotify",
            provider_track_id="trk-b",
            title="X",
            artists=("Artist",),
        ),
        music_provider=provider,
    )
    ctx2.like_count = 3
    await action.run(ctx2)

    # find_or_create called once total — second call uses cached id.
    assert provider.find_or_create_calls == ["Best"]
    assert provider.add_calls == [("trk-a", "pl1"), ("trk-b", "pl1")]


@pytest.mark.asyncio
async def test_non_spotify_provider_is_noop() -> None:
    action = PromoteToBestAction(playlist_name="Best", threshold=3)
    ctx = _ctx(3)
    ctx.music_provider = object()  # not a SpotifyMusicProvider
    await action.run(ctx)  # should not raise


@pytest.mark.asyncio
async def test_storage_unavailable_count_none_is_noop() -> None:
    """When the Pipeline could not increment Storage, like_count is None.
    Without a real count we can't decide threshold — silent skip."""
    provider = FakeSpotifyProvider(existing_playlist_id="pl1")
    action = PromoteToBestAction(playlist_name="Best", threshold=3)

    ctx = LikeContext(track=_track(), music_provider=provider)
    ctx.like_count = None
    await action.run(ctx)

    assert provider.find_or_create_calls == []
    assert provider.add_calls == []


@pytest.mark.asyncio
async def test_constructor_validates_inputs() -> None:
    with pytest.raises(ValueError):
        PromoteToBestAction(playlist_name="")
    with pytest.raises(ValueError):
        PromoteToBestAction(playlist_name="   ")
    with pytest.raises(ValueError):
        PromoteToBestAction(playlist_name="Best", threshold=0)


@pytest.mark.asyncio
async def test_auth_error_logged_not_raised(caplog) -> None:
    provider = FakeSpotifyProvider(
        find_or_create_raises=AuthError("scope expired")
    )
    action = PromoteToBestAction(playlist_name="Best", threshold=3)
    ctx = _ctx(3)
    ctx.music_provider = provider

    # Must not raise.
    await action.run(ctx)
    assert provider.add_calls == []
