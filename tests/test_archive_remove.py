"""Tests for ArchiveRemoveAction (#23).

Stub a SpotifyMusicProvider — we record method calls and don't go near HTTP.
"""

from __future__ import annotations

import logging
import time

import pytest

from like_spotify.core.types import CurrentTrack, LikeContext
from like_spotify.extensions.archive_remove import ArchiveRemoveAction
from like_spotify.extensions.spotify import SpotifyMusicProvider


def _track(track_id: str = "trk1") -> CurrentTrack:
    return CurrentTrack(
        provider="spotify", provider_track_id=track_id, title="t", artists=("a",)
    )


class FakeSpotifyProvider(SpotifyMusicProvider):
    """Bypass HTTP — record calls, return canned responses."""

    def __init__(
        self,
        playlist_id: str | None,
        track_ids: set[str],
        find_raises: Exception | None = None,
        fetch_raises: Exception | None = None,
    ):
        # Skip the real constructor's client-id check; set the bare minimum.
        self._client_id = "cid"
        from pathlib import Path
        self._token_path = Path("/dev/null")
        self._tokens = {
            "access_token": "tt",
            "refresh_token": "rt",
            "expires_at": time.time() + 3600,
        }
        import threading
        self._lock = threading.Lock()
        self._user_id_cache = None

        self._playlist_id = playlist_id
        self._track_ids = set(track_ids)
        self._find_raises = find_raises
        self._fetch_raises = fetch_raises
        self.find_calls: list[str] = []
        self.fetch_calls: list[str] = []
        self.remove_calls: list[tuple[str, str]] = []

    async def find_playlist_by_name(self, name: str) -> str | None:
        self.find_calls.append(name)
        if self._find_raises is not None:
            raise self._find_raises
        return self._playlist_id

    async def get_playlist_track_ids(self, playlist_id: str) -> set[str]:
        self.fetch_calls.append(playlist_id)
        if self._fetch_raises is not None:
            raise self._fetch_raises
        return set(self._track_ids)

    async def remove_track_from_playlist(
        self, track_id: str, playlist_id: str
    ) -> None:
        self.remove_calls.append((track_id, playlist_id))
        self._track_ids.discard(track_id)


@pytest.mark.asyncio
async def test_track_in_archive_is_removed() -> None:
    provider = FakeSpotifyProvider(playlist_id="pl1", track_ids={"trk1", "trk2"})
    action = ArchiveRemoveAction(playlist_name="My Archive")

    await action.run(LikeContext(track=_track("trk1"), music_provider=provider))

    assert provider.remove_calls == [("trk1", "pl1")]


@pytest.mark.asyncio
async def test_track_not_in_archive_no_delete_issued() -> None:
    """AC: not in archive → no DELETE issued on the per-like path.

    The first invocation still triggers the lazy resolve (one find + one
    paged fetch); covered separately by
    `test_first_call_resolves_then_subsequent_uses_cache` which verifies
    that the per-like hot path has zero playlist API calls.
    """
    provider = FakeSpotifyProvider(playlist_id="pl1", track_ids={"other"})
    action = ArchiveRemoveAction(playlist_name="My Archive")

    await action.run(LikeContext(track=_track("trk1"), music_provider=provider))

    assert provider.remove_calls == []
    # Resolve happens on first call; that's expected (see module docstring).
    assert provider.find_calls == ["My Archive"]


@pytest.mark.asyncio
async def test_constructor_strips_whitespace_only_name() -> None:
    with pytest.raises(ValueError):
        ArchiveRemoveAction(playlist_name="   ")
    # Surrounding whitespace stripped; the name is still valid.
    action = ArchiveRemoveAction(playlist_name="  My Archive  ")
    assert action._playlist_name == "My Archive"


@pytest.mark.asyncio
async def test_first_call_resolves_then_subsequent_uses_cache() -> None:
    provider = FakeSpotifyProvider(playlist_id="pl1", track_ids={"trk1"})
    action = ArchiveRemoveAction(playlist_name="My Archive")

    await action.run(LikeContext(track=_track("other"), music_provider=provider))
    await action.run(LikeContext(track=_track("trk1"), music_provider=provider))

    # find + fetch called once total, despite two action invocations.
    assert provider.find_calls == ["My Archive"]
    assert provider.fetch_calls == ["pl1"]
    assert provider.remove_calls == [("trk1", "pl1")]


@pytest.mark.asyncio
async def test_archive_not_found_is_silent_noop() -> None:
    provider = FakeSpotifyProvider(playlist_id=None, track_ids=set())
    action = ArchiveRemoveAction(playlist_name="Ghost Playlist")

    # Should not raise — runs silently with no removal.
    await action.run(LikeContext(track=_track("trk1"), music_provider=provider))
    await action.run(LikeContext(track=_track("trk2"), music_provider=provider))

    # find is attempted once; fetch and remove never happen.
    assert provider.find_calls == ["Ghost Playlist"]
    assert provider.fetch_calls == []
    assert provider.remove_calls == []


@pytest.mark.asyncio
async def test_non_spotify_provider_is_silent_noop(caplog) -> None:
    """Cross-flavour safety: action lives in Spotify ecosystem but the
    chain may be wired into a non-Spotify pipeline by a contributor."""
    action = ArchiveRemoveAction(playlist_name="My Archive")

    class NotSpotify:
        pass

    with caplog.at_level(logging.DEBUG, logger="like_spotify.extensions"):
        await action.run(LikeContext(track=_track(), music_provider=NotSpotify()))

    # "Did not raise" proves nothing here: without the capability guard the
    # action calls a method the provider does not have, and the resolve step
    # swallows that into a warning. Silent means it never got that far.
    assert caplog.records == []
    assert action._resolved is False


@pytest.mark.asyncio
async def test_constructor_rejects_empty_name() -> None:
    with pytest.raises(ValueError):
        ArchiveRemoveAction(playlist_name="")


@pytest.mark.asyncio
async def test_resolve_failure_is_logged_not_raised(caplog) -> None:
    """Network blip during initial resolve must not break the chain."""
    provider = FakeSpotifyProvider(
        playlist_id=None, track_ids=set(), find_raises=RuntimeError("net")
    )
    action = ArchiveRemoveAction(playlist_name="My Archive")

    with caplog.at_level(logging.WARNING, logger="like_spotify.extensions"):
        await action.run(LikeContext(track=_track(), music_provider=provider))
        # No remove call attempted; second invocation also no-ops.
        await action.run(LikeContext(track=_track(), music_provider=provider))
    assert provider.remove_calls == []
    # Logged once, with the cause, and the lookup is not retried per like.
    assert provider.find_calls == ["My Archive"]
    assert [r.levelno for r in caplog.records] == [logging.WARNING]
    assert "net" in caplog.records[0].getMessage()
