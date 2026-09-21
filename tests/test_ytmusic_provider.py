"""YouTubeMusicProvider — search resolution, like/dislike/is_liked, errors,
user id.

HTTP is faked at the `requests` boundary and now-playing is injected, so
nothing here needs winrt, a browser, or a Google project.
"""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any

import pytest

from like_spotify.core.errors import AuthError, RateLimited
from like_spotify.extensions import ytmusic
from like_spotify.extensions.ytmusic import NowPlaying, YouTubeMusicProvider


@dataclass
class FakeResponse:
    status_code: int
    json_body: Any = None
    text: str = ""
    headers: dict[str, str] | None = None

    def __post_init__(self) -> None:
        if self.headers is None:
            self.headers = {}

    def json(self) -> Any:
        return self.json_body


def _reader(np: NowPlaying | None):
    async def read() -> NowPlaying | None:
        return np

    return read


def _provider(tmp_path, np: NowPlaying | None = None) -> YouTubeMusicProvider:
    p = YouTubeMusicProvider(token_path=tmp_path / "yt.json", now_playing=_reader(np))
    p._token_provider = lambda: "test-token"  # skip OAuth refresh
    return p


def _search_items(*pairs: tuple[str, str]) -> dict:
    return {
        "items": [
            {"id": {"videoId": vid}, "snippet": {"channelTitle": ch}}
            for vid, ch in pairs
        ]
    }


# ── get_currently_playing ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_nothing_playing_returns_none_without_searching(
    monkeypatch, tmp_path
) -> None:
    def boom(*_a, **_kw):
        raise AssertionError("must not search when nothing plays")

    monkeypatch.setattr(ytmusic.requests, "get", boom)
    assert await _provider(tmp_path, None).get_currently_playing() is None


@pytest.mark.asyncio
async def test_prefers_topic_art_track_over_top_hit(monkeypatch, tmp_path) -> None:
    captured: dict[str, Any] = {}

    def fake_get(url, headers=None, params=None, timeout=None):
        captured["url"] = url
        captured["params"] = params
        return FakeResponse(
            200,
            _search_items(
                ("mv", "Daft Punk VEVO"),
                ("art", "Daft Punk - Topic"),
            ),
        )

    monkeypatch.setattr(ytmusic.requests, "get", fake_get)
    np = NowPlaying(title="One More Time", artist="Daft Punk", album="Discovery")
    track = await _provider(tmp_path, np).get_currently_playing()

    assert track is not None
    assert track.provider == "ytmusic"
    assert track.provider_track_id == "art"
    assert track.artists == ("Daft Punk",)
    assert track.album == "Discovery"
    assert captured["url"].endswith("/search")
    assert captured["params"]["q"] == "Daft Punk One More Time"
    assert captured["params"]["videoCategoryId"] == "10"


@pytest.mark.asyncio
async def test_strips_topic_suffix_and_falls_back_to_artist_channel(
    monkeypatch, tmp_path
) -> None:
    captured: dict[str, Any] = {}

    def fake_get(url, headers=None, params=None, timeout=None):
        captured["q"] = params["q"]
        return FakeResponse(
            200, _search_items(("cover", "Someone Else"), ("own", "Björk"))
        )

    monkeypatch.setattr(ytmusic.requests, "get", fake_get)
    np = NowPlaying(title="Army of Me", artist="Björk - Topic")
    track = await _provider(tmp_path, np).get_currently_playing()

    assert captured["q"] == "Björk Army of Me"
    assert track is not None and track.provider_track_id == "own"


@pytest.mark.asyncio
async def test_resolution_is_cached_per_song(monkeypatch, tmp_path) -> None:
    calls = {"n": 0}

    def fake_get(url, headers=None, params=None, timeout=None):
        calls["n"] += 1
        return FakeResponse(200, _search_items(("v1", "x")))

    monkeypatch.setattr(ytmusic.requests, "get", fake_get)
    p = _provider(tmp_path, NowPlaying(title="Song", artist="Artist"))
    await p.get_currently_playing()
    await p.get_currently_playing()
    assert calls["n"] == 1  # 100 quota units saved on the repeat press


@pytest.mark.asyncio
async def test_no_search_hits_means_nothing_to_like(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(
        ytmusic.requests, "get", lambda *a, **kw: FakeResponse(200, {"items": []})
    )
    p = _provider(tmp_path, NowPlaying(title="Obscure", artist="Nobody"))
    assert await p.get_currently_playing() is None


# ── like / is_liked ────────────────────────────────────────────────────


def _track(video_id: str = "vid1"):
    from like_spotify.core.types import CurrentTrack

    return CurrentTrack(
        provider="ytmusic", provider_track_id=video_id, title="t", artists=("a",)
    )


@pytest.mark.asyncio
async def test_like_rates_the_video(monkeypatch, tmp_path) -> None:
    captured: dict[str, Any] = {}

    def fake_post(url, headers=None, params=None, timeout=None):
        captured["url"] = url
        captured["params"] = params
        captured["auth"] = headers["Authorization"]
        return FakeResponse(204)

    monkeypatch.setattr(ytmusic.requests, "post", fake_post)
    await _provider(tmp_path).like(_track("abc"))

    assert captured["url"].endswith("/videos/rate")
    assert captured["params"] == {"id": "abc", "rating": "like"}
    assert captured["auth"] == "Bearer test-token"


@pytest.mark.asyncio
async def test_dislike_rates_the_video_down(monkeypatch, tmp_path) -> None:
    """A real thumbs-down, not a library removal: YouTube’s `videos.rate`
    takes `dislike` as a first-class rating (#172)."""
    captured: dict[str, Any] = {}

    def fake_post(url, headers=None, params=None, timeout=None):
        captured["url"] = url
        captured["params"] = params
        return FakeResponse(204)

    monkeypatch.setattr(ytmusic.requests, "post", fake_post)
    await _provider(tmp_path).dislike(_track("abc"))

    assert captured["url"].endswith("/videos/rate")
    assert captured["params"] == {"id": "abc", "rating": "dislike"}


@pytest.mark.asyncio
@pytest.mark.parametrize("rating,expected", [("like", True), ("none", False)])
async def test_is_liked_reads_rating(monkeypatch, tmp_path, rating, expected) -> None:
    monkeypatch.setattr(
        ytmusic.requests,
        "get",
        lambda *a, **kw: FakeResponse(
            200, {"items": [{"videoId": "abc", "rating": rating}]}
        ),
    )
    assert await _provider(tmp_path).is_liked(_track("abc")) is expected


# ── Error mapping ──────────────────────────────────────────────────────


def _error(reason: str) -> dict:
    return {"error": {"code": 403, "errors": [{"reason": reason}]}}


@pytest.mark.asyncio
async def test_exhausted_quota_is_rate_limited_not_auth(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(
        ytmusic.requests,
        "post",
        lambda *a, **kw: FakeResponse(403, _error("quotaExceeded")),
    )
    with pytest.raises(RateLimited):
        await _provider(tmp_path).like(_track())


@pytest.mark.asyncio
async def test_dislike_surfaces_quota_exhaustion(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(
        ytmusic.requests,
        "post",
        lambda *a, **kw: FakeResponse(403, _error("quotaExceeded")),
    )
    with pytest.raises(RateLimited):
        await _provider(tmp_path).dislike(_track())


@pytest.mark.asyncio
async def test_other_403_is_auth_error(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(
        ytmusic.requests,
        "post",
        lambda *a, **kw: FakeResponse(403, _error("insufficientPermissions")),
    )
    with pytest.raises(AuthError):
        await _provider(tmp_path).like(_track())


# ── user_id / has_tokens ───────────────────────────────────────────────


def _id_token(claims: dict) -> str:
    def seg(obj: dict) -> str:
        raw = base64.urlsafe_b64encode(json.dumps(obj).encode()).decode()
        return raw.rstrip("=")

    return f"{seg({'alg': 'RS256'})}.{seg(claims)}.sig"


@pytest.mark.asyncio
async def test_user_id_is_id_token_sub(tmp_path) -> None:
    token_path = tmp_path / "yt.json"
    token_path.write_text(
        json.dumps({"refresh_token": "rt", "id_token": _id_token({"sub": "1234"})}),
        encoding="utf-8",
    )
    p = YouTubeMusicProvider(token_path=token_path, now_playing=_reader(None))
    assert p.has_tokens
    assert await p.user_id() == "1234"


@pytest.mark.asyncio
async def test_user_id_without_id_token_asks_for_reauth(tmp_path) -> None:
    p = YouTubeMusicProvider(token_path=tmp_path / "none.json", now_playing=_reader(None))
    assert not p.has_tokens
    with pytest.raises(AuthError):
        await p.user_id()


# ── Artist channel resolution (#99) ────────────────────────────────────


def _search_items_with_channels(*triples: tuple[str, str, str]) -> dict:
    return {
        "items": [
            {"id": {"videoId": vid}, "snippet": {"channelId": cid, "channelTitle": ch}}
            for vid, cid, ch in triples
        ]
    }


@pytest.mark.asyncio
async def test_topic_match_carries_topic_channel_as_artist_id(
    monkeypatch, tmp_path
) -> None:
    captured: dict[str, Any] = {}

    def fake_get(url, headers=None, params=None, timeout=None):
        captured["fields"] = params["fields"]
        return FakeResponse(
            200,
            _search_items_with_channels(
                ("mv", "UCvevo", "Daft Punk VEVO"),
                ("art", "UCtopic", "Daft Punk - Topic"),
            ),
        )

    monkeypatch.setattr(ytmusic.requests, "get", fake_get)
    np = NowPlaying(title="One More Time", artist="Daft Punk")
    track = await _provider(tmp_path, np).get_currently_playing()

    assert track is not None
    assert track.provider_track_id == "art"
    assert track.artist_ids == ("UCtopic",)
    assert "snippet/channelId" in captured["fields"]


@pytest.mark.asyncio
async def test_artist_own_channel_match_carries_its_channel(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setattr(
        ytmusic.requests,
        "get",
        lambda *a, **kw: FakeResponse(
            200,
            _search_items_with_channels(
                ("cover", "UCother", "Someone Else"), ("own", "UCbjork", "Björk")
            ),
        ),
    )
    np = NowPlaying(title="Army of Me", artist="Björk")
    track = await _provider(tmp_path, np).get_currently_playing()
    assert track is not None and track.artist_ids == ("UCbjork",)


@pytest.mark.asyncio
async def test_top_hit_fallback_has_no_artist_id(monkeypatch, tmp_path) -> None:
    """An unrelated uploader must never become the channel follow-artist
    subscribes to."""
    monkeypatch.setattr(
        ytmusic.requests,
        "get",
        lambda *a, **kw: FakeResponse(
            200, _search_items_with_channels(("cover", "UCstranger", "Cover Guy"))
        ),
    )
    np = NowPlaying(title="Song", artist="Artist")
    track = await _provider(tmp_path, np).get_currently_playing()
    assert track is not None
    assert track.provider_track_id == "cover"
    assert track.artist_ids == ()


# ── PlaylistCapableProvider (#99) ──────────────────────────────────────


class FakeHttp:
    """Routes `requests.get/post/delete` by (method, endpoint) to a queue of
    canned responses and records every call."""

    def __init__(
        self, monkeypatch, routes: dict[tuple[str, str], list[FakeResponse]]
    ) -> None:
        self.routes = {k: list(v) for k, v in routes.items()}
        self.calls: list[dict[str, Any]] = []
        for method in ("get", "post", "delete"):
            monkeypatch.setattr(ytmusic.requests, method, self._handler(method.upper()))

    def _handler(self, method: str):
        def handle(url, headers=None, params=None, json=None, timeout=None):
            endpoint = url.rsplit("/v3/", 1)[1]
            self.calls.append(
                {"method": method, "endpoint": endpoint, "params": params, "json": json}
            )
            queue = self.routes.get((method, endpoint))
            if not queue:
                raise AssertionError(f"unexpected {method} {endpoint} {params}")
            return queue.pop(0)

        return handle

    def of(self, method: str, endpoint: str) -> list[dict[str, Any]]:
        return [
            c for c in self.calls if c["method"] == method and c["endpoint"] == endpoint
        ]


def _playlists_page(*pairs: tuple[str, str], next_token: str | None = None) -> dict:
    body: dict[str, Any] = {
        "items": [{"id": pid, "snippet": {"title": title}} for pid, title in pairs]
    }
    if next_token:
        body["nextPageToken"] = next_token
    return body


def _items_page(*pairs: tuple[str, str], next_token: str | None = None) -> dict:
    body: dict[str, Any] = {
        "items": [
            {"id": item_id, "contentDetails": {"videoId": vid}} for item_id, vid in pairs
        ]
    }
    if next_token:
        body["nextPageToken"] = next_token
    return body


def test_youtube_provider_satisfies_playlist_capability(tmp_path) -> None:
    from like_spotify.core.music_provider import PlaylistCapableProvider

    assert isinstance(_provider(tmp_path), PlaylistCapableProvider)


def test_scope_is_full_youtube_scope() -> None:
    """Playlist and subscription writes need `youtube`; `youtube.readonly`
    would 403 them."""
    assert "https://www.googleapis.com/auth/youtube" in ytmusic.SCOPE.split()


@pytest.mark.asyncio
async def test_find_playlist_by_name_pages_mine_and_matches_case_insensitively(
    monkeypatch, tmp_path
) -> None:
    http = FakeHttp(monkeypatch, {
        ("GET", "playlists"): [
            FakeResponse(200, _playlists_page(("p1", "Chill"), next_token="T2")),
            FakeResponse(200, _playlists_page(("p2", "  discover ARCHIVE "))),
        ],
    })
    pid = await _provider(tmp_path).find_playlist_by_name("Discover Archive")

    assert pid == "p2"
    calls = http.of("GET", "playlists")
    assert calls[0]["params"]["mine"] == "true"
    assert "pageToken" not in calls[0]["params"]
    assert calls[1]["params"]["pageToken"] == "T2"


@pytest.mark.asyncio
async def test_find_playlist_by_name_not_found_returns_none(
    monkeypatch, tmp_path
) -> None:
    FakeHttp(monkeypatch, {
        ("GET", "playlists"): [FakeResponse(200, _playlists_page(("p1", "Chill")))],
    })
    assert await _provider(tmp_path).find_playlist_by_name("Archive") is None


@pytest.mark.asyncio
async def test_find_or_create_playlist_reuses_existing(monkeypatch, tmp_path) -> None:
    http = FakeHttp(monkeypatch, {
        ("GET", "playlists"): [FakeResponse(200, _playlists_page(("p1", "Best")))],
    })
    assert await _provider(tmp_path).find_or_create_playlist("Best") == "p1"
    assert http.of("POST", "playlists") == []


@pytest.mark.asyncio
async def test_find_or_create_playlist_creates_private_when_missing(
    monkeypatch, tmp_path
) -> None:
    http = FakeHttp(monkeypatch, {
        ("GET", "playlists"): [FakeResponse(200, _playlists_page())],
        ("POST", "playlists"): [FakeResponse(200, {"id": "new"})],
    })
    assert await _provider(tmp_path).find_or_create_playlist("Best") == "new"

    (create,) = http.of("POST", "playlists")
    assert create["params"] == {"part": "snippet,status"}
    assert create["json"]["snippet"]["title"] == "Best"
    assert create["json"]["status"] == {"privacyStatus": "private"}


@pytest.mark.asyncio
async def test_get_playlist_track_ids_pages_through_items(
    monkeypatch, tmp_path
) -> None:
    http = FakeHttp(monkeypatch, {
        ("GET", "playlistItems"): [
            FakeResponse(200, _items_page(("i1", "v1"), ("i2", "v2"), next_token="N")),
            FakeResponse(200, _items_page(("i3", "v3"))),
        ],
    })
    ids = await _provider(tmp_path).get_playlist_track_ids("pl")

    assert ids == {"v1", "v2", "v3"}
    calls = http.of("GET", "playlistItems")
    assert calls[0]["params"]["playlistId"] == "pl"
    assert calls[1]["params"]["pageToken"] == "N"


@pytest.mark.asyncio
async def test_add_track_to_playlist_inserts_video(monkeypatch, tmp_path) -> None:
    http = FakeHttp(monkeypatch, {
        ("POST", "playlistItems"): [FakeResponse(200, {"id": "item"})],
    })
    await _provider(tmp_path).add_track_to_playlist("vid", "pl")

    (insert,) = http.of("POST", "playlistItems")
    assert insert["params"] == {"part": "snippet"}
    assert insert["json"] == {
        "snippet": {
            "playlistId": "pl",
            "resourceId": {"kind": "youtube#video", "videoId": "vid"},
        }
    }


@pytest.mark.asyncio
async def test_remove_track_deletes_every_matching_playlist_item(
    monkeypatch, tmp_path
) -> None:
    http = FakeHttp(monkeypatch, {
        ("GET", "playlistItems"): [
            FakeResponse(
                200, _items_page(("i1", "vid"), ("i2", "other"), ("i3", "vid"))
            ),
        ],
        ("DELETE", "playlistItems"): [FakeResponse(204), FakeResponse(204)],
    })
    await _provider(tmp_path).remove_track_from_playlist("vid", "pl")

    assert [c["params"] for c in http.of("DELETE", "playlistItems")] == [
        {"id": "i1"},
        {"id": "i3"},
    ]


@pytest.mark.asyncio
async def test_remove_track_absent_from_playlist_issues_no_delete(
    monkeypatch, tmp_path
) -> None:
    http = FakeHttp(monkeypatch, {
        ("GET", "playlistItems"): [FakeResponse(200, _items_page(("i1", "other")))],
    })
    await _provider(tmp_path).remove_track_from_playlist("vid", "pl")
    assert http.of("DELETE", "playlistItems") == []


@pytest.mark.asyncio
async def test_remove_track_already_deleted_item_is_not_an_error(
    monkeypatch, tmp_path
) -> None:
    FakeHttp(monkeypatch, {
        ("GET", "playlistItems"): [FakeResponse(200, _items_page(("i1", "vid")))],
        ("DELETE", "playlistItems"): [
            FakeResponse(404, _error("playlistItemNotFound"))
        ],
    })
    await _provider(tmp_path).remove_track_from_playlist("vid", "pl")


@pytest.mark.asyncio
async def test_follow_artist_subscribes_to_channel(monkeypatch, tmp_path) -> None:
    http = FakeHttp(monkeypatch, {
        ("POST", "subscriptions"): [FakeResponse(200, {"id": "sub"})],
    })
    await _provider(tmp_path).follow_artist("UCartist")

    (sub,) = http.of("POST", "subscriptions")
    assert sub["params"] == {"part": "snippet"}
    assert sub["json"] == {
        "snippet": {"resourceId": {"kind": "youtube#channel", "channelId": "UCartist"}}
    }


def _error_400(reason: str) -> dict:
    return {"error": {"code": 400, "errors": [{"reason": reason}]}}


@pytest.mark.asyncio
async def test_follow_artist_already_subscribed_is_not_an_error(
    monkeypatch, tmp_path
) -> None:
    FakeHttp(monkeypatch, {
        ("POST", "subscriptions"): [
            FakeResponse(400, _error_400("subscriptionDuplicate"))
        ],
    })
    await _provider(tmp_path).follow_artist("UCartist")


@pytest.mark.asyncio
async def test_follow_artist_other_400_raises(monkeypatch, tmp_path) -> None:
    FakeHttp(monkeypatch, {
        ("POST", "subscriptions"): [
            FakeResponse(400, _error_400("subscriptionForbidden"))
        ],
    })
    with pytest.raises(RuntimeError):
        await _provider(tmp_path).follow_artist("UCartist")


_PLAYLIST_CALLS = [
    ("find_playlist_by_name", ("Archive",), ("GET", "playlists")),
    ("find_or_create_playlist", ("Best",), ("GET", "playlists")),
    ("get_playlist_track_ids", ("pl",), ("GET", "playlistItems")),
    ("add_track_to_playlist", ("vid", "pl"), ("POST", "playlistItems")),
    ("remove_track_from_playlist", ("vid", "pl"), ("GET", "playlistItems")),
    ("follow_artist", ("UCartist",), ("POST", "subscriptions")),
]


@pytest.mark.asyncio
@pytest.mark.parametrize("reason", ["quotaExceeded", "rateLimitExceeded"])
@pytest.mark.parametrize("method,args,route", _PLAYLIST_CALLS)
async def test_playlist_methods_map_quota_403_to_rate_limited(
    monkeypatch, tmp_path, method, args, route, reason
) -> None:
    FakeHttp(monkeypatch, {route: [FakeResponse(403, _error(reason))]})
    with pytest.raises(RateLimited):
        await getattr(_provider(tmp_path), method)(*args)


@pytest.mark.asyncio
async def test_quota_403_on_the_delete_itself_is_rate_limited(
    monkeypatch, tmp_path
) -> None:
    FakeHttp(monkeypatch, {
        ("GET", "playlistItems"): [FakeResponse(200, _items_page(("i1", "vid")))],
        ("DELETE", "playlistItems"): [FakeResponse(403, _error("quotaExceeded"))],
    })
    with pytest.raises(RateLimited):
        await _provider(tmp_path).remove_track_from_playlist("vid", "pl")


@pytest.mark.asyncio
@pytest.mark.parametrize("method,args,route", _PLAYLIST_CALLS)
async def test_playlist_methods_map_other_403_to_auth_error(
    monkeypatch, tmp_path, method, args, route
) -> None:
    FakeHttp(
        monkeypatch, {route: [FakeResponse(403, _error("insufficientPermissions"))]}
    )
    with pytest.raises(AuthError):
        await getattr(_provider(tmp_path), method)(*args)


# ── The existing actions run against it unchanged (#99) ────────────────


def _yt_track(video_id: str = "vid", artist_ids: tuple[str, ...] = ("UCartist",)):
    from like_spotify.core.types import CurrentTrack

    return CurrentTrack(
        provider="ytmusic",
        provider_track_id=video_id,
        title="t",
        artists=("Artist",),
        artist_ids=artist_ids,
    )


@pytest.mark.asyncio
async def test_archive_remove_action_runs_against_youtube(
    monkeypatch, tmp_path
) -> None:
    from like_spotify.core.types import LikeContext
    from like_spotify.extensions.archive_remove import ArchiveRemoveAction

    http = FakeHttp(monkeypatch, {
        ("GET", "playlists"): [FakeResponse(200, _playlists_page(("pl", "Archive")))],
        ("GET", "playlistItems"): [
            FakeResponse(200, _items_page(("i1", "vid"))),  # action's snapshot
            FakeResponse(200, _items_page(("i1", "vid"))),  # remove's lookup
        ],
        ("DELETE", "playlistItems"): [FakeResponse(204)],
    })
    await ArchiveRemoveAction("Archive").run(
        LikeContext(track=_yt_track("vid"), music_provider=_provider(tmp_path))
    )
    assert [c["params"] for c in http.of("DELETE", "playlistItems")] == [{"id": "i1"}]


@pytest.mark.asyncio
async def test_archive_remove_action_missing_playlist_is_a_no_op(
    monkeypatch, tmp_path
) -> None:
    from like_spotify.core.types import LikeContext
    from like_spotify.extensions.archive_remove import ArchiveRemoveAction

    http = FakeHttp(monkeypatch, {
        ("GET", "playlists"): [FakeResponse(200, _playlists_page(("p1", "Chill")))],
    })
    await ArchiveRemoveAction("Archive").run(
        LikeContext(track=_yt_track("vid"), music_provider=_provider(tmp_path))
    )
    assert [c["endpoint"] for c in http.calls] == ["playlists"]


@pytest.mark.asyncio
async def test_promote_to_best_action_runs_against_youtube(
    monkeypatch, tmp_path
) -> None:
    from like_spotify.core.types import LikeContext
    from like_spotify.extensions.promote_to_best import PromoteToBestAction

    http = FakeHttp(monkeypatch, {
        ("GET", "playlists"): [FakeResponse(200, _playlists_page())],
        ("POST", "playlists"): [FakeResponse(200, {"id": "best"})],
        ("POST", "playlistItems"): [FakeResponse(200, {"id": "item"})],
    })
    await PromoteToBestAction("Best", threshold=3).run(
        LikeContext(
            track=_yt_track("vid"), like_count=3, music_provider=_provider(tmp_path)
        )
    )
    (insert,) = http.of("POST", "playlistItems")
    assert insert["json"]["snippet"]["playlistId"] == "best"
    assert insert["json"]["snippet"]["resourceId"]["videoId"] == "vid"


@pytest.mark.asyncio
async def test_follow_artist_action_subscribes_at_threshold(
    monkeypatch, tmp_path
) -> None:
    from like_spotify.core.storage import Storage
    from like_spotify.core.types import LikeContext
    from like_spotify.extensions.follow_artist import FollowArtistAction

    class CountingStorage(Storage):
        def __init__(self) -> None:
            self.seen: set[tuple[str, str, str]] = set()

        async def increment(self, user_id, track, was_already_liked=False) -> int:
            raise AssertionError("not used")  # pragma: no cover

        async def get_count(self, user_id, track) -> int:
            raise AssertionError("not used")  # pragma: no cover

        async def record_artist_track(self, user_id, artist_id, track_id) -> int:
            self.seen.add((user_id, artist_id, track_id))
            return sum(1 for u, a, _t in self.seen if (u, a) == (user_id, artist_id))

    token_path = tmp_path / "yt.json"
    token_path.write_text(
        json.dumps({"refresh_token": "rt", "id_token": _id_token({"sub": "g-1"})}),
        encoding="utf-8",
    )
    provider = YouTubeMusicProvider(token_path=token_path, now_playing=_reader(None))
    provider._token_provider = lambda: "test-token"
    http = FakeHttp(monkeypatch, {
        ("POST", "subscriptions"): [FakeResponse(200, {"id": "sub"})],
    })
    storage = CountingStorage()
    action = FollowArtistAction(storage=storage, threshold=2)

    await action.run(LikeContext(track=_yt_track("v1"), music_provider=provider))
    assert http.of("POST", "subscriptions") == []
    await action.run(LikeContext(track=_yt_track("v2"), music_provider=provider))

    (sub,) = http.of("POST", "subscriptions")
    assert sub["json"]["snippet"]["resourceId"]["channelId"] == "UCartist"
    assert {u for u, _a, _t in storage.seen} == {"g-1"}
