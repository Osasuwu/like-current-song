# YouTube Music provider (beta)

Press the hotkey while a song plays in YouTube Music and it lands in your
**Liked music**. This works with the music.youtube.com tab in Chrome, Edge or
Firefox and with the YT Music desktop app.

- **Status:** beta. Desktop only, **Windows only** for now.
- **Selected by:** `music.provider = "ytmusic"` in `~/.like_spotify/config.json`,
  or the "Music service" prompt in `like-spotify --setup`.

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
5. Run `like-spotify --setup` and choose `ytmusic`. Paste the client ID and
   secret when asked. A browser opens for the Google login, and the tokens are
   saved to `~/.like_spotify/youtube_token.json`.

Requested scopes: `youtube` (to rate videos) and `openid` (for a stable
account id used by the cross-device counter).

If you installed with pip instead of the Windows installer, add the extra:

```bash
pip install "like-spotify[ytmusic]"
```

## Limits and caveats

- **Daily quota.** The free YouTube Data API quota is 10,000 units a day. A
  like costs about 150 units (search 100 + rate 50), which is roughly
  **65 likes a day**. Repeat presses on the same song reuse the match. When
  the quota runs out, the like fails with a rate-limit error until the quota
  resets at midnight Pacific time.
- **Matching is by title and artist.** Remixes, live versions and songs with
  very generic titles can match the wrong upload. The Topic preference gets
  most studio tracks right.
- **Any playing media session counts.** If Spotify and a YT Music tab both
  play at once, Windows' current session wins. Pause the one you don't mean.
- **Only playing sessions count.** A paused track is ignored, so there is
  nothing to like.
- **Playlist actions are Spotify-only.** Archive-remove, promote-to-best-of
  and follow-artist turn themselves off under this provider.
- **macOS / Linux:** not supported yet. Now-playing needs a different OS
  integration there (MPRIS on Linux). Contributions are welcome.
