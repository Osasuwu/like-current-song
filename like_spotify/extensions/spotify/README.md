# Spotify provider

Press the hotkey while a song plays in Spotify and it lands in your **Liked
Songs**. This is the default provider, and the one the installer configures.

- **Status:** stable. Every desktop OS the app runs on.
- **Selected by:** `music.provider = "spotify"` in `~/.like_spotify/config.json`
  (the default), or the "Music service" prompt in `like-current-song --setup`.

## Setup: your own Spotify app (one time, about 3 minutes)

The app ships no shared credentials, so each user brings their own free
Spotify Developer app.

1. Open [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
   and create an app.
2. Add `http://127.0.0.1:8793/callback` as a **Redirect URI**. The desktop
   half listens on that port during sign-in; the Android half uses a different
   one, so an app shared by both needs both entries.
3. Run `like-current-song --setup`, choose `spotify`, and paste the client ID.
   A browser opens for the Spotify login (PKCE, so no client secret is
   needed), and the tokens are saved to `~/.like_spotify/spotify_token.json`.

Requested scopes: `user-library-modify`, `user-library-read`,
`user-read-playback-state`, `playlist-read-private`,
`playlist-modify-private`, `playlist-modify-public`, `user-follow-modify`,
`user-follow-read`. The playlist and follow scopes are what the optional
actions need, so turning those on later needs no new sign-in.

## Endpoints

Reads now-playing from `/me/player/currently-playing` — the real playback
state, so there is nothing to match by title and no chance of liking the wrong
track.

Library writes go to the generic `/me/library` endpoints, with `uris` as a
**query** parameter (a JSON body gets a 400). Client IDs created before that
migration are still routed to the entity-specific endpoints they replaced, and
answer the generic form with 403 or 404, so each write falls back once to
`/me/tracks` (or `/me/following`) and the answer is remembered for the rest of
the process. See `LIBRARY_FALLBACK_STATUSES` in `__init__.py` for which
statuses are treated as "wrong endpoint" and, just as importantly, which are
not.

## Playlist actions

The archive-remove, promote-to-best and follow-artist actions all work here;
turn them on in the "Playlist clean-up" step of `--setup` or under `actions.*`
in `config.json`. Playlists are matched by name, case-insensitively, across
your own playlists; best creates its playlist as **private** if it does not
exist yet. Follow-artist follows every artist credited on the track.

## Dislike: what Spotify does not offer

The discard hotkey (default `Ctrl+Shift+Alt+Q`) asks the provider to send the
strongest negative signal the service supports. **Spotify has none.** The Web
API has no dislike, thumbs-down or "don't play this" endpoint of any kind, and
the *Hide this song* control in the first-party clients is not exposed to
third-party apps — it is a client-side preference, not a public API.

So under this provider the discard press removes the track from your Liked
Songs (`DELETE` on the same library endpoint `like` writes to, with the same
fallback). That is a genuine negative — it takes the song out of the library
and out of anything keyed on it — but it is **not** a dislike, and it does
nothing to a track you never liked. Where YouTube Music sends a real
thumbs-down that feeds recommendations, Spotify simply has nowhere to send
one. The notification you get after the press says which of the two happened,
so the difference is never hidden behind a shared word.

If Spotify ever exposes a negative-feedback endpoint, `dislike` in
`__init__.py` is the one method that changes.
