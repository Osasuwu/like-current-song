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

## Setup: your own Google OAuth client (one time, about 5 minutes)

The app ships no shared credentials, so each user brings their own free
Google Cloud project.

1. Open [console.cloud.google.com](https://console.cloud.google.com/) and
   create a project.
2. Go to **APIs & Services → Library**, find **YouTube Data API v3** and
   click **Enable**.
3. Go to **APIs & Services → OAuth consent screen** and choose **External**.
   Fill in the app name and your email.
   - Add yourself under *Test users* if you are asked to.
   - Then click **Publish app** so it is *In production*. While the app is in
     *Testing*, Google expires the login after **7 days**. An unverified app
     in production just shows an "unverified app" warning on your own login,
     which you can click through.
4. Go to **APIs & Services → Credentials → Create credentials → OAuth client
   ID**, and pick application type **Desktop app**.
5. Run `like-current-song --setup` and choose `ytmusic`. Paste the client ID and
   secret when asked. A browser opens for the Google login, and the tokens are
   saved to `~/.like_spotify/youtube_token.json`.

Requested scopes: `youtube` and `openid`. `youtube` covers rating videos
plus the playlist and subscription writes the actions below need, so turning
those actions on needs no new login. `openid` gives a stable account id for
the cross-device counter.

## Playlist actions

The archive-remove, promote-to-best-of and follow-artist actions work under
this provider too. Turn them on the same way as for Spotify (the "Playlist
clean-up" step in `--setup`, or `actions.*` in `config.json`).

- **Playlists** are ordinary YouTube playlists on your account, the same
  ones YT Music lists under *Library → Playlists*. The playlist name is
  matched case-insensitively. Best-of creates its playlist as **private**
  if it doesn't exist yet.
- **Archive remove** takes the liked song out of the named playlist. The
  remove-without-like hotkey works as well.
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

- **Daily quota.** The free YouTube Data API quota is 10,000 units a day. A
  like costs about 150 units (search 100 + rate 50), which is roughly
  **65 likes a day**. Repeat presses on the same song reuse the match. When
  the quota runs out, the like fails with a rate-limit error until the quota
  resets at midnight Pacific time.
- **Playlist actions spend quota too.** Each write costs about **50
  units**: adding to best-of, removing from the archive, creating the best-of
  playlist once, and subscribing. Reading a playlist costs 1 unit per 50
  songs. The archive is read once per session, and then only when the liked
  song is in it. A like that also triggers a write costs about 200 units
  instead of 150. When quota runs out mid-action, the like itself has already
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
