# Like Current Song — save the Spotify song you're hearing without touching your phone

[![CI](https://github.com/Osasuwu/like-current-song/actions/workflows/ci.yml/badge.svg)](https://github.com/Osasuwu/like-current-song/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/Osasuwu/like-current-song)](https://github.com/Osasuwu/like-current-song/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Python 3.11+](https://img.shields.io/badge/python-3.11%2B-blue)](pyproject.toml)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](CONTRIBUTING.md)

Heard a song you love while your phone is in your pocket with the screen off? **Pause and resume it with your headphone button** (e.g. pause → play), and the track is saved to your Spotify **Liked Songs**. You don't unlock the phone, look at the screen, or open the Spotify app.

At your computer, a **global keyboard shortcut** does the same thing: press `Ctrl+Shift+Alt+W` while Spotify plays in the background, and the current song is liked without switching away from the app you're working in.

- **Android**: works with the screen off and the phone locked. It reacts to Spotify's pause/play state, so anything that pauses and resumes playback can trigger it: wired or Bluetooth headphones, earbud taps, a smartwatch, or a car stereo. The pattern is configurable, and a short sound confirms the like.
- **Windows**: a tray app with a global hotkey to like the current track, plus a second hotkey to remove it from a playlist.
- **macOS / Linux**: a `like-current-song like-once` command you can bind to any shortcut.
- **Beyond "like"** (optional rules): remove the track from a Discover Weekly archive playlist, promote it to a "best-of" playlist after you like it N times across devices, and auto-follow an artist after N liked tracks. Counters are stored in Supabase or Google Sheets, so your phone and computer see the same numbers.

Open source (MIT). It uses the official Spotify Web API with your own Spotify Developer app. There's no UI scraping, and your tokens stay on your devices.

For developers: the desktop side is a **pluggable framework** with five extension points (`Trigger`, `MusicProvider`, `Storage`, `PreLikeAction`, `PostLikeAction`) discovered from `manifest.json` folders. See [CONTRIBUTING.md](CONTRIBUTING.md).

## FAQ

### Can I like a Spotify song without unlocking my phone?
Yes, that's the main use case. Install the Android app, connect Spotify, and turn on the listener service. With the screen off, do the trigger pattern with your headphone button (default: pause, then play within a short window), and the current track goes to Liked Songs.

### Does it work with Bluetooth headphones, earbuds, or a smartwatch?
Yes. The app watches Spotify's playback state rather than one specific button, so any device that pauses and resumes Spotify works.

### Is there a global keyboard shortcut to like the current Spotify song on Windows?
Yes. The Windows tray host binds `Ctrl+Shift+Alt+W` (configurable) to "save current track to Liked Songs", and it works while Spotify is minimized or in the background. On macOS and Linux, bind `like-current-song like-once` to a shortcut in your OS settings, Raycast, skhd, or similar.

### Can it add the song to a playlist too, not only Liked Songs?
Yes, through the rule engine: it can promote a track to a "best-of" playlist after N likes and remove it from an archive playlist. New actions are small Python plugins.

### Does it work on iPhone?
No. iOS doesn't let third-party apps observe another app's playback in the background. Android and desktop only.

## По-русски

**Like Spotify** лайкает трек в Spotify, не доставая телефон: нажмите пауза → плей на наушниках, и песня попадёт в «Любимые треки», даже с выключенным экраном и заблокированным телефоном. Работает с любыми наушниками (проводными и Bluetooth), часами и магнитолой. На компьютере (Windows) то же самое делает глобальная горячая клавиша `Ctrl+Shift+Alt+W`, пока Spotify играет в фоне. Открытый исходный код, лицензия MIT.

## How it works

1. **Trigger** — pause-play your headset (Android) or press a hotkey (desktop)
2. **Like** — the current track is added to your Spotify Liked Songs
3. **Archive cleanup** — if the track is in your archive playlist, it gets removed
4. **Best-of promotion** — like a track 3 times across devices and it's added to your best-of playlist
5. **Artist follow** — like 5+ tracks from an artist and they get auto-followed

Steps 3–5 are optional and off until you set them up. On Android they live
under **Trigger configuration → Extra actions**.

## How it compares

Several desktop hotkey tools can like the current Spotify song. We haven't found another open-source project that does it **from a phone with the screen off**, or one that covers phone and desktop with shared rules. If you only need a Windows hotkey, the smaller tools below may fit you better.

| Project | One-press like | Headset trigger (phone) | Hotkey trigger (desktop) | Rule engine (archive/best-of/follow) | Cross-device counters | Pluggable | Use **theirs** when |
|---|---|---|---|---|---|---|---|
| **Like Spotify** (this) | ✓ | ✓ Android | ✓ Windows tray + mac/linux CLI | ✓ | ✓ Supabase / Sheets | ✓ 5 typed seams + manifest discovery | n/a |
| [Pano Scrobbler](https://github.com/kawaiiDango/pano-scrobbler) | partial (love via UI) | — (notification scrape) | — | — (scrobble target only) | — | provider seam only (write target) | you want **scrobbling history** to last.fm/listenbrainz/librefm/pleroma. Pano is the right answer for "where did my listens go" — we don't try to replace it. |
| [BeatBind](https://github.com/justinknguyen/BeatBind) | ✓ (save / remove) | — | ✓ Windows tray (.NET) | — | — | — | you want a polished **Windows-only** global-hotkey app for full playback control (play/pause, skip, volume, seek) as well as saving tracks. |
| [Spotikey](https://github.com/dannj90/Spotikey) | ✓ | — | ✓ Windows (`Ctrl+Alt+L`) | — | — | — | you want **only** a like hotkey, as a single small executable. |
| [SpotiLike-GUI](https://github.com/senuka-b/SpotiLike-GUI) | ✓ (to a playlist) | — | ✓ desktop (PyQt) | — | — | — | you want one hotkey per **target playlist** and a GUI to manage them. |
| [SpotifyHotKeys.ahk](https://github.com/rjmccallumbigl/SpotifyHotKeys.ahk) | ✓ (like / unlike) | — | ✓ Windows only (AutoHotKey) | — | — | — | you already live in AutoHotKey and want a small single-file script you can paste & edit. We're heavier (Python install) but cross-platform and rule-capable. |
| [Music Assistant](https://www.music-assistant.io/) | partial (per-provider) | — | via Home Assistant | extensive (queue / library / sync) | — (per-instance) | ✓ ~60 providers | you want **Home Assistant-grade music orchestration** — multi-provider library merging, multi-room sync, queue scripting. We don't try to be your music server; we sit next to your existing Spotify client. |
| [n8n](https://n8n.io/) / Zapier / IFTTT | only via polling | — | — | yes (general workflows) | yes (workflow vars) | ✓ generic | you want **a generic workflow engine** with a UI and 400+ integrations. We're the inverse — narrow to "like + post-like rules", but one button press and ~30 ms latency vs minutes of polling. |

## Quick start

### 1. Spotify Developer App

You run this against your own Spotify app, which stays in Spotify's
**development mode**. Since the February 2026 changes (in force for existing
integrations from 9 March 2026), that mode has three limits worth knowing
before you start — see
[quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes):

- **The owner needs Spotify Premium.** "The app owner must have a Spotify
  Premium account for apps in development mode to function." On a free
  account your own app does not work at all.
- **Five users, allowlisted by hand.** "Up to 5 authenticated Spotify users
  can use an app that is in development mode" (it was 25). Everyone counts,
  you included, and each one is added manually in the dashboard.
- **One development-mode app per developer.** "Developers will be limited to
  one Development Mode Client ID", so a single client ID has to serve your
  phone and your computer — which is how this project uses it anyway.

Extended quota mode is not an escape hatch for a project like this one: since
15 May 2025 Spotify only accepts applications from organizations, not
individuals, and expects at least 250k monthly active users.

1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
2. Create an app
3. Add redirect URIs:
   - `likespotify://auth-callback` (Android)
   - `http://127.0.0.1:8793/callback` (Desktop)
4. Open the app's **Settings → User Management** and add every Spotify
   account that will use it — your own included — by display name and the
   email on the account
5. Copy your Client ID

**If likes fail with 403 right after a successful login**, that is the
allowlist, not a bug here. An account that is not under *User Management* can
still complete the whole OAuth flow and look connected; the limit is enforced
on the API calls afterwards. Add the account, then reconnect in the app.

### 2. Android

```bash
# Clone and setup
git clone https://github.com/Osasuwu/like-current-song.git
cd like-current-song

# Configure
cp .env.example .env
# Edit .env — set SPOTIFY_CLIENT_ID (and optionally SUPABASE_URL/KEY)

# Build
flutter pub get
flutter build apk --release --dart-define-from-file=.env
```

Install the APK, connect Spotify in the app, enable the listener service.

#### YouTube Music (Android)

**YouTube Music (beta).** Pick YouTube Music under *Connected services*. The
trigger then gives the playing song a thumbs-up through the YT Music app's own
media session, so it works with the screen off and needs **no Google sign-in
at all** — only the notification access the listener already uses.

**Signing in is optional, and the rest of this section is only about that.**
It buys two things: a YouTube Data API fallback for when the session rating
doesn't take, and likes that count in the shared counter (the same one the
desktop app uses, keyed by your Google account, and only when Supabase is
configured). It also costs a re-sign-in about once a week — see step 3. If
that trade isn't worth it to you, stop here; the thumbs-up keeps working.

Counting looks a song up through the Data API the first time it is liked.
Since 1 June 2026 that lookup has its own budget: Google grants a project
**100 `search.list` calls a day**, separate from the **10,000 units a day**
shared by every other endpoint
([quota details](https://developers.google.com/youtube/v3/getting-started)).
So counting stops after about 100 *new* songs in a day while the 10,000-unit
pool is still almost untouched — the two run out independently. Repeats of a
song already looked up cost nothing. Past the limit, likes still work, they
just stop counting until the buckets reset at midnight Pacific time.

To sign in, you use your own Google OAuth client. Nothing goes in
`.env`: you enter the client in the app. It takes about 5 minutes, once.

1. Open [console.cloud.google.com](https://console.cloud.google.com/) and
   create a project. You can reuse the desktop one.
2. Go to **APIs & Services → Library**, find **YouTube Data API v3** and
   click **Enable**.
3. Go to **APIs & Services → OAuth consent screen** and choose **External**.
   Fill in the app name and your email. Leave the app in **Testing** and add
   your own Google account under *Test users*.
   - **Don't click Publish app.** Google requires a home page, a privacy
     policy link and a terms-of-service link for every external production
     app, each on a domain you have verified in Search Console: "These links
     are required for all external production apps. You will not be able to
     submit your app for verification if it is missing these links"
     ([source](https://support.google.com/cloud/answer/10311615)). Without
     them, Publish only gets you *"To publish your app, you must complete
     your configuration on the Branding page"*.
   - **The cost of staying in Testing**: Google expires the refresh token
     after **7 days**, so you have to repeat the sign-in (steps 6–7) roughly
     once a week. There is no way around it for the `youtube` scope — the
     7-day limit is waived only for the name/email/profile scopes.
   - A Google account that is *not* on the *Test users* list gets "Access
     blocked: … has not completed the Google verification process" instead of
     a consent screen. Add the account there first.
4. Go to **APIs & Services → Credentials → Create credentials → OAuth client
   ID**, and pick application type **TVs and Limited Input devices**. Other
   types (Android, Desktop app, Web) are rejected by the sign-in the app uses.
   **Copy the client secret straight away** — it is shown only once, when the
   client is created, and cannot be downloaded again. If you lose it, open
   **Google Auth Platform → Clients →** your client **→ Add Secret** and use
   the new secret instead.
5. In the app, open **Connected services**, pick **YouTube Music**, paste the
   client ID and secret, and tap **Save credentials**.
6. Tap **Connect YouTube Music**. The app shows a code and a link
   (`google.com/device`). Open the link on the phone or any other device, enter
   the code, and pick your Google account.
7. Google warns that the app isn't verified, because it is your own
   unreviewed project. Click **Advanced → Go to *app name* (unsafe)** and
   allow access. The app notices on its own and shows the account as
   connected.

Requested scopes: `youtube` (to rate videos) and `openid` (the account id shown
in the app). Tokens stay on the phone in encrypted storage, apart from
Spotify's, so switching services keeps both signed in. **Disconnect** signs out
of YouTube Music only and keeps the client ID and secret.

The opt-in **Extra actions** work under YouTube Music too: archive clean-up,
promote-to-best-of and follow-artist act on your ordinary YouTube playlists and
channel subscriptions. Each one spends about 50 units of the 10,000-unit daily
pool — the pool the song lookup above does *not* draw on — so a like with all
three enabled costs a couple of hundred units out of 10,000, and you would need
hundreds of likes in a day to exhaust it. A plain like costs none. The
`youtube` scope above already covers them, so there is nothing more to
authorise.

### 3. Desktop

The desktop side ships as a pluggable Python package (`like_spotify/`) —
a tray host + global hotkey on Windows, a CLI fallback (`like-once`) on
macOS / Linux, and a multi-backend counter Storage (Supabase or Google
Sheets).

**One-liner installs.** Run from a fresh clone:

```powershell
# Windows (PowerShell)
git clone https://github.com/Osasuwu/like-current-song.git
cd like-current-song
.\install.ps1
```

```bash
# macOS / Linux
git clone https://github.com/Osasuwu/like-current-song.git
cd like-current-song
./install.sh
```

The installer checks for Python 3.11+, installs `pipx` if missing,
installs the `like-current-song` package, then walks you through the
interactive setup wizard:

1. **Spotify** — paste a Client ID from
   [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
   (redirect URI: `http://127.0.0.1:8793/callback`); a browser opens
   for PKCE OAuth.
2. **Storage** — pick `supabase`, `sheets`, or `none` (likes work
   without a counter; you'd just lose cross-device aggregation).
3. **Autostart** — Windows: toggle the `HKCU\…\Run` entry. macOS /
   Linux: instructions for a Launch Agent / `.desktop` file are
   printed (no auto-config — too platform-fragmented).

The wizard is re-runnable; existing tokens are kept unless you pass
`--reauth` (or `-Reauth` on PowerShell).

**After install:**

```bash
like-current-song             # Windows: tray host with the hotkey (default Ctrl+Shift+Alt+W)
like-current-song like-once   # any OS: like the currently-playing track and exit
like-current-song remove-once # any OS: remove the current track from the archive playlist (no like)
like-current-song --config    # print config + token paths
like-current-song --settings  # open the settings window
```

**Upgrading from `like-spotify`.** The package and commands used to be
called `like-spotify` / `like-spotify-gui`. Re-run the installer: it
removes the old pipx package and installs `like-current-song`. Your config
and tokens in `~/.like_spotify/` stay where they are. The old command names
still work for now (the console one prints a short note), but they will be
removed in a future release, so update any scripts or hotkey tools. On
Windows, an autostart entry from the old version is moved to the new
launcher the next time the tray starts, or when `--setup` asks about
autostart.

**Settings window.** Everything the wizard asks, in one window instead of a
terminal: the music service and the account sign-in (the same browser flow
as `--setup`), the hotkeys, the sound volume (with a Test button), the like
counter storage, and autostart. The optional **Extra actions** (archive
clean-up, best-of, follow artist, like cooldown) sit in a collapsed
section, each with a one-line explanation. On a fresh install they all
start switched off. On Windows, open it from the tray menu (**Settings…**).
Saved changes apply right away, hotkeys included. If the new settings can't
run yet (for example, you switched service but haven't signed in), the tray
keeps the old ones and tells you why. If a change can't be applied live, it
offers to restart. From a terminal, run `like-current-song --settings` (or
`like-current-song-gui --settings`). It needs Tk: on Linux, install your
distro's `python3-tk` package. The window only edits the keys it knows, so
anything else you added to `config.json` by hand is kept as is.

`like-current-song` is a console-subsystem executable, so any of the above
briefly shows a terminal window. On Windows, a windowed twin is also
installed — `like-current-song-gui` — that runs the exact same commands with no
console at all. Autostart uses it automatically; if you trigger `like-once`
/ `remove-once` from an external hotkey tool (AutoHotkey, a macro app, a
Stream Deck, etc.), point it at `like-current-song-gui like-once` instead of
`like-current-song like-once` to avoid the flash. (`--setup` / `--config` still
need `like-current-song`, since they read from the terminal.)

On Windows the tray host also binds a **second** global hotkey (default
`Ctrl+Shift+Alt+Q`) that removes the currently-playing track from your
Discover-Weekly archive playlist **without liking it** — for tracks you
want gone but not in your Liked Songs. It's active only once you set an
archive playlist name in `--setup`; if it collides with the like hotkey
it's skipped. Audio feedback is audible through the default sound device
and distinct per action (like / remove / error).

**YouTube Music (beta, Windows).** Choose `ytmusic` at the "Music service"
prompt in `--setup`. The hotkey then likes the song playing in the YT Music
browser tab or desktop app, and it lands in YT Music's *Liked music*. You need
your own free Google OAuth client with the YouTube Data API enabled; the steps
are in [`extensions/ytmusic/README.md`](like_spotify/extensions/ytmusic/README.md).
The playlist actions (archive-remove, best-of, follow-artist) work there too.
Follow-artist subscribes to the artist's channel, and each playlist write
costs YouTube API quota (see that README).

**Single-file `.exe`** (for users without Python): build via
`tools\build.bat` → `dist\LikeSpotify.exe`.

### 4. Cross-device counters (optional)

Pick a backend during `--setup`:

#### Option A — Supabase (default; one SQL block)

Counters live in Supabase Postgres (free tier).

1. Create a Supabase project
2. Run the setup SQL:
   ```sql
   CREATE TABLE public.track_likes (
       user_id TEXT NOT NULL,
       track_id TEXT NOT NULL,
       count INTEGER NOT NULL DEFAULT 1,
       updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
       PRIMARY KEY (user_id, track_id)
   );

   CREATE OR REPLACE FUNCTION increment_track_like(p_user_id TEXT, p_track_id TEXT)
   RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER AS $$
   DECLARE new_count INTEGER;
   BEGIN
       INSERT INTO public.track_likes (user_id, track_id, count, updated_at)
       VALUES (p_user_id, p_track_id, 1, now())
       ON CONFLICT (user_id, track_id)
       DO UPDATE SET count = track_likes.count + 1, updated_at = now()
       RETURNING count INTO new_count;
       RETURN new_count;
   END; $$;

   ALTER TABLE public.track_likes ENABLE ROW LEVEL SECURITY;
   CREATE POLICY "anon_full_access" ON public.track_likes FOR ALL USING (true) WITH CHECK (true);
   ```
3. Android: add `SUPABASE_URL` and `SUPABASE_ANON_KEY` to `.env`. Desktop: paste both into the wizard when prompted for the `supabase` backend.

#### Option B — Google Sheets

If you'd rather see counts in a spreadsheet you control:

1. Create a Google Sheet with header row `user_id | track_id | count | backfilled | updated_at` on a tab named `Likes`. Optionally add an `ArtistTracks` tab for the follow-artist rule.
2. Create a Google Cloud OAuth client (type: **Desktop app**) at [console.cloud.google.com/apis/credentials](https://console.cloud.google.com/apis/credentials). Enable the Google Sheets API for the project. Note the Client ID + secret.
3. Run `like-current-song --setup`, pick `sheets`, paste the spreadsheet ID (from the URL), Client ID, and secret. A browser opens for Google authorization — tokens are refreshed automatically afterwards.

Without a backend, counters are silently skipped — likes still write to your Spotify Liked Songs.

## Architecture

```
Android (Flutter + Kotlin)          Desktop (Python framework)
┌──────────────────────┐           ┌──────────────────────────┐
│  MediaSession        │           │  Trigger (hotkey/tray)   │
│  pause-play pattern  │           │       ↓                  │
│       ↓              │           │  MusicProvider (Spotify) │
│  SpotifyLikeWorker   │           │  • like track            │
│  • like track        │           │  Storage  → #22          │
│  • remove from       │           │  PostLikeAction → #23/26 │
│    archive           │           │    · archive remove      │
│  • Supabase counter  │           │    · best-of promote     │
│  • best-of / follow  │           │    · artist follow       │
└──────┬───────────────┘           └──────┬───────────────────┘
       │                                  │
       └──────────┬───────────────────────┘
                  ↓
          Spotify Web API (shared state)
          Supabase (shared counters)
```

- `lib/` — Flutter app (Dart): UI, state management (Riverpod), Spotify OAuth
- `android/.../kotlin/` — Native Android: foreground service, MediaSession, background worker
- `like_spotify/` — Python desktop package: `core/` (ABCs), `hosts/` (tray runtime), `extensions/` (default Spotify provider + tray-hotkey trigger), `samples/` (alt-flavor examples)

## Configuration

Every desktop setting below except the token files can be changed in the
settings window (`like-current-song --settings`, or **Settings…** in the tray menu).

| Setting | Android | Desktop |
|---------|---------|---------|
| Trigger pattern / hotkey | In-app UI | `~/.like_spotify/config.json` → `trigger.hotkey` (default `Ctrl+Shift+Alt+W`) |
| Remove-from-archive hotkey | n/a (one trigger on headphones) | `~/.like_spotify/config.json` → `trigger.remove_hotkey` (default `Ctrl+Shift+Alt+Q`) |
| Archive playlist name | In-app UI | `~/.like_spotify/config.json` → `actions.archive_remove.playlist_name` (blank = archive-remove disabled) |
| Music service | In-app UI (Spotify / YouTube Music) | `~/.like_spotify/config.json` → `music.provider` (`spotify` / `ytmusic`, default `spotify`) |
| YouTube Music tokens | n/a (planned) | `~/.like_spotify/youtube_token.json` (refreshed automatically) |
| Spotify client_id | `.env` (`SPOTIFY_CLIENT_ID`) | `like-current-song --setup` → `~/.like_spotify/config.json` |
| Spotify tokens | `FlutterSecureStorage` | `~/.like_spotify/spotify_token.json` |
| Storage backend | (Supabase only) | `~/.like_spotify/config.json` → `storage.backend` (`supabase` / `sheets` / `none`) |
| Google Sheets tokens | n/a | `~/.like_spotify/google_token.json` (refreshed automatically) |
| Best-of / follow | In-app UI | `~/.like_spotify/config.json` → `actions.{promote_to_best_of,follow_artist}` |

## Contributing

Contributions are welcome — the desktop side is a plugin framework precisely so
that other people's triggers, providers, storages, and actions can live in it.

- [**CONTRIBUTING.md**](CONTRIBUTING.md) — repo layout, the five extension
  points with code, the add-an-extension checklist, and how to run the tests.
  It also lists what's known to be easy to land.
- [**Good first issues**](https://github.com/Osasuwu/like-current-song/labels/good%20first%20issue)
  · [**Help wanted**](https://github.com/Osasuwu/like-current-song/labels/help%20wanted)
- [**CODE_OF_CONDUCT.md**](CODE_OF_CONDUCT.md)
- [**SECURITY.md**](SECURITY.md) — please report vulnerabilities privately, not
  as a public issue.
- [**CHANGELOG.md**](CHANGELOG.md)

## License

[MIT](LICENSE)
