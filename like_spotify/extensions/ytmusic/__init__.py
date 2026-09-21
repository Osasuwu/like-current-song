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

**Playlist capability** (`PlaylistCapableProvider`): YT Music playlists
are ordinary YouTube playlists on the user's channel, so archive-remove,
promote-to-best and follow-artist run unchanged. Reads (playlists.list,
playlistItems.list) cost 1 unit per page; each write (playlistItems.insert
/ delete, playlists.insert, subscriptions.insert) costs 50.

**Artist id = channel id.** "Follow artist" is a channel subscribe. The
channel is the uploader of the matched video, but only when that upload is
the artist's own: the auto-generated "Artist - Topic" channel (what YT
Music's artist page is built on) or a channel named after the artist.
When matching fell back to an unrelated uploader (a cover, a label
compilation) `artist_ids` stays empty and follow-artist skips the track,
so a lucky search hit never subscribes the user to a stranger.

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
# `youtube` covers videos.rate / getRating and the playlist + subscription
# writes (playlists.insert, playlistItems.insert/delete,
# subscriptions.insert); `openid` yields an id_token whose `sub` is a
# stable user id even for accounts without a channel.
SCOPE = "https://www.googleapis.com/auth/youtube openid"
MUSIC_CATEGORY_ID = "10"
TOPIC_SUFFIX = " - Topic"
PAGE_SIZE = 50  # max for playlists.list / playlistItems.list
PLAYLIST_DESCRIPTION = "Managed by Like Current Song"


@dataclass(frozen=True)
class NowPlaying:
    """What the OS media session reports. No provider id — just text."""

    title: str
    artist: str
    album: str | None = None


NowPlayingReader = Callable[[], Awaitable[NowPlaying | None]]


@dataclass(frozen=True)
class _Match:
    video_id: str
    # Uploader channel, only when it is the artist's own (see module doc).
    artist_channel_id: str | None


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
        # (artist, title) -> match. Per process: saves 100 quota units on
        # every repeat press for the same song.
        self._resolved: dict[tuple[str, str], _Match] = {}

    # ── MusicProvider ─────────────────────────────────────────────────

    async def get_currently_playing(self) -> CurrentTrack | None:
        np = await self._now_playing()
        if np is None or not np.title:
            return None
        artist = _clean_artist(np.artist)
        match = await asyncio.to_thread(self._resolve_sync, artist, np.title)
        if match is None:
            return None
        return CurrentTrack(
            provider=DOMAIN,
            provider_track_id=match.video_id,
            title=np.title,
            artists=(artist,) if artist else (),
            artist_ids=(match.artist_channel_id,) if match.artist_channel_id else (),
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
                "youtube token has no id_token; re-run `like-current-song --setup --reauth`"
            )
        return sub

    # ── PlaylistCapableProvider ───────────────────────────────────────

    async def find_playlist_by_name(self, name: str) -> str | None:
        return await asyncio.to_thread(self._find_playlist_by_name_sync, name)

    async def find_or_create_playlist(self, name: str) -> str:
        return await asyncio.to_thread(self._find_or_create_playlist_sync, name)

    async def get_playlist_track_ids(self, playlist_id: str) -> set[str]:
        items = await asyncio.to_thread(self._playlist_items_sync, playlist_id)
        return {video_id for _item_id, video_id in items}

    async def add_track_to_playlist(self, track_id: str, playlist_id: str) -> None:
        await asyncio.to_thread(self._add_to_playlist_sync, track_id, playlist_id)

    async def remove_track_from_playlist(
        self, track_id: str, playlist_id: str
    ) -> None:
        await asyncio.to_thread(self._remove_from_playlist_sync, track_id, playlist_id)

    async def follow_artist(self, artist_id: str) -> None:
        await asyncio.to_thread(self._subscribe_sync, artist_id)

    # ── DislikeCapableProvider ────────────────────────────────────────

    async def dislike(self, track: CurrentTrack) -> None:
        """A real thumbs-down: `videos.rate` with `rating=dislike`.

        This is the genuine article — the same signal the thumbs-down
        button in the YT Music client sends, and it feeds recommendations.
        Spotify has no equivalent (see `DislikeCapableProvider`), so the
        two providers' `dislike` differ in what they reach, on purpose.

        Costs the same 50 units as a like, and clears any existing like on
        the track because ratings are exclusive.
        """
        await asyncio.to_thread(self._dislike_sync, track.provider_track_id)

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

    def _auth(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self._access_token()}"}

    def _resolve_sync(self, artist: str, title: str) -> _Match | None:
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
                "fields": "items(id/videoId,snippet/channelId,snippet/channelTitle)",
            },
            timeout=5,
        )
        _raise_for_status(r)
        match = _pick_video(r.json().get("items", []), artist)
        if match:
            self._resolved[key] = match
        return match

    def _rate_sync(self, video_id: str, rating: str) -> None:
        """`videos.rate` — 50 quota units, whichever rating is sent.

        Ratings are exclusive, not additive: posting `dislike` clears an
        existing `like` in the same call (and vice versa), so neither side
        needs to read `getRating` first or undo the other.
        """
        r = requests.post(
            f"{API_BASE}/videos/rate",
            headers={"Authorization": f"Bearer {self._access_token()}"},
            params={"id": video_id, "rating": rating},
            timeout=5,
        )
        _raise_for_status(r)

    def _like_sync(self, video_id: str) -> None:
        self._rate_sync(video_id, "like")

    def _dislike_sync(self, video_id: str) -> None:
        self._rate_sync(video_id, "dislike")

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

    def _find_playlist_by_name_sync(self, name: str) -> str | None:
        needle = name.strip().casefold()
        page_token: str | None = None
        while True:
            params = {
                "part": "snippet",
                "mine": "true",
                "maxResults": PAGE_SIZE,
                "fields": "items(id,snippet/title),nextPageToken",
            }
            if page_token:
                params["pageToken"] = page_token
            r = requests.get(
                f"{API_BASE}/playlists", headers=self._auth(), params=params, timeout=5
            )
            _raise_for_status(r)
            data = r.json()
            for p in data.get("items", []):
                title = (p.get("snippet") or {}).get("title") or ""
                if title.strip().casefold() == needle:
                    return p.get("id")
            page_token = data.get("nextPageToken")
            if not page_token:
                return None

    def _find_or_create_playlist_sync(self, name: str) -> str:
        existing = self._find_playlist_by_name_sync(name)
        if existing:
            return existing
        r = requests.post(
            f"{API_BASE}/playlists",
            headers=self._auth(),
            params={"part": "snippet,status"},
            json={
                "snippet": {"title": name.strip(), "description": PLAYLIST_DESCRIPTION},
                "status": {"privacyStatus": "private"},
            },
            timeout=5,
        )
        _raise_for_status(r)
        pid = r.json().get("id")
        if not pid:
            raise RuntimeError("youtube playlist create returned no id")
        return pid

    def _playlist_items_sync(self, playlist_id: str) -> list[tuple[str, str]]:
        """(playlistItem id, videoId) for every entry, all pages."""
        out: list[tuple[str, str]] = []
        page_token: str | None = None
        while True:
            params = {
                "part": "contentDetails",
                "playlistId": playlist_id,
                "maxResults": PAGE_SIZE,
                "fields": "items(id,contentDetails/videoId),nextPageToken",
            }
            if page_token:
                params["pageToken"] = page_token
            r = requests.get(
                f"{API_BASE}/playlistItems",
                headers=self._auth(),
                params=params,
                timeout=10,
            )
            _raise_for_status(r)
            data = r.json()
            for it in data.get("items", []):
                video_id = (it.get("contentDetails") or {}).get("videoId")
                if it.get("id") and video_id:
                    out.append((it["id"], video_id))
            page_token = data.get("nextPageToken")
            if not page_token:
                return out

    def _add_to_playlist_sync(self, video_id: str, playlist_id: str) -> None:
        r = requests.post(
            f"{API_BASE}/playlistItems",
            headers=self._auth(),
            params={"part": "snippet"},
            json={
                "snippet": {
                    "playlistId": playlist_id,
                    "resourceId": {"kind": "youtube#video", "videoId": video_id},
                }
            },
            timeout=5,
        )
        _raise_for_status(r)

    def _remove_from_playlist_sync(self, video_id: str, playlist_id: str) -> None:
        # YouTube deletes by playlistItem id, not videoId: list, then delete
        # every entry of this video (1 unit per page + 50 per delete).
        for item_id, vid in self._playlist_items_sync(playlist_id):
            if vid != video_id:
                continue
            r = requests.delete(
                f"{API_BASE}/playlistItems",
                headers=self._auth(),
                params={"id": item_id},
                timeout=5,
            )
            if r.status_code == 404:
                continue  # already gone (removed elsewhere meanwhile)
            _raise_for_status(r)

    def _subscribe_sync(self, channel_id: str) -> None:
        r = requests.post(
            f"{API_BASE}/subscriptions",
            headers=self._auth(),
            params={"part": "snippet"},
            json={
                "snippet": {
                    "resourceId": {"kind": "youtube#channel", "channelId": channel_id}
                }
            },
            timeout=5,
        )
        if r.status_code == 400 and _error_reason(r) == "subscriptionDuplicate":
            return  # already subscribed: follow is idempotent
        _raise_for_status(r)


# ── Module-level helpers ──────────────────────────────────────────────


def _clean_artist(artist: str) -> str:
    """Plain YouTube playback reports auto-generated channels as
    "Artist - Topic"; the suffix only hurts the search."""
    artist = (artist or "").strip()
    if artist.endswith(TOPIC_SUFFIX):
        artist = artist[: -len(TOPIC_SUFFIX)].strip()
    return artist


def _pick_video(items: list[dict], artist: str) -> _Match | None:
    """Prefer the "Artist - Topic" Art Track (the audio-only upload YT Music
    itself plays), then any upload from the artist's own channel, then the
    top hit. Only the first two carry the uploader as the artist channel."""
    want = artist.casefold()
    candidates: list[tuple[str, str | None, str]] = []
    for it in items:
        vid = (it.get("id") or {}).get("videoId")
        snippet = it.get("snippet") or {}
        if vid:
            channel_id = snippet.get("channelId") or None
            channel_title = (snippet.get("channelTitle") or "").casefold()
            candidates.append((vid, channel_id, channel_title))
    if not candidates:
        return None
    if want:
        for vid, channel_id, channel_title in candidates:
            if channel_title == f"{want}{TOPIC_SUFFIX.casefold()}":
                return _Match(vid, channel_id)
        for vid, channel_id, channel_title in candidates:
            if channel_title.startswith(want):
                return _Match(vid, channel_id)
    return _Match(candidates[0][0], None)


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
