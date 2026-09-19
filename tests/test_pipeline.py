"""Smoke tests for the pipeline.

Slices:
    #21 — tracer-bullet currently_playing → like → feedback.
    #22 — Storage wiring + count in feedback title.
    #23 — Pre/PostLikeAction chains.
    #24 — backfill probe (is_liked → was_already_liked → Storage.increment).

Network / keyboard / tray are not exercised — we mock MusicProvider +
Storage and verify the core composition flows the way the host depends on.
"""

from __future__ import annotations

import pytest

from like_spotify.core.actions import PostLikeAction, PreLikeAction
from like_spotify.core.music_provider import MusicProvider
from like_spotify.core.pipeline import Pipeline, RemoveFromPlaylistPipeline
from like_spotify.core.storage import Storage
from like_spotify.core.types import CurrentTrack, LikeContext


class FakeProvider(MusicProvider):
    def __init__(
        self,
        track: CurrentTrack | None,
        like_raises: Exception | None = None,
        is_liked_value: bool = False,
        is_liked_raises: Exception | None = None,
        user: str = "user-id",
    ):
        self._track = track
        self._like_raises = like_raises
        self._is_liked_value = is_liked_value
        self._is_liked_raises = is_liked_raises
        self._user = user
        self.like_calls: list[CurrentTrack] = []
        self.is_liked_calls: list[CurrentTrack] = []
        self.user_id_calls = 0

    async def get_currently_playing(self) -> CurrentTrack | None:
        return self._track

    async def like(self, track: CurrentTrack) -> None:
        if self._like_raises is not None:
            raise self._like_raises
        self.like_calls.append(track)

    async def is_liked(self, track: CurrentTrack) -> bool:
        self.is_liked_calls.append(track)
        if self._is_liked_raises is not None:
            raise self._is_liked_raises
        return self._is_liked_value

    async def user_id(self) -> str:
        self.user_id_calls += 1
        return self._user


class FakeStorage(Storage):
    def __init__(self, raises: Exception | None = None):
        self._raises = raises
        # Records: (user_id, track_id, was_already_liked)
        self.increment_calls: list[tuple[str, str, bool]] = []
        self._rows: dict[tuple[str, str], dict] = {}
        self._artist_seen: set[tuple[str, str, str]] = set()

    async def increment(
        self,
        user_id: str,
        track: CurrentTrack,
        was_already_liked: bool = False,
    ) -> int:
        if self._raises is not None:
            raise self._raises
        key = (user_id, track.provider_track_id)
        self.increment_calls.append((user_id, track.provider_track_id, was_already_liked))
        if key not in self._rows:
            self._rows[key] = {
                "count": 2 if was_already_liked else 1,
                "backfilled": was_already_liked,
            }
        else:
            self._rows[key]["count"] += 1
        return self._rows[key]["count"]

    async def get_count(self, user_id: str, track: CurrentTrack) -> int:
        return self._rows.get((user_id, track.provider_track_id), {}).get("count", 0)

    async def record_artist_track(
        self, user_id: str, artist_id: str, track_id: str
    ) -> int:
        self._artist_seen.add((user_id, artist_id, track_id))
        return sum(1 for u, a, _t in self._artist_seen if u == user_id and a == artist_id)

    def row(self, user_id: str, track_id: str) -> dict:
        return self._rows[(user_id, track_id)]


class Feedback:
    def __init__(self) -> None:
        self.calls: list[tuple[bool, str, str]] = []
        self.kinds: list[str] = []

    def __call__(
        self, success: bool, title: str, message: str, *, kind: str = "like"
    ) -> None:
        self.calls.append((success, title, message))
        self.kinds.append(kind)


def _track(track_id: str = "abc123") -> CurrentTrack:
    return CurrentTrack(
        provider="spotify",
        provider_track_id=track_id,
        title="Song",
        artists=("Artist",),
    )


@pytest.mark.asyncio
async def test_like_path_calls_provider_and_emits_success() -> None:
    provider = FakeProvider(track=_track())
    fb = Feedback()

    await Pipeline(provider=provider, feedback=fb).run_once()

    assert provider.like_calls == [_track()]
    assert len(fb.calls) == 1
    success, title, _ = fb.calls[0]
    assert success is True
    assert title == "Liked"


@pytest.mark.asyncio
async def test_nothing_playing_skips_like() -> None:
    provider = FakeProvider(track=None)
    fb = Feedback()

    await Pipeline(provider=provider, feedback=fb).run_once()

    assert provider.like_calls == []
    assert fb.calls == [(False, "Nothing playing", "")]


@pytest.mark.asyncio
async def test_like_failure_surfaces_to_feedback() -> None:
    provider = FakeProvider(track=_track(), like_raises=RuntimeError("boom"))
    fb = Feedback()

    await Pipeline(provider=provider, feedback=fb).run_once()

    assert provider.like_calls == []
    assert len(fb.calls) == 1
    success, title, message = fb.calls[0]
    assert success is False
    assert title == "Like failed"
    assert "boom" in message


@pytest.mark.asyncio
async def test_storage_increment_count_surfaces_in_title() -> None:
    provider = FakeProvider(track=_track())
    storage = FakeStorage()
    fb = Feedback()

    await Pipeline(provider=provider, feedback=fb, storage=storage).run_once()
    await Pipeline(provider=provider, feedback=fb, storage=storage).run_once()
    await Pipeline(provider=provider, feedback=fb, storage=storage).run_once()

    assert [c[:2] for c in storage.increment_calls] == [("user-id", "abc123")] * 3
    assert [c[1] for c in fb.calls] == ["Liked × 1", "Liked × 2", "Liked × 3"]


@pytest.mark.asyncio
async def test_storage_failure_does_not_fail_like() -> None:
    provider = FakeProvider(track=_track())
    storage = FakeStorage(raises=RuntimeError("supabase down"))
    fb = Feedback()

    await Pipeline(provider=provider, feedback=fb, storage=storage).run_once()

    assert provider.like_calls == [_track()]
    success, title, _ = fb.calls[0]
    assert success is True
    assert title == "Liked"


@pytest.mark.asyncio
async def test_storage_not_called_when_like_fails() -> None:
    provider = FakeProvider(track=_track(), like_raises=RuntimeError("nope"))
    storage = FakeStorage()
    fb = Feedback()

    await Pipeline(provider=provider, feedback=fb, storage=storage).run_once()

    assert storage.increment_calls == []


# ── #24: backfill ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_no_is_liked_probe_when_storage_absent() -> None:
    """Skipping the probe saves a Spotify API call on every press."""
    provider = FakeProvider(track=_track(), is_liked_value=True)
    fb = Feedback()

    await Pipeline(provider=provider, feedback=fb).run_once()

    assert provider.is_liked_calls == []
    assert provider.like_calls == [_track()]


@pytest.mark.asyncio
async def test_first_encounter_already_liked_passes_flag_true() -> None:
    provider = FakeProvider(track=_track(), is_liked_value=True)
    storage = FakeStorage()
    fb = Feedback()

    await Pipeline(provider=provider, feedback=fb, storage=storage).run_once()

    assert provider.is_liked_calls == [_track()]
    assert storage.increment_calls == [("user-id", "abc123", True)]
    # FakeStorage mirrors the RPC: was_already_liked=True on INSERT → count=2.
    assert fb.calls[0][1] == "Liked × 2"


@pytest.mark.asyncio
async def test_subsequent_like_ignores_was_already_liked_flag() -> None:
    """The flag matters only on INSERT — backfill is idempotent."""
    track = _track()
    storage = FakeStorage()

    p1 = FakeProvider(track=track, is_liked_value=True)
    await Pipeline(provider=p1, feedback=Feedback(), storage=storage).run_once()

    # Second press: even if is_liked says True again, count goes 2 → 3,
    # backfilled flag in row stays as it was.
    p2 = FakeProvider(track=track, is_liked_value=True)
    fb2 = Feedback()
    await Pipeline(provider=p2, feedback=fb2, storage=storage).run_once()

    row = storage.row("user-id", "abc123")
    assert row == {"count": 3, "backfilled": True}
    assert fb2.calls[0][1] == "Liked × 3"


@pytest.mark.asyncio
async def test_first_encounter_not_already_liked_passes_flag_false() -> None:
    provider = FakeProvider(track=_track(), is_liked_value=False)
    storage = FakeStorage()
    fb = Feedback()

    await Pipeline(provider=provider, feedback=fb, storage=storage).run_once()

    assert storage.increment_calls == [("user-id", "abc123", False)]
    assert storage.row("user-id", "abc123") == {"count": 1, "backfilled": False}
    assert fb.calls[0][1] == "Liked × 1"


@pytest.mark.asyncio
async def test_is_liked_failure_falls_back_to_false() -> None:
    """Soft fail on the probe — better to miss a backfill than double-count."""
    provider = FakeProvider(
        track=_track(), is_liked_raises=RuntimeError("contains 500")
    )
    storage = FakeStorage()
    fb = Feedback()

    await Pipeline(provider=provider, feedback=fb, storage=storage).run_once()

    assert provider.like_calls == [_track()]
    assert storage.increment_calls == [("user-id", "abc123", False)]
    assert fb.calls[0][0] is True


@pytest.mark.asyncio
async def test_is_liked_probed_before_like() -> None:
    """Probe before write — liking first would always return True."""
    call_order: list[str] = []

    class OrderedProvider(FakeProvider):
        async def is_liked(self, track: CurrentTrack) -> bool:
            call_order.append("is_liked")
            return await super().is_liked(track)

        async def like(self, track: CurrentTrack) -> None:
            call_order.append("like")
            await super().like(track)

    provider = OrderedProvider(track=_track(), is_liked_value=False)
    await Pipeline(
        provider=provider, feedback=Feedback(), storage=FakeStorage()
    ).run_once()

    assert call_order == ["is_liked", "like"]


# ── #23: Pre/Post action chains ────────────────────────────────────────


class RecordingPre(PreLikeAction):
    """PreLikeAction that records calls and returns a configurable verdict."""

    def __init__(self, proceed: bool = True, raises: Exception | None = None):
        self.proceed = proceed
        self.raises = raises
        self.calls: list[LikeContext] = []

    async def run(self, ctx: LikeContext) -> bool:
        self.calls.append(ctx)
        if self.raises is not None:
            raise self.raises
        return self.proceed


class RecordingPost(PostLikeAction):
    """PostLikeAction that records calls and optionally raises."""

    def __init__(self, raises: Exception | None = None):
        self.raises = raises
        self.calls: list[LikeContext] = []

    async def run(self, ctx: LikeContext) -> None:
        self.calls.append(ctx)
        if self.raises is not None:
            raise self.raises


@pytest.mark.asyncio
async def test_pre_action_returning_false_aborts_like() -> None:
    provider = FakeProvider(track=_track())
    pre = RecordingPre(proceed=False)
    fb = Feedback()

    await Pipeline(
        provider=provider, feedback=fb, pre_like_actions=[pre]
    ).run_once()

    assert pre.calls and pre.calls[0].track == _track()
    assert provider.like_calls == []
    success, title, _ = fb.calls[0]
    assert success is False
    assert "RecordingPre" in title


@pytest.mark.asyncio
async def test_pre_action_returning_true_proceeds() -> None:
    provider = FakeProvider(track=_track())
    pre = RecordingPre(proceed=True)
    fb = Feedback()

    await Pipeline(
        provider=provider, feedback=fb, pre_like_actions=[pre]
    ).run_once()

    assert provider.like_calls == [_track()]
    assert fb.calls[0][:2] == (True, "Liked")


@pytest.mark.asyncio
async def test_pre_action_exception_is_skip_not_abort() -> None:
    """A raising pre-action is logged and skipped; later actions and the
    like itself still proceed. Independence is the contract."""
    provider = FakeProvider(track=_track())
    flaky = RecordingPre(raises=RuntimeError("flaky"))
    healthy = RecordingPre(proceed=True)
    fb = Feedback()

    await Pipeline(
        provider=provider, feedback=fb, pre_like_actions=[flaky, healthy]
    ).run_once()

    assert flaky.calls and healthy.calls
    assert provider.like_calls == [_track()]


@pytest.mark.asyncio
async def test_post_action_runs_after_successful_like() -> None:
    provider = FakeProvider(track=_track())
    post = RecordingPost()
    fb = Feedback()

    await Pipeline(
        provider=provider, feedback=fb, post_like_actions=[post]
    ).run_once()

    assert post.calls and post.calls[0].track == _track()
    assert fb.calls[0][:2] == (True, "Liked")


@pytest.mark.asyncio
async def test_post_action_not_run_when_like_fails() -> None:
    provider = FakeProvider(track=_track(), like_raises=RuntimeError("nope"))
    post = RecordingPost()

    await Pipeline(
        provider=provider, feedback=Feedback(), post_like_actions=[post]
    ).run_once()

    assert post.calls == []


@pytest.mark.asyncio
async def test_post_action_failure_does_not_abort_chain() -> None:
    """AC: if first PostLikeAction throws, second still runs."""
    provider = FakeProvider(track=_track())
    broken = RecordingPost(raises=RuntimeError("boom"))
    healthy = RecordingPost()
    fb = Feedback()

    await Pipeline(
        provider=provider,
        feedback=fb,
        post_like_actions=[broken, healthy],
    ).run_once()

    assert broken.calls and healthy.calls
    assert fb.calls[0][0] is True  # Like still reported as success.


# ── #43: RemoveFromPlaylistPipeline (remove-without-like hotkey) ────────


class FakeRemoveProvider(MusicProvider):
    """Provider speaking `PlaylistCapableProvider` — the remove flow needs it."""

    def __init__(
        self,
        track: CurrentTrack | None,
        playlist_id: str | None = "pl1",
        get_raises: Exception | None = None,
        find_raises: Exception | None = None,
        remove_raises: Exception | None = None,
        remove_raises_once: bool = False,
    ):
        self._track = track
        self._playlist_id = playlist_id
        self._get_raises = get_raises
        self._find_raises = find_raises
        self._remove_raises = remove_raises
        self._remove_raises_once = remove_raises_once
        self.find_calls: list[str] = []
        self.remove_calls: list[tuple[str, str]] = []

    async def get_currently_playing(self) -> CurrentTrack | None:
        if self._get_raises is not None:
            raise self._get_raises
        return self._track

    async def like(self, track: CurrentTrack) -> None:  # pragma: no cover
        raise AssertionError("remove flow must not like")

    async def is_liked(self, track: CurrentTrack) -> bool:  # pragma: no cover
        raise AssertionError("remove flow must not probe is_liked")

    async def user_id(self) -> str:  # pragma: no cover
        return "user-id"

    async def find_playlist_by_name(self, name: str) -> str | None:
        self.find_calls.append(name)
        if self._find_raises is not None:
            raise self._find_raises
        return self._playlist_id

    async def remove_track_from_playlist(
        self, track_id: str, playlist_id: str
    ) -> None:
        self.remove_calls.append((track_id, playlist_id))
        if self._remove_raises is not None and (
            not self._remove_raises_once or len(self.remove_calls) == 1
        ):
            raise self._remove_raises

    async def get_playlist_track_ids(self, playlist_id: str) -> set[str]:  # pragma: no cover
        raise AssertionError("remove flow does not need track-id membership")

    async def find_or_create_playlist(self, name: str) -> str:  # pragma: no cover
        raise AssertionError("remove flow must not create playlists")

    async def add_track_to_playlist(
        self, track_id: str, playlist_id: str
    ) -> None:  # pragma: no cover
        raise AssertionError("remove flow must not add tracks")

    async def follow_artist(self, artist_id: str) -> None:  # pragma: no cover
        raise AssertionError("remove flow does not follow artists")


@pytest.mark.asyncio
async def test_remove_pipeline_removes_current_track_without_liking() -> None:
    provider = FakeRemoveProvider(track=_track("trk1"), playlist_id="pl1")
    fb = Feedback()

    await RemoveFromPlaylistPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert provider.remove_calls == [("trk1", "pl1")]
    assert provider.find_calls == ["My Archive"]
    assert fb.calls[0][0] is True
    assert fb.calls[0][1] == "Removed from My Archive"
    assert fb.kinds == ["remove"]


@pytest.mark.asyncio
async def test_remove_pipeline_nothing_playing() -> None:
    provider = FakeRemoveProvider(track=None)
    fb = Feedback()

    await RemoveFromPlaylistPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert provider.remove_calls == []
    assert fb.calls == [(False, "Nothing playing", "")]
    assert fb.kinds == ["remove"]


@pytest.mark.asyncio
async def test_remove_pipeline_playlist_not_found_does_not_cache() -> None:
    provider = FakeRemoveProvider(track=_track("trk1"), playlist_id=None)
    fb = Feedback()
    pipe = RemoveFromPlaylistPipeline(
        provider=provider, feedback=fb, playlist_name="Ghost"
    )

    await pipe.run_once()
    await pipe.run_once()

    assert provider.remove_calls == []
    # Not cached → re-resolved on the second press.
    assert provider.find_calls == ["Ghost", "Ghost"]
    assert fb.calls[0] == (False, "Playlist not found", "Ghost")


@pytest.mark.asyncio
async def test_remove_pipeline_caches_playlist_id_after_success() -> None:
    provider = FakeRemoveProvider(track=_track("trk1"), playlist_id="pl1")
    fb = Feedback()
    pipe = RemoveFromPlaylistPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    )

    await pipe.run_once()
    await pipe.run_once()

    # find resolved once; both presses removed.
    assert provider.find_calls == ["My Archive"]
    assert provider.remove_calls == [("trk1", "pl1"), ("trk1", "pl1")]


@pytest.mark.asyncio
async def test_remove_pipeline_provider_without_playlist_api() -> None:
    provider = FakeProvider(track=_track("trk1"))  # like-flow only, no playlist API
    fb = Feedback()

    await RemoveFromPlaylistPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert fb.calls[0][:2] == (False, "Remove unsupported")
    assert fb.kinds == ["remove"]


@pytest.mark.asyncio
async def test_remove_pipeline_remove_failure_surfaces() -> None:
    provider = FakeRemoveProvider(
        track=_track("trk1"), playlist_id="pl1", remove_raises=RuntimeError("boom")
    )
    fb = Feedback()

    await RemoveFromPlaylistPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert fb.calls[0][:2] == (False, "Remove failed")
    assert "boom" in fb.calls[0][2]


@pytest.mark.asyncio
async def test_remove_pipeline_drops_cache_after_remove_failure() -> None:
    """A remove failure (stale id — playlist deleted/renamed) must drop the
    cached id so the next press re-resolves instead of failing forever."""
    provider = FakeRemoveProvider(
        track=_track("trk1"),
        playlist_id="pl1",
        remove_raises=RuntimeError("gone"),
        remove_raises_once=True,
    )
    fb = Feedback()
    pipe = RemoveFromPlaylistPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    )

    await pipe.run_once()  # resolves pl1, remove raises → cache dropped
    await pipe.run_once()  # re-resolves, then succeeds

    # find called twice proves the cache was invalidated by the failure.
    assert provider.find_calls == ["My Archive", "My Archive"]
    assert provider.remove_calls == [("trk1", "pl1"), ("trk1", "pl1")]
    assert fb.calls[0][:2] == (False, "Remove failed")
    assert fb.calls[1][0] is True


@pytest.mark.asyncio
async def test_remove_pipeline_lookup_failure_does_not_cache() -> None:
    provider = FakeRemoveProvider(
        track=_track("trk1"), find_raises=RuntimeError("net")
    )
    fb = Feedback()
    pipe = RemoveFromPlaylistPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    )

    await pipe.run_once()
    await pipe.run_once()

    assert provider.find_calls == ["My Archive", "My Archive"]
    assert provider.remove_calls == []
    assert fb.calls[0][:2] == (False, "Playlist lookup failed")


@pytest.mark.asyncio
async def test_remove_pipeline_get_currently_playing_failure() -> None:
    provider = FakeRemoveProvider(track=None, get_raises=RuntimeError("api down"))
    fb = Feedback()

    await RemoveFromPlaylistPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert fb.calls[0][:2] == (False, "Error")
    assert provider.remove_calls == []


def test_remove_pipeline_rejects_blank_playlist_name() -> None:
    with pytest.raises(ValueError):
        RemoveFromPlaylistPipeline(
            provider=FakeRemoveProvider(track=None), feedback=Feedback(),
            playlist_name="   ",
        )
