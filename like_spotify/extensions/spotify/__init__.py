"""Spotify MusicProvider — default flavor.

Ported from `tools/spotify_liker.py`. Sync `requests` wrapped in
`asyncio.to_thread` so the extension presents an async surface without
rewriting the I/O. PKCE OAuth, tokens stored under the host config dir.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import http.server
import json
import secrets
import socketserver
import threading
import time
import urllib.parse
import webbrowser
from pathlib import Path

import requests

from like_spotify.core.errors import AuthError, RateLimited, TransientError
from like_spotify.core.music_provider import MusicProvider
from like_spotify.core.types import CurrentTrack

DOMAIN = "spotify"

AUTH_URL = "https://accounts.spotify.com/authorize"
TOKEN_URL = "https://accounts.spotify.com/api/token"
API_BASE = "https://api.spotify.com/v1"

REDIRECT_PORT = 8793
REDIRECT_URI = f"http://127.0.0.1:{REDIRECT_PORT}/callback"
SCOPES = (
    "user-library-modify user-library-read user-read-playback-state "
    "playlist-read-private playlist-modify-private playlist-modify-public "
    "user-follow-modify user-follow-read"
)

# Statuses that mean "this client ID cannot use the generic `/me/library`
# endpoints", so the entity-specific endpoint they replaced is worth one retry:
#
#   404 — the generic path is not routed for this client at all.
#   403 — Spotify's restricted-access model answers endpoints outside a
#         client's granted set with Forbidden, which is what a client ID
#         grandfathered onto the entity-specific endpoints sees here.
#
# Deliberately excluded: 401 (token — must surface so the caller refreshes),
# 429 (rate limit — must surface unchanged), 400 (our own payload; a retry
# cannot fix it) and 5xx (transient). A 403 caused by a missing scope rather
# than by endpoint access fails on both forms, and since the fallback is only
# remembered once the legacy call *succeeds*, such a 403 never pins the process
# to the legacy endpoints.
LIBRARY_FALLBACK_STATUSES = frozenset({403, 404})


class SpotifyMusicProvider(MusicProvider):
    # Set once the generic `/me/library` endpoints have proven unavailable to
    # this client ID *and* an entity-specific endpoint has answered in their
    # place, so the rest of the process skips the doomed first request. Class
    # level on purpose: the answer depends on the client ID, not on the
    # instance.
    _use_legacy_library_endpoints = False

    def __init__(self, client_id: str, token_path: Path) -> None:
        if not client_id:
            raise ValueError("spotify client_id is required")
        self._client_id = client_id
        self._token_path = token_path
        self._tokens: dict = _load_tokens(token_path)
        self._lock = threading.Lock()
        self._user_id_cache: str | None = None

    # ── MusicProvider ─────────────────────────────────────────────────

    async def get_currently_playing(self) -> CurrentTrack | None:
        return await asyncio.to_thread(self._get_currently_playing_sync)

    async def like(self, track: CurrentTrack) -> None:
        await asyncio.to_thread(self._like_sync, track.provider_track_id)

    async def is_liked(self, track: CurrentTrack) -> bool:
        return await asyncio.to_thread(self._is_liked_sync, track.provider_track_id)

    async def user_id(self) -> str:
        if self._user_id_cache:
            return self._user_id_cache
        self._user_id_cache = await asyncio.to_thread(self._fetch_user_id_sync)
        return self._user_id_cache

    # ── Playlist API (used by Spotify-flavored Actions — NOT on the abstract base) ──

    async def find_playlist_by_name(self, name: str) -> str | None:
        """Case-insensitive lookup over the user's library playlists (owned
        + followed; the `/me/playlists` endpoint returns both). None if absent."""
        return await asyncio.to_thread(self._find_playlist_by_name_sync, name)

    async def get_playlist_track_ids(self, playlist_id: str) -> set[str]:
        """Snapshot of track IDs in the playlist. One paged fetch."""
        return await asyncio.to_thread(self._get_playlist_track_ids_sync, playlist_id)

    async def remove_track_from_playlist(self, track_id: str, playlist_id: str) -> None:
        await asyncio.to_thread(
            self._remove_track_from_playlist_sync, track_id, playlist_id
        )

    async def add_track_to_playlist(self, track_id: str, playlist_id: str) -> None:
        await asyncio.to_thread(
            self._add_track_to_playlist_sync, track_id, playlist_id
        )

    async def find_or_create_playlist(self, name: str) -> str:
        """Return the id of the playlist with `name`, creating a private
        one under the current user if absent. Idempotent."""
        return await asyncio.to_thread(self._find_or_create_playlist_sync, name)

    async def follow_artist(self, artist_id: str) -> None:
        await asyncio.to_thread(self._follow_artist_sync, artist_id)

    # ── Auth (sync, called from setup; safe outside event loop) ───────

    @property
    def has_tokens(self) -> bool:
        return bool(self._tokens.get("access_token"))

    def authorize(self) -> None:
        """PKCE flow: open browser, wait for callback, persist tokens."""
        verifier = secrets.token_urlsafe(64)[:96]
        challenge = (
            base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
            .rstrip(b"=")
            .decode()
        )
        state = secrets.token_hex(8)
        params = {
            "client_id": self._client_id,
            "response_type": "code",
            "redirect_uri": REDIRECT_URI,
            "code_challenge_method": "S256",
            "code_challenge": challenge,
            "state": state,
            "scope": SCOPES,
        }
        url = f"{AUTH_URL}?{urllib.parse.urlencode(params)}"

        captured: dict[str, str | None] = {"code": None, "state": None}
        event = threading.Event()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                captured["code"] = qs.get("code", [None])[0]
                captured["state"] = qs.get("state", [None])[0]
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    b"<h2 style='font-family:sans-serif;margin:40px'>"
                    b"Authorized! You can close this tab.</h2>"
                )
                event.set()

            def log_message(self, *_args):
                pass

        server = socketserver.TCPServer(("127.0.0.1", REDIRECT_PORT), Handler)
        threading.Thread(target=server.handle_request, daemon=True).start()
        webbrowser.open(url)
        event.wait(timeout=120)
        server.server_close()

        if not captured["code"]:
            raise AuthError("authorization timed out (120s)")
        if captured["state"] != state:
            raise AuthError("state mismatch in OAuth callback")

        r = requests.post(
            TOKEN_URL,
            data={
                "grant_type": "authorization_code",
                "code": captured["code"],
                "redirect_uri": REDIRECT_URI,
                "client_id": self._client_id,
                "code_verifier": verifier,
            },
            timeout=10,
        )
        if r.status_code >= 400:
            raise AuthError(f"token exchange failed ({r.status_code}): {r.text}")
        self._tokens = _augment_tokens(r.json())
        _save_tokens(self._token_path, self._tokens)

    # ── Internals ─────────────────────────────────────────────────────

    def _access_token(self) -> str:
        with self._lock:
            if not self._tokens.get("refresh_token") and not self._tokens.get("access_token"):
                raise AuthError("not authenticated; run `like-current-song --setup` first")
            if time.time() > self._tokens.get("expires_at", 0) - 60:
                self._refresh_locked()
            return self._tokens["access_token"]

    def _refresh_locked(self) -> None:
        r = requests.post(
            TOKEN_URL,
            data={
                "grant_type": "refresh_token",
                "refresh_token": self._tokens["refresh_token"],
                "client_id": self._client_id,
            },
            timeout=10,
        )
        if r.status_code in (400, 401):
            raise AuthError(f"refresh rejected ({r.status_code}): {r.text}")
        if r.status_code >= 500:
            raise TransientError(f"token endpoint 5xx: {r.status_code}")
        if r.status_code >= 400:
            raise AuthError(f"token refresh failed: {r.status_code} {r.text}")
        fresh = r.json()
        self._tokens["access_token"] = fresh["access_token"]
        self._tokens["expires_at"] = time.time() + fresh["expires_in"]
        if "refresh_token" in fresh:
            self._tokens["refresh_token"] = fresh["refresh_token"]
        _save_tokens(self._token_path, self._tokens)

    def _get_currently_playing_sync(self) -> CurrentTrack | None:
        token = self._access_token()
        r = requests.get(
            f"{API_BASE}/me/player/currently-playing",
            headers={"Authorization": f"Bearer {token}"},
            timeout=5,
        )
        if r.status_code == 204:
            return None
        _raise_for_status(r)
        item = r.json().get("item")
        if not item:
            return None
        return CurrentTrack(
            provider=DOMAIN,
            provider_track_id=item["id"],
            title=item.get("name", ""),
            artists=tuple(a["name"] for a in item.get("artists", []) if a.get("name")),
            artist_ids=tuple(a["id"] for a in item.get("artists", []) if a.get("id")),
            album=(item.get("album") or {}).get("name"),
        )

    def _save_to_library(self, uri: str, legacy_call) -> None:
        """Save/follow `uri` through the generic `PUT /me/library` endpoint that
        replaced `PUT /me/tracks`, `PUT /me/following` and friends in Spotify's
        February 2026 API migration.

        `uris` is a *query* parameter — a comma-separated list, maximum 40 —
        not a request body, which is why this passes `params=` and sends no
        body and no `Content-Type` at all. The JSON-body form is rejected as
        malformed with 400 every time (#150); don't "simplify" it back. Only
        one URI is ever written per call here, so the 40 maximum is out of
        reach and nothing needs chunking.

        Client IDs registered before 2026-02-11 were grandfathered onto the
        entity-specific endpoints, so when `/me/library` is unavailable to this
        client (see `LIBRARY_FALLBACK_STATUSES`) `legacy_call(token)` runs once
        instead. A successful legacy call is remembered for the process
        lifetime, so only the first write of a session pays two round trips.
        """
        token = self._access_token()
        if not SpotifyMusicProvider._use_legacy_library_endpoints:
            r = requests.put(
                f"{API_BASE}/me/library",
                headers={"Authorization": f"Bearer {token}"},
                params={"uris": uri},
                timeout=5,
            )
            if 200 <= r.status_code < 300:
                return
            if r.status_code not in LIBRARY_FALLBACK_STATUSES:
                _raise_for_status(r)

        _raise_for_status(legacy_call(token))
        SpotifyMusicProvider._use_legacy_library_endpoints = True

    def _like_sync(self, track_id: str) -> None:
        def legacy(token: str):
            return requests.put(
                f"{API_BASE}/me/tracks",
                headers={"Authorization": f"Bearer {token}"},
                params={"ids": track_id},
                timeout=5,
            )

        self._save_to_library(f"spotify:track:{track_id}", legacy)

    def _is_liked_sync(self, track_id: str) -> bool:
        """`GET /me/library/contains`, falling back to `GET /me/tracks/contains`
        under the same rule as `_save_to_library`."""
        token = self._access_token()
        uri = f"spotify:track:{track_id}"
        if not SpotifyMusicProvider._use_legacy_library_endpoints:
            r = requests.get(
                f"{API_BASE}/me/library/contains",
                headers={"Authorization": f"Bearer {token}"},
                params={"uris": uri},
                timeout=5,
            )
            if 200 <= r.status_code < 300:
                return _contains_flag(r.json(), uri)
            if r.status_code not in LIBRARY_FALLBACK_STATUSES:
                _raise_for_status(r)

        r = requests.get(
            f"{API_BASE}/me/tracks/contains",
            headers={"Authorization": f"Bearer {token}"},
            params={"ids": track_id},
            timeout=5,
        )
        _raise_for_status(r)
        SpotifyMusicProvider._use_legacy_library_endpoints = True
        return _contains_flag(r.json(), uri)

    def _find_playlist_by_name_sync(self, name: str) -> str | None:
        needle = name.strip().lower()
        offset = 0
        while True:
            token = self._access_token()
            r = requests.get(
                f"{API_BASE}/me/playlists",
                headers={"Authorization": f"Bearer {token}"},
                params={"limit": 50, "offset": offset},
                timeout=5,
            )
            _raise_for_status(r)
            data = r.json()
            items = data.get("items", [])
            for p in items:
                if (p.get("name") or "").strip().lower() == needle:
                    return p.get("id")
            if len(items) < 50:
                return None
            offset += 50

    def _get_playlist_track_ids_sync(self, playlist_id: str) -> set[str]:
        ids: set[str] = set()
        offset = 0
        while True:
            token = self._access_token()
            r = requests.get(
                f"{API_BASE}/playlists/{playlist_id}/tracks",
                headers={"Authorization": f"Bearer {token}"},
                params={
                    "limit": 100,
                    "offset": offset,
                    "fields": "items(track(id)),next",
                },
                timeout=10,
            )
            _raise_for_status(r)
            data = r.json()
            for item in data.get("items", []):
                tid = (item.get("track") or {}).get("id")
                if tid:
                    ids.add(tid)
            if not data.get("next"):
                return ids
            offset += 100

    def _remove_track_from_playlist_sync(self, track_id: str, playlist_id: str) -> None:
        token = self._access_token()
        r = requests.delete(
            f"{API_BASE}/playlists/{playlist_id}/tracks",
            headers={"Authorization": f"Bearer {token}"},
            json={"tracks": [{"uri": f"spotify:track:{track_id}"}]},
            timeout=5,
        )
        _raise_for_status(r)

    def _add_track_to_playlist_sync(self, track_id: str, playlist_id: str) -> None:
        token = self._access_token()
        r = requests.post(
            f"{API_BASE}/playlists/{playlist_id}/tracks",
            headers={"Authorization": f"Bearer {token}"},
            json={"uris": [f"spotify:track:{track_id}"]},
            timeout=5,
        )
        _raise_for_status(r)

    def _find_or_create_playlist_sync(self, name: str) -> str:
        existing = self._find_playlist_by_name_sync(name)
        if existing:
            return existing
        # Create under the authenticated user.
        token = self._access_token()
        # _fetch_user_id_sync caches; reusing keeps the create path 1 extra call.
        uid = self._user_id_cache or self._fetch_user_id_sync()
        self._user_id_cache = uid
        r = requests.post(
            f"{API_BASE}/users/{uid}/playlists",
            headers={"Authorization": f"Bearer {token}"},
            json={
                "name": name,
                "public": False,
                "description": "Managed by Like Current Song",
            },
            timeout=5,
        )
        _raise_for_status(r)
        pid = r.json().get("id")
        if not pid:
            raise RuntimeError("playlist create returned no id")
        return pid

    def _follow_artist_sync(self, artist_id: str) -> None:
        def legacy(token: str):
            return requests.put(
                f"{API_BASE}/me/following",
                headers={"Authorization": f"Bearer {token}"},
                params={"type": "artist", "ids": artist_id},
                timeout=5,
            )

        self._save_to_library(f"spotify:artist:{artist_id}", legacy)

    def _fetch_user_id_sync(self) -> str:
        token = self._access_token()
        r = requests.get(
            f"{API_BASE}/me",
            headers={"Authorization": f"Bearer {token}"},
            timeout=5,
        )
        _raise_for_status(r)
        uid = r.json().get("id")
        if not uid:
            raise AuthError("/me did not return an id")
        return uid


# ── Module-level helpers ──────────────────────────────────────────────


def _load_tokens(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _save_tokens(path: Path, tokens: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(tokens, indent=2), encoding="utf-8")


def _augment_tokens(payload: dict) -> dict:
    tokens = dict(payload)
    tokens["expires_at"] = time.time() + tokens.get("expires_in", 3600)
    return tokens


def _contains_flag(body, uri: str) -> bool:
    """Read the saved/not-saved answer for `uri` out of a contains response.

    The legacy `/me/tracks/contains` answers with one boolean per requested id,
    in order. The migration guide documents only the *input* change for
    `/me/library/contains`, so the same list is expected there; a mapping keyed
    by URI is accepted as well rather than trusting one undocumented shape.
    """
    if isinstance(body, dict):
        return bool(body.get(uri))
    return bool(body) and bool(body[0])


def _raise_for_status(r: requests.Response) -> None:
    if 200 <= r.status_code < 300:
        return
    if r.status_code in (401, 403):
        raise AuthError(f"{r.status_code} {r.text}")
    if r.status_code == 429:
        raise RateLimited(r.headers.get("Retry-After", "1"))
    if r.status_code >= 500:
        raise TransientError(f"{r.status_code} {r.text}")
    raise RuntimeError(f"spotify API {r.status_code}: {r.text}")


# ── Factory export (filesystem-convention sentinel) ───────────────────


def MUSIC_PROVIDER(client_id: str, token_path: Path) -> SpotifyMusicProvider:
    """Factory called by the host. Signature widens in #28 (manifest deps)."""
    return SpotifyMusicProvider(client_id=client_id, token_path=token_path)
