"""YouTubeMusicProvider — search resolution, like/is_liked, errors, user id.

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
