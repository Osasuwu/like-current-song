# YouTube Music provider (beta)

Press the hotkey while a song plays in YouTube Music and it lands in your
**Liked music**. This works with the music.youtube.com tab in Chrome, Edge or
Firefox and with the YT Music desktop app.

- **Status:** beta. Desktop only, **Windows only** for now.
- **Selected by:** `music.provider = "ytmusic"` in `~/.like_spotify/config.json`,
  or the "Music service" prompt in `like-current-song --setup`.

## How it works

YouTube has no public "currently playing" API, so the provider takes three
steps:

1. **Now playing.** It reads the title and artist from the Windows media
   session (SMTC). That is the same info the volume flyout shows.
2. **Match.** It resolves the title and artist to a video with the YouTube
   Data API `search.list` (music category). The auto-generated
   "Artist - Topic" upload is preferred, since that is the track YT Music
   itself plays. Next comes a channel named after the artist, then the top
   hit.
3. **Like.** It calls `videos.rate`. On YouTube, liking the video *is* liking
   the song, so it shows up in YT Music's Liked music.

The discard hotkey takes the same three steps and ends in the same call with
`rating=dislike` — a **real thumbs-down**, the one YT Music's own interface
sends. Ratings are exclusive rather than additive, so disliking a song you had
liked clears the like in the same call; there is no separate “un-like” step to
go wrong. (This is where YT Music differs from Spotify, which has no dislike
in its API at all — see `../spotify/README.md`.)

## Setup: your own Google OAuth client (one time, about 5 minutes)

The app ships no shared credentials, so each user brings their own free
Google Cloud project.

1. Open [console.cloud.google.com](https://console.cloud.google.com/) and
   create a project.
2. Go to **APIs & Services → Library**, find **YouTube Data API v3** and
   click **Enable**.
3. Go to **APIs & Services → OAuth consent screen** and choose **External**.
   Fill in the app name and your email. Leave the app in **Testing** and add
   your own Google account under *Test users*.
   - **Don't click Publish app.** Every external production app needs a home
     page, a privacy policy link and a terms-of-service link on a domain you
     have verified in Search Console
     ([source](https://support.google.com/cloud/answer/10311615)), which a
     personal project has no way to supply.
   - Staying in *Testing* means Google expires the refresh token after
     **7 days**, so the sign-in has to be repeated about once a week. A
     Google account that is not a listed test user is refused with "Access
     blocked: … has not completed the Google verification process".
4. Go to **APIs & Services → Credentials → Create credentials → OAuth client
   ID**, and pick application type **Desktop app**. Copy the client secret
   right away — it is shown only at creation and cannot be downloaded again;
   if you lose it, use **Google Auth Platform → Clients →** your client
   **→ Add Secret**.
5. Run `like-current-song --setup` and choose `ytmusic`. Paste the client ID and
   secret when asked. A browser opens for the Google login, and the tokens are
   saved to `~/.like_spotify/youtube_token.json`.

Requested scopes: `youtube` and `openid`. `youtube` covers rating videos
plus the playlist and subscription writes the actions below need, so turning
those actions on needs no new login. `openid` gives a stable account id for
the cross-device counter.

## Playlist actions

The archive-remove, promote-to-best and follow-artist actions work under
this provider too. Turn them on the same way as for Spotify (the "Playlist
clean-up" step in `--setup`, or `actions.*` in `config.json`).

- **Playlists** are ordinary YouTube playlists on your account, the same
  ones YT Music lists under *Library → Playlists*. The playlist name is
  matched case-insensitively. Best creates its playlist as **private**
  if it doesn't exist yet.
- **Archive remove** takes the liked song out of the named playlist. The
  discard hotkey works as well, and under this provider it also thumbs the
  song down — both in one press, each independent of the other's failure.
- **Follow artist** means **subscribing to the artist's channel**, which
  is what YT Music's own "Subscribe" button on an artist page does. The
  channel is the one that uploaded the matched song, and only when that
  upload is the artist's own: the auto-generated "Artist - Topic" channel, or
  a channel named after the artist. If the match fell back to an unrelated
  uploader (a cover or a label compilation), the song counts toward no artist
  and no one is subscribed. That means you never end up subscribed to a
  stranger's channel.

If you installed with pip instead of the Windows installer, add the extra:

```bash
pip install "like-current-song[ytmusic]"
```

## Limits and caveats

- **Daily quota, in two buckets.** Since 1 June 2026 a project gets **100
  `search.list` calls a day** in a bucket of their own, plus **10,000 units a
  day** shared by every other endpoint. A like spends one search call to match
  the song and 50 units to rate it. The search bucket is what runs out first:
  about **100 new songs a day**, with the 10,000 units barely dented. Repeat
  presses on the same song reuse the match and spend no search call. When
  either bucket is empty the like fails with a rate-limit error until they
  reset at midnight Pacific time. A **dislike costs exactly the same**: it is
  the same `videos.rate` call, 50 units, on a song that had to be matched
  first.
- **Playlist actions spend quota too**, but only from the 10,000-unit pool,
  never from the search bucket. Each write costs about **50 units**: adding to
  best, removing from the archive, creating the best playlist once, and
  subscribing. Reading a playlist costs 1 unit per 50 songs. The archive is
  read once per session, and then only when the liked song is in it. A like
  that also triggers a write costs about 100 units instead of 50 — still far
  inside the pool. When quota runs out mid-action, the like itself has already
  happened and only the extra step is skipped (it is logged as rate-limited).
- **Matching is by title and artist.** Remixes, live versions and songs with
  very generic titles can match the wrong upload. The Topic preference gets
  most studio tracks right.
- **Any playing media session counts.** If Spotify and a YT Music tab both
  play at once, Windows' current session wins. Pause the one you don't mean.
- **Only playing sessions count.** A paused track is ignored, so there is
  nothing to like.
- **macOS / Linux:** not supported yet. Now-playing needs a different OS
  integration there (MPRIS on Linux). Contributions are welcome.
