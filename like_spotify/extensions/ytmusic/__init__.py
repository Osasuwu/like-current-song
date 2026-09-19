"""YouTube Music MusicProvider.

YouTube Music has no "currently playing" API, so the two halves come from
different places:

- **What is playing**: the OS media session. On Windows that is SMTC
  (System Media Transport Controls), which every browser tab and the YT
  Music desktop app publish title/artist to. See `smtc.py`. The reader is
  injectable, so tests and future hosts can supply their own.
- **Liking**: YouTube Data API v3 `videos.rate`. A liked song/video shows
  up in YT Music's "Liked music". The session exposes no videoId, so the
  title/artist is resolved with one `search.list` call first.

Quota (default 10,000 units/day per Google project): search = 100,
rate = 50, getRating = 1 — about 65 likes a day. Resolved ids are cached
per process so a repeat press on the same song does not search again.

OAuth rides on `like_spotify.auth.google` with the YouTube scope and its
own token file; the user brings their own Google Cloud OAuth client.
"""

from __future__ import annotations

import asyncio
import base64
import json
import threading
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path

import requests

from like_spotify.auth import google as google_auth
from like_spotify.core.errors import AuthError, RateLimited, TransientError
from like_spotify.core.music_provider import MusicProvider
from like_spotify.core.types import CurrentTrack

DOMAIN = "ytmusic"

API_BASE = "https://www.googleapis.com/youtube/v3"
# `youtube` covers videos.rate / getRating; `openid` yields an id_token
# whose `sub` is a stable user id even for accounts without a channel.
SCOPE = "https://www.googleapis.com/auth/youtube openid"
MUSIC_CATEGORY_ID = "10"
TOPIC_SUFFIX = " - Topic"


@dataclass(frozen=True)
class NowPlaying:
    """What the OS media session reports. No provider id — just text."""

    title: str
    artist: str
    album: str | None = None


NowPlayingReader = Callable[[], Awaitable[NowPlaying | None]]


class YouTubeMusicProvider(MusicProvider):
    def __init__(
        self,
        token_path: Path,
        now_playing: NowPlayingReader | None = None,
    ) -> None:
        self._token_path = token_path
        self._now_playing = now_playing or _default_reader()
        self._token_provider: Callable[[], str] | None = None
        self._lock = threading.Lock()
        # (artist, title) -> videoId. Per process: saves 100 quota units on
        # every repeat press for the same song.
        self._resolved: dict[tuple[str, str], str] = {}

    # ── MusicProvider ─────────────────────────────────────────────────

    async def get_currently_playing(self) -> CurrentTrack | None:
        np = await self._now_playing()
        if np is None or not np.title:
            return None
        artist = _clean_artist(np.artist)
        video_id = await asyncio.to_thread(self._resolve_sync, artist, np.title)
        if video_id is None:
            return None
        return CurrentTrack(
            provider=DOMAIN,
            provider_track_id=video_id,
            title=np.title,
            artists=(artist,) if artist else (),
            album=np.album or None,
        )

    async def like(self, track: CurrentTrack) -> None:
        await asyncio.to_thread(self._like_sync, track.provider_track_id)

    async def is_liked(self, track: CurrentTrack) -> bool:
        return await asyncio.to_thread(self._is_liked_sync, track.provider_track_id)

    async def user_id(self) -> str:
        tokens = google_auth.load_tokens(self._token_path)
        sub = _id_token_sub(tokens.get("id_token", ""))
        if not sub:
            raise AuthError(
                "youtube token has no id_token; re-run `like-spotify --setup --reauth`"
            )
        return sub

    # ── Auth (host wiring, not on the abstract base) ──────────────────

    @property
    def has_tokens(self) -> bool:
        return bool(google_auth.load_tokens(self._token_path).get("refresh_token"))

    def authorize(self, client_id: str, client_secret: str) -> None:
        google_auth.authorize(
            client_id=client_id,
            client_secret=client_secret,
            token_path=self._token_path,
            scope=SCOPE,
        )
        with self._lock:
            self._token_provider = None  # pick up the fresh tokens

    # ── Sync internals (run via to_thread) ────────────────────────────

    def _access_token(self) -> str:
        with self._lock:
            if self._token_provider is None:
                self._token_provider = google_auth.make_token_provider(
                    self._token_path
                )
            provider = self._token_provider
        return provider()

    def _resolve_sync(self, artist: str, title: str) -> str | None:
        key = (artist.casefold(), title.casefold())
        if key in self._resolved:
            return self._resolved[key]
        r = requests.get(
            f"{API_BASE}/search",
            headers={"Authorization": f"Bearer {self._access_token()}"},
            params={
                "part": "snippet",
                "q": f"{artist} {title}".strip(),
                "type": "video",
                "videoCategoryId": MUSIC_CATEGORY_ID,
                "maxResults": 5,
                "fields": "items(id/videoId,snippet/channelTitle)",
            },
            timeout=5,
        )
        _raise_for_status(r)
        video_id = _pick_video(r.json().get("items", []), artist)
        if video_id:
            self._resolved[key] = video_id
        return video_id

    def _like_sync(self, video_id: str) -> None:
        r = requests.post(
            f"{API_BASE}/videos/rate",
            headers={"Authorization": f"Bearer {self._access_token()}"},
            params={"id": video_id, "rating": "like"},
            timeout=5,
        )
        _raise_for_status(r)

    def _is_liked_sync(self, video_id: str) -> bool:
        r = requests.get(
            f"{API_BASE}/videos/getRating",
            headers={"Authorization": f"Bearer {self._access_token()}"},
            params={"id": video_id},
            timeout=5,
        )
        _raise_for_status(r)
        items = r.json().get("items", [])
        return bool(items) and items[0].get("rating") == "like"


# ── Module-level helpers ──────────────────────────────────────────────


def _clean_artist(artist: str) -> str:
    """Plain YouTube playback reports auto-generated channels as
    "Artist - Topic"; the suffix only hurts the search."""
    artist = (artist or "").strip()
    if artist.endswith(TOPIC_SUFFIX):
        artist = artist[: -len(TOPIC_SUFFIX)].strip()
    return artist


def _pick_video(items: list[dict], artist: str) -> str | None:
    """Prefer the "Artist - Topic" Art Track (the audio-only upload YT Music
    itself plays), then any upload from the artist's own channel, then the
    top hit."""
    want = artist.casefold()
    candidates = [
        (it.get("id", {}).get("videoId"), it.get("snippet", {}).get("channelTitle", ""))
        for it in items
    ]
    candidates = [(vid, ch.casefold()) for vid, ch in candidates if vid]
    if not candidates:
        return None
    if want:
        for vid, ch in candidates:
            if ch == f"{want}{TOPIC_SUFFIX.casefold()}":
                return vid
        for vid, ch in candidates:
            if ch.startswith(want):
                return vid
    return candidates[0][0]


def _id_token_sub(id_token: str) -> str | None:
    """`sub` claim of a Google id_token. No signature check: the token came
    straight from Google's token endpoint over TLS and is only used as a
    storage key, never for authorization."""
    parts = id_token.split(".")
    if len(parts) != 3:
        return None
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except (ValueError, json.JSONDecodeError):
        return None
    sub = claims.get("sub")
    return str(sub) if sub else None


def _raise_for_status(r: requests.Response) -> None:
    if 200 <= r.status_code < 300:
        return
    if r.status_code == 401:
        raise AuthError(f"401 {r.text}")
    if r.status_code == 403:
        # YouTube reports an exhausted daily quota as 403, not 429.
        if _error_reason(r) in ("quotaExceeded", "rateLimitExceeded"):
            raise RateLimited("youtube daily quota exhausted — resets at midnight PT")
        raise AuthError(f"403 {r.text}")
    if r.status_code == 429:
        raise RateLimited(r.headers.get("Retry-After", "1"))
    if r.status_code >= 500:
        raise TransientError(f"{r.status_code} {r.text}")
    raise RuntimeError(f"youtube API {r.status_code}: {r.text}")


def _error_reason(r: requests.Response) -> str | None:
    try:
        errors = r.json().get("error", {}).get("errors", [])
    except (ValueError, AttributeError):
        return None
    return errors[0].get("reason") if errors else None


def _default_reader() -> NowPlayingReader:
    from .smtc import read_now_playing

    return read_now_playing


# ── Factory export (filesystem-convention sentinel) ───────────────────


def MUSIC_PROVIDER(
    token_path: Path, now_playing: NowPlayingReader | None = None
) -> YouTubeMusicProvider:
    """Factory called by the host."""
    return YouTubeMusicProvider(token_path=token_path, now_playing=now_playing)
