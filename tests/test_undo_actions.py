"""Undo of the shipped post-like actions (#270).

Each action records in `ctx.extras` what its `run` changed, and `undo`
reverses exactly that for the same `ctx`. The pipeline side (order, window,
feedback) is in `tests/test_undo.py`; these drive one action at a time
against a provider fake that keeps the state an undo has to restore.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from like_spotify.core.storage import Storage
from like_spotify.core.types import CurrentTrack, LikeContext
from like_spotify.extensions.archive_remove import ArchiveRemoveAction
from like_spotify.extensions.follow_artist import FollowArtistAction
from like_spotify.extensions.google_sheets_storage import GoogleSheetsStorage
from like_spotify.extensions.like_cooldown import build_like_cooldown
from like_spotify.extensions.promote_to_best import PromoteToBestAction
from tests.test_storage_contract import SheetsSim


class Provider:
    """Playlists and follows as a service holds them; every call recorded."""

    def __init__(
        self,
        playlists: dict[str, set[str]] | None = None,
        following: set[str] | None = None,
        probe_raises: Exception | None = None,
        unfollow_raises: Exception | None = None,
        add_raises: Exception | None = None,
    ) -> None:
        self.playlists = {k: set(v) for k, v in (playlists or {}).items()}
        self.following = set(following or ())
        self._probe_raises = probe_raises
        self._unfollow_raises = unfollow_raises
        self._add_raises = add_raises
        self.calls: list[tuple] = []

    async def user_id(self) -> str:
        return "user-1"

    async def find_playlist_by_name(self, name: str) -> str | None:
        return name if name in self.playlists else None

    async def find_or_create_playlist(self, name: str) -> str:
        self.playlists.setdefault(name, set())
        return name

    async def get_playlist_track_ids(self, playlist_id: str) -> set[str]:
        return set(self.playlists[playlist_id])

    async def add_track_to_playlist(self, track_id: str, playlist_id: str) -> None:
        self.calls.append(("add", track_id, playlist_id))
        if self._add_raises is not None:
            raise self._add_raises
        self.playlists[playlist_id].add(track_id)

    async def remove_track_from_playlist(self, track_id: str, playlist_id: str) -> None:
        self.calls.append(("remove", track_id, playlist_id))
        self.playlists[playlist_id].discard(track_id)

    async def follow_artist(self, artist_id: str) -> None:
        self.calls.append(("follow", artist_id))
        self.following.add(artist_id)

    async def is_following_artist(self, artist_id: str) -> bool:
        if self._probe_raises is not None:
            raise self._probe_raises
        return artist_id in self.following

    async def unfollow_artist(self, artist_id: str) -> None:
        self.calls.append(("unfollow", artist_id))
        if self._unfollow_raises is not None:
            raise self._unfollow_raises
        self.following.discard(artist_id)


class FollowOnlyProvider(Provider):
    """A provider that follows but cannot read or reverse a follow."""

    is_following_artist = None  # type: ignore[assignment]
    unfollow_artist = None  # type: ignore[assignment]


class LegacyArtistStorage(Storage):
    """A storage written before #283: it records, but has no undo for it."""

    def __init__(self, count: int, record_raises: Exception | None = None) -> None:
        self._count = count
        self._record_raises = record_raises

    async def increment(self, user_id, track, was_already_liked=False) -> int:
        return 1

    async def get_count(self, user_id, track) -> int:
        return 0

    async def record_artist_track(self, user_id, artist_id, track_id) -> int:
        if self._record_raises is not None:
            raise self._record_raises
        return self._count


class ArtistStorage(LegacyArtistStorage):
    """A constant count, with every undo of a record kept."""

    def __init__(
        self,
        count: int,
        record_raises: Exception | None = None,
        undo_raises: Exception | None = None,
    ) -> None:
        super().__init__(count, record_raises)
        self._undo_raises = undo_raises
        self.undone: list[tuple[str, str, str]] = []

    async def undo_record_artist_track(self, user_id, artist_id, track_id) -> int:
        self.undone.append((user_id, artist_id, track_id))
        if self._undo_raises is not None:
            raise self._undo_raises
        return self._count


@pytest.fixture
def shared_sheet(monkeypatch):
    """A GoogleSheetsStorage factory over one simulated spreadsheet: each
    call is a fresh instance (a restart, another device) on the same tabs."""
    sim = SheetsSim()
    for verb in ("get", "post", "put"):
        monkeypatch.setattr(
            f"like_spotify.extensions.google_sheets_storage.requests.{verb}",
            getattr(sim, f"handle_{verb}"),
        )
    return lambda: GoogleSheetsStorage(spreadsheet_id="s", token_provider=lambda: "tok")


def _ctx(
    provider: Provider,
    track_id: str = "trk-a",
    count: int | None = None,
    artist_ids: tuple[str, ...] = ("art1",),
) -> LikeContext:
    track = CurrentTrack(
        provider="spotify",
        provider_track_id=track_id,
        title="t",
        artists=("Artist",),
        artist_ids=artist_ids,
    )
    ctx = LikeContext(track=track, music_provider=provider)
    ctx.like_count = count
    return ctx


# ── Archive remove ───────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_archive_undo_puts_the_removed_track_back() -> None:
    provider = Provider(playlists={"Archive": {"trk-a", "trk-b"}})
    action = ArchiveRemoveAction("Archive")
    ctx = _ctx(provider)
    await action.run(ctx)
    assert provider.playlists["Archive"] == {"trk-b"}

    await action.undo(ctx)

    assert provider.playlists["Archive"] == {"trk-a", "trk-b"}
    # The action's own snapshot is back too: the next like removes it again.
    again = _ctx(provider)
    await action.run(again)
    assert provider.playlists["Archive"] == {"trk-b"}


@pytest.mark.asyncio
async def test_archive_undo_adds_nothing_the_press_did_not_remove() -> None:
    provider = Provider(playlists={"Archive": {"trk-b"}})
    action = ArchiveRemoveAction("Archive")
    ctx = _ctx(provider)
    await action.run(ctx)

    await action.undo(ctx)

    assert provider.calls == []
    assert provider.playlists["Archive"] == {"trk-b"}


# ── Promote to best ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_promote_undo_takes_the_track_out_and_forgets_it(tmp_path: Path) -> None:
    provider = Provider()
    action = PromoteToBestAction("Best", threshold=3, promoted_path=tmp_path / "p.json")
    ctx = _ctx(provider, count=3)
    await action.run(ctx)
    assert provider.playlists["Best"] == {"trk-a"}

    await action.undo(ctx)

    assert provider.playlists["Best"] == set()
    # Forgotten, so the next like at the threshold promotes it again.
    await action.run(_ctx(provider, count=3))
    assert provider.playlists["Best"] == {"trk-a"}


@pytest.mark.asyncio
async def test_promote_undo_leaves_a_track_that_was_already_there(
    tmp_path: Path,
) -> None:
    provider = Provider(playlists={"Best": {"trk-a"}})
    action = PromoteToBestAction("Best", threshold=3, promoted_path=tmp_path / "p.json")
    ctx = _ctx(provider, count=3)
    await action.run(ctx)

    await action.undo(ctx)

    assert ("remove", "trk-a", "Best") not in provider.calls
    assert provider.playlists["Best"] == {"trk-a"}


@pytest.mark.asyncio
async def test_promote_undo_never_reaches_an_older_promotion(tmp_path: Path) -> None:
    provider = Provider()
    action = PromoteToBestAction("Best", threshold=3, promoted_path=tmp_path / "p.json")
    await action.run(_ctx(provider, count=3))
    later = _ctx(provider, count=4)
    await action.run(later)

    await action.undo(later)

    assert provider.playlists["Best"] == {"trk-a"}


@pytest.mark.asyncio
async def test_promote_undo_after_a_failed_add_does_nothing(tmp_path: Path) -> None:
    provider = Provider(add_raises=RuntimeError("503"))
    action = PromoteToBestAction("Best", threshold=3, promoted_path=tmp_path / "p.json")
    ctx = _ctx(provider, count=3)
    await action.run(ctx)

    await action.undo(ctx)

    assert [c for c in provider.calls if c[0] == "remove"] == []


# ── Follow artist ────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_follow_undo_unfollows_an_artist_this_press_followed(
    tmp_path: Path,
) -> None:
    provider = Provider()
    action = FollowArtistAction(
        ArtistStorage(count=5), threshold=5, followed_path=tmp_path / "f.json"
    )
    ctx = _ctx(provider)
    await action.run(ctx)
    assert provider.following == {"art1"}

    await action.undo(ctx)

    assert provider.following == set()
    # Forgotten, so the next like past the threshold follows again.
    await action.run(_ctx(provider))
    assert provider.following == {"art1"}


@pytest.mark.asyncio
async def test_already_followed_artist_stays_followed(tmp_path: Path) -> None:
    provider = Provider(following={"art1"})
    action = FollowArtistAction(
        ArtistStorage(count=5), threshold=5, followed_path=tmp_path / "f.json"
    )
    ctx = _ctx(provider)
    await action.run(ctx)

    await action.undo(ctx)

    assert ("unfollow", "art1") not in provider.calls
    assert provider.following == {"art1"}


@pytest.mark.asyncio
async def test_follow_undo_reverses_only_the_artists_it_followed(
    tmp_path: Path,
) -> None:
    provider = Provider(following={"art2"})
    action = FollowArtistAction(
        ArtistStorage(count=5), threshold=5, followed_path=tmp_path / "f.json"
    )
    ctx = _ctx(provider, artist_ids=("art1", "art2"))
    await action.run(ctx)

    await action.undo(ctx)

    assert provider.following == {"art2"}


@pytest.mark.asyncio
async def test_follow_undo_reports_an_artist_it_could_not_tell_about(
    tmp_path: Path,
) -> None:
    """The probe failed, so the follow went ahead blind: undo must not
    guess the artist was new, and must say it stays followed."""
    provider = Provider(probe_raises=RuntimeError("503"))
    action = FollowArtistAction(
        ArtistStorage(count=5), threshold=5, followed_path=tmp_path / "f.json"
    )
    ctx = _ctx(provider)
    await action.run(ctx)
    assert provider.following == {"art1"}

    with pytest.raises(RuntimeError, match="art1"):
        await action.undo(ctx)

    assert provider.following == {"art1"}
    assert ("unfollow", "art1") not in provider.calls


@pytest.mark.asyncio
async def test_failed_unfollow_raises_and_the_other_artist_is_still_undone(
    tmp_path: Path,
) -> None:
    provider = Provider(unfollow_raises=RuntimeError("503"))
    action = FollowArtistAction(
        ArtistStorage(count=5), threshold=5, followed_path=tmp_path / "f.json"
    )
    ctx = _ctx(provider, artist_ids=("art1", "art2"))
    await action.run(ctx)

    with pytest.raises(RuntimeError, match="art1.*art2"):
        await action.undo(ctx)

    assert [c for c in provider.calls if c[0] == "unfollow"] == [
        ("unfollow", "art1"),
        ("unfollow", "art2"),
    ]


@pytest.mark.asyncio
async def test_follow_on_a_provider_that_cannot_unfollow_is_not_undoable(
    tmp_path: Path, caplog
) -> None:
    provider = FollowOnlyProvider()
    action = FollowArtistAction(
        ArtistStorage(count=5), threshold=5, followed_path=tmp_path / "f.json"
    )
    ctx = _ctx(provider)
    await action.run(ctx)
    assert provider.following == {"art1"}

    with pytest.raises(NotImplementedError, match="unfollow"):
        await action.undo(ctx)


@pytest.mark.asyncio
async def test_follow_undo_with_no_follow_this_press_only_reverses_the_record(
    tmp_path: Path,
) -> None:
    """Below the threshold nothing was followed; the undo still reverses
    the record the press made, and touches the provider not at all."""
    provider = Provider()
    storage = ArtistStorage(count=1)
    action = FollowArtistAction(storage, threshold=5, followed_path=tmp_path / "f.json")
    ctx = _ctx(provider, artist_ids=("art1", "art2"))
    await action.run(ctx)

    await action.undo(ctx)

    assert provider.calls == []
    assert storage.undone == [
        ("user-1", "art1", "trk-a"),
        ("user-1", "art2", "trk-a"),
    ]


# ── Follow artist: the artist-track record (#283) ────────────────────────


@pytest.mark.asyncio
async def test_undone_follow_takes_the_track_back_off_the_artist_record(
    tmp_path: Path, shared_sheet
) -> None:
    """The press that crossed the threshold is undone: the artist's count
    on the sheet reads what it read before, so liking a track that was
    already counted does not follow the artist again."""
    provider = Provider()
    action = FollowArtistAction(
        shared_sheet(), threshold=2, followed_path=tmp_path / "f.json"
    )
    await action.run(_ctx(provider, track_id="trk-a"))
    crossing = _ctx(provider, track_id="trk-b")
    await action.run(crossing)
    assert provider.following == {"art1"}

    await action.undo(crossing)

    assert provider.following == set()
    # Another instance reads the sheet afresh: trk-a alone is counted.
    assert await shared_sheet().record_artist_track("user-1", "art1", "trk-a") == 1
    await action.run(_ctx(provider, track_id="trk-a"))
    assert provider.following == set()
    assert [c for c in provider.calls if c[0] == "follow"] == [("follow", "art1")]


@pytest.mark.asyncio
async def test_undo_of_a_like_that_counted_nothing_keeps_the_record(
    tmp_path: Path, shared_sheet
) -> None:
    """The re-like found trk-a already counted; undoing it must not take
    off the count the first like made."""
    provider = Provider()
    action = FollowArtistAction(
        shared_sheet(), threshold=5, followed_path=tmp_path / "f.json"
    )
    await action.run(_ctx(provider, track_id="trk-a"))
    relike = _ctx(provider, track_id="trk-a")
    await action.run(relike)

    await action.undo(relike)

    assert await shared_sheet().record_artist_track("user-1", "art1", "trk-b") == 2


@pytest.mark.asyncio
async def test_undo_takes_a_newly_counted_track_off_below_the_threshold(
    tmp_path: Path, shared_sheet
) -> None:
    """No follow this press, but the count still moved: left counted, the
    undone like would bring the next follow one real track early."""
    provider = Provider()
    action = FollowArtistAction(
        shared_sheet(), threshold=5, followed_path=tmp_path / "f.json"
    )
    ctx = _ctx(provider, track_id="trk-a")
    await action.run(ctx)

    await action.undo(ctx)

    assert await shared_sheet().record_artist_track("user-1", "art1", "trk-b") == 1


@pytest.mark.asyncio
async def test_undo_skips_the_record_of_an_artist_whose_record_failed(
    tmp_path: Path,
) -> None:
    provider = Provider()
    storage = ArtistStorage(count=1, record_raises=RuntimeError("sheet 503"))
    action = FollowArtistAction(storage, threshold=5, followed_path=tmp_path / "f.json")
    ctx = _ctx(provider)
    await action.run(ctx)

    await action.undo(ctx)

    assert storage.undone == []


@pytest.mark.asyncio
async def test_follow_undo_on_a_storage_without_record_undo_still_unfollows(
    tmp_path: Path,
) -> None:
    """A storage from before #283 cannot take the track off: the unfollow
    still happens, and the undo says the record stayed."""
    provider = Provider()
    action = FollowArtistAction(
        LegacyArtistStorage(count=5), threshold=5, followed_path=tmp_path / "f.json"
    )
    ctx = _ctx(provider)
    await action.run(ctx)

    with pytest.raises(
        NotImplementedError,
        match="LegacyArtistStorage cannot reverse an artist-track record; art1",
    ):
        await action.undo(ctx)

    assert provider.following == set()


@pytest.mark.asyncio
async def test_failed_record_undo_raises_and_the_unfollow_is_still_done(
    tmp_path: Path,
) -> None:
    provider = Provider()
    storage = ArtistStorage(count=5, undo_raises=RuntimeError("sheet 503"))
    action = FollowArtistAction(storage, threshold=5, followed_path=tmp_path / "f.json")
    ctx = _ctx(provider, artist_ids=("art1", "art2"))
    await action.run(ctx)

    with pytest.raises(
        RuntimeError,
        match=r"art1: artist-track record not restored \(sheet 503\); "
        r"art2: artist-track record not restored",
    ):
        await action.undo(ctx)

    assert provider.following == set()
    assert len(storage.undone) == 2


@pytest.mark.asyncio
async def test_failed_record_undo_still_names_a_follow_it_could_not_reverse(
    tmp_path: Path,
) -> None:
    """Two legs, two reports: a failed record undo must not hide that the
    provider left the artist followed."""
    provider = FollowOnlyProvider()
    storage = ArtistStorage(count=5, undo_raises=RuntimeError("sheet 503"))
    action = FollowArtistAction(storage, threshold=5, followed_path=tmp_path / "f.json")
    ctx = _ctx(provider)
    await action.run(ctx)

    with pytest.raises(
        RuntimeError,
        match=r"art1: artist-track record not restored \(sheet 503\); "
        r"FollowOnlyProvider cannot unfollow; art1 left followed",
    ):
        await action.undo(ctx)


# ── like_cooldown (#270) ───────────────────────────────────────────────


def _cooldown_ctx(track_id: str = "trk-a") -> LikeContext:
    return LikeContext(
        track=CurrentTrack(
            provider="spotify", provider_track_id=track_id, title="t", artists=("A",)
        )
    )


@pytest.mark.asyncio
async def test_cooldown_undo_lets_the_track_be_liked_again(tmp_path: Path) -> None:
    """An undone like must not leave the track in its cooldown: the user
    who undoes and presses again gets a like, not "Skipped"."""
    gate, recorder = build_like_cooldown(tmp_path / "c.json")
    ctx = _cooldown_ctx()
    await recorder.run(ctx)
    assert await gate.run(_cooldown_ctx()) is False

    await recorder.undo(ctx)

    assert await gate.run(_cooldown_ctx()) is True


@pytest.mark.asyncio
async def test_cooldown_undo_restores_the_stamp_the_press_replaced(
    tmp_path: Path, monkeypatch
) -> None:
    import like_spotify.extensions.like_cooldown as mod

    gate, recorder = build_like_cooldown(tmp_path / "c.json")
    now = [1_000.0]
    monkeypatch.setattr(mod.time, "time", lambda: now[0])
    await recorder.run(_cooldown_ctx())  # an older like, 11 min ago
    now[0] += 11 * 60
    ctx = _cooldown_ctx()
    await recorder.run(ctx)

    await recorder.undo(ctx)

    state = (tmp_path / "c.json").read_text(encoding="utf-8")
    assert state == '{"trk-a": 1000.0}'


@pytest.mark.asyncio
async def test_cooldown_undo_never_reaches_an_older_like(tmp_path: Path) -> None:
    gate, recorder = build_like_cooldown(tmp_path / "c.json")
    await recorder.run(_cooldown_ctx("trk-old"))
    ctx = _cooldown_ctx("trk-new")
    await recorder.run(ctx)

    await recorder.undo(ctx)

    assert await gate.run(_cooldown_ctx("trk-old")) is False  # still cooling down
    assert await gate.run(_cooldown_ctx("trk-new")) is True


@pytest.mark.asyncio
async def test_cooldown_undo_with_no_record_this_press_is_quiet(tmp_path: Path) -> None:
    gate, recorder = build_like_cooldown(tmp_path / "c.json")
    await recorder.run(_cooldown_ctx())

    await recorder.undo(_cooldown_ctx())  # a press that recorded nothing

    assert await gate.run(_cooldown_ctx()) is False
