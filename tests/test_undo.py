"""Undo the last like (#270).

`Pipeline(undo_window_s=…)` keeps a journal of the effects the last
`run_once` actually performed; `undo_last()` reverses exactly those, and
only inside the window. These tests drive the pipeline with fakes and a
fake clock — no network, no keyboard, no tray.
"""

from __future__ import annotations

import asyncio
import logging

import pytest

from like_spotify.core.actions import PostLikeAction
from like_spotify.core.music_provider import MusicProvider, UnlikeCapableProvider
from like_spotify.core.pipeline import (
    BOTH,
    PLAYLIST,
    LikeDestination,
    Pipeline,
)
from like_spotify.core.storage import Storage
from like_spotify.core.types import CurrentTrack, LikeContext


def _track(track_id: str = "abc123") -> CurrentTrack:
    return CurrentTrack(
        provider="spotify",
        provider_track_id=track_id,
        title="Song",
        artists=("Artist",),
    )


class Clock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now


class Feedback:
    def __init__(self) -> None:
        self.calls: list[tuple[bool, str, str, str]] = []

    def __call__(
        self, success: bool, title: str, message: str, *, kind: str = "like"
    ) -> None:
        self.calls.append((success, title, message, kind))

    @property
    def last(self) -> tuple[bool, str, str, str]:
        return self.calls[-1]


class UndoProvider(MusicProvider):
    """Playlist-capable, unlike-capable provider with real liked/playlist
    state, so a test can compare "before the like" with "after the undo"."""

    def __init__(
        self,
        *,
        liked: set[str] | None = None,
        playlist: set[str] | None = None,
        is_liked_raises: Exception | None = None,
        membership_raises: Exception | None = None,
        unlike_raises: Exception | None = None,
        remove_raises: Exception | None = None,
    ) -> None:
        self.track: CurrentTrack | None = _track()
        self.liked = set(liked or ())
        self.playlist = set(playlist or ())
        self._is_liked_raises = is_liked_raises
        self._membership_raises = membership_raises
        self._unlike_raises = unlike_raises
        self._remove_raises = remove_raises
        self.unlike_calls: list[str] = []
        self.remove_calls: list[tuple[str, str]] = []

    async def get_currently_playing(self) -> CurrentTrack | None:
        return self.track

    async def like(self, track: CurrentTrack) -> None:
        self.liked.add(track.provider_track_id)

    async def is_liked(self, track: CurrentTrack) -> bool:
        if self._is_liked_raises is not None:
            raise self._is_liked_raises
        return track.provider_track_id in self.liked

    async def unlike(self, track: CurrentTrack) -> None:
        self.unlike_calls.append(track.provider_track_id)
        if self._unlike_raises is not None:
            raise self._unlike_raises
        self.liked.discard(track.provider_track_id)

    async def user_id(self) -> str:
        return "user-id"

    async def find_playlist_by_name(self, name: str) -> str | None:
        return "pl-dest"

    async def find_or_create_playlist(self, name: str) -> str:
        return "pl-dest"

    async def get_playlist_track_ids(self, playlist_id: str) -> set[str]:
        if self._membership_raises is not None:
            raise self._membership_raises
        return set(self.playlist)

    async def add_track_to_playlist(self, track_id: str, playlist_id: str) -> None:
        self.playlist.add(track_id)

    async def remove_track_from_playlist(self, track_id: str, playlist_id: str) -> None:
        self.remove_calls.append((track_id, playlist_id))
        if self._remove_raises is not None:
            raise self._remove_raises
        self.playlist.discard(track_id)

    async def follow_artist(self, artist_id: str) -> None:  # pragma: no cover
        raise AssertionError("no follow-artist action in these tests")


class NoUnlikeProvider(MusicProvider):
    """A provider written before #270: it can like, but has no `unlike`."""

    def __init__(self) -> None:
        self.liked: set[str] = set()

    async def get_currently_playing(self) -> CurrentTrack | None:
        return _track()

    async def like(self, track: CurrentTrack) -> None:
        self.liked.add(track.provider_track_id)

    async def is_liked(self, track: CurrentTrack) -> bool:
        return track.provider_track_id in self.liked

    async def user_id(self) -> str:
        return "user-id"


class CountingStorage(Storage):
    """Real counter semantics plus `undo_increment`."""

    def __init__(self, undo_raises: Exception | None = None) -> None:
        self.counts: dict[tuple[str, str], int] = {}
        self._last: dict[tuple[str, str], int | None] = {}
        self._undo_raises = undo_raises
        self.undo_calls: list[tuple[str, str]] = []

    async def increment(
        self, user_id: str, track: CurrentTrack, was_already_liked: bool = False
    ) -> int:
        key = (user_id, track.provider_track_id)
        self._last[key] = self.counts.get(key)
        if key in self.counts:
            self.counts[key] += 1
        else:
            self.counts[key] = 2 if was_already_liked else 1
        return self.counts[key]

    async def undo_increment(self, user_id: str, track: CurrentTrack) -> int:
        key = (user_id, track.provider_track_id)
        self.undo_calls.append(key)
        if self._undo_raises is not None:
            raise self._undo_raises
        previous = self._last.pop(key)
        if previous is None:
            del self.counts[key]
            return 0
        self.counts[key] = previous
        return previous

    async def get_count(self, user_id: str, track: CurrentTrack) -> int:
        return self.counts.get((user_id, track.provider_track_id), 0)

    async def record_artist_track(
        self, user_id: str, artist_id: str, track_id: str
    ) -> int:  # pragma: no cover
        return 0


class LegacyStorage(CountingStorage):
    """A storage written before #270 — inherits the ABC's default undo."""

    undo_increment = Storage.undo_increment  # type: ignore[assignment]


class JournalAction(PostLikeAction):
    def __init__(self, name: str, log: list[str]) -> None:
        self.name = name
        self.log = log

    async def run(self, ctx: LikeContext) -> None:
        self.log.append(f"run {self.name}")

    async def undo(self, ctx: LikeContext) -> None:
        self.log.append(f"undo {self.name}")


class LegacyAction(PostLikeAction):
    """A post-like action written before #270: no `undo`."""

    async def run(self, ctx: LikeContext) -> None:
        pass


class FailingUndoAction(PostLikeAction):
    async def run(self, ctx: LikeContext) -> None:
        pass

    async def undo(self, ctx: LikeContext) -> None:
        raise RuntimeError("playlist gone")


class GatedProvider(UndoProvider):
    """Holds the next `like` or `unlike` until the test releases it, so a
    second press can start while the first is still on the network."""

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._held: dict[str, tuple[asyncio.Event, asyncio.Event]] = {}

    def hold(self, method: str) -> tuple[asyncio.Event, asyncio.Event]:
        entered, release = asyncio.Event(), asyncio.Event()
        self._held[method] = (entered, release)
        return entered, release

    async def _maybe_hold(self, method: str) -> None:
        held = self._held.pop(method, None)
        if held is not None:
            entered, release = held
            entered.set()
            await release.wait()

    async def like(self, track: CurrentTrack) -> None:
        await self._maybe_hold("like")
        await super().like(track)

    async def unlike(self, track: CurrentTrack) -> None:
        await self._maybe_hold("unlike")
        await super().unlike(track)


async def _let_others_run() -> None:
    """Give every other ready task on the loop as many turns as it wants."""
    for _ in range(50):
        await asyncio.sleep(0)


def _pipe(provider, fb, clock, **kwargs) -> Pipeline:
    return Pipeline(
        provider=provider, feedback=fb, undo_window_s=10.0, clock=clock, **kwargs
    )


# ── AC1: like then undo leaves everything as it was ─────────────────────


@pytest.mark.asyncio
async def test_undo_reverses_the_native_like_and_the_counter() -> None:
    provider = UndoProvider()
    storage = CountingStorage()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock, storage=storage)

    await pipe.run_once()
    assert provider.liked == {"abc123"}
    assert storage.counts == {("user-id", "abc123"): 1}

    clock.now += 9.5
    await pipe.undo_last()

    assert provider.liked == set()
    assert storage.counts == {}
    assert fb.last == (True, "Undone", "Song — Artist", "undo")


@pytest.mark.asyncio
async def test_undo_restores_the_previous_count_of_a_track_liked_before() -> None:
    provider = UndoProvider()
    storage = CountingStorage()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock, storage=storage)

    await pipe.run_once()
    await pipe.run_once()
    assert storage.counts[("user-id", "abc123")] == 2

    await pipe.undo_last()

    assert storage.counts[("user-id", "abc123")] == 1


@pytest.mark.asyncio
async def test_undo_keeps_a_track_that_was_already_liked() -> None:
    provider = UndoProvider(liked={"abc123"})
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock)

    await pipe.run_once()
    await pipe.undo_last()

    assert provider.unlike_calls == []
    assert provider.liked == {"abc123"}
    assert fb.last[:2] == (True, "Undone")


@pytest.mark.asyncio
async def test_undo_takes_the_track_back_out_of_the_destination_playlist() -> None:
    provider = UndoProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(
        provider,
        fb,
        clock,
        like_destination=LikeDestination(PLAYLIST, "Liked songs"),
    )

    await pipe.run_once()
    assert provider.playlist == {"abc123"}
    await pipe.undo_last()

    assert provider.remove_calls == [("abc123", "pl-dest")]
    assert provider.playlist == set()
    assert provider.unlike_calls == []
    assert fb.last[:2] == (True, "Undone")


@pytest.mark.asyncio
async def test_undo_leaves_a_track_that_was_already_in_the_playlist() -> None:
    provider = UndoProvider(playlist={"abc123"})
    storage = CountingStorage()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(
        provider,
        fb,
        clock,
        storage=storage,
        like_destination=LikeDestination(PLAYLIST, "Liked songs"),
    )

    await pipe.run_once()
    await pipe.undo_last()

    assert provider.remove_calls == []
    assert provider.playlist == {"abc123"}
    assert storage.counts == {}


@pytest.mark.asyncio
async def test_undo_reverses_both_legs_of_a_both_destination() -> None:
    provider = UndoProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(
        provider, fb, clock, like_destination=LikeDestination(BOTH, "Liked songs")
    )

    await pipe.run_once()
    await pipe.undo_last()

    assert provider.liked == set()
    assert provider.playlist == set()


@pytest.mark.asyncio
async def test_both_with_storage_keeps_a_like_made_before_the_press() -> None:
    """Under `both` the backfill probe answers "liked?"; the playlist leg
    must still be judged by the playlist (#278 S5)."""
    provider = UndoProvider(liked={"abc123"})
    fb, clock = Feedback(), Clock()
    pipe = _pipe(
        provider,
        fb,
        clock,
        storage=CountingStorage(),
        like_destination=LikeDestination(BOTH, "Liked songs"),
    )

    await pipe.run_once()
    await pipe.undo_last()

    assert provider.liked == {"abc123"}
    assert provider.playlist == set()


@pytest.mark.asyncio
async def test_both_with_storage_keeps_a_playlist_entry_made_before() -> None:
    provider = UndoProvider(playlist={"abc123"})
    fb, clock = Feedback(), Clock()
    pipe = _pipe(
        provider,
        fb,
        clock,
        storage=CountingStorage(),
        like_destination=LikeDestination(BOTH, "Liked songs"),
    )

    await pipe.run_once()
    await pipe.undo_last()

    assert provider.liked == set()
    assert provider.playlist == {"abc123"}


@pytest.mark.asyncio
async def test_undo_runs_post_action_undos_in_reverse_order() -> None:
    log: list[str] = []
    provider = UndoProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(
        provider,
        fb,
        clock,
        post_like_actions=[JournalAction("a", log), JournalAction("b", log)],
    )

    await pipe.run_once()
    await pipe.undo_last()

    assert log == ["run a", "run b", "undo b", "undo a"]


# ── AC2: no open window → nothing destructive, never an older like ──────


@pytest.mark.asyncio
async def test_undo_after_the_window_does_nothing() -> None:
    provider = UndoProvider()
    storage = CountingStorage()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock, storage=storage)

    await pipe.run_once()
    clock.now += 10.01
    assert pipe.undo_available() is False
    await pipe.undo_last()

    assert provider.unlike_calls == []
    assert storage.undo_calls == []
    assert provider.liked == {"abc123"}
    success, title, _message, kind = fb.last
    assert (success, title, kind) == (False, "Nothing to undo", "undo")


@pytest.mark.asyncio
async def test_undo_with_no_like_yet_does_nothing() -> None:
    provider = UndoProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock)

    assert pipe.undo_available() is False
    await pipe.undo_last()

    assert provider.unlike_calls == []
    assert fb.last[:2] == (False, "Nothing to undo")


@pytest.mark.asyncio
async def test_window_closes_after_an_undo() -> None:
    provider = UndoProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock)

    await pipe.run_once()
    assert pipe.undo_available() is True
    await pipe.undo_last()
    assert pipe.undo_available() is False

    provider.liked.add("abc123")  # liked again by some other route
    await pipe.undo_last()

    assert provider.unlike_calls == ["abc123"]
    assert provider.liked == {"abc123"}
    assert fb.last[:2] == (False, "Nothing to undo")


@pytest.mark.asyncio
async def test_a_later_press_that_likes_nothing_closes_the_older_window() -> None:
    provider = UndoProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock)

    await pipe.run_once()
    provider.track = None  # the next press finds nothing playing
    await pipe.run_once()
    await pipe.undo_last()

    assert provider.unlike_calls == []
    assert provider.liked == {"abc123"}
    assert fb.last[:2] == (False, "Nothing to undo")


@pytest.mark.asyncio
async def test_undo_reverses_only_the_most_recent_like() -> None:
    provider = UndoProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock)

    await pipe.run_once()
    provider.track = _track("second")
    await pipe.run_once()
    await pipe.undo_last()

    assert provider.unlike_calls == ["second"]
    assert provider.liked == {"abc123"}


@pytest.mark.asyncio
async def test_overlapping_presses_undo_the_one_pressed_last() -> None:
    """Press 1 (X) is slow on the network, press 2 (Y) is fast. However
    they finish, the undo reverses Y, the latest press, and leaves X."""
    provider = GatedProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock)
    provider.track = _track("X")
    entered, release = provider.hold("like")

    first = asyncio.create_task(pipe.run_once())
    await entered.wait()
    provider.track = _track("Y")
    second = asyncio.create_task(pipe.run_once())
    await _let_others_run()
    release.set()
    await asyncio.gather(first, second)
    await pipe.undo_last()

    assert provider.unlike_calls == ["Y"]
    assert provider.liked == {"X"}


@pytest.mark.asyncio
async def test_undo_pressed_during_a_newer_press_reverses_that_press() -> None:
    provider = GatedProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock)
    provider.track = _track("X")
    await pipe.run_once()

    provider.track = _track("Y")
    entered, release = provider.hold("like")
    press = asyncio.create_task(pipe.run_once())
    await entered.wait()
    undo = asyncio.create_task(pipe.undo_last())
    await _let_others_run()
    release.set()
    await asyncio.gather(press, undo)

    assert provider.unlike_calls == ["Y"]
    assert provider.liked == {"X"}
    assert fb.last[:2] == (True, "Undone")


@pytest.mark.asyncio
async def test_a_like_pressed_while_an_undo_is_in_flight_ends_liked() -> None:
    """The undo's unlike is still on the network when the same track is
    liked again: the new press must see the track unliked, like it, and
    open a window that can take that like back."""
    provider = GatedProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock)
    await pipe.run_once()

    entered, release = provider.hold("unlike")
    undo = asyncio.create_task(pipe.undo_last())
    await entered.wait()
    press = asyncio.create_task(pipe.run_once())
    await _let_others_run()
    release.set()
    await asyncio.gather(undo, press)

    assert provider.liked == {"abc123"}
    assert pipe.undo_available() is True
    await pipe.undo_last()
    assert provider.liked == set()


@pytest.mark.asyncio
async def test_close_undo_shuts_the_window_without_touching_anything() -> None:
    """A discard press closes the like's window (#278 S2): an undo after
    it must not re-add, re-like or un-dislike anything."""
    log: list[str] = []
    provider = UndoProvider()
    storage = CountingStorage()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(
        provider, fb, clock, storage=storage, post_like_actions=[JournalAction("a", log)]
    )

    await pipe.run_once()
    await pipe.close_undo()
    assert pipe.undo_available() is False
    await pipe.undo_last()

    assert provider.unlike_calls == []
    assert storage.undo_calls == []
    assert log == ["run a"]
    assert fb.last[:2] == (False, "Nothing to undo")


@pytest.mark.asyncio
async def test_close_undo_waits_for_a_like_in_flight() -> None:
    provider = GatedProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock)
    entered, release = provider.hold("like")

    press = asyncio.create_task(pipe.run_once())
    await entered.wait()
    close = asyncio.create_task(pipe.close_undo())
    await _let_others_run()
    release.set()
    await asyncio.gather(press, close)

    assert pipe.undo_available() is False


@pytest.mark.asyncio
async def test_a_failed_like_opens_no_window() -> None:
    provider = UndoProvider()

    async def broken_like(track: CurrentTrack) -> None:
        raise RuntimeError("503")

    provider.like = broken_like  # type: ignore[method-assign]
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock)

    await pipe.run_once()

    assert pipe.undo_available() is False


@pytest.mark.asyncio
async def test_undo_is_off_unless_the_host_asks_for_a_window() -> None:
    provider = UndoProvider()
    fb = Feedback()
    pipe = Pipeline(provider=provider, feedback=fb)

    await pipe.run_once()

    assert pipe.undo_available() is False
    await pipe.undo_last()
    assert provider.liked == {"abc123"}


# ── Feedback: a failure names the leg it could not reverse ──────────────


@pytest.mark.asyncio
async def test_a_failed_unlike_is_named_in_the_message() -> None:
    provider = UndoProvider(unlike_raises=RuntimeError("401 expired"))
    storage = CountingStorage()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock, storage=storage)

    await pipe.run_once()
    await pipe.undo_last()

    success, title, message, kind = fb.last
    assert (success, kind) == (False, "undo")
    assert "still liked" in title
    assert "still liked" in message  # the tray balloon drops the title
    assert "401 expired" in message
    # the other legs were still reversed
    assert storage.counts == {}


@pytest.mark.asyncio
async def test_a_failed_playlist_removal_is_named_in_the_message() -> None:
    provider = UndoProvider(remove_raises=RuntimeError("403"))
    fb, clock = Feedback(), Clock()
    pipe = _pipe(
        provider, fb, clock, like_destination=LikeDestination(BOTH, "Liked songs")
    )

    await pipe.run_once()
    await pipe.undo_last()

    success, _title, message, _kind = fb.last
    assert success is False
    assert "still in Liked songs" in message
    assert provider.liked == set()


@pytest.mark.asyncio
async def test_a_failed_counter_undo_is_named_in_the_message() -> None:
    provider = UndoProvider()
    storage = CountingStorage(undo_raises=RuntimeError("sheet 500"))
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock, storage=storage)

    await pipe.run_once()
    await pipe.undo_last()

    success, _title, message, _kind = fb.last
    assert success is False
    assert "counter not restored" in message
    assert provider.liked == set()


@pytest.mark.asyncio
async def test_a_failed_action_undo_is_named_in_the_message() -> None:
    provider = UndoProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock, post_like_actions=[FailingUndoAction()])

    await pipe.run_once()
    await pipe.undo_last()

    success, _title, message, _kind = fb.last
    assert success is False
    assert "FailingUndoAction not undone" in message
    assert "playlist gone" in message
    assert provider.liked == set()


@pytest.mark.asyncio
async def test_an_unknown_prior_like_state_is_left_alone_and_reported() -> None:
    """If we cannot tell whether the track was liked before the press,
    unliking could take away a like the user already had — so it stays."""
    provider = UndoProvider(is_liked_raises=RuntimeError("timeout"))
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock)

    await pipe.run_once()
    await pipe.undo_last()

    assert provider.unlike_calls == []
    success, _title, message, _kind = fb.last
    assert success is False
    assert "still liked" in message


@pytest.mark.asyncio
async def test_an_unknown_prior_playlist_state_is_left_alone() -> None:
    provider = UndoProvider(membership_raises=RuntimeError("timeout"))
    fb, clock = Feedback(), Clock()
    pipe = _pipe(
        provider, fb, clock, like_destination=LikeDestination(PLAYLIST, "Liked songs")
    )

    await pipe.run_once()
    await pipe.undo_last()

    assert provider.remove_calls == []
    assert fb.last[0] is False
    assert "still in Liked songs" in fb.last[2]


@pytest.mark.asyncio
async def test_a_provider_without_unlike_reports_the_like_stays() -> None:
    provider = NoUnlikeProvider()
    assert not isinstance(provider, UnlikeCapableProvider)
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock)

    await pipe.run_once()
    await pipe.undo_last()

    assert provider.liked == {"abc123"}
    assert fb.last[0] is False
    assert "still liked" in fb.last[2]


# ── AC5: an extension without a reverse is logged, not a failure ────────


@pytest.mark.asyncio
async def test_a_post_action_without_undo_is_logged_as_not_undoable(caplog) -> None:
    provider = UndoProvider()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock, post_like_actions=[LegacyAction()])

    await pipe.run_once()
    with caplog.at_level(logging.INFO, logger="like_spotify.core.pipeline"):
        await pipe.undo_last()

    assert any(
        "LegacyAction" in r.getMessage() and "not undoable" in r.getMessage()
        for r in caplog.records
    )
    assert fb.last[:2] == (True, "Undone")
    assert provider.liked == set()


@pytest.mark.asyncio
async def test_a_storage_without_undo_is_logged_as_not_undoable(caplog) -> None:
    provider = UndoProvider()
    storage = LegacyStorage()
    fb, clock = Feedback(), Clock()
    pipe = _pipe(provider, fb, clock, storage=storage)

    await pipe.run_once()
    with caplog.at_level(logging.INFO, logger="like_spotify.core.pipeline"):
        await pipe.undo_last()

    assert any(
        "LegacyStorage" in r.getMessage() and "not undoable" in r.getMessage()
        for r in caplog.records
    )
    assert storage.counts == {("user-id", "abc123"): 1}
    assert fb.last[:2] == (True, "Undone")
