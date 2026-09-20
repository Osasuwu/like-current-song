"""Contract tests for SpotifyMusicProvider.

We don't re-test the OAuth flow here; just the library calls the pipeline
makes — `is_liked`, `like` and `follow_artist` — against the generic
`/me/library` endpoints and their entity-specific fallbacks (#121).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import pytest

from like_spotify.core.errors import RateLimited, TransientError
from like_spotify.core.types import CurrentTrack
from like_spotify.extensions.spotify import SpotifyMusicProvider


@dataclass
class FakeResponse:
    status_code: int
    text: str = ""
    json_body: Any = None
    headers: dict[str, str] | None = None

    def __post_init__(self) -> None:
        if self.headers is None:
            self.headers = {}

    def json(self) -> Any:
        return self.json_body


def _provider(tmp_path) -> SpotifyMusicProvider:
    """Build a provider with a primed access token to skip auth refresh."""
    import time

    token_path = tmp_path / "token.json"
    p = SpotifyMusicProvider(client_id="cid", token_path=token_path)
    # Inject a non-expired access token so _access_token() short-circuits.
    p._tokens = {
        "access_token": "test-token",
        "refresh_token": "rt",
        "expires_at": time.time() + 3600,
    }
    return p


def _track(track_id: str = "trk1") -> CurrentTrack:
    return CurrentTrack(
        provider="spotify", provider_track_id=track_id, title="t", artists=("a",)
    )


@pytest.fixture(autouse=True)
def _forget_endpoint_choice():
    """The generic-vs-legacy decision lives for the process lifetime, so it has
    to be cleared between tests."""
    SpotifyMusicProvider._use_legacy_library_endpoints = False
    yield
    SpotifyMusicProvider._use_legacy_library_endpoints = False


def _record(monkeypatch, method: str, respond) -> list[dict[str, Any]]:
    """Stub `requests.<method>`, recording every call and answering with
    `respond(url)`. Returns the growing call log, so tests can assert on the
    exact endpoint sequence the fallback produced."""
    calls: list[dict[str, Any]] = []

    def fake(url, headers=None, params=None, json=None, timeout=None):
        calls.append({"url": url, "params": params, "json": json})
        return respond(url)

    monkeypatch.setattr(f"like_spotify.extensions.spotify.requests.{method}", fake)
    return calls


# ── is_liked ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_is_liked_true(monkeypatch, tmp_path) -> None:
    calls = _record(
        monkeypatch, "get", lambda url: FakeResponse(status_code=200, json_body=[True])
    )

    p = _provider(tmp_path)
    assert await p.is_liked(_track("trk-42")) is True
    assert calls[-1]["url"].endswith("/me/library/contains")
    assert calls[-1]["params"] == {"uris": "spotify:track:trk-42"}


@pytest.mark.asyncio
async def test_is_liked_false(monkeypatch, tmp_path) -> None:
    _record(
        monkeypatch, "get", lambda url: FakeResponse(status_code=200, json_body=[False])
    )
    p = _provider(tmp_path)
    assert await p.is_liked(_track()) is False


@pytest.mark.asyncio
async def test_is_liked_empty_body_treated_as_false(monkeypatch, tmp_path) -> None:
    _record(
        monkeypatch, "get", lambda url: FakeResponse(status_code=200, json_body=[])
    )
    p = _provider(tmp_path)
    assert await p.is_liked(_track()) is False


@pytest.mark.asyncio
async def test_is_liked_accepts_a_uri_keyed_answer(monkeypatch, tmp_path) -> None:
    _record(
        monkeypatch,
        "get",
        lambda url: FakeResponse(
            status_code=200, json_body={"spotify:track:trk-42": True}
        ),
    )
    p = _provider(tmp_path)
    assert await p.is_liked(_track("trk-42")) is True


@pytest.mark.asyncio
async def test_is_liked_falls_back_to_the_legacy_endpoint(monkeypatch, tmp_path) -> None:
    def respond(url):
        if url.endswith("/me/library/contains"):
            return FakeResponse(status_code=404, text="not found")
        return FakeResponse(status_code=200, json_body=[True])

    calls = _record(monkeypatch, "get", respond)

    p = _provider(tmp_path)
    assert await p.is_liked(_track("trk-42")) is True
    assert [c["url"].rsplit("/v1", 1)[-1] for c in calls] == [
        "/me/library/contains",
        "/me/tracks/contains",
    ]
    assert calls[-1]["params"] == {"ids": "trk-42"}


# ── like ──────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_like_uses_the_generic_library_endpoint(monkeypatch, tmp_path) -> None:
    calls = _record(monkeypatch, "put", lambda url: FakeResponse(status_code=200))

    p = _provider(tmp_path)
    await p.like(_track("trk-42"))

    assert len(calls) == 1
    assert calls[0]["url"].endswith("/me/library")
    # `uris` is a query parameter; a JSON body gets a 400 (#150).
    assert calls[0]["params"] == {"uris": "spotify:track:trk-42"}
    assert calls[0]["json"] is None


@pytest.mark.asyncio
@pytest.mark.parametrize("status", [403, 404])
async def test_like_falls_back_to_the_legacy_endpoint(
    monkeypatch, tmp_path, status: int
) -> None:
    def respond(url):
        if url.endswith("/me/library"):
            return FakeResponse(status_code=status, text="denied")
        return FakeResponse(status_code=200)

    calls = _record(monkeypatch, "put", respond)

    p = _provider(tmp_path)
    await p.like(_track("trk-42"))

    assert [c["url"].rsplit("/v1", 1)[-1] for c in calls] == ["/me/library", "/me/tracks"]
    assert calls[-1]["params"] == {"ids": "trk-42"}
    assert calls[-1]["json"] is None


@pytest.mark.asyncio
async def test_a_successful_fallback_is_remembered(monkeypatch, tmp_path) -> None:
    def respond(url):
        if url.endswith("/me/library"):
            return FakeResponse(status_code=404, text="not found")
        return FakeResponse(status_code=200)

    calls = _record(monkeypatch, "put", respond)

    p = _provider(tmp_path)
    await p.like(_track("trk-1"))
    await p.like(_track("trk-2"))
    await p.follow_artist("art-1")

    # Only the first write pays two round trips.
    assert [c["url"].rsplit("/v1", 1)[-1] for c in calls] == [
        "/me/library",
        "/me/tracks",
        "/me/tracks",
        "/me/following",
    ]


@pytest.mark.asyncio
async def test_a_failing_fallback_is_not_remembered(monkeypatch, tmp_path) -> None:
    def respond(url):
        if url.endswith("/me/library"):
            return FakeResponse(status_code=404, text="not found")
        return FakeResponse(status_code=500, text="boom")

    calls = _record(monkeypatch, "put", respond)

    p = _provider(tmp_path)
    with pytest.raises(TransientError):
        await p.like(_track("trk-1"))
    calls.clear()

    # A legacy failure proves nothing about /me/library, so the next write
    # tries the generic endpoint again.
    with pytest.raises(TransientError):
        await p.like(_track("trk-2"))
    assert calls[0]["url"].endswith("/me/library")


@pytest.mark.asyncio
async def test_a_bad_request_never_falls_back_and_carries_the_body(
    monkeypatch, tmp_path
) -> None:
    body = '{"error":{"status":400,"message":"Invalid uris"}}'
    calls = _record(
        monkeypatch, "put", lambda url: FakeResponse(status_code=400, text=body)
    )

    p = _provider(tmp_path)
    with pytest.raises(RuntimeError) as excinfo:
        await p.like(_track("trk-42"))

    # 400 means our own payload is wrong; the legacy endpoint cannot fix that,
    # so it must not be tried — and Spotify's message has to reach the caller.
    assert len(calls) == 1
    assert calls[0]["url"].endswith("/me/library")
    assert body in str(excinfo.value)


@pytest.mark.asyncio
async def test_rate_limits_surface_without_a_retry(monkeypatch, tmp_path) -> None:
    calls = _record(
        monkeypatch,
        "put",
        lambda url: FakeResponse(status_code=429, headers={"Retry-After": "7"}),
    )

    p = _provider(tmp_path)
    with pytest.raises(RateLimited):
        await p.like(_track())

    assert len(calls) == 1
    assert calls[0]["url"].endswith("/me/library")


@pytest.mark.asyncio
async def test_server_errors_surface_without_a_retry(monkeypatch, tmp_path) -> None:
    calls = _record(monkeypatch, "put", lambda url: FakeResponse(status_code=500))

    p = _provider(tmp_path)
    with pytest.raises(TransientError):
        await p.like(_track())

    assert len(calls) == 1


# ── follow_artist ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_follow_artist_uses_the_generic_library_endpoint(
    monkeypatch, tmp_path
) -> None:
    calls = _record(monkeypatch, "put", lambda url: FakeResponse(status_code=200))

    p = _provider(tmp_path)
    await p.follow_artist("art-7")

    assert len(calls) == 1
    assert calls[0]["url"].endswith("/me/library")
    assert calls[0]["params"] == {"uris": "spotify:artist:art-7"}
    assert calls[0]["json"] is None


@pytest.mark.asyncio
async def test_follow_artist_falls_back_to_the_legacy_endpoint(
    monkeypatch, tmp_path
) -> None:
    def respond(url):
        if url.endswith("/me/library"):
            return FakeResponse(status_code=403, text="forbidden")
        return FakeResponse(status_code=200)

    calls = _record(monkeypatch, "put", respond)

    p = _provider(tmp_path)
    await p.follow_artist("art-7")

    assert calls[-1]["url"].endswith("/me/following")
    assert calls[-1]["params"] == {"type": "artist", "ids": "art-7"}
