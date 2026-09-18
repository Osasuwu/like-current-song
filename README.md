# Like Spotify

[![CI](https://github.com/Osasuwu/like_spotify_mobile_app/actions/workflows/ci.yml/badge.svg)](https://github.com/Osasuwu/like_spotify_mobile_app/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/Osasuwu/like_spotify_mobile_app)](https://github.com/Osasuwu/like_spotify_mobile_app/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Python 3.11+](https://img.shields.io/badge/python-3.11%2B-blue)](pyproject.toml)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](CONTRIBUTING.md)

**One-button Spotify automation across your phone and laptop.** Like the currently-playing track with a headset pause-play pattern (Android) or a global keyboard hotkey (Windows tray; macOS / Linux CLI). On top of "like", a small rule engine runs per like: remove from an archive playlist (Discover Weekly clean-up), promote a track to a "best-of" playlist when you've liked it N times across devices, auto-follow an artist after N liked tracks. Counters live in Supabase or Google Sheets so phone + laptop see the same numbers.

The desktop side is a **pluggable framework**, not a single tool. Five extension points — `Trigger`, `MusicProvider`, `Storage`, `PreLikeAction`, `PostLikeAction` — discover at startup via a filesystem convention (each extension is a folder with a `manifest.json` and a `TRIGGER` / `MUSIC_PROVIDER` / `STORAGE` / `PRE_LIKE_ACTION` / `POST_LIKE_ACTION` factory). Drop a folder, restart, your code runs in the like pipeline. See [CONTRIBUTING.md](CONTRIBUTING.md) for the plugin-author guide.

Keywords for the search-engine crowd: spotify like hotkey, spotify automation, headset pause-play like, spotify scrobbler alternative, spotify plugin framework, cross-device like counter.

## How it works

1. **Trigger** — pause-play your headset (Android) or press a hotkey (desktop)
2. **Like** — the current track is added to your Spotify Liked Songs
3. **Archive cleanup** — if the track is in your archive playlist, it gets removed
4. **Best-of promotion** — like a track 3 times across devices and it's added to your best-of playlist
5. **Artist follow** — like 5+ tracks from an artist and they get auto-followed

## How it compares

There are several adjacent projects in this space; they solve overlapping problems but none solve all four of *one-press cross-device like + rule engine + headset-button trigger on phone + plugin framework on desktop*.

| Project | One-press like | Headset trigger (phone) | Hotkey trigger (desktop) | Rule engine (archive/best-of/follow) | Cross-device counters | Pluggable | Use **theirs** when |
|---|---|---|---|---|---|---|---|
| **Like Spotify** (this) | ✓ | ✓ Android | ✓ Windows tray + mac/linux CLI | ✓ | ✓ Supabase / Sheets | ✓ 5 typed seams + manifest discovery | n/a |
| [Pano Scrobbler](https://github.com/kawaiiDango/pano-scrobbler) | partial (love via UI) | — (notification scrape) | — | — (scrobble target only) | — | provider seam only (write target) | you want **scrobbling history** to last.fm/listenbrainz/librefm/pleroma. Pano is the right answer for "where did my listens go" — we don't try to replace it. |
| [SpotifyHotKeys.ahk](https://github.com/rjmccallumbigl/SpotifyHotKeys.ahk) | ✓ (like / unlike) | — | ✓ Windows only (AutoHotKey) | — | — | — | you already live in AutoHotKey and want a small single-file script you can paste & edit. We're heavier (Python install) but cross-platform and rule-capable. |
| [Music Assistant](https://www.music-assistant.io/) | partial (per-provider) | — | via Home Assistant | extensive (queue / library / sync) | — (per-instance) | ✓ ~60 providers | you want **Home Assistant-grade music orchestration** — multi-provider library merging, multi-room sync, queue scripting. We don't try to be your music server; we sit next to your existing Spotify client. |
| [n8n](https://n8n.io/) / Zapier / IFTTT | only via polling | — | — | yes (general workflows) | yes (workflow vars) | ✓ generic | you want **a generic workflow engine** with a UI and 400+ integrations. We're the inverse — narrow to "like + post-like rules", but one button press and ~30 ms latency vs minutes of polling. |

## Quick start

### 1. Spotify Developer App

1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
2. Create an app
3. Add redirect URIs:
   - `likespotify://auth-callback` (Android)
   - `http://127.0.0.1:8793/callback` (Desktop)
4. Copy your Client ID

### 2. Android

```bash
# Clone and setup
git clone https://github.com/Osasuwu/like_spotify_mobile_app.git
cd like_spotify_mobile_app

# Configure
cp .env.example .env
# Edit .env — set SPOTIFY_CLIENT_ID (and optionally SUPABASE_URL/KEY)

# Build
flutter pub get
flutter build apk --release --dart-define-from-file=.env
```

Install the APK, connect Spotify in the app, enable the listener service.

> **Play Protect / "restricted settings" block on install?** The app declares
> `BIND_NOTIFICATION_LISTENER_SERVICE` (needed for the notification-based
> playback fallback), which Android treats as sensitive for sideloaded APKs.
> On Android 13+, installing via a browser or file manager can get the app
> blocked or its settings greyed out. Fix: install with
> `adb install app-release.apk` (a trusted source, so the restriction doesn't
> apply), or after installing go to **Settings → Apps → Like Spotify → ⋮ (top
> right) → Allow restricted settings**, then enable notification access from
> the app's Permissions screen.

### 3. Desktop

The desktop side ships as a pluggable Python package (`like_spotify/`) —
a tray host + global hotkey on Windows, a CLI fallback (`like-once`) on
macOS / Linux, and a multi-backend counter Storage (Supabase or Google
Sheets).

**One-liner installs.** Run from a fresh clone:

```powershell
# Windows (PowerShell)
git clone https://github.com/Osasuwu/like_spotify_mobile_app.git
cd like_spotify_mobile_app
.\install.ps1
```

```bash
# macOS / Linux
git clone https://github.com/Osasuwu/like_spotify_mobile_app.git
cd like_spotify_mobile_app
./install.sh
```

The installer checks for Python 3.11+, installs `pipx` if missing,
installs the `like-spotify` package, then walks you through the
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
like-spotify            # Windows: tray host with the hotkey (default Ctrl+Shift+Alt+W)
like-spotify like-once  # any OS: like the currently-playing track and exit
like-spotify remove-once # any OS: remove the current track from the archive playlist (no like)
like-spotify --config   # print config + token paths
```

`like-spotify` is a console-subsystem executable, so any of the above
briefly shows a terminal window. On Windows, a windowed twin is also
installed — `like-spotify-gui` — that runs the exact same commands with no
console at all. Autostart uses it automatically; if you trigger `like-once`
/ `remove-once` from an external hotkey tool (AutoHotkey, a macro app, a
Stream Deck, etc.), point it at `like-spotify-gui like-once` instead of
`like-spotify like-once` to avoid the flash. (`--setup` / `--config` still
need `like-spotify`, since they read from the terminal.)

On Windows the tray host also binds a **second** global hotkey (default
`Ctrl+Shift+Alt+Q`) that removes the currently-playing track from your
Discover-Weekly archive playlist **without liking it** — for tracks you
want gone but not in your Liked Songs. It's active only once you set an
archive playlist name in `--setup`; if it collides with the like hotkey
it's skipped. Audio feedback is audible through the default sound device
and distinct per action (like / remove / error).

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
3. Run `like-spotify --setup`, pick `sheets`, paste the spreadsheet ID (from the URL), Client ID, and secret. A browser opens for Google authorization — tokens are refreshed automatically afterwards.

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

| Setting | Android | Desktop |
|---------|---------|---------|
| Trigger pattern / hotkey | In-app UI | `~/.like_spotify/config.json` → `trigger.hotkey` (default `Ctrl+Shift+Alt+W`) |
| Remove-from-archive hotkey | n/a (one trigger on headphones) | `~/.like_spotify/config.json` → `trigger.remove_hotkey` (default `Ctrl+Shift+Alt+Q`) |
| Archive playlist name | In-app UI | `~/.like_spotify/config.json` → `actions.archive_remove.playlist_name` (blank = archive-remove disabled) |
| Spotify client_id | `.env` (`SPOTIFY_CLIENT_ID`) | `like-spotify --setup` → `~/.like_spotify/config.json` |
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
- [**Good first issues**](https://github.com/Osasuwu/like_spotify_mobile_app/labels/good%20first%20issue)
  · [**Help wanted**](https://github.com/Osasuwu/like_spotify_mobile_app/labels/help%20wanted)
- [**CODE_OF_CONDUCT.md**](CODE_OF_CONDUCT.md)
- [**SECURITY.md**](SECURITY.md) — please report vulnerabilities privately, not
  as a public issue.
- [**CHANGELOG.md**](CHANGELOG.md)

## License

[MIT](LICENSE)
