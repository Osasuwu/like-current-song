"""Smoke tests for the pipeline.

Slices:
    #21 — tracer-bullet currently_playing → like → feedback.
    #22 — Storage wiring + count in feedback title.
    #23 — Pre/PostLikeAction chains.
    #24 — backfill probe (is_liked → was_already_liked → Storage.increment).
    #168 — a storage failure is logged, and a user-fixable one is shown.
    #43 / #172 — DiscardPipeline: the two independent "not this one" legs.
    #177 — DiscardPipeline's third leg: the like-destination playlist, so a
           press can undo a like that never touched the service's library.

Network / keyboard / tray are not exercised — we mock MusicProvider +
Storage and verify the core composition flows the way the host depends on.
"""

from __future__ import annotations

import logging

import pytest

from like_spotify.core.actions import PostLikeAction, PreLikeAction
from like_spotify.core.errors import TransientError, UserActionRequired
from like_spotify.core.music_provider import DislikeCapableProvider, MusicProvider
from like_spotify.core.pipeline import (
    BOTH,
    NATIVE,
    PLAYLIST,
    DiscardPipeline,
    LikeDestination,
    Pipeline,
    _and,
    _unique_names,
)
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
    storage = FakeStorage(raises=RuntimeError("counter backend down"))
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


# ── #168: a like that could not be counted says so ────────────────────


class CounterUnreachable(TransientError):
    """A blip: the next press may well work, so the user is not told."""


class SheetDeleted(UserActionRequired, RuntimeError):
    """Stands in for `SheetsApiDisabledError` — permanent until acted on."""


@pytest.mark.asyncio
async def test_transient_storage_failure_is_logged_but_not_shown(caplog) -> None:
    provider = FakeProvider(track=_track())
    storage = FakeStorage(raises=CounterUnreachable("sheets get 503"))
    fb = Feedback()

    with caplog.at_level(logging.WARNING, logger="like_spotify.core.pipeline"):
        await Pipeline(provider=provider, feedback=fb, storage=storage).run_once()

    assert provider.like_calls == [_track()]
    success, title, message = fb.calls[0]
    assert success is True
    assert title == "Liked"
    assert message == "Song — Artist"

    record = _only_warning(caplog)
    assert record.exc_info is not None
    assert "FakeStorage" in record.getMessage()
    assert "sheets get 503" in caplog.text


@pytest.mark.asyncio
async def test_user_fixable_storage_failure_reaches_the_feedback(caplog) -> None:
    provider = FakeProvider(track=_track())
    storage = FakeStorage(raises=SheetDeleted("Enable the Sheets API at <url>."))
    fb = Feedback()

    with caplog.at_level(logging.WARNING, logger="like_spotify.core.pipeline"):
        await Pipeline(provider=provider, feedback=fb, storage=storage).run_once()

    # The like still happened and the count still degraded to None.
    assert provider.like_calls == [_track()]
    success, title, message = fb.calls[0]
    assert success is True
    assert title == "Liked — counter not updated"
    assert "Song — Artist" in message
    assert "Enable the Sheets API at <url>." in message

    assert _only_warning(caplog).exc_info is not None


def _only_warning(caplog) -> logging.LogRecord:
    warnings = [
        r for r in caplog.records if r.name == "like_spotify.core.pipeline"
    ]
    assert len(warnings) == 1
    return warnings[0]


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


# ── #43 / #172: DiscardPipeline ("I don't want this one") ───────────────
#
# Two legs per press — dislike the track on the service, take it out of the
# archive playlist — that must not be able to cost each other. The fakes
# below therefore come in all four capability shapes: playlist-only,
# dislike-only, both, and neither.


class FakeRemoveProvider(MusicProvider):
    """Provider speaking `PlaylistCapableProvider` only — no dislike."""

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
        raise AssertionError("discard flow must not like")

    async def is_liked(self, track: CurrentTrack) -> bool:  # pragma: no cover
        raise AssertionError("discard flow must not probe is_liked")

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
        raise AssertionError("discard flow does not need track-id membership")

    async def find_or_create_playlist(self, name: str) -> str:  # pragma: no cover
        raise AssertionError("discard flow must not create playlists")

    async def add_track_to_playlist(
        self, track_id: str, playlist_id: str
    ) -> None:  # pragma: no cover
        raise AssertionError("discard flow must not add tracks")

    async def follow_artist(self, artist_id: str) -> None:  # pragma: no cover
        raise AssertionError("discard flow does not follow artists")


class FakeDislikeProvider(FakeProvider):
    """`DislikeCapableProvider` and nothing more — no playlist API.

    Stands in for the dislike-only wiring a user gets with no archive
    playlist configured.
    """

    def __init__(
        self,
        track: CurrentTrack | None,
        dislike_raises: Exception | None = None,
        get_raises: Exception | None = None,
    ):
        super().__init__(track=track)
        self._dislike_raises = dislike_raises
        self._get_raises = get_raises
        self.dislike_calls: list[str] = []

    async def get_currently_playing(self) -> CurrentTrack | None:
        if self._get_raises is not None:
            raise self._get_raises
        return await super().get_currently_playing()

    async def dislike(self, track: CurrentTrack) -> None:
        self.dislike_calls.append(track.provider_track_id)
        if self._dislike_raises is not None:
            raise self._dislike_raises


class FakeBothProvider(FakeRemoveProvider):
    """Playlist- *and* dislike-capable — what Spotify and YT Music are."""

    def __init__(self, *args, dislike_raises: Exception | None = None, **kwargs):
        super().__init__(*args, **kwargs)
        self._dislike_raises = dislike_raises
        self.dislike_calls: list[str] = []

    async def dislike(self, track: CurrentTrack) -> None:
        self.dislike_calls.append(track.provider_track_id)
        if self._dislike_raises is not None:
            raise self._dislike_raises


# ── Capability detection ────────────────────────────────────────────────


def test_dislike_protocol_is_structural() -> None:
    assert isinstance(FakeDislikeProvider(track=None), DislikeCapableProvider)
    assert not isinstance(FakeRemoveProvider(track=None), DislikeCapableProvider)
    # The ABC itself gained nothing — a pre-#172 provider still qualifies as
    # a MusicProvider without implementing `dislike`.
    assert not hasattr(MusicProvider, "dislike")


# ── Both legs ───────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_discard_runs_both_legs() -> None:
    provider = FakeBothProvider(track=_track("trk1"), playlist_id="pl1")
    fb = Feedback()

    await DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert provider.dislike_calls == ["trk1"]
    assert provider.remove_calls == [("trk1", "pl1")]
    assert fb.calls[0][0] is True
    assert fb.calls[0][1] == "Disliked and removed from My Archive"
    assert fb.kinds == ["remove"]


@pytest.mark.asyncio
async def test_discard_playlist_leg_failure_does_not_cost_the_dislike() -> None:
    provider = FakeBothProvider(
        track=_track("trk1"), playlist_id="pl1", remove_raises=RuntimeError("boom")
    )
    fb = Feedback()

    await DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert provider.dislike_calls == ["trk1"]  # still happened
    ok, title, message = fb.calls[0][:3]
    assert ok is False  # the tone reports the partial failure
    assert title == "Disliked — not removed from My Archive"
    assert "boom" in message


@pytest.mark.asyncio
async def test_discard_dislike_leg_failure_does_not_cost_the_remove() -> None:
    provider = FakeBothProvider(
        track=_track("trk1"),
        playlist_id="pl1",
        dislike_raises=RuntimeError("rate limited"),
    )
    fb = Feedback()

    await DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert provider.remove_calls == [("trk1", "pl1")]  # still happened
    ok, title, message = fb.calls[0][:3]
    assert ok is False
    assert title == "Removed from My Archive — not disliked"
    assert "rate limited" in message


@pytest.mark.asyncio
async def test_discard_both_legs_failing_says_nothing_changed() -> None:
    provider = FakeBothProvider(
        track=_track("trk1"),
        playlist_id="pl1",
        dislike_raises=RuntimeError("nope"),
        remove_raises=RuntimeError("boom"),
    )
    fb = Feedback()

    await DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    ok, title, message = fb.calls[0][:3]
    assert ok is False
    assert title == "Nothing changed"
    assert "nope" in message and "boom" in message


# ── One capability only ─────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_discard_dislike_capable_but_not_playlist_capable() -> None:
    """The dislike-only wiring: no archive name, no playlist API."""
    provider = FakeDislikeProvider(track=_track("trk1"))
    fb = Feedback()
    pipe = DiscardPipeline(provider=provider, feedback=fb)

    assert pipe.label == "Dislike current track"
    await pipe.run_once()

    assert provider.dislike_calls == ["trk1"]
    assert fb.calls[0][0] is True
    assert fb.calls[0][1] == "Disliked"
    assert fb.kinds == ["remove"]


@pytest.mark.asyncio
async def test_discard_dislike_capable_ignores_configured_playlist() -> None:
    """A name is configured but the provider can't do playlists: the dislike
    still lands, and the missing leg is not counted as a failure."""
    provider = FakeDislikeProvider(track=_track("trk1"))
    fb = Feedback()

    await DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert provider.dislike_calls == ["trk1"]
    assert fb.calls[0][:2] == (True, "Disliked")


@pytest.mark.asyncio
async def test_discard_playlist_capable_but_not_dislike_capable() -> None:
    provider = FakeRemoveProvider(track=_track("trk1"), playlist_id="pl1")
    fb = Feedback()
    pipe = DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    )

    assert pipe.label == "Remove from My Archive"
    await pipe.run_once()

    assert provider.remove_calls == [("trk1", "pl1")]
    assert provider.find_calls == ["My Archive"]
    assert fb.calls[0][0] is True
    assert fb.calls[0][1] == "Removed from My Archive"
    assert fb.kinds == ["remove"]


@pytest.mark.asyncio
async def test_discard_provider_with_neither_capability() -> None:
    provider = FakeProvider(track=_track("trk1"))  # like-flow only
    fb = Feedback()

    await DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert fb.calls[0][:2] == (False, "Discard unsupported")
    assert fb.kinds == ["remove"]


@pytest.mark.asyncio
async def test_discard_with_neither_capability_and_no_playlist() -> None:
    """Degrades to the same clear message, never a crash."""
    provider = FakeProvider(track=_track("trk1"))
    fb = Feedback()

    await DiscardPipeline(provider=provider, feedback=fb).run_once()

    assert fb.calls[0][:2] == (False, "Discard unsupported")


def test_discard_label_names_both_legs() -> None:
    pipe = DiscardPipeline(
        provider=FakeBothProvider(track=None),
        feedback=Feedback(),
        playlist_name="My Archive",
    )
    assert pipe.label == "Dislike and remove from My Archive"


def test_discard_accepts_blank_playlist_name() -> None:
    """Blank is the dislike-only wiring, not a misconfiguration (#172).
    It used to raise ValueError, when the playlist leg was the only leg."""
    pipe = DiscardPipeline(
        provider=FakeDislikeProvider(track=None), feedback=Feedback(),
        playlist_name="   ",
    )
    assert pipe.label == "Dislike current track"


# ── Shared preconditions and playlist-id caching (#43, unchanged) ───────


@pytest.mark.asyncio
async def test_discard_nothing_playing() -> None:
    provider = FakeRemoveProvider(track=None)
    fb = Feedback()

    await DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert provider.remove_calls == []
    assert fb.calls == [(False, "Nothing playing", "")]
    assert fb.kinds == ["remove"]


@pytest.mark.asyncio
async def test_discard_get_currently_playing_failure() -> None:
    provider = FakeRemoveProvider(track=None, get_raises=RuntimeError("api down"))
    fb = Feedback()

    await DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert fb.calls[0][:2] == (False, "Error")
    assert provider.remove_calls == []


@pytest.mark.asyncio
async def test_discard_playlist_not_found_does_not_cache() -> None:
    provider = FakeRemoveProvider(track=_track("trk1"), playlist_id=None)
    fb = Feedback()
    pipe = DiscardPipeline(provider=provider, feedback=fb, playlist_name="Ghost")

    await pipe.run_once()
    await pipe.run_once()

    assert provider.remove_calls == []
    # Not cached → re-resolved on the second press.
    assert provider.find_calls == ["Ghost", "Ghost"]
    assert fb.calls[0][:2] == (False, "Nothing changed")
    assert "Playlist not found: Ghost" in fb.calls[0][2]


@pytest.mark.asyncio
async def test_discard_caches_playlist_id_after_success() -> None:
    provider = FakeRemoveProvider(track=_track("trk1"), playlist_id="pl1")
    fb = Feedback()
    pipe = DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    )

    await pipe.run_once()
    await pipe.run_once()

    # find resolved once; both presses removed.
    assert provider.find_calls == ["My Archive"]
    assert provider.remove_calls == [("trk1", "pl1"), ("trk1", "pl1")]


@pytest.mark.asyncio
async def test_discard_remove_failure_surfaces() -> None:
    provider = FakeRemoveProvider(
        track=_track("trk1"), playlist_id="pl1", remove_raises=RuntimeError("boom")
    )
    fb = Feedback()

    await DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    ).run_once()

    assert fb.calls[0][:2] == (False, "Nothing changed")
    assert "Remove failed: boom" in fb.calls[0][2]


@pytest.mark.asyncio
async def test_discard_drops_cache_after_remove_failure() -> None:
    """A remove failure (stale id — playlist deleted/renamed) must drop the
    cached id so the next press re-resolves instead of failing forever."""
    provider = FakeRemoveProvider(
        track=_track("trk1"),
        playlist_id="pl1",
        remove_raises=RuntimeError("gone"),
        remove_raises_once=True,
    )
    fb = Feedback()
    pipe = DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    )

    await pipe.run_once()  # resolves pl1, remove raises → cache dropped
    await pipe.run_once()  # re-resolves, then succeeds

    # find called twice proves the cache was invalidated by the failure.
    assert provider.find_calls == ["My Archive", "My Archive"]
    assert provider.remove_calls == [("trk1", "pl1"), ("trk1", "pl1")]
    assert fb.calls[0][0] is False
    assert fb.calls[1][0] is True


@pytest.mark.asyncio
async def test_discard_lookup_failure_does_not_cache() -> None:
    provider = FakeRemoveProvider(
        track=_track("trk1"), find_raises=RuntimeError("net")
    )
    fb = Feedback()
    pipe = DiscardPipeline(
        provider=provider, feedback=fb, playlist_name="My Archive"
    )

    await pipe.run_once()
    await pipe.run_once()

    assert provider.find_calls == ["My Archive", "My Archive"]
    assert provider.remove_calls == []
    assert "Playlist lookup failed: net" in fb.calls[0][2]


# ── #177: the discard press also empties the like destination ───────────
#
# A like that went to a playlist can only be undone by taking it back out
# of that playlist, so the press grows a third leg — subject to the same
# independence, caching and reporting rules as the other two. The fake
# below keeps ids and failures *per playlist*, which the older two-leg
# fakes (one id, one failure) cannot express.


class FakeDiscardProvider(MusicProvider):
    """Dislike- and playlist-capable, with per-playlist ids and failures."""

    def __init__(
        self,
        track: CurrentTrack | None,
        *,
        playlists: dict[str, str | None] | None = None,
        dislike_raises: Exception | None = None,
        find_raises: dict[str, Exception] | None = None,
        remove_raises: dict[str, Exception] | None = None,
        fail_removes_once: bool = False,
    ):
        self._track = track
        # Keyed casefolded: `find_playlist_by_name` is case-insensitive.
        self._playlists = {k.casefold(): v for k, v in (playlists or {}).items()}
        self._dislike_raises = dislike_raises
        self._find_raises = find_raises or {}
        self._remove_raises = remove_raises or {}
        self._fail_removes_once = fail_removes_once
        self.find_calls: list[str] = []
        self.remove_calls: list[tuple[str, str]] = []
        self.dislike_calls: list[str] = []

    async def get_currently_playing(self) -> CurrentTrack | None:
        return self._track

    async def like(self, track: CurrentTrack) -> None:  # pragma: no cover
        raise AssertionError("discard flow must not like")

    async def is_liked(self, track: CurrentTrack) -> bool:  # pragma: no cover
        raise AssertionError("discard flow must not probe is_liked")

    async def user_id(self) -> str:  # pragma: no cover
        return "user-id"

    async def dislike(self, track: CurrentTrack) -> None:
        self.dislike_calls.append(track.provider_track_id)
        if self._dislike_raises is not None:
            raise self._dislike_raises

    async def find_playlist_by_name(self, name: str) -> str | None:
        self.find_calls.append(name)
        raises = self._find_raises.get(name)
        if raises is not None:
            raise raises
        return self._playlists.get(name.casefold())

    async def remove_track_from_playlist(
        self, track_id: str, playlist_id: str
    ) -> None:
        self.remove_calls.append((track_id, playlist_id))
        raises = self._remove_raises.get(playlist_id)
        if raises is not None and (
            not self._fail_removes_once
            or sum(1 for _t, p in self.remove_calls if p == playlist_id) == 1
        ):
            raise raises

    async def get_playlist_track_ids(
        self, playlist_id: str
    ) -> set[str]:  # pragma: no cover
        raise AssertionError("discard flow does not need track-id membership")

    async def find_or_create_playlist(self, name: str) -> str:  # pragma: no cover
        raise AssertionError("discard flow must not create playlists")

    async def add_track_to_playlist(
        self, track_id: str, playlist_id: str
    ) -> None:  # pragma: no cover
        raise AssertionError("discard flow must not add tracks")

    async def follow_artist(self, artist_id: str) -> None:  # pragma: no cover
        raise AssertionError("discard flow does not follow artists")


def _three_leg_pipe(provider, fb, **kwargs) -> DiscardPipeline:
    return DiscardPipeline(
        provider=provider,
        feedback=fb,
        playlist_name="My Archive",
        destination_playlist_name="My Songs",
        **kwargs,
    )


@pytest.mark.asyncio
async def test_discard_removes_from_the_like_destination_too() -> None:
    """AC: a like that went to `like.playlist_name` is undone by a press."""
    provider = FakeDiscardProvider(
        track=_track("trk1"), playlists={"My Archive": "pl-arch", "My Songs": "pl-dest"}
    )
    fb = Feedback()

    await _three_leg_pipe(provider, fb).run_once()

    assert provider.dislike_calls == ["trk1"]
    assert provider.remove_calls == [("trk1", "pl-arch"), ("trk1", "pl-dest")]
    ok, title, _message = fb.calls[0][:3]
    assert ok is True
    assert title == "Disliked, removed from My Archive and removed from My Songs"
    assert fb.kinds == ["remove"]


@pytest.mark.asyncio
async def test_discard_destination_only_no_archive() -> None:
    """The `playlist` destination with archiving switched off: two legs."""
    provider = FakeDiscardProvider(
        track=_track("trk1"), playlists={"My Songs": "pl-dest"}
    )
    fb = Feedback()
    pipe = DiscardPipeline(
        provider=provider, feedback=fb, destination_playlist_name="My Songs"
    )

    assert pipe.label == "Dislike and remove from My Songs"
    await pipe.run_once()

    assert provider.remove_calls == [("trk1", "pl-dest")]
    assert fb.calls[0][:2] == (True, "Disliked and removed from My Songs")


@pytest.mark.asyncio
async def test_discard_native_destination_adds_no_leg() -> None:
    """AC: `native` (the default) changes nothing — no extra playlist call,
    no extra feedback text. A `native` config resolves to a blank
    destination name, which is what the host hands over."""
    provider = FakeDiscardProvider(
        track=_track("trk1"), playlists={"My Archive": "pl-arch"}
    )
    fb = Feedback()
    pipe = DiscardPipeline(
        provider=provider,
        feedback=fb,
        playlist_name="My Archive",
        destination_playlist_name="",
    )

    assert pipe.label == "Dislike and remove from My Archive"
    await pipe.run_once()

    assert provider.find_calls == ["My Archive"]
    assert provider.remove_calls == [("trk1", "pl-arch")]
    assert fb.calls[0][:2] == (True, "Disliked and removed from My Archive")


@pytest.mark.asyncio
async def test_discard_deduplicates_archive_and_destination_by_name() -> None:
    """AC: archive name equal to destination name removes once, reports once.
    Case and surrounding space don't make it two playlists — the provider
    matches names case-insensitively and trimmed."""
    provider = FakeDiscardProvider(
        track=_track("trk1"), playlists={"My Songs": "pl-one"}
    )
    fb = Feedback()
    pipe = DiscardPipeline(
        provider=provider,
        feedback=fb,
        playlist_name="My Songs",
        destination_playlist_name="  my songs  ",
    )

    assert pipe.label == "Dislike and remove from My Songs"
    await pipe.run_once()

    assert provider.find_calls == ["My Songs"]
    assert provider.remove_calls == [("trk1", "pl-one")]
    assert fb.calls[0][:2] == (True, "Disliked and removed from My Songs")


@pytest.mark.asyncio
async def test_discard_destination_failure_costs_neither_other_leg() -> None:
    """AC: a destination-leg failure costs neither the dislike nor the
    archive removal."""
    provider = FakeDiscardProvider(
        track=_track("trk1"),
        playlists={"My Archive": "pl-arch", "My Songs": "pl-dest"},
        remove_raises={"pl-dest": RuntimeError("boom")},
    )
    fb = Feedback()

    await _three_leg_pipe(provider, fb).run_once()

    assert provider.dislike_calls == ["trk1"]
    assert provider.remove_calls == [("trk1", "pl-arch"), ("trk1", "pl-dest")]
    ok, title, message = fb.calls[0][:3]
    assert ok is False
    assert title == "Disliked and removed from My Archive — not removed from My Songs"
    assert "boom" in message


@pytest.mark.asyncio
async def test_discard_archive_failure_costs_neither_other_leg() -> None:
    """AC, the other way round: the destination removal and the dislike
    both still land when the archive leg fails."""
    provider = FakeDiscardProvider(
        track=_track("trk1"),
        playlists={"My Archive": "pl-arch", "My Songs": "pl-dest"},
        remove_raises={"pl-arch": RuntimeError("archive gone")},
    )
    fb = Feedback()

    await _three_leg_pipe(provider, fb).run_once()

    assert provider.dislike_calls == ["trk1"]
    assert ("trk1", "pl-dest") in provider.remove_calls
    ok, title, message = fb.calls[0][:3]
    assert ok is False
    assert title == "Disliked and removed from My Songs — not removed from My Archive"
    assert "archive gone" in message


@pytest.mark.asyncio
async def test_discard_dislike_failure_costs_neither_playlist_leg() -> None:
    provider = FakeDiscardProvider(
        track=_track("trk1"),
        playlists={"My Archive": "pl-arch", "My Songs": "pl-dest"},
        dislike_raises=RuntimeError("rate limited"),
    )
    fb = Feedback()

    await _three_leg_pipe(provider, fb).run_once()

    assert provider.remove_calls == [("trk1", "pl-arch"), ("trk1", "pl-dest")]
    ok, title, message = fb.calls[0][:3]
    assert ok is False
    assert title == (
        "Removed from My Archive and removed from My Songs — not disliked"
    )
    assert "rate limited" in message


@pytest.mark.asyncio
async def test_discard_destination_id_caches_after_success() -> None:
    """AC: the destination playlist id caches after a successful resolve."""
    provider = FakeDiscardProvider(
        track=_track("trk1"), playlists={"My Archive": "pl-arch", "My Songs": "pl-dest"}
    )
    pipe = _three_leg_pipe(provider, Feedback())

    await pipe.run_once()
    await pipe.run_once()

    assert provider.find_calls == ["My Archive", "My Songs"]  # resolved once each
    assert provider.remove_calls == [
        ("trk1", "pl-arch"),
        ("trk1", "pl-dest"),
        ("trk1", "pl-arch"),
        ("trk1", "pl-dest"),
    ]


@pytest.mark.asyncio
async def test_discard_destination_id_dropped_on_failure() -> None:
    """AC: … and is dropped on failure, so the next press re-resolves —
    while the archive leg keeps the id it already resolved."""
    provider = FakeDiscardProvider(
        track=_track("trk1"),
        playlists={"My Archive": "pl-arch", "My Songs": "pl-dest"},
        remove_raises={"pl-dest": RuntimeError("gone")},
        fail_removes_once=True,
    )
    fb = Feedback()
    pipe = _three_leg_pipe(provider, fb)

    await pipe.run_once()  # destination remove raises → only its cache drops
    await pipe.run_once()  # re-resolves the destination, then succeeds

    assert provider.find_calls == ["My Archive", "My Songs", "My Songs"]
    assert fb.calls[0][0] is False
    assert fb.calls[1][0] is True
    assert fb.calls[1][1] == (
        "Disliked, removed from My Archive and removed from My Songs"
    )


@pytest.mark.asyncio
async def test_discard_destination_not_found_does_not_cache() -> None:
    provider = FakeDiscardProvider(
        track=_track("trk1"), playlists={"My Archive": "pl-arch", "My Songs": None}
    )
    fb = Feedback()
    pipe = _three_leg_pipe(provider, fb)

    await pipe.run_once()
    await pipe.run_once()

    assert provider.find_calls == ["My Archive", "My Songs", "My Songs"]
    assert "Playlist not found: My Songs" in fb.calls[0][2]


@pytest.mark.asyncio
async def test_discard_destination_skipped_when_provider_has_no_playlists() -> None:
    """AC-adjacent: a provider without the playlist capability skips the leg
    silently — it is not counted as a failure."""
    provider = FakeDislikeProvider(track=_track("trk1"))
    fb = Feedback()
    pipe = DiscardPipeline(
        provider=provider, feedback=fb, destination_playlist_name="My Songs"
    )

    assert pipe.label == "Dislike current track"
    await pipe.run_once()

    assert fb.calls[0][:2] == (True, "Disliked")


def test_discard_label_names_three_legs() -> None:
    """AC: `label` reads well with three legs."""
    pipe = _three_leg_pipe(FakeDiscardProvider(track=None), Feedback())
    assert pipe.label == "Dislike, remove from My Archive and remove from My Songs"


def test_and_joins_one_two_and_three_parts() -> None:
    """The wording decision (#177): two legs keep the original "a and b";
    three take commas, with "and" before the last."""
    assert _and(["disliked"]) == "disliked"
    assert _and(["disliked", "removed from A"]) == "disliked and removed from A"
    assert _and(["disliked", "removed from A", "removed from B"]) == (
        "disliked, removed from A and removed from B"
    )


def test_unique_names_drops_blanks_and_case_insensitive_repeats() -> None:
    assert _unique_names("My Archive", "My Songs") == ["My Archive", "My Songs"]
    assert _unique_names("My Songs", "my songs") == ["My Songs"]
    assert _unique_names("", "My Songs") == ["My Songs"]
    assert _unique_names("", "") == []


# ── #173: where a like goes (native / playlist / both) ──────────────────


class FakeLikeProvider(MusicProvider):
    """Playlist-capable provider that records both halves of a like.

    `FakeRemoveProvider` asserts on the playlist *writes* (the remove flow
    must never add), so the destination tests need their own fake.
    """

    def __init__(
        self,
        track: CurrentTrack | None = None,
        *,
        playlist_id: str = "pl-dest",
        playlist_tracks: set[str] | None = None,
        like_raises: Exception | None = None,
        add_raises: Exception | None = None,
        is_liked_value: bool = False,
    ):
        self._track = track if track is not None else _track()
        self._playlist_id = playlist_id
        self._playlist_tracks = set(playlist_tracks or ())
        self._like_raises = like_raises
        self._add_raises = add_raises
        self._is_liked_value = is_liked_value
        self.like_calls: list[CurrentTrack] = []
        self.is_liked_calls: list[CurrentTrack] = []
        self.find_or_create_calls: list[str] = []
        self.add_calls: list[tuple[str, str]] = []
        self.membership_calls: list[str] = []

    async def get_currently_playing(self) -> CurrentTrack | None:
        return self._track

    async def like(self, track: CurrentTrack) -> None:
        if self._like_raises is not None:
            raise self._like_raises
        self.like_calls.append(track)

    async def is_liked(self, track: CurrentTrack) -> bool:
        self.is_liked_calls.append(track)
        return self._is_liked_value

    async def user_id(self) -> str:
        return "user-id"

    async def find_playlist_by_name(self, name: str) -> str | None:  # pragma: no cover
        raise AssertionError("the like destination resolves with find_or_create")

    async def find_or_create_playlist(self, name: str) -> str:
        self.find_or_create_calls.append(name)
        return self._playlist_id

    async def get_playlist_track_ids(self, playlist_id: str) -> set[str]:
        self.membership_calls.append(playlist_id)
        return set(self._playlist_tracks)

    async def add_track_to_playlist(self, track_id: str, playlist_id: str) -> None:
        if self._add_raises is not None:
            raise self._add_raises
        self.add_calls.append((track_id, playlist_id))

    async def remove_track_from_playlist(
        self, track_id: str, playlist_id: str
    ) -> None:  # pragma: no cover
        raise AssertionError("the like flow must not remove tracks")

    async def follow_artist(self, artist_id: str) -> None:  # pragma: no cover
        raise AssertionError("no follow-artist action is wired in these tests")


def test_like_destination_rejects_an_unknown_mode() -> None:
    with pytest.raises(ValueError, match="unknown like destination"):
        LikeDestination(mode="mixtape")


def test_like_destination_needs_a_playlist_name_off_native() -> None:
    with pytest.raises(ValueError, match="playlist_name"):
        LikeDestination(mode=PLAYLIST, playlist_name="   ")
    # …and native does not.
    assert LikeDestination().mode == NATIVE


@pytest.mark.asyncio
async def test_default_destination_never_touches_the_playlist_api() -> None:
    """THE upgrade path: a config with no `like` block behaves exactly as
    it did before #173, even on a provider that *could* do playlists."""
    provider = FakeLikeProvider()
    fb = Feedback()

    await Pipeline(provider=provider, feedback=fb).run_once()

    assert len(provider.like_calls) == 1
    assert provider.find_or_create_calls == []
    assert provider.add_calls == []
    assert fb.calls == [(True, "Liked", "Song — Artist")]


@pytest.mark.asyncio
async def test_playlist_destination_adds_instead_of_liking() -> None:
    provider = FakeLikeProvider()
    fb = Feedback()

    await Pipeline(
        provider=provider,
        feedback=fb,
        like_destination=LikeDestination(mode=PLAYLIST, playlist_name="Songs"),
    ).run_once()

    assert provider.like_calls == []
    assert provider.find_or_create_calls == ["Songs"]
    assert provider.add_calls == [("abc123", "pl-dest")]
    assert fb.calls[0][:2] == (True, "Liked")


@pytest.mark.asyncio
async def test_both_destination_does_the_two() -> None:
    provider = FakeLikeProvider()
    fb = Feedback()

    await Pipeline(
        provider=provider,
        feedback=fb,
        like_destination=LikeDestination(mode=BOTH, playlist_name="Songs"),
    ).run_once()

    assert len(provider.like_calls) == 1
    assert provider.add_calls == [("abc123", "pl-dest")]
    assert fb.calls[0][:2] == (True, "Liked")


@pytest.mark.asyncio
async def test_both_counts_the_like_when_only_the_playlist_leg_fails() -> None:
    provider = FakeLikeProvider(add_raises=RuntimeError("playlist is full"))
    storage = FakeStorage()
    fb = Feedback()

    await Pipeline(
        provider=provider,
        feedback=fb,
        storage=storage,
        like_destination=LikeDestination(mode=BOTH, playlist_name="Songs"),
    ).run_once()

    success, title, message = fb.calls[0]
    assert success is True  # the press landed somewhere
    assert "Liked × 1" in title and "not added to Songs" in title
    assert "playlist is full" in message
    assert len(storage.increment_calls) == 1


@pytest.mark.asyncio
async def test_both_counts_the_like_when_only_the_native_leg_fails() -> None:
    provider = FakeLikeProvider(like_raises=RuntimeError("token expired"))
    storage = FakeStorage()
    fb = Feedback()

    await Pipeline(
        provider=provider,
        feedback=fb,
        storage=storage,
        like_destination=LikeDestination(mode=BOTH, playlist_name="Songs"),
    ).run_once()

    success, title, message = fb.calls[0]
    assert success is True
    assert "service like failed" in title
    assert "token expired" in message
    assert provider.add_calls == [("abc123", "pl-dest")]
    assert len(storage.increment_calls) == 1


@pytest.mark.asyncio
async def test_both_fails_only_when_both_legs_fail() -> None:
    provider = FakeLikeProvider(
        like_raises=RuntimeError("token expired"),
        add_raises=RuntimeError("playlist is full"),
    )
    storage = FakeStorage()
    fb = Feedback()

    await Pipeline(
        provider=provider,
        feedback=fb,
        storage=storage,
        like_destination=LikeDestination(mode=BOTH, playlist_name="Songs"),
    ).run_once()

    success, title, message = fb.calls[0]
    assert (success, title) == (False, "Like failed")
    assert "token expired" in message and "playlist is full" in message
    assert storage.increment_calls == []  # nothing landed, nothing counted


@pytest.mark.asyncio
async def test_single_leg_failure_keeps_the_bare_provider_message() -> None:
    """One configured leg has nothing to disambiguate, so the message stays
    the raw provider error — what every install saw before #173."""
    provider = FakeLikeProvider(add_raises=RuntimeError("playlist is full"))
    fb = Feedback()

    await Pipeline(
        provider=provider,
        feedback=fb,
        like_destination=LikeDestination(mode=PLAYLIST, playlist_name="Songs"),
    ).run_once()

    assert fb.calls[0] == (False, "Like failed", "playlist is full")


@pytest.mark.asyncio
async def test_playlist_destination_probes_playlist_membership() -> None:
    """Under `playlist` nothing writes the service's own like, so asking
    `is_liked` would answer about a bucket this install never fills."""
    provider = FakeLikeProvider(playlist_tracks={"abc123"}, is_liked_value=False)
    storage = FakeStorage()

    await Pipeline(
        provider=provider,
        feedback=Feedback(),
        storage=storage,
        like_destination=LikeDestination(mode=PLAYLIST, playlist_name="Songs"),
    ).run_once()

    assert provider.is_liked_calls == []
    assert provider.membership_calls == ["pl-dest"]
    assert storage.increment_calls == [("user-id", "abc123", True)]


@pytest.mark.asyncio
async def test_both_destination_keeps_the_is_liked_probe() -> None:
    provider = FakeLikeProvider(playlist_tracks=set(), is_liked_value=True)
    storage = FakeStorage()

    await Pipeline(
        provider=provider,
        feedback=Feedback(),
        storage=storage,
        like_destination=LikeDestination(mode=BOTH, playlist_name="Songs"),
    ).run_once()

    assert len(provider.is_liked_calls) == 1
    assert provider.membership_calls == []
    assert storage.increment_calls == [("user-id", "abc123", True)]


@pytest.mark.asyncio
async def test_destination_playlist_id_is_cached_then_dropped_on_failure() -> None:
    provider = FakeLikeProvider(add_raises=RuntimeError("gone"))
    pipeline = Pipeline(
        provider=provider,
        feedback=Feedback(),
        like_destination=LikeDestination(mode=PLAYLIST, playlist_name="Songs"),
    )

    await pipeline.run_once()
    await pipeline.run_once()

    # A failed add drops the cached id, so the next press re-resolves the
    # playlist instead of writing to one that may have been deleted.
    assert provider.find_or_create_calls == ["Songs", "Songs"]

    provider._add_raises = None
    await pipeline.run_once()
    await pipeline.run_once()
    # Two clean presses later the id is still the one resolved on the third.
    assert provider.find_or_create_calls == ["Songs", "Songs", "Songs"]


def test_playlist_destination_refused_on_a_provider_without_playlists() -> None:
    with pytest.raises(ValueError, match="FakeProvider has no playlist API"):
        Pipeline(
            provider=FakeProvider(track=_track()),
            feedback=Feedback(),
            like_destination=LikeDestination(mode=BOTH, playlist_name="Songs"),
        )
